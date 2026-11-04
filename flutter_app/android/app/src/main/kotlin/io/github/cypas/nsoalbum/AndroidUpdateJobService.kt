package io.github.cypas.nsoalbum

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Handler
import android.os.Looper

/**
 * Owns the potentially long APK copy/hash/signature check outside the short
 * DownloadManager completion broadcast window.
 */
class AndroidUpdateJobService : JobService() {
    private class Run(
        val parameters: JobParameters,
        val controller: AndroidUpdateController,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private var activeRun: Run? = null

    override fun onStartJob(params: JobParameters): Boolean {
        val run = Run(params, AndroidUpdateController.get(this))
        activeRun = run
        run.controller.startScheduledVerification { retry ->
            mainHandler.post {
                // Start, stop and completion all mutate the current run on the
                // main thread; a delayed worker cannot finish a replacement job.
                if (activeRun === run) {
                    activeRun = null
                    jobFinished(run.parameters, retry)
                }
            }
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        val run = activeRun ?: return false
        if (run.parameters !== params) return false
        activeRun = null
        run.controller.stopScheduledVerification()
        // The worker leaves state=verifying on cancellation, so JobScheduler
        // should enqueue another attempt after a preemption or timeout.
        return run.controller.verificationNeedsRetry()
    }
}
