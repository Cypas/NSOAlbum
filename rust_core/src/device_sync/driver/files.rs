//! Multi-file request pipelining. Frames and receiver open files remain bounded.
use super::*;

impl Driver {
    pub(super) fn next_requested_file(&mut self) -> Result<Option<String>> {
        if self.requested_files.is_empty() && !self.needed.is_empty() {
            let mut batch = vec![];
            let mut batch_bytes = 0_u64;
            while let Some(sha) = self.needed.front() {
                let length = self
                    .receive
                    .as_ref()
                    .ok_or(DriverError::Protocol)?
                    .plan()
                    .media
                    .iter()
                    .find(|decision| &decision.sha256 == sha)
                    .and_then(|decision| decision.final_record.as_ref())
                    .ok_or(DriverError::Protocol)?
                    .length;
                if !batch.is_empty()
                    && (length > flow::SMALL_FILE_BYTES
                        || batch.len() == flow::BATCH_FILES
                        || batch_bytes.saturating_add(length) > flow::BATCH_BYTES)
                {
                    break;
                }
                batch.push(self.needed.pop_front().ok_or(DriverError::Protocol)?);
                batch_bytes = batch_bytes.saturating_add(length);
                if length > flow::SMALL_FILE_BYTES {
                    break;
                }
            }
            self.requested_files.extend(batch.iter().cloned());
            if batch.len() == 1 {
                self.enqueue(Message::FileRequest {
                    sha256: batch.remove(0),
                })?;
            } else {
                self.enqueue(Message::FileRequestBatch { sha256: batch })?;
            }
        }
        Ok(self.requested_files.pop_front())
    }

    pub(super) fn start_stream_batch(&mut self, hashes: Vec<String>) -> Result<()> {
        if hashes.len() < 2
            || hashes.len() > flow::BATCH_FILES
            || hashes.iter().collect::<BTreeSet<_>>().len() != hashes.len()
        {
            return Err(DriverError::Protocol);
        }
        // Validate the complete authorized batch before opening any source file.
        let mut total = 0_u64;
        for sha in &hashes {
            let record = self
                .plan
                .as_ref()
                .ok_or(DriverError::Protocol)?
                .media
                .iter()
                .find(|decision| &decision.sha256 == sha && !decision.reuse_original)
                .and_then(|decision| decision.final_record.as_ref())
                .ok_or(DriverError::Protocol)?;
            if self.served.contains(sha) || record.length > flow::SMALL_FILE_BYTES {
                return Err(DriverError::Protocol);
            }
            total = total
                .checked_add(record.length)
                .ok_or(DriverError::Bounds)?;
            if total > flow::BATCH_BYTES {
                return Err(DriverError::Protocol);
            }
        }
        for sha in hashes {
            self.start_stream_file(sha)?;
            self.pending_files
                .push_back(self.file.take().ok_or(DriverError::Protocol)?);
        }
        self.file = self.pending_files.pop_front();
        Ok(())
    }

    pub(super) fn advance_stream_file(&mut self) {
        if self
            .file
            .as_ref()
            .is_some_and(|file| file.offset == file.length)
            && !self.pending_files.is_empty()
        {
            if let Some(file) = self.file.take() {
                self.awaiting_files.push_back(file);
            }
        }
        if self.file.is_none() {
            self.file = self.pending_files.pop_front();
        }
    }
}
