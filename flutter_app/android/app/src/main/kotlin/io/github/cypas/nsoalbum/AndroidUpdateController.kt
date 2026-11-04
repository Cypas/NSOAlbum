package io.github.cypas.nsoalbum

import android.Manifest
import android.app.Activity
import android.app.DownloadManager
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

internal class AndroidUpdateController private constructor(private val context: Context) {
    private val preferences = context.getSharedPreferences("android_update", Context.MODE_PRIVATE)
    private val downloads = context.getSystemService(DownloadManager::class.java)
    private val jobs = context.getSystemService(JobScheduler::class.java)
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var verificationRunning = false
    private var verificationJobRunning = false
    private var verificationCancellation: AndroidUpdateCancellation? = null
    private var installationRunning = false

    fun status(): Map<String, Any?> = synchronized(lock) {
        refreshLocked()
        snapshotLocked()
    }

    fun startDownload(arguments: Map<*, *>): Map<String, Any?> = synchronized(lock) {
        val spec = AndroidUpdatePolicy.parse(arguments, installedVersion())
        val oldSpec = savedSpec()
        if (oldSpec == spec && state() in setOf("downloading", "verifying", "ready")) {
            refreshLocked()
            return@synchronized snapshotLocked()
        }
        if (verificationRunning || verificationJobRunning || installationRunning) {
            throw AndroidUpdateException("UPDATE_BUSY")
        }
        removeOldDownloadLocked()
        val externalRoot = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: throw AndroidUpdateException("STORAGE_UNAVAILABLE")
        val directory = File(externalRoot, "updates")
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw AndroidUpdateException("STORAGE_UNAVAILABLE")
        }
        val destination = File(directory, "${spec.sha256}.apk")
        if (destination.exists() && !destination.delete()) {
            throw AndroidUpdateException("STORAGE_UNAVAILABLE")
        }
        val request = DownloadManager.Request(Uri.parse(spec.url))
            .setTitle(title(spec))
            .setDescription(text(spec, "Downloading APK", "\u6b63\u5728\u4e0b\u8f7d APK"))
            .setMimeType("application/vnd.android.package-archive")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(false)
            .setDestinationInExternalFilesDir(
                context, Environment.DIRECTORY_DOWNLOADS, "updates/${spec.sha256}.apk")
            .addRequestHeader("User-Agent", spec.userAgent)
        // Metadata is durable before enqueue; receiver/status only trust this app's saved ID.
        if (!preferences.edit().clear()
                .putString("version", spec.version)
                .putString("url", spec.url)
                .putString("sha256", spec.sha256)
                .putLong("size", spec.size)
                .putString("userAgent", spec.userAgent)
                .putString("language", spec.language)
                .putString("nonce", UUID.randomUUID().toString())
                .putString("state", "downloading")
                .commit()) {
            throw AndroidUpdateException("STORAGE_UNAVAILABLE")
        }
        try {
            val id = downloads.enqueue(request)
            if (!preferences.edit().putLong("downloadId", id).commit()) {
                downloads.remove(id)
                failLocked("STORAGE_UNAVAILABLE")
            }
        } catch (_: Exception) {
            failLocked("DOWNLOAD_FAILED")
        }
        snapshotLocked()
    }

    fun onDownloadComplete(id: Long) {
        synchronized(lock) {
            if (id <= 0 || id != preferences.getLong("downloadId", -1)) return
            // Only query durable DownloadManager metadata and enqueue a JobService
            // here. The receiver must return before Android's broadcast deadline.
            refreshLocked()
        }
    }

    fun notificationAllowed(): Boolean =
        (Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED) && notifications.areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < 26 ||
                notifications.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)

    fun install(activity: Activity, result: (String?) -> Unit) {
        val spec = synchronized(lock) {
            refreshLocked()
            if (installationRunning) {
                result("UPDATE_BUSY")
                return
            }
            if (state() != "ready") {
                result("UPDATE_NOT_READY")
                return
            }
            savedSpec()
        } ?: run {
            result("INVALID_UPDATE")
            return
        }
        if (Build.VERSION.SDK_INT >= 26 && !context.packageManager.canRequestPackageInstalls()) {
            try {
                openInstallPermission(activity)
                result("INSTALL_PERMISSION_REQUIRED")
            } catch (_: Exception) {
                result("INSTALL_UNAVAILABLE")
            }
            return
        }
        synchronized(lock) { installationRunning = true }
        executor.execute {
            val error = try {
                val file = privateFile(spec)
                AndroidApkVerifier.validate(context, file, spec)
                null
            } catch (failure: Exception) {
                failureCode(failure)
            }
            mainHandler.post {
                try {
                    if (activity.isFinishing || activity.isDestroyed) {
                        result("INSTALL_UNAVAILABLE")
                    } else if (error != null) {
                        synchronized(lock) { failLocked(error) }
                        result(error)
                    } else {
                        try {
                            synchronized(lock) {
                                // A new update cannot replace the selected artifact while validation runs.
                                if (state() != "ready" || savedSpec() != spec) {
                                    throw AndroidUpdateException("UPDATE_NOT_READY")
                                }
                                val uri = FileProvider.getUriForFile(
                                    context, "${context.packageName}.update_files", privateFile(spec))
                                @Suppress("DEPRECATION")
                                val intent = Intent(Intent.ACTION_INSTALL_PACKAGE)
                                    .setDataAndType(uri, "application/vnd.android.package-archive")
                                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                intent.clipData = ClipData.newRawUri("APK", uri)
                                activity.startActivity(intent)
                            }
                            result(null)
                        } catch (failure: Exception) {
                            result(if (failure is AndroidUpdateException) failure.code else "INSTALL_UNAVAILABLE")
                        }
                    }
                } finally {
                    synchronized(lock) { installationRunning = false }
                }
            }
        }
    }

    fun openInstallPermission(activity: Activity) {
        if (Build.VERSION.SDK_INT >= 26) {
            activity.startActivity(Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")))
        }
    }

    internal fun startScheduledVerification(onFinished: (Boolean) -> Unit) {
        val cancellation: AndroidUpdateCancellation
        synchronized(lock) {
            if (verificationJobRunning) {
                onFinished(true)
                return
            }
            if (state() != "verifying") {
                onFinished(false)
                return
            }
            verificationJobRunning = true
            cancellation = AndroidUpdateCancellation()
            verificationCancellation = cancellation
        }
        executor.execute {
            val retry = try {
                verifyDownloaded(cancellation)
            } catch (_: Exception) {
                synchronized(lock) {
                    if (state() == "verifying") failLocked("DOWNLOAD_FAILED")
                }
                false
            } finally {
                synchronized(lock) {
                    verificationJobRunning = false
                    verificationCancellation = null
                }
            }
            onFinished(retry)
        }
    }

    internal fun stopScheduledVerification() {
        synchronized(lock) {
            verificationCancellation?.cancel()
        }
    }

    internal fun verificationNeedsRetry(): Boolean = synchronized(lock) {
        state() == "verifying"
    }

    fun isInstallNotification(intent: Intent?): Boolean = synchronized(lock) {
        intent != null && intent.action == INSTALL_ACTION && state() == "ready" &&
            intent.getStringExtra("updateNonce") == preferences.getString("nonce", null) &&
            intent.getLongExtra("downloadId", -1) == preferences.getLong("downloadId", -2) &&
            intent.data?.toString() == "nsoalbum-update://install/${preferences.getString("nonce", "")}"
    }

    fun installErrorText(code: String): String {
        val spec = synchronized(lock) { savedSpec() }
        return if (code == "INSTALL_PERMISSION_REQUIRED") {
            if (spec?.language == "zh")
                "\u8bf7\u5141\u8bb8\u6b64\u5e94\u7528\u5b89\u88c5\u66f4\u65b0\uff0c\u7136\u540e\u518d\u6b21\u70b9\u51fb\u5b89\u88c5\u3002"
            else "Allow installation from this app, then tap Install again."
        } else {
            if (spec?.language == "zh") "\u65e0\u6cd5\u5b89\u88c5\u66f4\u65b0\uff0c\u8bf7\u5728\u5e94\u7528\u5185\u91cd\u8bd5\u3002"
            else "Could not install the update. Retry from the app."
        }
    }

    private fun refreshLocked(scheduleVerification: Boolean = true) {
        if (state() == "idle" || state() == "failed") return
        val spec = savedSpec()
        if (spec == null) {
            removeOldDownloadLocked()
            preferences.edit().clear().commit()
            return
        }
        if (state() == "ready") {
            if (!privateFile(spec).isFile) failLocked("DOWNLOAD_MISSING")
            else if (!preferences.getBoolean("notificationPosted", false)) {
                runCatching { downloads.remove(preferences.getLong("downloadId", -1)) }
                postReadyNotificationLocked(spec, preferences.getLong("downloadId", -1))
            }
            return
        }
        val id = preferences.getLong("downloadId", -1)
        if (id <= 0) {
            failLocked("DOWNLOAD_MISSING")
            return
        }
        try {
            downloads.query(DownloadManager.Query().setFilterById(id)).use { cursor ->
                if (cursor == null || !cursor.moveToFirst()) {
                    failLocked("DOWNLOAD_MISSING")
                    return
                }
                val received = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                val total = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                preferences.edit().putLong("received", received.coerceAtLeast(0))
                    .putLong("total", if (total > 0) total else spec.size).apply()
                if (received > spec.size || total > spec.size ||
                    received > AndroidUpdatePolicy.MAX_SIZE || total > AndroidUpdatePolicy.MAX_SIZE) {
                    failLocked("DOWNLOAD_TOO_LARGE")
                    return
                }
                when (cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))) {
                    DownloadManager.STATUS_SUCCESSFUL -> {
                        preferences.edit().putString("state", "verifying").commit()
                        if (scheduleVerification) scheduleVerificationLocked()
                    }
                    DownloadManager.STATUS_FAILED -> failLocked("DOWNLOAD_FAILED")
                    else -> preferences.edit().putString("state", "downloading").apply()
                }
            }
        } catch (_: Exception) {
            failLocked("DOWNLOAD_FAILED")
        }
    }

    private fun scheduleVerificationLocked() {
        if (state() != "verifying" || verificationJobRunning) return
        val pending = jobs.getPendingJob(JOB_ID)
        if (pending != null) return
        val scheduled = jobs.schedule(
            JobInfo.Builder(JOB_ID, ComponentName(context, AndroidUpdateJobService::class.java))
                .setBackoffCriteria(30_000L, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
                .build(),
        )
        if (scheduled != JobScheduler.RESULT_SUCCESS) {
            failLocked("VERIFICATION_UNAVAILABLE")
        }
    }

    private fun verifyDownloaded(cancellation: AndroidUpdateCancellation): Boolean {
        val spec: AndroidUpdateSpec
        val id: Long
        synchronized(lock) {
            if (state() != "verifying") return false
            spec = savedSpec() ?: run {
                failLocked("INVALID_UPDATE")
                return false
            }
            id = preferences.getLong("downloadId", -1)
            verificationRunning = true
        }
        var temporary: File? = null
        try {
            val directory = File(context.filesDir, "updates")
            if (!directory.isDirectory && !directory.mkdirs()) {
                throw AndroidUpdateException("STORAGE_UNAVAILABLE")
            }
            temporary = File(directory, "${spec.sha256}.part")
            downloads.openDownloadedFile(id).use { descriptor ->
                android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
                    temporary.outputStream().buffered().use { output ->
                        AndroidUpdateFiles.copyVerified(input, output, spec, cancellation)
                    }
                }
            }
            cancellation.throwIfCanceled()
            AndroidApkVerifier.validate(context, temporary, spec)
            val destination = privateFile(spec)
            if (destination.exists() && !destination.delete()) {
                throw AndroidUpdateException("STORAGE_UNAVAILABLE")
            }
            if (!temporary.renameTo(destination)) throw AndroidUpdateException("STORAGE_UNAVAILABLE")
            synchronized(lock) {
                if (state() != "verifying" ||
                    preferences.getLong("downloadId", -1) != id || savedSpec() != spec) {
                    destination.delete()
                    return false
                }
                if (!preferences.edit().putString("state", "ready")
                        .putLong("received", spec.size).putLong("total", spec.size)
                        .remove("error").commit()) {
                    throw AndroidUpdateException("STORAGE_UNAVAILABLE")
                }
                runCatching { downloads.remove(id) }
                postReadyNotificationLocked(spec, id)
            }
            return false
        } catch (failure: Exception) {
            synchronized(lock) {
                if (failure is AndroidUpdateException &&
                    failure.code == "VERIFICATION_INTERRUPTED") {
                    // Leave verifying metadata intact so JobScheduler can retry.
                    return true
                }
                if (preferences.getLong("downloadId", -1) == id) failLocked(failureCode(failure))
            }
            return false
        } finally {
            temporary?.delete()
            synchronized(lock) { verificationRunning = false }
        }
    }

    private fun postReadyNotificationLocked(spec: AndroidUpdateSpec, id: Long) {
        // Notification failures must never invalidate an already verified private APK.
        runCatching { postReadyNotification(spec, id) }
    }

    private fun postReadyNotification(spec: AndroidUpdateSpec, id: Long) {
        ensureNotificationChannel(spec)
        if (!notificationAllowed()) return
        val nonce = preferences.getString("nonce", "") ?: ""
        val intent = Intent(context, MainActivity::class.java)
            .setAction(INSTALL_ACTION)
            .setData(Uri.parse("nsoalbum-update://install/$nonce"))
            .putExtra("updateNonce", nonce)
            .putExtra("downloadId", id)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(context, NOTIFICATION_ID, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL)
            else Notification.Builder(context)
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(title(spec))
            .setContentText(text(spec, "APK downloaded. Tap to install.",
                "APK \u4e0b\u8f7d\u5b8c\u6210\uff0c\u70b9\u51fb\u5b89\u88c5\u3002"))
            .setContentIntent(pending)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .build()
        try {
            notifications.notify(NOTIFICATION_ID, notification)
            preferences.edit().putBoolean("notificationPosted", true).apply()
        } catch (_: SecurityException) {
            // Ready state and the in-app installer do not depend on notification permission.
        }
    }

    private fun ensureNotificationChannel(spec: AndroidUpdateSpec) {
        if (Build.VERSION.SDK_INT >= 26) {
            notifications.createNotificationChannel(NotificationChannel(
                CHANNEL, text(spec, "App updates", "\u5e94\u7528\u66f4\u65b0"), NotificationManager.IMPORTANCE_DEFAULT))
        }
    }

    private fun savedSpec(): AndroidUpdateSpec? = try {
        AndroidUpdatePolicy.parse(mapOf(
            "version" to preferences.getString("version", null),
            "url" to preferences.getString("url", null),
            "sha256" to preferences.getString("sha256", null),
            "size" to preferences.getLong("size", 0),
            "userAgent" to preferences.getString("userAgent", null),
            "language" to preferences.getString("language", null),
        ), installedVersion())
    } catch (_: Exception) { null }

    @Suppress("DEPRECATION")
    private fun installedVersion(): String =
        context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: ""

    private fun privateFile(spec: AndroidUpdateSpec) = File(context.filesDir, "updates/${spec.sha256}.apk")
    private fun state() = preferences.getString("state", "idle") ?: "idle"
    private fun snapshotLocked(): Map<String, Any?> = mapOf(
        "state" to state(),
        "version" to preferences.getString("version", null),
        "received" to preferences.getLong("received", 0),
        "total" to preferences.getLong("total", preferences.getLong("size", 0)),
        "error" to preferences.getString("error", null),
        "notificationAllowed" to notificationAllowed(),
    )

    private fun failLocked(code: String) {
        preferences.edit().putString("state", "failed").putString("error", code).commit()
        val id = preferences.getLong("downloadId", -1)
        if (id > 0) runCatching { downloads.remove(id) }
        if (!verificationJobRunning) runCatching { jobs.cancel(JOB_ID) }
        deleteSavedPrivateFilesLocked()
        notifications.cancel(NOTIFICATION_ID)
    }

    private fun removeOldDownloadLocked() {
        val id = preferences.getLong("downloadId", -1)
        if (id > 0) runCatching { downloads.remove(id) }
        runCatching { jobs.cancel(JOB_ID) }
        verificationCancellation?.cancel()
        deleteSavedPrivateFilesLocked()
        notifications.cancel(NOTIFICATION_ID)
    }

    private fun deleteSavedPrivateFilesLocked() {
        val hash = preferences.getString("sha256", null) ?: return
        if (!Regex("[0-9a-f]{64}").matches(hash)) return
        File(context.filesDir, "updates/$hash.apk").delete()
        File(context.filesDir, "updates/$hash.part").delete()
    }

    private fun title(spec: AndroidUpdateSpec) =
        "${text(spec, "NSOAlbum", "\u9c7f\u578b\u76f8\u518c")} ${spec.version}"
    private fun text(spec: AndroidUpdateSpec, english: String, chinese: String) =
        if (spec.language == "zh") chinese else english
    private fun failureCode(failure: Exception) =
        if (failure is AndroidUpdateException) failure.code else "INVALID_APK"

    companion object {
        const val INSTALL_ACTION = "io.github.cypas.nsoalbum.INSTALL_UPDATE"
        const val JOB_ID = 0x4e534f
        private const val CHANNEL = "io.github.cypas.nsoalbum/update"
        private const val NOTIFICATION_ID = 9216
        private val executor = Executors.newSingleThreadExecutor()
        @Volatile private var instance: AndroidUpdateController? = null
        fun get(context: Context): AndroidUpdateController = instance ?: synchronized(this) {
            instance ?: AndroidUpdateController(context.applicationContext).also { instance = it }
        }
    }
}
