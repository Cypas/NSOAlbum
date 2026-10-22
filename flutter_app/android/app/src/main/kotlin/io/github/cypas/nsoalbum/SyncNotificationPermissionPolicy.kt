package io.github.cypas.nsoalbum

internal object SyncNotificationPermissionPolicy {
    fun shouldRequest(
        sdkInt: Int,
        permissionGranted: Boolean,
        alreadyRequested: Boolean,
        anotherPermissionRequestInProgress: Boolean,
    ): Boolean =
        sdkInt >= 33 &&
            !permissionGranted &&
            !alreadyRequested &&
            !anotherPermissionRequestInProgress
}

internal class SyncNotificationPermissionCoordinator(
    private val sdkInt: Int,
    private val permissionGranted: () -> Boolean,
    private val alreadyRequested: () -> Boolean,
    private val markRequested: () -> Unit,
    private val requestPermission: () -> Unit,
    private val post: (String, String) -> Unit,
) {
    private var activeRequest: Int? = null
    private var pending: Pair<String, String>? = null
    private var closed = false

    fun beginExternalRequest(requestCode: Int): Boolean {
        if (closed || activeRequest != null) return false
        markRequested()
        activeRequest = requestCode
        return true
    }

    fun syncCompleted(title: String, body: String) {
        if (closed) return
        if (sdkInt < 33 || permissionGranted()) {
            pending = null
            post(title, body)
            return
        }
        // A permission prompt launched by either feature owns the shared
        // result. Retain one latest summary rather than prompting or dropping it.
        if (activeRequest != null) {
            pending = title to body
            return
        }
        if (!SyncNotificationPermissionPolicy.shouldRequest(
                sdkInt, false, alreadyRequested(), false,
            )) return
        pending = title to body
        activeRequest = SYNC_REQUEST_CODE
        try {
            markRequested()
            requestPermission()
        } catch (failure: Exception) {
            cancel(SYNC_REQUEST_CODE)
            throw failure
        }
    }

    fun complete(requestCode: Int) {
        if (closed || activeRequest != requestCode) return
        activeRequest = null
        val message = pending
        pending = null
        if (permissionGranted() && message != null) post(message.first, message.second)
    }

    fun cancel(requestCode: Int) {
        if (activeRequest != requestCode) return
        activeRequest = null
        pending = null
    }

    fun close() {
        closed = true
        activeRequest = null
        pending = null
    }

    companion object {
        const val SYNC_REQUEST_CODE = 9217
    }
}
