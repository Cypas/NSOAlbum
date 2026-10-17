//! Versioned, path-free device-sync records. Members and rules are separate records
//! so even a large album cannot turn one page into an unbounded JSON document.
use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{CoreError, CoreResult};
use crate::models::{AlbumRule, MediaKind};

pub const VERSION: u32 = 1;
pub const FAVORITES_UUID: &str = "00000000-0000-4000-8000-000000000001";
pub const MAX_PAGE_ITEMS: usize = 128;
pub const MAX_PAGE_BYTES: usize = 65_536;
pub const MAX_MANIFEST_RECORDS: usize = 1_000_000;
pub const MAX_MANIFEST_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_TAGS_PER_MEDIA: usize = 256;
pub const MAX_MAPPING_WORK_UNITS: usize = 16_000_000;

pub(crate) struct MappingResolution {
    pub records: BTreeMap<(MappingKind, String), MappingRecord>,
    pub work_units: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManifestHeader {
    pub version: u32,
    pub library_uuid: String,
    pub generation: u64,
    /// The source's clock sample, not a fabricated object modification time.
    pub observed_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MediaRecord {
    pub sha256: String,
    pub length: u64,
    pub kind: MediaKind,
    pub extension: String,
    pub original_display_name: String,
    pub captured_at: Option<DateTime<Utc>>,
    pub imported_at: Option<DateTime<Utc>>,
    pub game_title_id: Option<String>,
    pub source_game_name: String,
    pub game_name: String,
    pub tags: Vec<String>,
    pub note: String,
    pub favorite: bool,
    /// None means the historical complete metadata revision is unknown.
    pub revision: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AlbumRecord {
    pub uuid: String,
    pub source_library_uuid: String,
    pub name: String,
    pub description: String,
    pub album_type: String,
    pub pinned: bool,
    pub system_key: Option<String>,
    pub revision: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuleRecord {
    pub album_uuid: String,
    pub group: i64,
    pub field: String,
    pub operator: String,
    pub value: String,
}

impl RuleRecord {
    pub fn as_album_rule(&self) -> AlbumRule {
        AlbumRule {
            rule_group: self.group,
            field: self.field.clone(),
            operator: self.operator.clone(),
            value: self.value.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MemberRecord {
    pub album_uuid: String,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TagRecord {
    pub name: String,
    pub revision: Option<DateTime<Utc>>,
    pub deleted: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MappingKind {
    Tag,
    Game,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MappingRecord {
    pub kind: MappingKind,
    pub source_name: String,
    pub target_name: Option<String>,
    pub revision: Option<DateTime<Utc>>,
    pub deleted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "record",
    content = "value",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub enum ManifestRecord {
    Media(MediaRecord),
    Album(AlbumRecord),
    Rule(RuleRecord),
    Member(MemberRecord),
    Tag(TagRecord),
    Mapping(MappingRecord),
}

/// Keyset cursor, valid only with its original header and unchanged generation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManifestCursor {
    pub library_uuid: String,
    pub generation: u64,
    pub section: u8,
    pub after: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManifestPage {
    pub header: ManifestHeader,
    pub records: Vec<ManifestRecord>,
    pub next: Option<ManifestCursor>,
}

impl ManifestPage {
    pub fn from_json(bytes: &[u8]) -> CoreResult<Self> {
        if bytes.len() > MAX_PAGE_BYTES {
            return Err(invalid("page byte limit exceeded"));
        }
        let page: Self = serde_json::from_slice(bytes)?;
        page.validate()?;
        Ok(page)
    }
    pub fn validate(&self) -> CoreResult<()> {
        validate_header(&self.header)?;
        if self.records.len() > MAX_PAGE_ITEMS || serde_json::to_vec(self)?.len() > MAX_PAGE_BYTES {
            return Err(invalid("page limit exceeded"));
        }
        if let Some(cursor) = &self.next {
            if cursor.library_uuid != self.header.library_uuid
                || cursor.generation != self.header.generation
                || cursor.section > 5
                || cursor.after < 0
                || self.records.is_empty()
            {
                return Err(invalid("invalid page cursor"));
            }
        }
        for record in &self.records {
            validate_record(record)?;
        }
        Ok(())
    }
}

pub struct ManifestCollector {
    header: ManifestHeader,
    records: Vec<ManifestRecord>,
    bytes: usize,
    previous: Option<ManifestCursor>,
    complete: bool,
    work: super::work::WorkControl,
}

impl ManifestCollector {
    pub fn new(header: ManifestHeader) -> CoreResult<Self> {
        Self::with_control(header, super::work::WorkControl::default())
    }
    pub fn with_control(
        header: ManifestHeader,
        work: super::work::WorkControl,
    ) -> CoreResult<Self> {
        work.check()?;
        validate_header(&header)?;
        let bytes = serde_json::to_vec(&Manifest {
            header: header.clone(),
            records: vec![],
        })?
        .len();
        Ok(Self {
            header,
            records: Vec::new(),
            bytes,
            previous: None,
            complete: false,
            work,
        })
    }
    pub fn push(&mut self, page: ManifestPage) -> CoreResult<()> {
        self.work.check()?;
        page.validate()?;
        if self.complete || page.header != self.header {
            return Err(invalid("foreign page or completed manifest"));
        }
        if let (Some(previous), Some(next)) = (&self.previous, &page.next) {
            if (next.section, next.after) <= (previous.section, previous.after) {
                return Err(invalid("repeated or out-of-order page cursor"));
            }
        }
        let count = self
            .records
            .len()
            .checked_add(page.records.len())
            .ok_or_else(|| invalid("record count overflow"))?;
        let mut bytes = self.bytes;
        for record in &page.records {
            self.work
                .checkpoint(super::work::WorkStage::Validating, 1)?;
            bytes = bytes
                .checked_add(serde_json::to_vec(record)?.len() + 1)
                .ok_or_else(|| invalid("manifest size overflow"))?;
        }
        if bytes > MAX_MANIFEST_BYTES || count > MAX_MANIFEST_RECORDS {
            return Err(invalid("manifest total limit exceeded"));
        }
        self.bytes = bytes;
        self.records.extend(page.records);
        self.complete = page.next.is_none();
        self.previous = page.next;
        Ok(())
    }
    pub fn finish(self) -> CoreResult<Manifest> {
        if !self.complete {
            return Err(invalid("manifest stream is incomplete"));
        }
        let manifest = Manifest {
            header: self.header,
            records: self.records,
        };
        manifest.validate_controlled(&self.work)?;
        Ok(manifest)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub header: ManifestHeader,
    pub records: Vec<ManifestRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AlbumState {
    pub definition: AlbumRecord,
    pub rules: Vec<RuleRecord>,
    pub members: BTreeSet<String>,
}

#[derive(Debug, Clone)]
pub struct ValidatedManifest {
    pub header: ManifestHeader,
    pub media: BTreeMap<String, MediaRecord>,
    pub albums: BTreeMap<String, AlbumState>,
    pub tags: BTreeMap<String, TagRecord>,
    pub mappings: BTreeMap<(MappingKind, String), MappingRecord>,
    pub digest: String,
}

pub(crate) fn invalid(message: &str) -> CoreError {
    CoreError::InvalidConfig(format!("device sync: {message}"))
}

pub fn normalized(value: &str) -> String {
    value.trim().to_lowercase()
}

pub(crate) fn validate_uuid(value: &str) -> CoreResult<()> {
    if uuid::Uuid::parse_str(value).is_ok_and(|uuid| uuid.to_string() == value && !uuid.is_nil()) {
        Ok(())
    } else {
        Err(invalid("invalid UUID"))
    }
}

pub(crate) fn validate_sha(value: &str) -> CoreResult<()> {
    if value.len() == 64
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        Ok(())
    } else {
        Err(invalid("invalid SHA-256"))
    }
}

fn text(value: &str, maximum: usize, empty: bool) -> CoreResult<()> {
    if value.len() > maximum || value.contains('\0') || (!empty && value.trim().is_empty()) {
        Err(invalid("invalid or oversized text"))
    } else {
        Ok(())
    }
}

pub(crate) fn validate_header(header: &ManifestHeader) -> CoreResult<()> {
    if header.version != VERSION || header.generation > i64::MAX as u64 {
        return Err(invalid("unsupported version or generation"));
    }
    validate_uuid(&header.library_uuid)
}

pub(crate) fn validate_record(record: &ManifestRecord) -> CoreResult<()> {
    match record {
        ManifestRecord::Media(media) => {
            validate_sha(&media.sha256)?;
            if media.length == 0 || media.length > i64::MAX as u64 {
                return Err(invalid("invalid media length"));
            }
            let allowed = match media.kind {
                MediaKind::Image => {
                    matches!(media.extension.as_str(), "jpg" | "jpeg" | "png" | "webp")
                }
                MediaKind::Video => matches!(media.extension.as_str(), "mp4" | "mov"),
            };
            if !allowed {
                return Err(invalid("invalid media extension"));
            }
            text(&media.original_display_name, 1024, false)?;
            if media.original_display_name.contains(['/', '\\', ':'])
                || matches!(media.original_display_name.as_str(), "." | "..")
            {
                return Err(invalid("display name must not be a path"));
            }
            text(&media.source_game_name, 1024, true)?;
            text(&media.game_name, 1024, true)?;
            text(&media.note, 8192, true)?;
            if let Some(title) = &media.game_title_id {
                text(title, 128, true)?;
            }
            if media.tags.len() > MAX_TAGS_PER_MEDIA {
                return Err(invalid("too many media tags"));
            }
            let mut tags = BTreeSet::new();
            for tag in &media.tags {
                text(tag, 128, false)?;
                if tag != tag.trim() || !tags.insert(normalized(tag)) {
                    return Err(invalid("duplicate or noncanonical media tag"));
                }
            }
        }
        ManifestRecord::Album(album) => {
            validate_uuid(&album.uuid)?;
            validate_uuid(&album.source_library_uuid)?;
            text(&album.name, 1024, false)?;
            text(&album.description, 8192, true)?;
            if !matches!(album.album_type.as_str(), "manual" | "smart")
                || album
                    .system_key
                    .as_deref()
                    .is_some_and(|key| key != "favorites")
                || (album.uuid == FAVORITES_UUID)
                    != (album.system_key.as_deref() == Some("favorites"))
                || (album.system_key.is_some() && album.album_type != "smart")
            {
                return Err(invalid("invalid album type or system identity"));
            }
        }
        ManifestRecord::Rule(rule) => {
            validate_uuid(&rule.album_uuid)?;
            if rule.group < 0
                || rule.group > 1_000_000
                || !matches!(
                    rule.field.as_str(),
                    "favorite" | "game" | "game_tag" | "note" | "type" | "tag"
                )
                || !matches!(
                    rule.operator.as_str(),
                    "equals"
                        | "not_equals"
                        | "contains"
                        | "not_contains"
                        | "starts_with"
                        | "ends_with"
                )
                || (rule.field == "favorite"
                    && (!matches!(rule.operator.as_str(), "equals" | "not_equals")
                        || !matches!(
                            normalized(&rule.value).as_str(),
                            "true" | "false" | "1" | "0" | "yes" | "no"
                        )))
            {
                return Err(invalid("invalid album rule"));
            }
            text(&rule.value, 1024, true)?;
        }
        ManifestRecord::Member(member) => {
            validate_uuid(&member.album_uuid)?;
            validate_sha(&member.sha256)?;
        }
        ManifestRecord::Tag(tag) => {
            text(&tag.name, 128, false)?;
            if tag.name != tag.name.trim() {
                return Err(invalid("noncanonical tag"));
            }
        }
        ManifestRecord::Mapping(mapping) => {
            let maximum = if mapping.kind == MappingKind::Tag {
                128
            } else {
                1024
            };
            text(&mapping.source_name, maximum, false)?;
            if mapping.source_name != mapping.source_name.trim()
                || mapping.deleted != mapping.target_name.is_none()
            {
                return Err(invalid("invalid mapping tombstone"));
            }
            if let Some(target) = &mapping.target_name {
                text(target, maximum, false)?;
                if target != target.trim() || normalized(target) == normalized(&mapping.source_name)
                {
                    return Err(invalid("invalid self mapping"));
                }
            }
        }
    }
    Ok(())
}

impl Manifest {
    pub fn from_json(bytes: &[u8]) -> CoreResult<Self> {
        if bytes.len() > MAX_MANIFEST_BYTES {
            return Err(invalid("manifest is too large"));
        }
        let manifest: Self = serde_json::from_slice(bytes)?;
        manifest.validate()?;
        Ok(manifest)
    }

    pub fn validate(&self) -> CoreResult<ValidatedManifest> {
        self.validate_controlled(&super::work::WorkControl::default())
    }

    pub fn validate_controlled(
        &self,
        work: &super::work::WorkControl,
    ) -> CoreResult<ValidatedManifest> {
        use super::work::WorkStage;
        let _scope = work.begin(WorkStage::Validating)?;
        work.checkpoint(WorkStage::Validating, 0)?;
        validate_header(&self.header)?;
        if self.records.len() > MAX_MANIFEST_RECORDS {
            return Err(invalid("too many manifest records"));
        }
        let mut result = ValidatedManifest {
            header: self.header.clone(),
            media: BTreeMap::new(),
            albums: BTreeMap::new(),
            tags: BTreeMap::new(),
            mappings: BTreeMap::new(),
            digest: String::new(),
        };
        let mut rules = BTreeSet::new();
        let mut members = BTreeSet::new();
        let mut encoded = BTreeSet::new();
        let mut bytes = serde_json::to_vec(&self.header)?.len() + 32;
        for record in &self.records {
            work.checkpoint(WorkStage::Validating, 1)?;
            validate_record(record)?;
            let canonical = match record {
                ManifestRecord::Media(media) => {
                    let mut media = media.clone();
                    media.tags.sort_by_key(|tag| normalized(tag));
                    ManifestRecord::Media(media)
                }
                other => other.clone(),
            };
            let serialized = serde_json::to_vec(&canonical)?;
            bytes = bytes
                .checked_add(serialized.len() + 1)
                .ok_or_else(|| invalid("manifest size overflow"))?;
            if bytes > MAX_MANIFEST_BYTES || serialized.len() > MAX_PAGE_BYTES - 2048 {
                return Err(invalid("manifest record or total size exceeded"));
            }
            encoded.insert(serialized);
            let duplicate = match record {
                ManifestRecord::Media(media) => {
                    let mut media = media.clone();
                    media.tags.sort_by_key(|tag| normalized(tag));
                    result.media.insert(media.sha256.clone(), media).is_some()
                }
                ManifestRecord::Album(album) => result
                    .albums
                    .insert(
                        album.uuid.clone(),
                        AlbumState {
                            definition: album.clone(),
                            rules: Vec::new(),
                            members: BTreeSet::new(),
                        },
                    )
                    .is_some(),
                ManifestRecord::Tag(tag) => result
                    .tags
                    .insert(normalized(&tag.name), tag.clone())
                    .is_some(),
                ManifestRecord::Mapping(mapping) => result
                    .mappings
                    .insert(
                        (mapping.kind, normalized(&mapping.source_name)),
                        mapping.clone(),
                    )
                    .is_some(),
                ManifestRecord::Rule(rule) => !rules.insert(rule.clone()),
                ManifestRecord::Member(member) => {
                    !members.insert((member.album_uuid.clone(), member.sha256.clone()))
                }
            };
            if duplicate {
                return Err(invalid("duplicate manifest record"));
            }
        }
        if !result.albums.contains_key(FAVORITES_UUID) {
            return Err(invalid("system favorites album is missing"));
        }
        for rule in rules {
            work.check()?;
            let album = result
                .albums
                .get_mut(&rule.album_uuid)
                .ok_or_else(|| invalid("orphan album rule"))?;
            if album.definition.album_type != "smart" {
                return Err(invalid("manual album has rules"));
            }
            album.rules.push(rule);
        }
        for (uuid, sha) in members {
            work.check()?;
            if !result.media.contains_key(&sha) {
                return Err(invalid("orphan album member"));
            }
            let album = result
                .albums
                .get_mut(&uuid)
                .ok_or_else(|| invalid("orphan album member"))?;
            if album.definition.album_type != "manual" {
                return Err(invalid("derived album must not contain frozen members"));
            }
            album.members.insert(sha);
        }
        for media in result.media.values() {
            work.check()?;
            for tag in &media.tags {
                if !result
                    .tags
                    .get(&normalized(tag))
                    .is_some_and(|tag| !tag.deleted)
                {
                    return Err(invalid("media refers to missing or deleted tag"));
                }
            }
        }
        resolve_mapping_graph_controlled(&result.mappings, MAX_MAPPING_WORK_UNITS, work)?;
        // A length prefix prevents record-boundary ambiguity; order is immaterial.
        let mut hash = Sha256::new();
        hash.update(serde_json::to_vec(&self.header)?);
        for record in encoded {
            work.check()?;
            hash.update((record.len() as u64).to_be_bytes());
            hash.update(record);
        }
        result.digest = hex::encode(hash.finalize());
        Ok(result)
    }
}

#[cfg(test)]
pub(crate) fn resolve_mapping_graph(
    mappings: &BTreeMap<(MappingKind, String), MappingRecord>,
    maximum_work: usize,
) -> CoreResult<MappingResolution> {
    resolve_mapping_graph_controlled(mappings, maximum_work, &super::work::WorkControl::default())
}

pub(crate) fn resolve_mapping_graph_controlled(
    mappings: &BTreeMap<(MappingKind, String), MappingRecord>,
    maximum_work: usize,
    work: &super::work::WorkControl,
) -> CoreResult<MappingResolution> {
    let _scope = work.begin(super::work::WorkStage::Mapping)?;
    let mut records = BTreeMap::new();
    let mut work_units = 0usize;
    for (start, mapping) in mappings {
        work.checkpoint(super::work::WorkStage::Mapping, 1)?;
        if mapping.deleted || records.contains_key(start) {
            continue;
        }
        let mut path = Vec::new();
        let mut visiting = BTreeSet::new();
        let mut current = start.clone();
        loop {
            work.checkpoint(super::work::WorkStage::Mapping, 1)?;
            if records.contains_key(&current) {
                break;
            }
            if !visiting.insert(current.clone()) {
                return Err(invalid("mapping cycle"));
            }
            let record = &mappings[&current];
            let target = record
                .target_name
                .as_deref()
                .ok_or_else(|| invalid("invalid active mapping"))?;
            charge_mapping_work(
                &mut work_units,
                1 + record.source_name.len() + target.len(),
                maximum_work,
            )?;
            let next = (current.0, normalized(target));
            if mappings.get(&next).is_some_and(|mapping| !mapping.deleted) {
                path.push((current, next.clone()));
                current = next;
            } else {
                let result = resolved_mapping(
                    record,
                    target,
                    record.revision,
                    &mut work_units,
                    maximum_work,
                )?;
                records.insert(current, result);
                break;
            }
        }
        // Every live node is resolved once, including shared tails. The explicit
        // path stack handles deep graphs without recursion or suffix rescans.
        for (key, next) in path.into_iter().rev() {
            work.checkpoint(super::work::WorkStage::Mapping, 1)?;
            let record = &mappings[&key];
            let (target, revision) = if key.0 == MappingKind::Tag {
                let tail = &records[&next];
                let revision = match (record.revision, tail.revision) {
                    (Some(first), Some(second)) => Some(first.max(second)),
                    _ => None,
                };
                (
                    tail.target_name.as_deref().expect("resolved live mapping"),
                    revision,
                )
            } else {
                // Raw game sources and display names are different namespaces.
                // We validate cycles but never reinterpret a display as a raw key.
                (
                    record.target_name.as_deref().expect("active mapping"),
                    record.revision,
                )
            };
            let result = resolved_mapping(record, target, revision, &mut work_units, maximum_work)?;
            records.insert(key, result);
        }
    }
    Ok(MappingResolution {
        records,
        work_units,
    })
}

fn charge_mapping_work(used: &mut usize, amount: usize, maximum: usize) -> CoreResult<()> {
    let next = used
        .checked_add(amount)
        .ok_or_else(|| invalid("mapping work overflow"))?;
    if next > maximum {
        return Err(invalid("mapping work budget exceeded"));
    }
    *used = next;
    Ok(())
}

fn resolved_mapping(
    record: &MappingRecord,
    target: &str,
    revision: Option<DateTime<Utc>>,
    work: &mut usize,
    maximum: usize,
) -> CoreResult<MappingRecord> {
    charge_mapping_work(work, record.source_name.len() + target.len(), maximum)?;
    Ok(MappingRecord {
        kind: record.kind,
        source_name: record.source_name.clone(),
        target_name: Some(target.into()),
        revision,
        deleted: false,
    })
}
