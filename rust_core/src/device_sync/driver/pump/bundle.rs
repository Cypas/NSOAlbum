//! USB v4 pump. Native publication and directory retirement are separate capabilities.

use super::*;
use crate::device_sync::mailbox::bundle::{
    BundleBuffer, BundleDecoder, BundleEncoder, EncodedBundle, FlushHint, FlushReason,
};
use crate::device_sync::session::OutputClass;
use std::collections::VecDeque;

struct Incoming {
    name: String,
    drains: VecDeque<Vec<u8>>,
}

#[derive(Default)]
pub(crate) struct BundlePump {
    encoder: BundleEncoder,
    decoder: BundleDecoder,
    buffer: BundleBuffer,
    pending: Option<EncodedBundle>,
    incoming: Option<Incoming>,
    blocked: bool,
    terminal: bool,
}

impl BundlePump {
    pub(crate) fn accept(
        &mut self,
        driver: &mut Driver,
        name: &str,
        bytes: &[u8],
    ) -> Result<Option<String>> {
        if self.terminal || self.incoming.is_some() {
            return Err(DriverError::Protocol);
        }
        let drains = match self.decoder.decode(name, bytes) {
            Ok(drains) => drains,
            Err(error) => {
                self.close(driver);
                return Err(error.into());
            }
        };
        self.incoming = Some(Incoming {
            name: name.into(),
            drains: drains.into(),
        });
        self.resume_input(driver)
    }

    /// A full Session window retains the rest of this validated bundle.
    /// No directory ACK is exposed until every drain was accepted by TLS.
    pub(crate) fn resume_input(&mut self, driver: &mut Driver) -> Result<Option<String>> {
        if self.terminal {
            return Err(DriverError::Protocol);
        }
        if let Some(incoming) = &mut self.incoming {
            while !incoming.drains.is_empty() && driver.ready_for_input() {
                let bytes = incoming.drains.pop_front().ok_or(DriverError::Protocol)?;
                if let Err(error) = driver.ingest_ciphertext(&bytes) {
                    self.close(driver);
                    return Err(error);
                }
            }
            if incoming.drains.is_empty() {
                return Ok(self.incoming.take().map(|incoming| incoming.name));
            }
        }
        Ok(None)
    }

    pub(crate) fn outgoing_without_finish(
        &mut self,
        driver: &mut Driver,
    ) -> Result<Option<(&str, &[u8])>> {
        if self.terminal {
            return if driver.state() == State::Completed {
                Ok(None)
            } else {
                Err(DriverError::Protocol)
            };
        }
        if self.blocked {
            return Ok(None);
        }
        // The exact pending carrier stays owned by its native write. Prepare
        // at most one bounded successor while that write is in flight.
        for _ in 0..crate::device_sync::mailbox::bundle::MAX_DRAINS {
            if self.buffer.stop_filling()
                || self
                    .buffered_bytes()
                    .saturating_add(super::super::super::MAX_CIPHERTEXT + 28)
                    > 16 * 1024 * 1024
            {
                break;
            }
            driver.poll()?;
            let (bytes, class) = driver.drain_classified_ciphertext()?;
            if bytes.is_empty() {
                // A transient gap is not a publication boundary. Retain
                // media until the target/timer or actual credit/file tail.
                break;
            }
            self.buffer.push(
                bytes,
                match class {
                    OutputClass::Media => FlushHint::Media,
                    OutputClass::Immediate => FlushHint::Immediate,
                },
                driver.clock.monotonic_ms(),
            )?;
            driver.record_usb_drain(class == OutputClass::Media);
        }
        if self.pending.is_none()
            && self.buffer.buffered_bytes() > 0
            && (self.buffer.ready(driver.clock.monotonic_ms())
                || driver.media_publication_boundary())
        {
            let immediate = self.buffer.immediate();
            let reason = self
                .buffer
                .flush_reason(driver.clock.monotonic_ms())
                .unwrap_or(FlushReason::Boundary);
            let mut bundle = self.encoder.encode(&self.buffer.take())?;
            bundle.immediate = immediate;
            bundle.reason = reason;
            self.pending = Some(bundle);
        }
        Ok(self
            .pending
            .as_ref()
            .map(|bundle| (bundle.name.as_str(), bundle.bytes.as_slice())))
    }

    /// Only the native owner's successful atomic publication authorizes this call.
    pub(crate) fn written(&mut self, driver: &mut Driver) -> Result<()> {
        let bundle = self.pending.take().ok_or(DriverError::Protocol)?;
        driver.ciphertext_written(bundle.ciphertext_bytes)?;
        driver.record_usb_bundle(bundle.drain_count);
        driver
            .metrics
            .usb_carrier(bundle.bytes.len(), bundle.reason);
        Ok(())
    }

    pub(crate) fn finish_success(&mut self, driver: &mut Driver) -> bool {
        if self.pending.is_none()
            && self.incoming.is_none()
            && self.buffer.buffered_bytes() == 0
            && !self.blocked
            && driver.finish_success()
        {
            self.terminal = true;
            true
        } else {
            false
        }
    }

    pub(crate) fn window_full(&mut self) {
        self.blocked = true;
    }
    pub(crate) fn capacity_released(&mut self) {
        self.blocked = false;
    }
    pub(crate) fn buffered_bytes(&self) -> usize {
        self.buffer.buffered_bytes()
            + self.pending.as_ref().map_or(0, |bundle| bundle.bytes.len())
            + self.incoming.as_ref().map_or(0, |incoming| {
                incoming.drains.iter().map(Vec::len).sum::<usize>()
            })
    }
    pub(crate) fn has_pending_input(&self) -> bool {
        self.incoming.is_some()
    }
    pub(crate) fn pending_is_control(&self) -> bool {
        self.pending.as_ref().is_some_and(|bundle| bundle.immediate)
    }
    pub(crate) fn close(&mut self, driver: &mut Driver) {
        self.terminal = true;
        self.pending = None;
        self.incoming = None;
        self.buffer.take();
        driver.disconnect();
    }
}
