//! Strict, bounded application messages inside the authenticated Session.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};

use super::clock::ConnectionSample;
use super::manifest::{
    Manifest, ManifestCollector, ManifestCursor, ManifestHeader, ManifestPage, MAX_PAGE_BYTES,
};
use super::planner::SyncMode;
use super::receiver::Snapshot;
use super::source_names::{
    SourceDescriptionPage, SourceDescriptions, MAX_SOURCES, MAX_SOURCE_BYTES,
};
use super::{SessionError, MAX_PAYLOAD};

pub const RAW_CHUNK: usize = 32_768;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    DesktopToPhone,
    PhoneToDesktop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PageKind {
    Manifest,
    Sources,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApplyPhase {
    #[default]
    Preparing,
    Publishing,
    Sql,
    Finalizing,
    Accounts,
}
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApplyWork {
    pub phase: ApplyPhase,
    pub publication_bytes: u64,
    pub sql_steps: u64,
    pub account_steps: u16,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub version: u8,
    pub session: String,
    pub operation: String,
    pub generation: u64,
    pub sequence: u64,
    pub message: Message,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Message {
    Configure {
        direction: Direction,
        mode: SyncMode,
        include_accounts: bool,
        start_ms: i64,
    },
    ClockReply {
        start_ms: i64,
        peer_ms: i64,
    },
    ClockSample {
        sample: ConnectionSample,
    },
    AccountConsent {
        accepted: bool,
    },
    ControllerAccountConsent {
        direction: Direction,
        mode: SyncMode,
        accepted: bool,
    },
    AccountPart {
        offset: usize,
        total: usize,
        data: String,
    },
    AccountEnd {
        digest: String,
        state_digest: String,
    },
    AccountBinding {
        source_digest: String,
        source_state: String,
        target_state: String,
    },
    SnapshotStart {
        header: ManifestHeader,
    },
    PagePart {
        page_kind: PageKind,
        page: u32,
        offset: usize,
        total: usize,
        data: String,
    },
    SnapshotEnd {
        digest: String,
    },
    PreparationProgress {
        source_digest: String,
        completed_bytes: u64,
    },
    Preview {
        binding: String,
    },
    ControllerPreview {
        summary: Box<super::read_model::PreviewSummary>,
        transfer_total_bytes: u64,
    },
    ControllerAccountsPreview {
        binding: String,
        counts: super::read_model::ChangeCounts,
    },
    ControllerApproval {
        binding: String,
    },
    Approved {
        binding: String,
    },
    FileRequest {
        sha256: String,
    },
    FileChunk {
        sha256: String,
        offset: u64,
        data: String,
    },
    FileVerification {
        sha256: String,
        completed: u64,
    },
    ChunkAccepted {
        sha256: String,
        offset: u64,
    },
    FilesComplete {},
    LeaseRequest {
        binding: String,
        id: u64,
        work: ApplyWork,
    },
    LeaseGranted {
        binding: String,
        id: u64,
        work: ApplyWork,
    },
    CommitAck {
        binding: String,
    },
    Abort {},
}

impl std::fmt::Debug for Message {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Message([REDACTED])")
    }
}

impl Envelope {
    pub fn encode(&self) -> Result<Vec<u8>, SessionError> {
        let bytes = serde_json::to_vec(self).map_err(|_| SessionError::Protocol)?;
        if bytes.len() > MAX_PAYLOAD {
            return Err(SessionError::Bounds);
        }
        Ok(bytes)
    }
    pub fn decode(bytes: &[u8]) -> Result<Self, SessionError> {
        if bytes.is_empty() || bytes.len() > MAX_PAYLOAD {
            return Err(SessionError::Bounds);
        }
        let envelope: Self = serde_json::from_slice(bytes).map_err(|_| SessionError::Protocol)?;
        if envelope.version != 1
            || !super::qr::valid_hex(&envelope.session, 32)
            || !super::qr::valid_hex(&envelope.operation, 32)
            || envelope.generation != 1
        {
            return Err(SessionError::Protocol);
        }
        Ok(envelope)
    }
}

pub fn encode_chunk(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}
pub fn decode_chunk(data: &str) -> Result<Vec<u8>, SessionError> {
    if data.is_empty() || data.len() > RAW_CHUNK.div_ceil(3) * 4 {
        return Err(SessionError::Bounds);
    }
    let bytes = STANDARD.decode(data).map_err(|_| SessionError::Protocol)?;
    if bytes.is_empty() || bytes.len() > RAW_CHUNK {
        return Err(SessionError::Bounds);
    }
    Ok(bytes)
}

/// Only one serialized page and one chunk are retained at a time.
pub(crate) struct MetadataSender {
    snapshot: Snapshot,
    position: usize,
    page: u32,
    kind: PageKind,
    source_pages: std::collections::VecDeque<SourceDescriptionPage>,
    blob: Vec<u8>,
    offset: usize,
    finished: bool,
    work: super::work::WorkControl,
}

impl MetadataSender {
    pub fn with_control(
        snapshot: Snapshot,
        work: &super::work::WorkControl,
    ) -> Result<Self, SessionError> {
        let source_pages = snapshot
            .sources
            .pages_controlled(&snapshot.manifest, work)
            .map_err(|_| SessionError::Protocol)?
            .into();
        Ok(Self {
            snapshot,
            position: 0,
            page: 0,
            kind: PageKind::Manifest,
            source_pages,
            blob: vec![],
            offset: 0,
            finished: false,
            work: work.clone(),
        })
    }
    pub fn next(&mut self) -> Result<Option<Message>, SessionError> {
        self.work.check().map_err(|_| SessionError::Terminal)?;
        if self.finished {
            return Ok(None);
        }
        if self.blob.is_empty() {
            if self.kind == PageKind::Manifest {
                let mut page = ManifestPage {
                    header: self.snapshot.manifest.header.clone(),
                    records: vec![],
                    next: None,
                };
                while self.position + page.records.len() < self.snapshot.manifest.records.len()
                    && page.records.len() < 128
                {
                    page.records.push(
                        self.snapshot.manifest.records[self.position + page.records.len()].clone(),
                    );
                    page.next = Some(ManifestCursor {
                        library_uuid: page.header.library_uuid.clone(),
                        generation: page.header.generation,
                        section: 5,
                        after: (self.position + page.records.len()) as i64,
                    });
                    if serde_json::to_vec(&page)
                        .map_err(|_| SessionError::Protocol)?
                        .len()
                        > MAX_PAGE_BYTES
                    {
                        page.records.pop();
                        break;
                    }
                }
                self.position += page.records.len();
                page.next = if self.position == self.snapshot.manifest.records.len() {
                    None
                } else {
                    Some(ManifestCursor {
                        library_uuid: page.header.library_uuid.clone(),
                        generation: page.header.generation,
                        section: 5,
                        after: self.position as i64,
                    })
                };
                page.validate().map_err(|_| SessionError::Bounds)?;
                self.blob = serde_json::to_vec(&page).map_err(|_| SessionError::Protocol)?;
            } else if let Some(page) = self.source_pages.pop_front() {
                self.blob = serde_json::to_vec(&page).map_err(|_| SessionError::Protocol)?;
            } else {
                self.finished = true;
                return Ok(Some(Message::SnapshotEnd {
                    digest: self
                        .snapshot
                        .digest_controlled(&self.work)
                        .map_err(|_| SessionError::Protocol)?,
                }));
            }
        }
        let end = (self.offset + RAW_CHUNK).min(self.blob.len());
        let result = Message::PagePart {
            page_kind: self.kind,
            page: self.page,
            offset: self.offset,
            total: self.blob.len(),
            data: encode_chunk(&self.blob[self.offset..end]),
        };
        self.offset = end;
        if self.offset == self.blob.len() {
            self.blob.clear();
            self.offset = 0;
            self.page += 1;
            if self.kind == PageKind::Manifest
                && self.position == self.snapshot.manifest.records.len()
            {
                self.kind = PageKind::Sources;
                self.page = 0;
            }
        }
        Ok(Some(result))
    }
}

pub(crate) struct MetadataReceiver {
    collector: Option<ManifestCollector>,
    manifest: Option<Manifest>,
    sources: Vec<SourceDescriptionPage>,
    source_bytes: usize,
    kind: PageKind,
    page: u32,
    blob: Vec<u8>,
    total: usize,
    sources_complete: bool,
    work: super::work::WorkControl,
}
impl MetadataReceiver {
    #[cfg(test)]
    pub fn new(header: ManifestHeader) -> Result<Self, SessionError> {
        Self::with_control(header, super::work::WorkControl::default())
    }
    pub fn with_control(
        header: ManifestHeader,
        work: super::work::WorkControl,
    ) -> Result<Self, SessionError> {
        Ok(Self {
            collector: Some(
                ManifestCollector::with_control(header, work.clone())
                    .map_err(|_| SessionError::Protocol)?,
            ),
            manifest: None,
            sources: vec![],
            source_bytes: 0,
            kind: PageKind::Manifest,
            page: 0,
            blob: vec![],
            total: 0,
            sources_complete: false,
            work,
        })
    }
    pub fn part(
        &mut self,
        kind: PageKind,
        page: u32,
        offset: usize,
        total: usize,
        data: &str,
    ) -> Result<(), SessionError> {
        if self.sources_complete
            || kind != self.kind
            || page != self.page
            || offset != self.blob.len()
            || total == 0
            || total > MAX_PAGE_BYTES
            || (offset != 0 && self.total != total)
        {
            return Err(SessionError::Protocol);
        }
        let bytes = decode_chunk(data)?;
        if offset.checked_add(bytes.len()).is_none_or(|n| n > total) {
            return Err(SessionError::Bounds);
        }
        self.total = total;
        self.blob.extend(bytes);
        if self.blob.len() != total {
            return Ok(());
        }
        match kind {
            PageKind::Manifest => {
                let value =
                    ManifestPage::from_json(&self.blob).map_err(|_| SessionError::Protocol)?;
                let complete = value.next.is_none();
                self.collector
                    .as_mut()
                    .ok_or(SessionError::Protocol)?
                    .push(value)
                    .map_err(|_| SessionError::Protocol)?;
                self.page += 1;
                if complete {
                    self.manifest = Some(
                        self.collector
                            .take()
                            .ok_or(SessionError::Protocol)?
                            .finish()
                            .map_err(|_| SessionError::Protocol)?,
                    );
                    self.kind = PageKind::Sources;
                    self.page = 0;
                }
            }
            PageKind::Sources => {
                let value = SourceDescriptionPage::from_json(&self.blob)
                    .map_err(|_| SessionError::Protocol)?;
                self.source_bytes = self
                    .source_bytes
                    .checked_add(total)
                    .ok_or(SessionError::Bounds)?;
                if self.sources.len() >= MAX_SOURCES || self.source_bytes > MAX_SOURCE_BYTES {
                    return Err(SessionError::Bounds);
                }
                let offset: usize = self.sources.iter().map(|p| p.entries.len()).sum();
                if value.offset != offset
                    || self.sources.first().is_some_and(|p| p.total != value.total)
                {
                    return Err(SessionError::Protocol);
                }
                self.sources_complete = offset + value.entries.len() == value.total;
                self.sources.push(value);
                self.page += 1;
            }
        }
        self.blob.clear();
        Ok(())
    }
    pub fn finish(self, digest: &str) -> Result<Snapshot, SessionError> {
        if !self.blob.is_empty() || !self.sources_complete {
            return Err(SessionError::Protocol);
        }
        let manifest = self.manifest.ok_or(SessionError::Protocol)?;
        let sources =
            SourceDescriptions::from_pages_controlled(self.sources, &manifest, &self.work)
                .map_err(|_| SessionError::Protocol)?;
        let snapshot = Snapshot { manifest, sources };
        if snapshot
            .digest_controlled(&self.work)
            .map_err(|_| SessionError::Protocol)?
            != digest
        {
            return Err(SessionError::Protocol);
        }
        Ok(snapshot)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_sync::manifest::{ManifestRecord, MediaRecord};
    use crate::models::MediaKind;

    fn snapshot() -> Snapshot {
        let root = tempfile::tempdir().unwrap();
        let api = crate::api::CoreApi::open(root.path()).unwrap();
        let mut snapshot = Snapshot::read(&api.database(), "Wire").unwrap();
        for index in 0..8 {
            snapshot
                .manifest
                .records
                .push(ManifestRecord::Media(MediaRecord {
                    sha256: format!("{index:064x}"),
                    length: 1,
                    kind: MediaKind::Image,
                    extension: "jpg".into(),
                    original_display_name: "image.jpg".into(),
                    captured_at: None,
                    imported_at: None,
                    game_title_id: None,
                    source_game_name: String::new(),
                    game_name: String::new(),
                    tags: vec![],
                    note: if index < 7 {
                        "x".repeat(8192)
                    } else {
                        String::new()
                    },
                    favorite: false,
                    revision: None,
                }));
        }
        let page = ManifestPage {
            header: snapshot.manifest.header.clone(),
            records: snapshot.manifest.records.clone(),
            next: None,
        };
        let size = serde_json::to_vec(&page).unwrap().len();
        if let Some(ManifestRecord::Media(media)) = snapshot.manifest.records.last_mut() {
            media.note = "z".repeat(MAX_PAGE_BYTES - size);
        }
        snapshot.sources =
            SourceDescriptions::new(&snapshot.manifest, snapshot.sources.entries).unwrap();
        snapshot
    }

    #[test]
    fn wire_exact_maximum_page_fragments_fit_envelope_and_reassemble() {
        let snapshot = snapshot();
        let page = ManifestPage {
            header: snapshot.manifest.header.clone(),
            records: snapshot.manifest.records.clone(),
            next: None,
        };
        let bytes = serde_json::to_vec(&page).unwrap();
        assert_eq!(bytes.len(), 65_536);
        page.validate().unwrap();
        let mut receive = MetadataReceiver::new(page.header.clone()).unwrap();
        for (index, part) in bytes.chunks(RAW_CHUNK).enumerate() {
            let data = encode_chunk(part);
            let envelope = Envelope {
                version: 1,
                session: "a".repeat(32),
                operation: "b".repeat(32),
                generation: 1,
                sequence: index as u64,
                message: Message::PagePart {
                    page_kind: PageKind::Manifest,
                    page: 0,
                    offset: index * RAW_CHUNK,
                    total: bytes.len(),
                    data: data.clone(),
                },
            };
            assert!(envelope.encode().unwrap().len() <= 65_536);
            receive
                .part(PageKind::Manifest, 0, index * RAW_CHUNK, bytes.len(), &data)
                .unwrap();
        }
        let sources = snapshot.sources.pages(&snapshot.manifest).unwrap();
        let bytes = serde_json::to_vec(&sources[0]).unwrap();
        receive
            .part(PageKind::Sources, 0, 0, bytes.len(), &encode_chunk(&bytes))
            .unwrap();
        assert_eq!(
            receive.finish(&snapshot.digest().unwrap()).unwrap(),
            snapshot
        );
    }

    #[test]
    fn wire_missing_duplicate_out_of_order_and_oversized_parts_fail_closed() {
        let snapshot = snapshot();
        for (page, offset, total) in [(1, 0, 65536), (0, 1, 65536), (0, 0, 65537), (0, 0, 0)] {
            let mut receive = MetadataReceiver::new(snapshot.manifest.header.clone()).unwrap();
            assert!(receive
                .part(
                    PageKind::Manifest,
                    page,
                    offset,
                    total,
                    &encode_chunk(b"abc")
                )
                .is_err());
        }
        let page = ManifestPage {
            header: snapshot.manifest.header.clone(),
            records: snapshot.manifest.records.clone(),
            next: None,
        };
        let bytes = serde_json::to_vec(&page).unwrap();
        let mut receive = MetadataReceiver::new(page.header.clone()).unwrap();
        let data = encode_chunk(&bytes[..RAW_CHUNK]);
        receive
            .part(PageKind::Manifest, 0, 0, bytes.len(), &data)
            .unwrap();
        assert!(receive
            .part(PageKind::Manifest, 0, 0, bytes.len(), &data)
            .is_err());
        assert!(receive.finish(&snapshot.digest().unwrap()).is_err());
        assert!(decode_chunk(&encode_chunk(&vec![0; RAW_CHUNK + 1])).is_err());
        assert!(Envelope::decode(&vec![b' '; 65_537]).is_err());
        let env = Envelope {
            version: 1,
            session: "a".repeat(32),
            operation: "b".repeat(32),
            generation: 1,
            sequence: 0,
            message: Message::FilesComplete {},
        };
        let mut value = serde_json::to_value(env).unwrap();
        value["unknown"] = true.into();
        assert!(Envelope::decode(&serde_json::to_vec(&value).unwrap()).is_err());
        value.as_object_mut().unwrap().remove("unknown");
        value["message"]["extra"] = true.into();
        assert!(Envelope::decode(&serde_json::to_vec(&value).unwrap()).is_err());
        value["message"] = serde_json::json!({"kind":"accounts","token":"forbidden"});
        assert!(Envelope::decode(&serde_json::to_vec(&value).unwrap()).is_err());
    }
}
