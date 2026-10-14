package android.os

import java.util.concurrent.ConcurrentLinkedQueue

class Looper private constructor() {
    private val pending = ConcurrentLinkedQueue<Runnable>()
    internal fun enqueue(action: Runnable) {
        pending.add(action)
    }

    fun drain() {
        while (true) (pending.poll() ?: return).run()
    }

    companion object {
        private val main = Looper()
        @JvmStatic fun getMainLooper(): Looper = main
    }
}

class Handler(private val looper: Looper) {
    fun post(action: Runnable): Boolean {
        looper.enqueue(action)
        return true
    }
}
