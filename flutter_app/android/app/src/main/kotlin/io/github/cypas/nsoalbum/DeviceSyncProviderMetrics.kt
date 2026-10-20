package io.github.cypas.nsoalbum

/** Fixed, numeric-only provider timings. An instance belongs to one operation owner. */
internal class DeviceSyncProviderMetrics {
    enum class Kind { List, Read, Write, Acknowledge }
    enum class Step(val label: String) {
        Create("create"), PayloadRead("payload_read"), PayloadWrite("payload_write"),
        Rename("rename"), Properties("properties"), Enumerate("enumerate"), Cleanup("cleanup"),
    }
    private class Counter {
        var count = 0L
        var nanos = 0L
        var bytes = 0L
        var failed = 0L
    }
    private val counters = Array(Kind.entries.size) { Counter() }
    private val steps = Array(Step.entries.size) { Counter() }
    private var active: Pair<Kind, Long>? = null
    private var valid = true
    private var summary: String? = null

    @Synchronized
    fun record(step: Step, nanos: Long, bytes: Long = 0) {
        if (summary != null) return
        val counter = steps[step.ordinal]
        counter.count = add(counter.count, 1)
        counter.nanos = add(counter.nanos, nanos)
        counter.bytes = add(counter.bytes, bytes)
    }

    private fun add(left: Long, right: Long): Long {
        if (right < 0 || left > Long.MAX_VALUE - right) {
            valid = false
            return Long.MAX_VALUE
        }
        return left + right
    }

    @Synchronized
    fun begin(kind: Kind, nowNanos: Long) {
        if (summary != null) return
        if (active != null) {
            valid = false
            return
        }
        active = kind to nowNanos
    }

    @Synchronized
    fun end(nowNanos: Long, failed: Boolean, bytes: Int) {
        if (summary != null) return
        val (kind, start) = active ?: return
        active = null
        val counter = counters[kind.ordinal]
        counter.count = add(counter.count, 1)
        // nanoTime is signed and may wrap. Do not turn regressing/overflowed time into a rate.
        val elapsed = try { Math.subtractExact(nowNanos, start) }
            catch (_: ArithmeticException) { valid = false; 0 }
        if (elapsed < 0) valid = false
        counter.nanos = add(counter.nanos, elapsed.coerceAtLeast(0))
        if (failed) counter.failed = add(counter.failed, 1)
        else counter.bytes = add(counter.bytes, bytes.toLong())
    }

    @Synchronized
    fun finish(nowNanos: Long): String {
        summary?.let { return it }
        // An in-flight provider request retired by cancellation is not a completed write.
        end(nowNanos, true, 0)
        return buildString {
            append("device_sync_provider_metrics valid=").append(valid).append(" nested=true")
            for (kind in Kind.entries) {
                val prefix = " provider_${kind.name.lowercase()}_"
                val counter = counters[kind.ordinal]
                append(prefix).append("count=").append(counter.count)
                append(prefix).append("ms=").append(counter.nanos / 1_000_000)
                append(prefix).append("bytes=").append(counter.bytes)
                append(prefix).append("failed=").append(counter.failed)
            }
            for (step in Step.entries) {
                val prefix = " provider_${step.label}_"
                val counter = steps[step.ordinal]
                append(prefix).append("count=").append(counter.count)
                append(prefix).append("us=").append(counter.nanos / 1_000)
                append(prefix).append("bytes=").append(counter.bytes)
            }
        }.also { summary = it }
    }
}
