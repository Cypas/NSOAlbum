package io.github.cypas.nsoalbum

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.widget.Toast
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File
import java.util.Locale

class MainActivity : FlutterActivity() {
    companion object {
        const val ACTION_OPEN_GALLERY = "io.github.cypas.nsoalbum.OPEN_GALLERY"
        private const val EXTRA_OPEN_GALLERY = "open_gallery"
        private const val SHARE_AUTHORITY_SUFFIX = ".update_files"
        private const val SHARE_REQUEST_CODE = 7302
        private const val SHARE_CACHE_MAX_AGE_MS = 24 * 60 * 60 * 1000L
    }

    private var notificationPermissionResult: MethodChannel.Result? = null
    private var syncPermissionResult: MethodChannel.Result? = null
    private var deviceSyncSaf: DeviceSyncSafChannel? = null
    private var pendingOpenGallery = false
    private var pendingShare: PendingShare? = null

    private data class PendingShare(
        val result: MethodChannel.Result,
        val uris: List<Uri>,
        val directory: File,
    )
    private val syncNotificationPermissions by lazy {
        val preferences = getSharedPreferences("nsoalbum-notifications", MODE_PRIVATE)
        SyncNotificationPermissionCoordinator(
            sdkInt = Build.VERSION.SDK_INT,
            permissionGranted = {
                Build.VERSION.SDK_INT < 33 ||
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                        PackageManager.PERMISSION_GRANTED
            },
            alreadyRequested = {
                preferences.getBoolean("sync-permission-requested", false)
            },
            markRequested = {
                preferences.edit().putBoolean("sync-permission-requested", true).apply()
            },
            requestPermission = {
                requestPermissions(
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    SyncNotificationPermissionCoordinator.SYNC_REQUEST_CODE,
                )
            },
            post = { title, body -> postSyncNotification(title, body) },
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingOpenGallery = isGalleryIntent(intent)
        super.onCreate(savedInstanceState)
        handleUpdateNotification(intent)
    }

    override fun onNewIntent(intent: Intent) {
        setIntent(intent)
        if (isGalleryIntent(intent)) {
            pendingOpenGallery = true
        }
        super.onNewIntent(intent)
        notifyGalleryIntent()
        handleUpdateNotification(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SplatNetWebViewDisposal.register(flutterEngine)
        deviceSyncSaf?.close()
        deviceSyncSaf = DeviceSyncSafChannel(this, MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "io.github.cypas.nsoalbum/device_sync_saf"))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "io.github.cypas.nsoalbum/storage").setMethodCallHandler { call, result ->
            when (call.method) {
                "allFilesAccessStatus" -> {
                    try {
                        result.success(allFilesAccessStatus())
                    } catch (_: Exception) {
                        result.error("STORAGE_ACCESS_UNAVAILABLE", null, null)
                    }
                    return@setMethodCallHandler
                }
                "beginAllFilesAccessRequest" -> {
                    var ownsRequest = false
                    try {
                        val status = allFilesAccessStatus()
                        val automatic = call.argument<Boolean>("automatic") == true
                        if (status["supported"] != true || status["allowed"] == true ||
                            (automatic && status["requested"] == true)) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        ownsRequest = syncNotificationPermissions.beginStorageRequest()
                        if (!ownsRequest) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        // Persist before opening another Activity. This contains
                        // only consent-flow state, never a path or account.
                        val recorded = getSharedPreferences(
                            "nsoalbum-storage-permissions", MODE_PRIVATE,
                        ).edit().putBoolean("all-files-requested", true).commit()
                        if (!recorded) throw IllegalStateException("CONSENT_STATE_UNAVAILABLE")
                        result.success(true)
                    } catch (_: Exception) {
                        if (ownsRequest) {
                            runCatching { syncNotificationPermissions.completeStorageRequest() }
                        }
                        result.error("STORAGE_ACCESS_UNAVAILABLE", null, null)
                    }
                    return@setMethodCallHandler
                }
                "endAllFilesAccessRequest" -> {
                    try {
                        syncNotificationPermissions.completeStorageRequest()
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("STORAGE_ACCESS_UNAVAILABLE", null, null)
                    }
                    return@setMethodCallHandler
                }
            }
            if (call.method != "locations") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val locations = mutableListOf<Map<String, Any>>(
                mapOf("id" to "internal",
                    "path" to File(filesDir, "NSOAlbum/media").absolutePath,
                    "removable" to false))
            getExternalFilesDirs(null).filterNotNull().forEachIndexed { index, directory ->
                if (Environment.isExternalStorageRemovable(directory) &&
                    Environment.getExternalStorageState(directory) == Environment.MEDIA_MOUNTED) {
                    locations.add(mapOf("id" to "sd-$index",
                        "path" to File(directory, "NSOAlbum/media").absolutePath,
                        "removable" to true))
                }
            }
            result.success(locations)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "io.github.cypas.nsoalbum/update").setMethodCallHandler { call, result ->
            val updater = AndroidUpdateController.get(this)
            try {
                when (call.method) {
                    "status" -> result.success(updater.status())
                    "startDownload" -> result.success(updater.startDownload(
                        call.arguments as? Map<*, *> ?: throw AndroidUpdateException("INVALID_UPDATE")))
                    "install" -> updater.install(this) { error ->
                        if (error == null) result.success(null)
                        else result.error(error, updater.installErrorText(error), null)
                    }
                    "openInstallPermission" -> {
                        updater.openInstallPermission(this)
                        result.success(null)
                    }
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                                PackageManager.PERMISSION_GRANTED) {
                            if (!syncNotificationPermissions.beginExternalRequest(9216)) {
                                result.error("PERMISSION_REQUEST_BUSY", "A permission request is already open.", null)
                            } else {
                                notificationPermissionResult = result
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 9216)
                            }
                        } else result.success(updater.notificationAllowed())
                    }
                    else -> result.notImplemented()
                }
            } catch (failure: Exception) {
                if (notificationPermissionResult === result) {
                    notificationPermissionResult = null
                    syncNotificationPermissions.cancel(9216)
                }
                val code = when (failure) {
                    is AndroidUpdateException -> failure.code
                    is IllegalArgumentException -> if (failure.message == "VERSION_NOT_NEWER")
                        "VERSION_NOT_NEWER" else "INVALID_UPDATE"
                    else -> "UPDATE_UNAVAILABLE"
                }
                result.error(code, "The update operation could not be completed.", null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "io.github.cypas.nsoalbum/notifications").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "notificationPermissionStatus" ->
                        result.success(notificationPermissionStatus())
                    "requestSyncPermission" -> {
                        val status = notificationPermissionStatus()
                        if (status == "allowed" || status == "unavailable") {
                            result.success(status)
                        } else if (!syncNotificationPermissions.beginExternalRequest(
                                SyncNotificationPermissionCoordinator.SYNC_REQUEST_CODE)) {
                            result.error("PERMISSION_REQUEST_BUSY", "A permission request is already open.", null)
                        } else {
                            syncPermissionResult = result
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                SyncNotificationPermissionCoordinator.SYNC_REQUEST_CODE,
                            )
                        }
                    }
                    "openNotificationSettings" -> {
                        val intent = Intent(
                            android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS,
                        ).apply {
                            putExtra(
                                android.provider.Settings.EXTRA_APP_PACKAGE,
                                packageName,
                            )
                        }
                        startActivity(intent)
                        result.success(null)
                    }
                    "takePendingGalleryIntent" -> {
                        val pending = pendingOpenGallery
                        pendingOpenGallery = false
                        result.success(pending)
                    }
                    "acknowledgeGalleryIntent" -> {
                        pendingOpenGallery = false
                        result.success(null)
                    }
                    "syncCompleted" -> {
                        val args = call.arguments as? Map<*, *>
                            ?: throw IllegalArgumentException("INVALID_NOTIFICATION")
                        syncNotificationPermissions.syncCompleted(
                            title = (args["title"] as? String) ?: "鱿型相册 · 自动同步完成",
                            body = (args["body"] as? String) ?: "",
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (failure: Exception) {
                result.error("NOTIFICATION_FAILED", null, null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "io.github.cypas.nsoalbum/share").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "shareMedia" -> shareMedia(call.arguments, result)
                    else -> result.notImplemented()
                }
            } catch (failure: Exception) {
                result.error("SHARE_FAILED", "The media could not be shared.", null)
            }
        }
    }

    private fun postSyncNotification(
        title: String,
        body: String,
    ) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED) return
        val manager = getSystemService(NotificationManager::class.java)
        val channelId = "sync-completed"
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    "同步完成 / Sync completed",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, channelId)
        } else {
            Notification.Builder(this)
        }
        val openGallery = Intent(this, MainActivity::class.java).apply {
            action = ACTION_OPEN_GALLERY
            putExtra(EXTRA_OPEN_GALLERY, true)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = android.app.PendingIntent.getActivity(
            this,
            7301,
            openGallery,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE,
        )
        manager.notify(
            7301,
            builder.setSmallIcon(applicationInfo.icon)
                .setContentTitle(title)
                .setContentText(body)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build(),
        )
    }

    private fun isGalleryIntent(intent: Intent?): Boolean =
        intent?.action == ACTION_OPEN_GALLERY &&
            intent.getBooleanExtra(EXTRA_OPEN_GALLERY, false)

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 9216) {
            notificationPermissionResult?.success(AndroidUpdateController.get(this).notificationAllowed())
            notificationPermissionResult = null
        }
        if (requestCode == SyncNotificationPermissionCoordinator.SYNC_REQUEST_CODE) {
            syncPermissionResult?.success(notificationPermissionStatus())
            syncPermissionResult = null
        }
        if (requestCode == 9216 ||
            requestCode == SyncNotificationPermissionCoordinator.SYNC_REQUEST_CODE) {
            try {
                syncNotificationPermissions.complete(requestCode)
            } catch (_: Exception) {
                android.util.Log.w("NSOAlbum",
                    "[sync] stage=notification_failed reason=system_delivery_failed")
            }
        }
    }

    private fun notificationPermissionStatus(): String {
        val notifications = getSystemService(NotificationManager::class.java)
        val syncChannel = if (Build.VERSION.SDK_INT >= 26) {
            notifications.getNotificationChannel("sync-completed")
        } else {
            null
        }
        val systemEnabled = notifications.areNotificationsEnabled() &&
            (syncChannel == null ||
                syncChannel.importance != NotificationManager.IMPORTANCE_NONE)
        if (Build.VERSION.SDK_INT < 33) {
            return if (systemEnabled) {
                "allowed"
            } else {
                "blocked"
            }
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED &&
            systemEnabled) {
            return "allowed"
        }
        val preferences = getSharedPreferences("nsoalbum-notifications", MODE_PRIVATE)
        if (!preferences.getBoolean("sync-permission-requested", false) ||
            shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
            return "requestable"
        }
        return "blocked"
    }

    private fun allFilesAccessStatus(): Map<String, Boolean> = mapOf(
        "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R),
        "allowed" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            Environment.isExternalStorageManager()),
        "requested" to getSharedPreferences(
            "nsoalbum-storage-permissions", MODE_PRIVATE,
        ).getBoolean("all-files-requested", false),
    )

    private fun handleUpdateNotification(intent: Intent?) {
        val updater = AndroidUpdateController.get(this)
        if (!updater.isInstallNotification(intent)) return
        // Clear the action so an Activity recreation never repeats an installation request.
        intent?.action = null
        updater.install(this) { error ->
            if (error != null) Toast.makeText(
                this, updater.installErrorText(error), Toast.LENGTH_LONG).show()
        }
    }

    override fun onDestroy() {
        deviceSyncSaf?.close()
        deviceSyncSaf = null
        pendingShare?.let { share ->
            pendingShare = null
            share.uris.forEach {
                revokeUriPermission(it, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            share.directory.deleteRecursively()
        }
        syncNotificationPermissions.close()
        notificationPermissionResult?.success(false)
        notificationPermissionResult = null
        syncPermissionResult?.success("blocked")
        syncPermissionResult = null
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (deviceSyncSaf?.onActivityResult(requestCode, resultCode, data) == true) return
        if (requestCode == SHARE_REQUEST_CODE) {
            finishShare()
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun finishShare() {
        val share = pendingShare ?: return
        pendingShare = null
        share.uris.forEach { revokeUriPermission(it, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        share.directory.deleteRecursively()
        share.result.success(null)
    }

    private fun shareMedia(arguments: Any?, result: MethodChannel.Result) {
        if (pendingShare != null) {
            result.error("SHARE_BUSY", "A media share is already open.", null)
            return
        }
        val args = arguments as? Map<*, *>
            ?: throw IllegalArgumentException("INVALID_SHARE")
        val paths = (args["paths"] as? List<*>)
            ?.mapNotNull { it as? String }
            ?.map(String::trim)
            ?.filter(String::isNotEmpty)
            ?: throw IllegalArgumentException("INVALID_SHARE")
        if (paths.isEmpty()) throw IllegalArgumentException("INVALID_SHARE")
        val root = File(cacheDir, "nsoalbum-share")
        if (!root.exists() && !root.mkdirs()) {
            throw IllegalStateException("SHARE_CACHE_UNAVAILABLE")
        }
        root.listFiles()?.filter {
            it.isDirectory && System.currentTimeMillis() - it.lastModified() > SHARE_CACHE_MAX_AGE_MS
        }?.forEach(File::deleteRecursively)
        val session = File(root, "share-${System.currentTimeMillis()}-${android.os.Process.myPid()}")
        if (!session.mkdirs() && !session.isDirectory) {
            throw IllegalStateException("SHARE_CACHE_UNAVAILABLE")
        }
        val uris = mutableListOf<Uri>()
        try {
            paths.forEachIndexed { index, path ->
                val source = File(path)
                if (!source.isFile) throw IllegalArgumentException("SHARE_FILE_UNAVAILABLE")
                val target = File(session, "$index-${source.name}")
                source.copyTo(target, overwrite = false)
                uris += FileProvider.getUriForFile(
                    this,
                    "${applicationContext.packageName}$SHARE_AUTHORITY_SUFFIX",
                    target,
                )
            }
            val mimeTypes = paths.map(::mimeTypeFor).toSet()
            val share = Intent(
                if (uris.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE,
            ).apply {
                type = if (mimeTypes.size == 1) mimeTypes.single() else "*/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newRawUri("media", uris.first()).also { clip ->
                    uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
                }
                if (uris.size == 1) putExtra(Intent.EXTRA_STREAM, uris.first())
                else putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
            }
            val launch = Intent.createChooser(share, getString(R.string.app_name)).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            pendingShare = PendingShare(result, uris, session)
            startActivityForResult(launch, SHARE_REQUEST_CODE)
        } catch (failure: ActivityNotFoundException) {
            pendingShare = null
            uris.forEach { revokeUriPermission(it, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            session.deleteRecursively()
            result.error("SHARE_UNAVAILABLE", "No compatible sharing app was found.", null)
        } catch (failure: Exception) {
            pendingShare = null
            uris.forEach { revokeUriPermission(it, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            session.deleteRecursively()
            throw failure
        }
    }

    private fun mimeTypeFor(path: String): String {
        val extension = path.substringAfterLast('.', "").lowercase(Locale.ROOT)
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "*/*"
    }

    private fun notifyGalleryIntent() {
        if (!pendingOpenGallery) return
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        MethodChannel(
            messenger,
            "io.github.cypas.nsoalbum/notifications",
        ).invokeMethod("openGallery", null)
    }

}
