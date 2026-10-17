package android.os

class CancellationSignal {
    var cancelled = false
    fun cancel() { cancelled = true }
}
