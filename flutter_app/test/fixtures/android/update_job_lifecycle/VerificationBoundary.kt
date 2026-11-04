package io.github.cypas.nsoalbum

// Only the asynchronous verification boundary is replaced; the real JobService
// owns start/stop/completion handling in this isolated JVM harness.
class AndroidUpdateController {
    val completions = mutableListOf<(Boolean) -> Unit>()

    fun startScheduledVerification(onFinished: (Boolean) -> Unit) {
        completions.add(onFinished)
    }

    fun stopScheduledVerification() = Unit
    fun verificationNeedsRetry(): Boolean = true

    companion object {
        val instance = AndroidUpdateController()
        @Suppress("UNUSED_PARAMETER")
        fun get(context: Any): AndroidUpdateController = instance
    }
}
