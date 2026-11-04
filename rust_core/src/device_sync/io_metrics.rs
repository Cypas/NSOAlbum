//! Numeric-only native subtimings. Nested intervals must not be added as percentages.
use std::fmt::{self, Write};
use std::time::Instant;

#[derive(Clone, Copy)]
#[cfg_attr(
    not(any(windows, target_os = "macos")),
    expect(
        dead_code,
        reason = "MTP-only steps retain their shared diagnostic slots on non-desktop targets"
    )
)]
pub(crate) enum IoStep {
    Create,
    PayloadRead,
    CreateWrite,
    Rename,
    Properties,
    Enumerate,
    ReceiptWait,
    Cleanup,
    IpcEncode,
    IpcDecode,
    IpcRoundtrip,
}

const NAMES: [&str; 11] = [
    "create",
    "payload_read",
    "create_write",
    "rename",
    "properties",
    "enumerate",
    "receipt_wait",
    "cleanup",
    "ipc_encode",
    "ipc_decode",
    "ipc_roundtrip",
];

#[derive(Clone, Copy, Default)]
struct Counter {
    count: u64,
    micros: u64,
    bytes: u64,
}

#[derive(Default)]
pub(crate) struct IoMetrics {
    counters: [Counter; 11],
}

impl IoMetrics {
    pub(crate) fn record(&mut self, step: IoStep, micros: u64, bytes: u64) {
        let counter = &mut self.counters[step as usize];
        counter.count = counter.count.saturating_add(1);
        counter.micros = counter.micros.saturating_add(micros);
        counter.bytes = counter.bytes.saturating_add(bytes);
    }

    pub(crate) fn elapsed(&mut self, step: IoStep, started: Instant, bytes: u64) {
        self.record(
            step,
            u64::try_from(started.elapsed().as_micros()).unwrap_or(u64::MAX),
            bytes,
        );
    }
}

impl fmt::Display for IoMetrics {
    fn fmt(&self, output: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut line = String::from("device_sync_native_timings nested=true");
        for (name, counter) in NAMES.into_iter().zip(self.counters) {
            write!(
                line,
                " {name}_count={} {name}_us={} {name}_bytes={}",
                counter.count, counter.micros, counter.bytes
            )?;
        }
        output.write_str(&line)
    }
}

#[cfg(test)]
mod tests {
    use super::{IoMetrics, IoStep};

    #[test]
    fn ipc_summary_retains_uncollected_native_steps_and_distinct_counters() {
        let mut metrics = IoMetrics::default();
        metrics.record(IoStep::ReceiptWait, 7, 0);
        metrics.record(IoStep::IpcEncode, 9, 90);
        metrics.record(IoStep::IpcDecode, 10, 100);
        metrics.record(IoStep::IpcRoundtrip, 11, 110);
        assert_eq!(
            metrics.to_string(),
            concat!(
                "device_sync_native_timings nested=true",
                " create_count=0 create_us=0 create_bytes=0",
                " payload_read_count=0 payload_read_us=0 payload_read_bytes=0",
                " create_write_count=0 create_write_us=0 create_write_bytes=0",
                " rename_count=0 rename_us=0 rename_bytes=0",
                " properties_count=0 properties_us=0 properties_bytes=0",
                " enumerate_count=0 enumerate_us=0 enumerate_bytes=0",
                " receipt_wait_count=1 receipt_wait_us=7 receipt_wait_bytes=0",
                " cleanup_count=0 cleanup_us=0 cleanup_bytes=0",
                " ipc_encode_count=1 ipc_encode_us=9 ipc_encode_bytes=90",
                " ipc_decode_count=1 ipc_decode_us=10 ipc_decode_bytes=100",
                " ipc_roundtrip_count=1 ipc_roundtrip_us=11 ipc_roundtrip_bytes=110",
            )
        );
    }
}
