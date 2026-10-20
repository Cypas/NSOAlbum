//! Bounded, payload-free measurements of one device-sync operation.

use std::fmt::Write;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Phase {
    Snapshot,
    Preview,
    Transfer,
    Verify,
    Apply,
    Receipt,
}
impl Phase {
    fn index(self) -> usize {
        self as usize
    }
    fn starts_operation(self) -> bool {
        matches!(
            self,
            Self::Transfer | Self::Verify | Self::Apply | Self::Receipt
        )
    }
}

#[derive(Clone, Copy)]
pub(crate) enum IoKind {
    List,
    Read,
    Write,
    Acknowledge,
}
#[derive(Clone, Copy, Default)]
struct Io {
    count: u64,
    elapsed_ms: u64,
    bytes: u64,
    failed: u64,
}

pub(crate) struct Metrics {
    started: u64,
    last: u64,
    operation_started: Option<u64>,
    active: Option<Phase>,
    elapsed: [u64; 6],
    io: [Io; 4],
    usb_bundles: [u64; 5],
    usb_carrier_bytes: u64,
    usb_carrier_max_bytes: u64,
    usb_carrier_sizes: [u64; 3],
    usb_flush: [u64; 4],
    media_bytes: u64,
    valid: bool,
    finished: Option<String>,
}
impl Metrics {
    pub(crate) fn new(now_ms: u64) -> Self {
        Self {
            started: now_ms,
            last: now_ms,
            operation_started: None,
            active: None,
            elapsed: [0; 6],
            io: [Io::default(); 4],
            usb_bundles: [0; 5],
            usb_carrier_bytes: 0,
            usb_carrier_max_bytes: 0,
            usb_carrier_sizes: [0; 3],
            usb_flush: [0; 4],
            media_bytes: 0,
            valid: true,
            finished: None,
        }
    }

    pub(crate) fn phase(&mut self, phase: Option<Phase>, now_ms: u64) {
        if self.finished.is_some() {
            return;
        }
        let Some(delta) = now_ms.checked_sub(self.last) else {
            self.valid = false;
            return;
        };
        if let Some(previous) = self.active {
            add(&mut self.elapsed[previous.index()], delta, &mut self.valid);
        }
        self.last = now_ms;
        self.active = phase;
        if self.operation_started.is_none() && phase.is_some_and(Phase::starts_operation) {
            self.operation_started = Some(now_ms);
        }
    }

    pub(crate) fn io(&mut self, kind: IoKind, elapsed_ms: u64, bytes: u64, failed: bool) {
        if self.finished.is_some() {
            return;
        }
        let io = &mut self.io[kind as usize];
        add(&mut io.count, 1, &mut self.valid);
        add(&mut io.elapsed_ms, elapsed_ms, &mut self.valid);
        add(&mut io.bytes, bytes, &mut self.valid);
        add(&mut io.failed, u64::from(failed), &mut self.valid);
    }

    pub(crate) fn observe_media_bytes(&mut self, cumulative: u64) {
        if self.finished.is_some() {
            return;
        }
        if cumulative < self.media_bytes {
            self.valid = false;
        } else {
            self.media_bytes = cumulative;
        }
    }

    pub(crate) fn usb_drain(&mut self, media: bool) {
        if self.finished.is_none() {
            add(
                &mut self.usb_bundles[usize::from(!media)],
                1,
                &mut self.valid,
            );
        }
    }

    pub(crate) fn usb_published(&mut self, drains: usize) {
        if self.finished.is_some() {
            return;
        }
        if !(1..=super::mailbox::bundle::MAX_DRAINS).contains(&drains) {
            self.valid = false;
            return;
        }
        add(&mut self.usb_bundles[2], 1, &mut self.valid);
        add(
            &mut self.usb_bundles[3],
            u64::from(drains > 1),
            &mut self.valid,
        );
        self.usb_bundles[4] = self.usb_bundles[4].max(drains as u64);
    }

    pub(crate) fn usb_carrier(
        &mut self,
        bytes: usize,
        reason: super::mailbox::bundle::FlushReason,
    ) {
        if self.finished.is_some() {
            return;
        }
        add(&mut self.usb_carrier_bytes, bytes as u64, &mut self.valid);
        self.usb_carrier_max_bytes = self.usb_carrier_max_bytes.max(bytes as u64);
        let bucket = if bytes < 1024 * 1024 {
            0
        } else if bytes < 4 * 1024 * 1024 {
            1
        } else {
            2
        };
        add(&mut self.usb_carrier_sizes[bucket], 1, &mut self.valid);
        add(&mut self.usb_flush[reason as usize], 1, &mut self.valid);
    }

    pub(crate) fn finish(&mut self, now_ms: u64) -> String {
        if let Some(record) = &self.finished {
            return record.clone();
        }
        self.phase(None, now_ms);
        let transfer_ms = self.elapsed[Phase::Transfer.index()];
        let rate = if self.valid && transfer_ms > 0 {
            match u64::try_from(u128::from(self.media_bytes) * 1_000 / u128::from(transfer_ms)) {
                Ok(value) => value.to_string(),
                Err(_) => {
                    self.valid = false;
                    "unknown".into()
                }
            }
        } else {
            "unknown".into()
        };
        let operation_ms = self
            .operation_started
            .map(|start| self.last.saturating_sub(start).to_string())
            .unwrap_or_else(|| "unknown".into());
        let mut record = format!(
            "device_sync_metrics valid={} session_ms={} operation_ms={} media_bytes={} transfer_bytes_per_second={rate}",
            self.valid,
            self.last.saturating_sub(self.started),
            operation_ms,
            self.media_bytes,
        );
        for (name, elapsed) in [
            "snapshot", "preview", "transfer", "verify", "apply", "receipt",
        ]
        .into_iter()
        .zip(self.elapsed)
        {
            let _ = write!(record, " {name}_ms={elapsed}");
        }
        for (name, io) in ["list", "read", "write", "acknowledge"]
            .into_iter()
            .zip(self.io)
        {
            let _ = write!(
                record,
                " usb_{name}_count={} usb_{name}_ms={} usb_{name}_bytes={} usb_{name}_failed={}",
                io.count, io.elapsed_ms, io.bytes, io.failed,
            );
        }
        for (name, count) in [
            "media_drains",
            "immediate_drains",
            "published_bundles",
            "multi_bundles",
            "max_bundle_drains",
        ]
        .into_iter()
        .zip(self.usb_bundles)
        {
            let _ = write!(record, " usb_{name}={count}");
        }
        let _ = write!(
            record,
            " usb_carrier_bytes={} usb_carrier_max_bytes={}",
            self.usb_carrier_bytes, self.usb_carrier_max_bytes
        );
        for (name, count) in ["below_mib", "below_four_mib", "four_mib_or_more"]
            .into_iter()
            .zip(self.usb_carrier_sizes)
        {
            let _ = write!(record, " usb_carrier_{name}={count}");
        }
        for (name, count) in ["target", "timer", "control", "boundary"]
            .into_iter()
            .zip(self.usb_flush)
        {
            let _ = write!(record, " usb_flush_{name}={count}");
        }
        self.finished = Some(record.clone());
        record
    }
}

fn add(target: &mut u64, value: u64, valid: &mut bool) {
    match target.checked_add(value) {
        Some(sum) => *target = sum,
        None => {
            *target = u64::MAX;
            *valid = false;
        }
    }
}

#[cfg(test)]
#[path = "metrics_tests.rs"]
mod tests;
