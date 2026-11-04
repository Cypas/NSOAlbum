package android.app.job

class JobParameters

open class JobService {
    data class Completion(val parameters: JobParameters, val retry: Boolean, val thread: Thread)
    val completedJobs = mutableListOf<Completion>()

    open fun onStartJob(params: JobParameters): Boolean = false
    open fun onStopJob(params: JobParameters): Boolean = false
    fun jobFinished(params: JobParameters, retry: Boolean) {
        completedJobs.add(Completion(params, retry, Thread.currentThread()))
    }
}
