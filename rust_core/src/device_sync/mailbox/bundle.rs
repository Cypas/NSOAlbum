//! USB-only envelopes of bounded, already authenticated TLS ciphertext.

use crate::device_sync::{SessionError, MAX_CIPHERTEXT};

const MAGIC: &[u8; 8] = b"NSOUSB4\0";
const HEADER_BYTES: usize = 24;
const MAX_BUNDLE_BYTES: usize = 8 * 1024 * 1024;
const TARGET_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_DRAINS: usize = 128;
const FLUSH_AFTER_MS: u64 = 50;

#[derive(Clone, Copy)]
pub(crate) enum FlushReason {
    Target,
    Timer,
    Control,
    Boundary,
}

pub(crate) struct EncodedBundle {
    pub name: String,
    pub bytes: Vec<u8>,
    pub ciphertext_bytes: usize,
    pub drain_count: usize,
    pub immediate: bool,
    pub reason: FlushReason,
}

#[derive(Default)]
pub(crate) struct BundleEncoder {
    outgoing: u64,
}

fn encoded_size(drains: &[Vec<u8>]) -> Result<usize, SessionError> {
    if drains.is_empty() || drains.len() > MAX_DRAINS {
        return Err(SessionError::Bounds);
    }
    drains.iter().try_fold(HEADER_BYTES, |total, drain| {
        if drain.is_empty() || drain.len() > MAX_CIPHERTEXT {
            return Err(SessionError::Bounds);
        }
        total
            .checked_add(4)
            .and_then(|value| value.checked_add(drain.len()))
            .filter(|value| *value <= MAX_BUNDLE_BYTES)
            .ok_or(SessionError::Bounds)
    })
}

impl BundleEncoder {
    pub(crate) fn encode(&mut self, drains: &[Vec<u8>]) -> Result<EncodedBundle, SessionError> {
        let size = encoded_size(drains)?;
        let next = self.outgoing.checked_add(1).ok_or(SessionError::Bounds)?;
        let mut bytes = Vec::with_capacity(size);
        bytes.extend_from_slice(MAGIC);
        bytes.extend_from_slice(&self.outgoing.to_be_bytes());
        bytes.extend_from_slice(&((size - HEADER_BYTES) as u32).to_be_bytes());
        bytes.extend_from_slice(&(drains.len() as u16).to_be_bytes());
        bytes.extend_from_slice(&[0, 0]);
        let mut ciphertext_bytes = 0;
        for drain in drains {
            bytes.extend_from_slice(&(drain.len() as u32).to_be_bytes());
            bytes.extend_from_slice(drain);
            ciphertext_bytes += drain.len();
        }
        let name = format!("{:016x}.block", self.outgoing);
        self.outgoing = next;
        Ok(EncodedBundle {
            name,
            bytes,
            ciphertext_bytes,
            drain_count: drains.len(),
            immediate: false,
            reason: FlushReason::Boundary,
        })
    }
}

#[derive(Default)]
pub(crate) struct BundleDecoder {
    incoming: u64,
    terminal: bool,
}

impl BundleDecoder {
    pub(crate) fn decode(
        &mut self,
        name: &str,
        bytes: &[u8],
    ) -> Result<Vec<Vec<u8>>, SessionError> {
        if self.terminal {
            return Err(SessionError::Terminal);
        }
        let answer = self.decode_inner(name, bytes);
        if answer.is_err() {
            self.terminal = true;
        }
        answer
    }

    fn decode_inner(&mut self, name: &str, bytes: &[u8]) -> Result<Vec<Vec<u8>>, SessionError> {
        // Exact ASCII comparison rejects paths, Unicode and partial names without slicing UTF-8.
        if name != format!("{:016x}.block", self.incoming) {
            return Err(SessionError::Protocol);
        }
        if bytes.len() < HEADER_BYTES || bytes.len() > MAX_BUNDLE_BYTES {
            return Err(SessionError::Bounds);
        }
        if &bytes[..8] != MAGIC
            || bytes[8..16] != self.incoming.to_be_bytes()
            || bytes[22..24] != [0, 0]
        {
            return Err(SessionError::Protocol);
        }
        let payload = u32::from_be_bytes(bytes[16..20].try_into().unwrap()) as usize;
        let count = u16::from_be_bytes(bytes[20..22].try_into().unwrap()) as usize;
        if payload != bytes.len() - HEADER_BYTES || !(1..=MAX_DRAINS).contains(&count) {
            return Err(SessionError::Bounds);
        }
        let mut ranges = Vec::with_capacity(count);
        let mut offset = HEADER_BYTES;
        for _ in 0..count {
            let length_end = offset.checked_add(4).ok_or(SessionError::Bounds)?;
            let length_bytes = bytes.get(offset..length_end).ok_or(SessionError::Bounds)?;
            let length = u32::from_be_bytes(length_bytes.try_into().unwrap()) as usize;
            if !(1..=MAX_CIPHERTEXT).contains(&length) {
                return Err(SessionError::Bounds);
            }
            let end = length_end.checked_add(length).ok_or(SessionError::Bounds)?;
            if end > bytes.len() {
                return Err(SessionError::Bounds);
            }
            ranges.push(length_end..end);
            offset = end;
        }
        if offset != bytes.len() {
            return Err(SessionError::Bounds);
        }
        let next = self.incoming.checked_add(1).ok_or(SessionError::Bounds)?;
        let drains = ranges
            .into_iter()
            .map(|range| bytes[range].to_vec())
            .collect();
        self.incoming = next;
        Ok(drains)
    }
}

#[derive(Clone, Copy)]
pub(crate) enum FlushHint {
    Media,
    Immediate,
}

#[derive(Default)]
pub(crate) struct BundleBuffer {
    drains: Vec<Vec<u8>>,
    encoded_bytes: usize,
    first_ms: Option<u64>,
    immediate: bool,
}

impl BundleBuffer {
    pub(crate) fn immediate(&self) -> bool {
        self.immediate
    }
    pub(crate) fn buffered_bytes(&self) -> usize {
        self.encoded_bytes
    }

    pub(crate) fn push(
        &mut self,
        drain: Vec<u8>,
        hint: FlushHint,
        now_ms: u64,
    ) -> Result<(), SessionError> {
        let total = self
            .encoded_bytes
            .max(HEADER_BYTES)
            .checked_add(4)
            .and_then(|value| value.checked_add(drain.len()))
            .ok_or(SessionError::Bounds)?;
        if drain.is_empty()
            || drain.len() > MAX_CIPHERTEXT
            || self.drains.len() >= MAX_DRAINS
            || total > MAX_BUNDLE_BYTES
        {
            return Err(SessionError::Bounds);
        }
        self.first_ms.get_or_insert(now_ms);
        self.immediate |= matches!(hint, FlushHint::Immediate);
        self.encoded_bytes = total;
        self.drains.push(drain);
        Ok(())
    }

    pub(crate) fn ready(&self, now_ms: u64) -> bool {
        self.flush_reason(now_ms).is_some()
    }

    pub(crate) fn flush_reason(&self, now_ms: u64) -> Option<FlushReason> {
        let first = self.first_ms?;
        if self.immediate {
            Some(FlushReason::Control)
        } else if self.drains.len() == MAX_DRAINS || self.encoded_bytes >= TARGET_BYTES {
            Some(FlushReason::Target)
        } else if now_ms < first || now_ms - first >= FLUSH_AFTER_MS {
            Some(FlushReason::Timer)
        } else {
            None
        }
    }

    /// Taking a partial bundle is allowed when no further authorized output can be prepared.
    /// This is not an I/O completion and must never acknowledge bytes to Driver.
    pub(crate) fn take(&mut self) -> Vec<Vec<u8>> {
        self.first_ms = None;
        self.immediate = false;
        self.encoded_bytes = 0;
        std::mem::take(&mut self.drains)
    }
}

#[cfg(test)]
#[path = "bundle_tests.rs"]
mod tests;
