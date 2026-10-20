//! Byte-based flow control; receipt is not media verification or library commit.
use super::{Driver, DriverError, SendingFile};
use std::collections::VecDeque;
pub(super) const WINDOW_BYTES: u64 = 16 * 1024 * 1024;
pub(super) const ACK_BYTES: u64 = 4 * 1024 * 1024;
pub(super) const ACK_MS: u64 = 250;
pub(super) const BATCH_FILES: usize = 8;
pub(super) const SMALL_FILE_BYTES: u64 = 4 * 1024 * 1024;
pub(super) const BATCH_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Default)]
pub(super) struct CumulativeAck {
    pending: Option<(String, u64, u64)>,
    acknowledged: u64,
}

impl Driver {
    pub(super) fn start_stream_file(&mut self, sha: String) -> super::Result<()> {
        if self.served.contains(&sha)
            || !self
                .plan
                .as_ref()
                .ok_or(DriverError::Protocol)?
                .media
                .iter()
                .any(|decision| {
                    decision.sha256 == sha
                        && !decision.reuse_original
                        && decision.final_record.is_some()
                })
        {
            return Err(DriverError::Protocol);
        }
        let identity = self
            .retained
            .as_ref()
            .ok_or(DriverError::Protocol)?
            .originals()
            .iter()
            .find(|identity| identity.sha256() == sha)
            .ok_or(DriverError::Library)?;
        let checked = super::super::library_guard::OriginalIdentity::controlled(
            &identity.root,
            &identity.path(),
            identity.sha256(),
            identity.length(),
        )
        .map_err(|_| DriverError::Library)?;
        if checked != *identity {
            return Err(DriverError::Library);
        }
        let file = std::fs::File::open(identity.path()).map_err(|_| DriverError::Library)?;
        if file.metadata().map_err(|_| DriverError::Library)?.len() != identity.length() {
            return Err(DriverError::Library);
        }
        self.served.insert(sha.clone());
        self.file = Some(SendingFile {
            sha,
            file,
            length: identity.length(),
            offset: 0,
            awaiting: false,
            pending_chunks: VecDeque::new(),
            acknowledged: 0,
        });
        Ok(())
    }

    pub(super) fn accept_stream_ack(&mut self, sha: String, offset: u64) -> super::Result<()> {
        if self
            .recent_acks
            .iter()
            .any(|receipt| receipt == &(sha.clone(), offset))
        {
            return Ok(());
        }
        let file = self
            .file
            .as_mut()
            .filter(|file| file.sha == sha)
            .or_else(|| self.awaiting_files.iter_mut().find(|file| file.sha == sha))
            .ok_or(DriverError::Protocol)?;
        if !file.awaiting
            || file.sha != sha
            || offset <= file.acknowledged
            || !file.pending_chunks.iter().any(|(end, _)| *end == offset)
        {
            return Err(DriverError::Protocol);
        }
        let bytes = offset - file.acknowledged;
        while file
            .pending_chunks
            .front()
            .is_some_and(|(end, _)| *end <= offset)
        {
            file.pending_chunks.pop_front();
        }
        file.acknowledged = offset;
        file.awaiting = !file.pending_chunks.is_empty();
        if file.offset == file.length && !file.awaiting {
            if self.file.as_ref().is_some_and(|file| file.sha == sha) {
                self.file = None;
            }
            self.awaiting_files.retain(|file| file.sha != sha);
        }
        self.progress.transferred_bytes = self
            .progress
            .transferred_bytes
            .checked_add(bytes)
            .ok_or(DriverError::Bounds)?;
        self.throughput.record(self.clock.monotonic_ms(), bytes);
        self.last_ack = Some((sha, offset));
        if let Some(receipt) = &self.last_ack {
            self.recent_acks.push_back(receipt.clone());
            if self.recent_acks.len() > BATCH_FILES {
                self.recent_acks.pop_front();
            }
        }
        self.verification_sent = 0;
        self.deadline = self.clock.monotonic_ms().saturating_add(super::DATA_MS);
        Ok(())
    }

    pub(super) fn accept_stream_receipts(
        &mut self,
        files: Vec<super::wire::FileReceipt>,
    ) -> super::Result<()> {
        if files.is_empty()
            || files.len() > BATCH_FILES
            || files
                .iter()
                .map(|receipt| &receipt.sha256)
                .collect::<std::collections::BTreeSet<_>>()
                .len()
                != files.len()
        {
            return Err(DriverError::Protocol);
        }
        // Validate the entire control frame before releasing any byte credit.
        for receipt in &files {
            if self
                .recent_acks
                .iter()
                .any(|previous| previous == &(receipt.sha256.clone(), receipt.offset))
            {
                continue;
            }
            let file = self
                .file
                .iter()
                .chain(self.awaiting_files.iter())
                .find(|file| file.sha == receipt.sha256)
                .ok_or(DriverError::Protocol)?;
            if !file.awaiting
                || receipt.offset <= file.acknowledged
                || !file
                    .pending_chunks
                    .iter()
                    .any(|(end, _)| *end == receipt.offset)
            {
                return Err(DriverError::Protocol);
            }
        }
        for receipt in files {
            self.accept_stream_ack(receipt.sha256, receipt.offset)?;
        }
        Ok(())
    }
}

impl CumulativeAck {
    pub(super) fn observe(&mut self, sha: &str, offset: u64, now: u64) {
        match &mut self.pending {
            Some((_, end, _)) => *end = offset,
            None => self.pending = Some((sha.into(), offset, now)),
        }
    }

    pub(super) fn ready(&self, now: u64) -> bool {
        self.pending.as_ref().is_some_and(|(_, end, since)| {
            end.saturating_sub(self.acknowledged) >= ACK_BYTES
                || now.saturating_sub(*since) >= ACK_MS
        })
    }

    pub(super) fn take(&mut self) -> Option<(String, u64)> {
        self.pending.take().map(|(sha, offset, _)| {
            self.acknowledged = offset;
            (sha, offset)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn receipts_wait_for_250ms_or_four_mib_and_reset_after_publication() {
        let mut ack = CumulativeAck::default();
        ack.observe(&"a".repeat(64), 1024 * 1024, 0);
        assert!(
            !ack.ready(25),
            "the previous 25ms cadence creates tiny reverse objects"
        );
        assert!(!ack.ready(249));
        assert!(ack.ready(250));
        ack.take().unwrap();
        ack.observe(&"a".repeat(64), 2 * 1024 * 1024, 251);
        assert!(
            !ack.ready(251),
            "already acknowledged bytes must not fill the threshold"
        );
        ack.observe(&"a".repeat(64), 5 * 1024 * 1024, 252);
        assert!(ack.ready(252));
    }
}
