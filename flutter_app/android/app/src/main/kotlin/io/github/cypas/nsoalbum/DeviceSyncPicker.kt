package io.github.cypas.nsoalbum

/** Retains an outstanding system request after cancellation to reject stale activity results. */
internal class DeviceSyncPicker<T> {
    var outstanding: Boolean = false
        private set
    private var callback: T? = null
    fun beginIfNeeded(value: T, reusable: Boolean): Boolean {
        check(!outstanding) { "PICKER_BUSY" }
        if (reusable) return false
        begin(value)
        return true
    }
    fun begin(value: T) {
        check(!outstanding) { "PICKER_BUSY" }
        outstanding = true
        callback = value
    }
    fun cancel(): T? = callback.also { callback = null }
    fun complete(): T? = callback.also {
        callback = null
        outstanding = false
    }
}
