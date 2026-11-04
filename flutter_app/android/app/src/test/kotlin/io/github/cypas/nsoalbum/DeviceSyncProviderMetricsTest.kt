package io.github.cypas.nsoalbum

object DeviceSyncProviderMetricsTest {
    private fun field(record: String, key: String): String =
        record.split(" ").mapNotNull { part ->
            part.split("=", limit = 2).takeIf { it.size == 2 }
        }.single { it[0] == key }[1]

    @JvmStatic
    fun main(args: Array<String>) {
        val timing = DeviceSyncProviderMetrics()
        timing.begin(DeviceSyncProviderMetrics.Kind.Read, 3_000_000)
        timing.end(8_000_000, false, 65_536)
        timing.begin(DeviceSyncProviderMetrics.Kind.Acknowledge, 9_000_000)
        timing.end(13_000_000, false, 0)
        timing.record(DeviceSyncProviderMetrics.Step.Create, 2_000_000)
        timing.record(DeviceSyncProviderMetrics.Step.PayloadWrite, 4_000_000, 8_388_608)
        val record = timing.finish(20_000_000)
        check(field(record, "provider_read_ms") == "5")
        check(field(record, "provider_read_bytes") == "65536")
        check(field(record, "provider_acknowledge_ms") == "4")
        check(field(record, "provider_read_count") == "1")
        check(field(record, "nested") == "true")
        check(field(record, "provider_create_us") == "2000")
        check(field(record, "provider_payload_write_us") == "4000")
        check(field(record, "provider_payload_write_bytes") == "8388608")
        timing.end(100_000_000, true, 1234)
        check(timing.finish(200_000_000) == record)

        val cancelled = DeviceSyncProviderMetrics()
        cancelled.begin(DeviceSyncProviderMetrics.Kind.Write, 10_000_000)
        val interrupted = cancelled.finish(17_000_000)
        check(field(interrupted, "provider_write_ms") == "7")
        check(field(interrupted, "provider_write_failed") == "1")
        check(field(interrupted, "provider_write_bytes") == "0")
        cancelled.end(18_000_000, false, 65_536)
        check(cancelled.finish(19_000_000) == interrupted)

        val backwards = DeviceSyncProviderMetrics()
        backwards.begin(DeviceSyncProviderMetrics.Kind.List, 100)
        backwards.end(90, false, 0)
        check(field(backwards.finish(200), "valid") == "false")
        val overflow = DeviceSyncProviderMetrics()
        repeat(2) {
            overflow.begin(DeviceSyncProviderMetrics.Kind.Read, 0)
            overflow.end(Long.MAX_VALUE, false, 0)
        }
        check(field(overflow.finish(Long.MAX_VALUE), "valid") == "false")
        val fresh = DeviceSyncProviderMetrics().finish(0)
        check(field(fresh, "provider_write_count") == "0")
        for (part in record.split(" ").drop(1)) {
            val pair = part.split("=", limit = 2)
            check(pair.size == 2 && pair[0].all { it in 'a'..'z' || it == '_' })
            check(pair[1] in listOf("true", "false") || pair[1].all { it.isDigit() })
        }
        println("DeviceSyncProviderMetricsTest PASS")
    }
}
