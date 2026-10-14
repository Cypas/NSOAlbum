package io.github.cypas.nsoalbum

import android.app.job.JobParameters
import android.os.Looper

object AndroidUpdateJobServiceLifecycleTest {
    @JvmStatic
    fun main(args: Array<String>) {
        val controller = AndroidUpdateController.instance
        val loop = Looper.getMainLooper()
        val mainThread = Thread.currentThread()
        fun reset() {
            loop.drain()
            controller.completions.clear()
        }

        reset()
        val staleStopService = AndroidUpdateJobService()
        val oldParameters = JobParameters()
        val newParameters = JobParameters()
        check(staleStopService.onStartJob(oldParameters))
        check(staleStopService.onStartJob(newParameters))
        staleStopService.onStopJob(oldParameters)
        controller.completions[1](false)
        loop.drain()
        check(staleStopService.completedJobs.size == 1 &&
            staleStopService.completedJobs.single().parameters === newParameters) {
            "A stale stop suppressed the newer job completion"
        }

        reset()
        val workerService = AndroidUpdateJobService()
        val workerParameters = JobParameters()
        check(workerService.onStartJob(workerParameters))
        val completeFromWorker = Thread { controller.completions.single()(false) }
        completeFromWorker.start()
        completeFromWorker.join()
        check(workerService.completedJobs.isEmpty()) {
            "Worker completion ran lifecycle handling outside the main loop"
        }
        loop.drain()
        check(workerService.completedJobs.single().thread === mainThread)

        reset()
        val delayedService = AndroidUpdateJobService()
        val stoppedParameters = JobParameters()
        val currentParameters = JobParameters()
        check(delayedService.onStartJob(stoppedParameters))
        val oldCompletion = controller.completions.single()
        check(delayedService.onStopJob(stoppedParameters))
        check(delayedService.onStartJob(currentParameters))
        val currentCompletion = controller.completions.last()
        Thread { oldCompletion(false) }.apply { start(); join() }
        Thread { currentCompletion(false) }.apply { start(); join() }
        loop.drain()
        check(delayedService.completedJobs.size == 1 &&
            delayedService.completedJobs.single().parameters === currentParameters) {
            "A delayed old completion cleared or suppressed the current job"
        }
        currentCompletion(false)
        loop.drain()
        check(delayedService.completedJobs.size == 1) {
            "Duplicate completion finished the same job twice"
        }

        reset()
        val stoppedService = AndroidUpdateJobService()
        val stopped = JobParameters()
        check(stoppedService.onStartJob(stopped))
        check(stoppedService.onStopJob(stopped))
        controller.completions.single()(false)
        loop.drain()
        check(stoppedService.completedJobs.isEmpty()) {
            "A stopped job was finished again by its delayed worker"
        }
        println("Android update JobService lifecycle: 4 scenarios passed")
    }
}
