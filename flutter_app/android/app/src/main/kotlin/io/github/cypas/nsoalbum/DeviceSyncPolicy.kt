package io.github.cypas.nsoalbum

import java.io.InputStream
import java.io.OutputStream
import java.io.Closeable

internal object DeviceSyncPolicy {
    const val MAX_BLOCK = 65548
    const val MAX_ENTRIES = 128
    private val idPattern = Regex("[0-9a-f]{32}")
    fun sessionDirectory(id: String): String {
        require(idPattern.matches(id)) { "INVALID_SCOPE" }
        return "s-$id"
    }
    fun exactTree(authority: String?, id: String): Boolean =
        authority == "com.android.externalstorage.documents" &&
            Regex("[^:/\\\\]+:Documents/NSOAlbumSync").matches(id)
    fun blockName(name: String): Boolean = Regex("[0-9a-f]{16}\\.block").matches(name)
    fun direction(value: String): String {
        require(value == "desktop" || value == "mobile") { "INVALID_SCOPE" }
        return value
    }
    fun errorCode(error: Throwable): String = when (error) {
        is DeviceSyncWindowFull -> "WINDOW_FULL"
        is DeviceSyncIoBusy -> "BUSY"
        is SecurityException -> "DIRECTORY_NOT_AUTHORIZED"
        is IllegalArgumentException -> "INVALID_BLOCK"
        else -> "DEVICE_SYNC_UNAVAILABLE"
    }
    /** Diagnostic-only fixed vocabulary; never return exception/provider text or scope values. */
    fun diagnostic(method: String, error: Throwable): String {
        val safeMethod = when (method) {
            "selectTree", "openSession", "listBlocks", "readBlock", "writeCiphertextBlock",
            "acknowledgeBlock", "close", "cancel", "revoke" -> method
            else -> "other"
        }
        val category = when (error) {
            is DeviceSyncWindowFull -> "WindowFull"
            is DeviceSyncIoBusy -> "Busy"
            is SecurityException -> "Security"
            is IllegalArgumentException -> "InvalidArgument"
            is IllegalStateException -> "InvalidState"
            is java.io.IOException -> "Io"
            else -> "Other"
        }
        val reason = if (error is IllegalArgumentException || error is IllegalStateException) {
            when (error.message) {
                "INVALID_SCOPE" -> "INVALID_SCOPE"
                "INVALID_BLOCK" -> "INVALID_BLOCK"
                "BLOCK_TOO_LARGE" -> "BLOCK_TOO_LARGE"
                "INVALID_DOCUMENT" -> "INVALID_DOCUMENT"
                "INVALID_DIRECTORY" -> "INVALID_DIRECTORY"
                "DUPLICATE_DOCUMENT" -> "DUPLICATE_DOCUMENT"
                "TOO_MANY_ENTRIES" -> "TOO_MANY_ENTRIES"
                "INVALID_SEQUENCE" -> "INVALID_SEQUENCE"
                "BLOCK_NOT_READ" -> "BLOCK_NOT_READ"
                "BLOCK_NOT_FOUND" -> "BLOCK_NOT_FOUND"
                "BLOCK_CHANGED" -> "BLOCK_CHANGED"
                "BLOCK_EXISTS" -> "BLOCK_EXISTS"
                "TOO_MANY_UNACKNOWLEDGED_BLOCKS" -> "TOO_MANY_UNACKNOWLEDGED_BLOCKS"
                "STALE_OPERATION" -> "STALE_OPERATION"
                "OPERATION_CLOSED" -> "OPERATION_CLOSED"
                "WINDOW_FULL" -> "WINDOW_FULL"
                "BUSY" -> "BUSY"
                "DIRECTORY_UNAVAILABLE" -> "DIRECTORY_UNAVAILABLE"
                "CREATE_FAILED" -> "CREATE_FAILED"
                "READ_FAILED" -> "READ_FAILED"
                "WRITE_FAILED" -> "WRITE_FAILED"
                "PUBLISH_FAILED" -> "PUBLISH_FAILED"
                "ACKNOWLEDGEMENT_FAILED" -> "ACKNOWLEDGEMENT_FAILED"
                else -> "other"
            }
        } else "other"
        return "device_sync_saf method=$safeMethod category=$category reason=$reason code=${errorCode(error)}"
    }
    fun copyBounded(input: InputStream, output: OutputStream, operation: DeviceSyncOperation) {
        var size = 0
        val buffer = ByteArray(8192)
        while (true) {
            operation.check()
            val count = input.read(buffer, 0, minOf(buffer.size, MAX_BLOCK + 1 - size))
            if (count < 0) break
            require(count > 0) { "INVALID_BLOCK" }
            size += count
            require(size <= MAX_BLOCK) { "BLOCK_TOO_LARGE" }
            output.write(buffer, 0, count)
        }
        require(size > 0) { "INVALID_BLOCK" }
        operation.check()
    }
}

internal class DeviceSyncIoBusy : IllegalStateException()
internal class DeviceSyncDirectoryDenied : SecurityException()

internal data class DeviceSyncOwnerScope(val operation: String, val session: String, val token: String) {
    init {
        DeviceSyncPolicy.sessionDirectory(operation)
        DeviceSyncPolicy.sessionDirectory(session)
        DeviceSyncPolicy.sessionDirectory(token)
    }
}

/** Main-thread owner admission and retirement, including reused protocol IDs. */
internal class DeviceSyncOwnerSlot {
    var operation: DeviceSyncOperation? = null
        private set
    private var scope: DeviceSyncOwnerScope? = null
    fun open(scope: DeviceSyncOwnerScope): DeviceSyncOperation {
        if (operation != null) throw DeviceSyncIoBusy()
        return DeviceSyncOperation(scope.operation, scope.session).also {
            operation = it
            this.scope = scope
        }
    }
    fun requireActive(scope: DeviceSyncOwnerScope): DeviceSyncOperation {
        val owner = operation ?: error("OPERATION_CLOSED")
        require(this.scope == scope) { "STALE_OPERATION" }
        owner.check()
        return owner
    }
    fun retire(scope: DeviceSyncOwnerScope): DeviceSyncOperation? {
        if (this.scope != scope) return null
        return invalidate()
    }
    fun invalidate(): DeviceSyncOperation? {
        val owner = operation
        operation = null
        scope = null
        owner?.invalidate()
        return owner
    }
}

/** Cancellation does not make a blocked provider executor available again. */
internal class DeviceSyncIoSlot {
    private var running = false
    private var closing = false
    @Synchronized fun requireIdle() { if (running || closing) throw DeviceSyncIoBusy() }
    @Synchronized fun begin() { requireIdle(); running = true }
    @Synchronized fun finished() { running = false }
    @Synchronized fun beginClose() { check(!closing); closing = true }
    @Synchronized fun finishedClose() { closing = false }
}

internal class DeviceSyncOperation(val id: String, val session: String) {
    @Volatile private var active = true
    private val resources = mutableSetOf<Closeable>()
    init {
        DeviceSyncPolicy.sessionDirectory(id)
        DeviceSyncPolicy.sessionDirectory(session)
    }
    fun cancel() {
        val closing = synchronized(this) {
            active = false
            resources.toList().also { resources.clear() }
        }
        closing.forEach { runCatching { it.close() } }
    }
    fun invalidate() { active = false }
    fun check() { check(active) { "OPERATION_CLOSED" } }
    fun requireActive(id: String, session: String) {
        check()
        require(this.id == id && this.session == session) { "STALE_OPERATION" }
    }
    @Synchronized fun track(resource: Closeable) {
        if (!active) {
            resource.close()
            error("OPERATION_CLOSED")
        }
        resources.add(resource)
    }
    @Synchronized fun untrack(resource: Closeable) { resources.remove(resource) }
}
