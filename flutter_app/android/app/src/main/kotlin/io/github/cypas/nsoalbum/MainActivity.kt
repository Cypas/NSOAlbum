package io.github.cypas.nsoalbum

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.widget.Toast
import java.io.File

class MainActivity : FlutterActivity() {
    private var notificationPermissionResult: MethodChannel.Result? = null
    private var deviceSyncSaf: DeviceSyncSafChannel? = null
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
        super.onCreate(savedInstanceState)
        handleUpdateNotification(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
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
            if (call.method != "syncCompleted") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val args = call.arguments as? Map<*, *> ?: throw IllegalArgumentException("INVALID_NOTIFICATION")
                syncNotificationPermissions.syncCompleted(
                    title = (args["title"] as? String) ?: "鱿型相册 · 自动同步完成",
                    body = (args["body"] as? String) ?: "",
                )
                result.success(null)
            } catch (failure: Exception) {
                result.error("NOTIFICATION_FAILED", null, null)
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
        manager.notify(
            7301,
            builder.setSmallIcon(applicationInfo.icon)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .build(),
        )
    }

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
        syncNotificationPermissions.close()
        notificationPermissionResult?.success(false)
        notificationPermissionResult = null
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (deviceSyncSaf?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
