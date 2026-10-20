//! Numeric-only native subtimings. Nested intervals must not be added as percentages.
use std::fmt::{self, Write};
use std::time::Instant;

#[derive(Clone, Copy)]
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
