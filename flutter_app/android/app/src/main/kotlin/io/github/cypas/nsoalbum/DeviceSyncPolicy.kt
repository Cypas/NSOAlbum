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
