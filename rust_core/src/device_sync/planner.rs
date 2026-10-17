//! Pure preview. The apply layer consumes this exact plan after checking its
//! source/target digests and target generation; it must not reimplement policy.
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

use super::manifest::*;
use crate::error::CoreResult;

pub const MAX_ALBUM_EVALUATION_WORK_UNITS: usize = 32_000_000;
pub const MAX_EVALUATED_MEMBER_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SyncMode {
    Merge,
    Overwrite,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Add,
    Replace,
    Remove,
    Keep,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConflictReason {
    UnknownRevision,
    EqualRevision,
    ClockSkew,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Conflict {
    pub object_kind: String,
    pub identity: String,
    pub reason: ConflictReason,
    pub source_revision: Option<DateTime<Utc>>,
    pub target_revision: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MediaDecision {
    pub sha256: String,
    pub action: Action,
    pub final_record: Option<MediaRecord>,
    pub reuse_original: bool,
    pub revision_only: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AlbumDecision {
    pub uuid: String,
    pub action: Action,
    pub final_state: Option<AlbumState>,
    /// Display-only derived membership. Never persist this to a smart album.
    pub evaluated_members: Vec<String>,
    pub revision_only: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SpaceEstimate {
    pub new_staging_bytes: u64,
    pub reusable_original_bytes: u64,
    pub backup_original_bytes: u64,
    pub backup_bytes_if_copied: u64,
    pub conservative_content_bytes: u64,
    pub excludes_metadata_and_filesystem_overhead: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AccountAuthorizationPreview {
    pub source_account_count: u32,
    pub selected: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SyncPlan {
    pub version: u32,
    pub mode: SyncMode,
    pub source_library_uuid: String,
    pub target_library_uuid: String,
    pub source_digest: String,
    pub target_digest: String,
    pub target_generation: u64,
    pub media: Vec<MediaDecision>,
    pub albums: Vec<AlbumDecision>,
    pub tags: Vec<TagRecord>,
    pub mappings: Vec<MappingRecord>,
    pub conflicts: Vec<Conflict>,
    pub space: SpaceEstimate,
    /// Reserved for an independently authorized account-transfer phase.
    pub account_authorization: Option<AccountAuthorizationPreview>,
    #[serde(default)]
    pub connection_clock: Option<super::clock::ClockTrust>,
}

pub fn build_plan(source: &Manifest, target: &Manifest, mode: SyncMode) -> CoreResult<SyncPlan> {
    build_plan_with_clock(source, target, mode, None)
}

pub fn build_plan_with_clock(
    source: &Manifest,
    target: &Manifest,
    mode: SyncMode,
    connection_clock: Option<super::clock::ClockTrust>,
) -> CoreResult<SyncPlan> {
    build_plan_controlled(
        source,
        target,
        mode,
        connection_clock,
        &super::work::WorkControl::default(),
    )
}

pub fn build_plan_controlled(
    source: &Manifest,
    target: &Manifest,
    mode: SyncMode,
    connection_clock: Option<super::clock::ClockTrust>,
    work: &super::work::WorkControl,
) -> CoreResult<SyncPlan> {
    let _scope = work.begin(super::work::WorkStage::Comparing)?;
    let source = source.validate_controlled(work)?;
    let target = target.validate_controlled(work)?;
    let legacy_skew = source
        .header
        .observed_at
        .signed_duration_since(target.header.observed_at)
        .abs()
        > chrono::Duration::seconds(120);
    let skew = connection_clock
        .map(|trust| trust != super::clock::ClockTrust::WithinLimit)
        .unwrap_or(legacy_skew);
    let mut policy = Policy {
        skew,
        conflicts: vec![],
    };
    let mut media = Vec::new();
    let mut final_media = BTreeMap::new();
    let mut staging = 0;
    let mut reused = 0;
    let backup = checked_sum(target.media.values().map(|media| media.length))?;
    for sha in controlled_keys(source.media.keys().chain(target.media.keys()), work)? {
        work.checkpoint(super::work::WorkStage::Comparing, 1)?;
        let incoming = source.media.get(sha);
        let existing = target.media.get(sha);
        let (action, final_record, revision_only) = match (incoming, existing) {
            (Some(incoming), Some(existing)) => {
                if incoming.length != existing.length || incoming.kind != existing.kind {
                    return Err(invalid("same SHA-256 declares incompatible length or type"));
                }
                if same_media_info(incoming, existing) {
                    let mut value = existing.clone();
                    value.revision =
                        policy.same_content_revision(incoming.revision, existing.revision);
                    let revision_only = value.revision != existing.revision;
                    (Action::Keep, Some(value), revision_only)
                } else if policy.prefer_source(
                    incoming.revision,
                    existing.revision,
                    "media",
                    sha,
                    mode,
                ) {
                    (Action::Replace, Some(incoming.clone()), false)
                } else {
                    (Action::Keep, Some(existing.clone()), false)
                }
            }
            (Some(incoming), None) => (Action::Add, Some(incoming.clone()), false),
            (None, Some(existing)) if mode == SyncMode::Merge => {
                (Action::Keep, Some(existing.clone()), false)
            }
            (None, Some(_)) => (Action::Remove, None, false),
            (None, None) => unreachable!(),
        };
        if let Some(value) = &final_record {
            if existing.is_some() {
                reused = add_bytes(reused, value.length)?;
            } else {
                staging = add_bytes(staging, value.length)?;
            }
            final_media.insert(sha.clone(), value.clone());
        }
        media.push(MediaDecision {
            sha256: sha.clone(),
            action,
            final_record,
            reuse_original: existing.is_some() && action != Action::Remove,
            revision_only,
        });
    }
    let mut albums = Vec::new();
    let mut evaluation_budget = EvaluationBudget {
        control: work.clone(),
        ..Default::default()
    };
    for uuid in controlled_keys(source.albums.keys().chain(target.albums.keys()), work)? {
        work.checkpoint(super::work::WorkStage::Comparing, 1)?;
        let incoming = source.albums.get(uuid);
        let existing = target.albums.get(uuid);
        let (action, mut final_state, revision_only) = match (incoming, existing) {
            (Some(incoming), Some(existing)) if uuid.as_str() == FAVORITES_UUID => {
                // A receiver keeps the presentation of its one system album.
                // Its membership is always derived from the final favorites.
                let _ = incoming;
                (Action::Keep, Some(existing.clone()), false)
            }
            (Some(incoming), Some(existing)) => {
                if incoming.definition.source_library_uuid
                    != existing.definition.source_library_uuid
                {
                    return Err(invalid("same album UUID has incompatible source identity"));
                }
                if same_album(incoming, existing) {
                    let mut value = existing.clone();
                    value.definition.revision = policy.same_content_revision(
                        incoming.definition.revision,
                        existing.definition.revision,
                    );
                    let revision_only = value.definition.revision != existing.definition.revision;
                    (Action::Keep, Some(value), revision_only)
                } else if policy.prefer_source(
                    incoming.definition.revision,
                    existing.definition.revision,
                    "album",
                    uuid,
                    mode,
                ) {
                    (Action::Replace, Some(incoming.clone()), false)
                } else {
                    (Action::Keep, Some(existing.clone()), false)
                }
            }
            (Some(incoming), None) => (Action::Add, Some(incoming.clone()), false),
            (None, Some(existing))
                if mode == SyncMode::Merge || uuid.as_str() == FAVORITES_UUID =>
            {
                (Action::Keep, Some(existing.clone()), false)
            }
            (None, Some(_)) => (Action::Remove, None, false),
            (None, None) => unreachable!(),
        };
        let evaluated_members = if let Some(state) = &mut final_state {
            state.members.retain(|sha| final_media.contains_key(sha));
            evaluate_album(state, &final_media, &mut evaluation_budget)?
        } else {
            vec![]
        };
        albums.push(AlbumDecision {
            uuid: uuid.clone(),
            action,
            final_state,
            evaluated_members,
            revision_only,
        });
    }
    let mut tags = BTreeMap::new();
    for key in controlled_keys(source.tags.keys().chain(target.tags.keys()), work)? {
        work.checkpoint(super::work::WorkStage::Comparing, 1)?;
        let incoming = source.tags.get(key);
        let existing = target.tags.get(key);
        let selected = match (incoming, existing) {
            (Some(incoming), Some(existing))
                if incoming.name == existing.name && incoming.deleted == existing.deleted =>
            {
                let mut value = existing.clone();
                value.revision = policy.same_content_revision(incoming.revision, existing.revision);
                Some(value)
            }
            (Some(incoming), Some(existing)) => Some(
                if policy.prefer_source(incoming.revision, existing.revision, "tag", key, mode) {
                    incoming
                } else {
                    existing
                }
                .clone(),
            ),
            (Some(incoming), None) => Some(incoming.clone()),
            (None, Some(existing)) if mode == SyncMode::Merge => Some(existing.clone()),
            _ => None,
        };
        if let Some(value) = selected {
            tags.insert(key.clone(), value);
        }
    }
    // A catalog tombstone must not silently remove tags from an independently
    // retained complete media version. Mapping tombstones still prevent old
    // rename operations from being replayed.
    for record in final_media.values() {
        work.check()?;
        for tag in &record.tags {
            let key = normalized(tag);
            if !tags.get(&key).is_some_and(|entry| !entry.deleted) {
                tags.insert(
                    key,
                    TagRecord {
                        name: tag.clone(),
                        revision: record.revision,
                        deleted: false,
                    },
                );
            }
        }
    }
    // Tags are shared objects keyed by the existing normalized identity. Their
    // catalog owns display spelling, not each media version independently.
    for decision in &mut media {
        work.check()?;
        if let Some(record) = &mut decision.final_record {
            for tag in &mut record.tags {
                *tag = tags
                    .get(&normalized(tag))
                    .filter(|entry| !entry.deleted)
                    .ok_or_else(|| invalid("final media tag has no live catalog identity"))?
                    .name
                    .clone();
            }
        }
    }
    let mut mappings = BTreeMap::new();
    for key in controlled_keys(source.mappings.keys().chain(target.mappings.keys()), work)? {
        work.checkpoint(super::work::WorkStage::Comparing, 1)?;
        let incoming = source.mappings.get(key);
        let existing = target.mappings.get(key);
        let selected = match (incoming, existing) {
            (Some(incoming), Some(existing))
                if incoming.target_name == existing.target_name
                    && incoming.deleted == existing.deleted =>
            {
                let mut value = existing.clone();
                value.revision = policy.same_content_revision(incoming.revision, existing.revision);
                Some(value)
            }
            (Some(incoming), Some(existing)) => Some(
                if policy.prefer_source(
                    incoming.revision,
                    existing.revision,
                    "mapping",
                    &format!("{:?}:{}", key.0, key.1),
                    mode,
                ) {
                    incoming
                } else {
                    existing
                }
                .clone(),
            ),
            (Some(incoming), None) => Some(incoming.clone()),
            (None, Some(existing)) if mode == SyncMode::Merge => Some(existing.clone()),
            _ => None,
        };
        if let Some(value) = selected {
            mappings.insert(key.clone(), value);
        }
    }
    flatten_mappings_controlled(&mut mappings, work)?;
    work.check()?;
    Ok(SyncPlan {
        version: VERSION,
        mode,
        source_library_uuid: source.header.library_uuid,
        target_library_uuid: target.header.library_uuid,
        source_digest: source.digest,
        target_digest: target.digest,
        target_generation: target.header.generation,
        media,
        albums,
        tags: tags.into_values().collect(),
        mappings: mappings.into_values().collect(),
        conflicts: policy.conflicts,
        space: SpaceEstimate {
            new_staging_bytes: staging,
            reusable_original_bytes: reused,
            backup_original_bytes: backup,
            backup_bytes_if_copied: backup,
            conservative_content_bytes: add_bytes(staging, backup)?,
            excludes_metadata_and_filesystem_overhead: true,
        },
        account_authorization: None,
        connection_clock,
    })
}

impl SyncPlan {
    pub fn verify_against(&self, source: &Manifest, target: &Manifest) -> CoreResult<()> {
        self.verify_controlled(source, target, &super::work::WorkControl::default())
    }
    pub fn verify_controlled(
        &self,
        source: &Manifest,
        target: &Manifest,
        work: &super::work::WorkControl,
    ) -> CoreResult<()> {
        if self != &build_plan_controlled(source, target, self.mode, self.connection_clock, work)? {
            return Err(invalid("preview is stale or was altered"));
        }
        Ok(())
    }
}

struct Policy {
    skew: bool,
    conflicts: Vec<Conflict>,
}

impl Policy {
    fn prefer_source(
        &mut self,
        source: Option<DateTime<Utc>>,
        target: Option<DateTime<Utc>>,
        kind: &str,
        identity: &str,
        mode: SyncMode,
    ) -> bool {
        let reason = if self.skew {
            Some(ConflictReason::ClockSkew)
        } else if source.is_none() || target.is_none() {
            Some(ConflictReason::UnknownRevision)
        } else if source == target {
            Some(ConflictReason::EqualRevision)
        } else {
            None
        };
        if let Some(reason) = reason {
            self.conflicts.push(Conflict {
                object_kind: kind.into(),
                identity: identity.into(),
                reason,
                source_revision: source,
                target_revision: target,
            });
            true
        } else {
            mode == SyncMode::Overwrite || source > target
        }
    }
    fn same_content_revision(
        &self,
        source: Option<DateTime<Utc>>,
        target: Option<DateTime<Utc>>,
    ) -> Option<DateTime<Utc>> {
        if self.skew {
            source.or(target)
        } else {
            source.max(target)
        }
    }
}

fn same_media_info(a: &MediaRecord, b: &MediaRecord) -> bool {
    a.game_title_id == b.game_title_id
        && a.source_game_name == b.source_game_name
        && a.game_name == b.game_name
        && a.tags
            .iter()
            .map(|tag| normalized(tag))
            .collect::<BTreeSet<_>>()
            == b.tags
                .iter()
                .map(|tag| normalized(tag))
                .collect::<BTreeSet<_>>()
        && a.note == b.note
        && a.favorite == b.favorite
}

fn same_album(a: &AlbumState, b: &AlbumState) -> bool {
    let mut a = a.clone();
    let mut b = b.clone();
    a.definition.revision = None;
    b.definition.revision = None;
    a == b
}

#[derive(Default)]
struct EvaluationBudget {
    work: usize,
    member_bytes: usize,
    control: super::work::WorkControl,
}

impl EvaluationBudget {
    fn work(&mut self, amount: usize) -> CoreResult<()> {
        self.control
            .checkpoint(super::work::WorkStage::Comparing, 1)?;
        let next = self
            .work
            .checked_add(amount)
            .ok_or_else(|| invalid("album work overflow"))?;
        if next > MAX_ALBUM_EVALUATION_WORK_UNITS {
            return Err(invalid("album evaluation work budget exceeded"));
        }
        self.work = next;
        Ok(())
    }
    fn bytes(&mut self, amount: usize) -> CoreResult<()> {
        let next = self
            .member_bytes
            .checked_add(amount)
            .ok_or_else(|| invalid("preview member size overflow"))?;
        if next > MAX_EVALUATED_MEMBER_BYTES {
            return Err(invalid("preview member byte budget exceeded"));
        }
        self.member_bytes = next;
        Ok(())
    }
    fn append(&mut self, members: &mut Vec<String>, sha: &str) -> CoreResult<()> {
        self.work(sha.len() + 1)?;
        // Quotes and a possible comma are charged before allocating the string.
        self.bytes(sha.len() + 3)?;
        members.push(sha.into());
        Ok(())
    }
}

fn evaluate_album(
    album: &AlbumState,
    media: &BTreeMap<String, MediaRecord>,
    budget: &mut EvaluationBudget,
) -> CoreResult<Vec<String>> {
    budget.bytes(2)?;
    let mut members = Vec::new();
    if album.definition.system_key.as_deref() == Some("favorites") {
        for media in media.values() {
            budget.work(1)?;
            if media.favorite {
                budget.append(&mut members, &media.sha256)?;
            }
        }
        return Ok(members);
    }
    if album.definition.album_type == "manual" {
        for sha in &album.members {
            budget.append(&mut members, sha)?;
        }
        return Ok(members);
    }
    for rule in &album.rules {
        budget.work(1 + rule.field.len() + rule.operator.len() + rule.value.len())?;
    }
    let rules = album
        .rules
        .iter()
        .map(RuleRecord::as_album_rule)
        .collect::<Vec<_>>();
    if rules.is_empty() {
        return Ok(members);
    }
    for media in media.values() {
        let tag_bytes = media.tags.iter().map(String::len).sum::<usize>();
        budget.work(
            1 + media.sha256.len()
                + media.original_display_name.len()
                + media.game_name.len()
                + media.note.len()
                + tag_bytes
                + media.game_title_id.as_ref().map_or(0, String::len),
        )?;
        for rule in &rules {
            let value_bytes = rule.value.len();
            let cost = match rule.field.as_str() {
                "tag" => {
                    media
                        .tags
                        .iter()
                        .map(|tag| 1 + tag.len() + value_bytes)
                        .sum::<usize>()
                        + 1
                }
                "note" => 1 + media.note.len() + value_bytes,
                "game" | "game_tag" => 1 + media.game_name.len() + value_bytes,
                "type" => 6 + value_bytes,
                _ => 2 + value_bytes,
            };
            budget.work(cost)?;
        }
        if crate::smart_album::matches_album_rules(
            &crate::models::MediaAsset {
                id: 0,
                sha256: media.sha256.clone(),
                original_name: media.original_display_name.clone(),
                storage_path: String::new(),
                kind: media.kind,
                captured_at: media.captured_at,
                imported_at: media.imported_at,
                game_title_id: media.game_title_id.clone(),
                game_name: media.game_name.clone(),
                favorite: media.favorite,
                note: Some(media.note.clone()),
                tags: media.tags.clone(),
            },
            &rules,
        ) {
            budget.append(&mut members, &media.sha256)?;
        }
    }
    Ok(members)
}

fn flatten_mappings_controlled(
    mappings: &mut BTreeMap<(MappingKind, String), MappingRecord>,
    work: &super::work::WorkControl,
) -> CoreResult<()> {
    let resolution =
        super::manifest::resolve_mapping_graph_controlled(mappings, MAX_MAPPING_WORK_UNITS, work)?;
    debug_assert!(resolution.work_units <= MAX_MAPPING_WORK_UNITS);
    for (key, record) in resolution.records {
        work.check()?;
        mappings.insert(key, record);
    }
    Ok(())
}

fn controlled_keys<'a, T: Ord + 'a>(
    values: impl Iterator<Item = &'a T>,
    work: &super::work::WorkControl,
) -> CoreResult<BTreeSet<&'a T>> {
    let mut result = BTreeSet::new();
    for value in values {
        work.check()?;
        result.insert(value);
    }
    Ok(result)
}

fn checked_sum(mut values: impl Iterator<Item = u64>) -> CoreResult<u64> {
    values.try_fold(0, add_bytes)
}
fn add_bytes(first: u64, second: u64) -> CoreResult<u64> {
    first
        .checked_add(second)
        .ok_or_else(|| invalid("space requirement overflow"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_sync::work::{WorkControl, WorkStage};

    fn cancel_inside<T: Send>(
        control: &WorkControl,
        phase: WorkStage,
        action: impl FnOnce() -> CoreResult<T> + Send,
    ) {
        std::thread::scope(|scope| {
            let worker = scope.spawn(action);
            let until = std::time::Instant::now() + std::time::Duration::from_secs(10);
            loop {
                let observed = control.observe();
                let middle = match phase {
                    WorkStage::Mapping => observed.mapped_items >= 128,
                    WorkStage::Comparing => observed.compared_items >= 128,
                    _ => false,
                };
                if observed.stage == phase && middle {
                    break;
                }
                assert!(
                    !worker.is_finished(),
                    "real work finished before cancellation"
                );
                assert!(std::time::Instant::now() < until);
                std::thread::yield_now();
            }
            control.cancellation().cancel();
            assert!(matches!(
                worker.join().unwrap(),
                Err(crate::error::CoreError::Cancelled)
            ));
        });
    }

    #[test]
    fn controlled_mapping_cancel_observes_real_mid_graph_work() {
        let mappings = long_tag_chain(30_000);
        let control = WorkControl::default();
        cancel_inside(&control, WorkStage::Mapping, || {
            super::super::manifest::resolve_mapping_graph_controlled(
                &mappings,
                MAX_MAPPING_WORK_UNITS,
                &control,
            )
        });
        assert!(control.observe().work_items < 90_000);
    }

    #[test]
    fn controlled_planner_cancel_observes_real_comparison_and_keeps_inputs() {
        let mut source = manifest(true);
        let target = manifest(false);
        for index in 0..20_000 {
            source.records.push(ManifestRecord::Tag(TagRecord {
                name: format!("compare-{index:05}"),
                revision: None,
                deleted: false,
            }));
        }
        let before = source.clone();
        let control = WorkControl::default();
        cancel_inside(&control, WorkStage::Comparing, || {
            build_plan_controlled(&source, &target, SyncMode::Merge, None, &control)
        });
        assert_eq!(source, before);
    }

    #[test]
    fn controlled_and_legacy_plans_and_digests_are_identical_without_cancel() {
        let mut source = manifest(true);
        let target = manifest(false);
        push_media(&mut source, media('a', "same plan", Some(10)));
        let control = WorkControl::default();
        assert_eq!(
            source.validate().unwrap().digest,
            source.validate_controlled(&control).unwrap().digest
        );
        assert_eq!(
            build_plan(&source, &target, SyncMode::Merge).unwrap(),
            build_plan_controlled(&source, &target, SyncMode::Merge, None, &control).unwrap()
        );
    }

    #[test]
    fn planner_authenticated_connection_clock_survives_long_scans_and_verify() {
        use crate::device_sync::clock::ClockTrust;
        let mut source = manifest(true);
        let mut target = manifest(false);
        push_media(&mut source, media('a', "source older", Some(1)));
        push_media(&mut target, media('a', "target newer", Some(10)));
        target.header.observed_at = time(3600);
        let plan = build_plan_with_clock(
            &source,
            &target,
            SyncMode::Merge,
            Some(ClockTrust::WithinLimit),
        )
        .unwrap();
        assert_eq!(
            plan.media[0].final_record.as_ref().unwrap().note,
            "target newer"
        );
        assert!(plan.conflicts.is_empty());
        plan.verify_against(&source, &target).unwrap();
        for trust in [ClockTrust::OutsideLimit, ClockTrust::Uncertain] {
            let plan =
                build_plan_with_clock(&source, &target, SyncMode::Merge, Some(trust)).unwrap();
            assert_eq!(
                plan.media[0].final_record.as_ref().unwrap().note,
                "source older"
            );
            assert_eq!(plan.conflicts[0].reason, ConflictReason::ClockSkew);
            plan.verify_against(&source, &target).unwrap();
        }
        assert_eq!(
            build_plan(&source, &target, SyncMode::Merge).unwrap().media[0]
                .final_record
                .as_ref()
                .unwrap()
                .note,
            "source older"
        );
    }

    fn time(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(1_792_152_000 + seconds, 0).unwrap()
    }
    fn manifest(source: bool) -> Manifest {
        let library_uuid = if source {
            "11111111-1111-4111-8111-111111111111"
        } else {
            "22222222-2222-4222-8222-222222222222"
        }
        .to_owned();
        Manifest {
            header: ManifestHeader {
                version: VERSION,
                library_uuid: library_uuid.clone(),
                generation: 7,
                observed_at: time(0),
            },
            records: vec![ManifestRecord::Album(AlbumRecord {
                uuid: FAVORITES_UUID.into(),
                source_library_uuid: library_uuid,
                name: "Favorites".into(),
                description: String::new(),
                album_type: "smart".into(),
                pinned: true,
                system_key: Some("favorites".into()),
                revision: None,
            })],
        }
    }
    fn media(hash: char, note: &str, revision: Option<i64>) -> MediaRecord {
        MediaRecord {
            sha256: hash.to_string().repeat(64),
            length: 12,
            kind: crate::models::MediaKind::Image,
            extension: "jpg".into(),
            original_display_name: "picture.jpg".into(),
            captured_at: None,
            imported_at: Some(time(-1000)),
            game_title_id: None,
            source_game_name: "Original".into(),
            game_name: "Game".into(),
            tags: vec![],
            note: note.into(),
            favorite: false,
            revision: revision.map(time),
        }
    }
    fn album(uuid: &str, origin: &str, smart: bool, revision: Option<i64>) -> AlbumRecord {
        AlbumRecord {
            uuid: uuid.into(),
            source_library_uuid: origin.into(),
            name: "Same name".into(),
            description: String::new(),
            album_type: if smart { "smart" } else { "manual" }.into(),
            pinned: false,
            system_key: None,
            revision: revision.map(time),
        }
    }
    fn push_media(snapshot: &mut Manifest, value: MediaRecord) {
        for tag in &value.tags {
            if !snapshot.records.iter().any(|record|matches!(record,ManifestRecord::Tag(t) if normalized(&t.name)==normalized(tag))) {
                snapshot.records.push(ManifestRecord::Tag(TagRecord {name:tag.clone(),revision:value.revision,deleted:false}));
            }
        }
        snapshot.records.push(ManifestRecord::Media(value));
    }

    #[test]
    fn planner_unknown_equal_and_clock_skew_conflicts_choose_source_complete_version() {
        for (source_revision, target_revision, clock, reason) in [
            (None, Some(10), 0, ConflictReason::UnknownRevision),
            (Some(10), Some(10), 0, ConflictReason::EqualRevision),
            (Some(1), Some(10), 121, ConflictReason::ClockSkew),
            (Some(1), Some(10), -121, ConflictReason::ClockSkew),
        ] {
            let mut source = manifest(true);
            let mut target = manifest(false);
            source.header.observed_at = time(clock);
            push_media(&mut source, media('a', "", source_revision));
            let mut old = media('a', "Old", target_revision);
            old.tags = vec!["Remove me".into()];
            old.favorite = true;
            push_media(&mut target, old);
            let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
            assert_eq!(plan.conflicts.len(), 1);
            assert_eq!(plan.conflicts[0].reason, reason);
            let result = plan.media[0].final_record.as_ref().unwrap();
            assert_eq!(result.note, "");
            assert!(result.tags.is_empty());
            assert!(!result.favorite);
            assert_eq!(plan.media[0].action, Action::Replace);
            assert_eq!(plan.space.new_staging_bytes, 0);
        }
    }

    #[test]
    fn planner_exact_clock_boundary_trusts_newer_target_and_keeps_full_version() {
        for clock in [-120, 120] {
            let mut source = manifest(true);
            let mut target = manifest(false);
            source.header.observed_at = time(clock);
            push_media(&mut source, media('a', "Source old", Some(1)));
            let mut newer = media('a', "Target new", Some(10));
            newer.favorite = true;
            push_media(&mut target, newer.clone());
            let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
            assert!(plan.conflicts.is_empty());
            assert_eq!(plan.media[0].action, Action::Keep);
            assert_eq!(plan.media[0].final_record, Some(newer));
        }
    }

    #[test]
    fn planner_merge_union_overwrite_removal_and_space_do_not_duplicate_existing_originals() {
        let mut source = manifest(true);
        let mut target = manifest(false);
        push_media(&mut source, media('a', "", Some(1)));
        push_media(&mut source, media('b', "", Some(2)));
        push_media(&mut target, media('b', "", Some(2)));
        push_media(&mut target, media('c', "", Some(3)));
        for mode in [SyncMode::Merge, SyncMode::Overwrite] {
            let plan = build_plan(&source, &target, mode).unwrap();
            assert_eq!(
                plan.media
                    .iter()
                    .filter(|m| m.action == Action::Add)
                    .count(),
                1
            );
            assert_eq!(
                plan.media
                    .iter()
                    .filter(|m| m.action == Action::Remove)
                    .count(),
                usize::from(mode == SyncMode::Overwrite)
            );
            assert_eq!(plan.space.new_staging_bytes, 12);
            assert_eq!(plan.space.backup_original_bytes, 24);
            assert_eq!(plan.space.conservative_content_bytes, 36);
            assert_eq!(
                plan.media
                    .iter()
                    .find(|m| m.sha256 == "b".repeat(64))
                    .unwrap()
                    .action,
                Action::Keep
            );
        }
    }

    #[test]
    fn planner_album_uuid_identity_and_dynamic_rules_survive_metadata_resolution() {
        let mut source = manifest(true);
        let mut target = manifest(false);
        let mut value = media('a', "Matching", Some(10));
        value.favorite = true;
        push_media(&mut source, value);
        push_media(&mut target, media('a', "Old", Some(1)));
        let shared = "33333333-3333-4333-8333-333333333333";
        let other = "44444444-4444-4444-8444-444444444444";
        source.records.push(ManifestRecord::Album(album(
            shared,
            &source.header.library_uuid,
            true,
            Some(10),
        )));
        source.records.push(ManifestRecord::Rule(RuleRecord {
            album_uuid: shared.into(),
            group: 0,
            field: "note".into(),
            operator: "equals".into(),
            value: "Matching".into(),
        }));
        target.records.push(ManifestRecord::Album(album(
            shared,
            &source.header.library_uuid,
            false,
            Some(1),
        )));
        target.records.push(ManifestRecord::Album(album(
            other,
            &target.header.library_uuid,
            false,
            Some(1),
        )));
        let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
        assert_eq!(plan.albums.len(), 3);
        let smart = plan.albums.iter().find(|a| a.uuid == shared).unwrap();
        assert_eq!(
            smart.final_state.as_ref().unwrap().definition.album_type,
            "smart"
        );
        assert!(smart.final_state.as_ref().unwrap().members.is_empty());
        assert_eq!(smart.evaluated_members, vec!["a".repeat(64)]);
        assert_eq!(
            plan.albums
                .iter()
                .find(|a| a.uuid == FAVORITES_UUID)
                .unwrap()
                .evaluated_members,
            vec!["a".repeat(64)]
        );
        assert_eq!(
            plan.albums
                .iter()
                .filter(|a| a
                    .final_state
                    .as_ref()
                    .is_some_and(|a| a.definition.name == "Same name"))
                .count(),
            2
        );
    }

    #[test]
    fn planner_rejects_length_conflict_duplicates_malicious_fields_and_overflow() {
        let mut source = manifest(true);
        let mut target = manifest(false);
        push_media(&mut source, media('a', "", None));
        let mut wrong = media('a', "", None);
        wrong.length = 13;
        push_media(&mut target, wrong);
        assert!(build_plan(&source, &target, SyncMode::Merge).is_err());
        source
            .records
            .push(ManifestRecord::Media(media('a', "", None)));
        assert!(build_plan(&source, &manifest(false), SyncMode::Merge).is_err());
        let mut huge = manifest(true);
        for hash in ['a', 'b', 'c'] {
            let mut value = media(hash, "", None);
            value.length = i64::MAX as u64;
            push_media(&mut huge, value);
        }
        assert!(build_plan(&huge, &manifest(false), SyncMode::Merge).is_err());
    }

    #[test]
    fn planner_mapping_flattening_tombstones_and_hidden_game_names_do_not_rewrite_associations() {
        let mut source = manifest(true);
        let target = manifest(false);
        let mut value = media('a', "", Some(10));
        value.tags = vec!["A".into()];
        value.source_game_name = "Original hidden".into();
        value.game_name = "Display".into();
        push_media(&mut source, value);
        for (name, target) in [("A", Some("B")), ("B", Some("C")), ("Old", None)] {
            source.records.push(ManifestRecord::Mapping(MappingRecord {
                kind: MappingKind::Tag,
                source_name: name.into(),
                target_name: target.map(str::to_owned),
                revision: Some(time(1)),
                deleted: target.is_none(),
            }));
        }
        let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
        assert_eq!(
            plan.mappings
                .iter()
                .find(|m| m.source_name == "A")
                .unwrap()
                .target_name
                .as_deref(),
            Some("C")
        );
        assert!(
            plan.mappings
                .iter()
                .find(|m| m.source_name == "Old")
                .unwrap()
                .deleted
        );
        let result = plan.media[0].final_record.as_ref().unwrap();
        assert_eq!(result.tags, vec!["A"]);
        assert_eq!(result.source_game_name, "Original hidden");
        source.records.push(ManifestRecord::Mapping(MappingRecord {
            kind: MappingKind::Tag,
            source_name: "C".into(),
            target_name: Some("A".into()),
            revision: Some(time(2)),
            deleted: false,
        }));
        assert!(build_plan(&source, &target, SyncMode::Merge).is_err());
    }

    #[test]
    fn strict_page_json_roundtrips_valid_bounded_records() {
        let source = manifest(true);
        let page = ManifestPage {
            header: source.header,
            records: source.records,
            next: None,
        };
        assert_eq!(
            ManifestPage::from_json(&serde_json::to_vec(&page).unwrap()).unwrap(),
            page
        );
    }

    #[test]
    fn strict_manifest_json_rejects_unknown_versions_fields_ids_paths_and_oversized_values() {
        let mut source = manifest(true);
        push_media(&mut source, media('a', "", None));
        let original = serde_json::to_value(&source).unwrap();
        for (pointer, value) in [
            ("/header/version", serde_json::json!(99)),
            ("/header/library_uuid", serde_json::json!("../../library")),
            ("/records/1/value/sha256", serde_json::json!("not-a-sha")),
            ("/records/1/value/extension", serde_json::json!("../jpg")),
            (
                "/records/1/value/original_display_name",
                serde_json::json!("C:\\secret\\x.jpg"),
            ),
            ("/records/1/value/note", serde_json::json!("x".repeat(8193))),
            ("/records/1/value/kind", serde_json::json!("script")),
        ] {
            let mut bad = original.clone();
            *bad.pointer_mut(pointer).unwrap() = value;
            assert!(
                Manifest::from_json(&serde_json::to_vec(&bad).unwrap()).is_err(),
                "{pointer}"
            );
        }
        let mut unknown = original.clone();
        unknown["records"][1]["value"]["remote_token"] = serde_json::json!("not-allowed");
        assert!(Manifest::from_json(&serde_json::to_vec(&unknown).unwrap()).is_err());
        source.records.push(ManifestRecord::Rule(RuleRecord {
            album_uuid: FAVORITES_UUID.into(),
            group: 0,
            field: "sql".into(),
            operator: "execute".into(),
            value: "DROP TABLE".into(),
        }));
        assert!(source.validate().is_err());
    }

    #[test]
    fn planner_same_content_propagates_revision_without_recopy_and_is_idempotent() {
        let mut source = manifest(true);
        let mut target = manifest(false);
        push_media(&mut source, media('a', "Same", Some(10)));
        let mut existing = media('a', "Same", Some(1));
        existing.imported_at = Some(time(-500));
        push_media(&mut target, existing.clone());
        let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
        assert_eq!(plan.media[0].action, Action::Keep);
        assert!(plan.media[0].revision_only);
        assert_eq!(
            plan.media[0].final_record.as_ref().unwrap().revision,
            Some(time(10))
        );
        assert_eq!(
            plan.media[0].final_record.as_ref().unwrap().imported_at,
            existing.imported_at
        );
        assert_eq!(plan.space.new_staging_bytes, 0);
        assert!(plan.conflicts.is_empty());
        plan.verify_against(&source, &target).unwrap();
        target
            .records
            .retain(|record| !matches!(record, ManifestRecord::Media(_)));
        push_media(&mut target, plan.media[0].final_record.clone().unwrap());
        assert!(plan.verify_against(&source, &target).is_err());
        let repeated = build_plan(&source, &target, SyncMode::Merge).unwrap();
        assert_eq!(repeated.media[0].action, Action::Keep);
        assert!(!repeated.media[0].revision_only);
        assert!(repeated.conflicts.is_empty());
        source.records.reverse();
        let shuffled = build_plan(&source, &target, SyncMode::Merge).unwrap();
        assert_eq!(shuffled, repeated);
    }

    #[test]
    fn planner_clock_boundary_one_nanosecond_over_is_untrusted() {
        let mut source = manifest(true);
        let mut target = manifest(false);
        source.header.observed_at = time(120) + chrono::Duration::nanoseconds(1);
        push_media(&mut source, media('a', "Source", Some(1)));
        push_media(&mut target, media('a', "Target", Some(10)));
        let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
        assert_eq!(plan.media[0].final_record.as_ref().unwrap().note, "Source");
        assert_eq!(plan.conflicts[0].reason, ConflictReason::ClockSkew);
    }

    #[test]
    fn strict_page_collection_requires_ordered_bound_header_and_complete_stream() {
        let source = manifest(true);
        let header = source.header.clone();
        let cursor = ManifestCursor {
            library_uuid: header.library_uuid.clone(),
            generation: header.generation,
            section: 1,
            after: 1,
        };
        let first = ManifestPage {
            header: header.clone(),
            records: source.records.clone(),
            next: Some(cursor),
        };
        let last = ManifestPage {
            header: header.clone(),
            records: vec![],
            next: None,
        };
        let mut collector = ManifestCollector::new(header.clone()).unwrap();
        collector.push(first.clone()).unwrap();
        assert!(collector.push(first.clone()).is_err());
        let mut foreign = last.clone();
        foreign.header.generation += 1;
        assert!(collector.push(foreign).is_err());
        collector.push(last).unwrap();
        assert_eq!(collector.finish().unwrap(), source);
        let mut partial = ManifestCollector::new(header).unwrap();
        partial.push(first).unwrap();
        assert!(partial.finish().is_err());
    }

    #[test]
    fn planner_manual_album_uses_complete_winning_member_set_and_unknown_conflict_is_visible() {
        let shared = "33333333-3333-4333-8333-333333333333";
        let mut source = manifest(true);
        let mut target = manifest(false);
        for hash in ['a', 'b'] {
            push_media(&mut source, media(hash, "", Some(1)));
            push_media(&mut target, media(hash, "", Some(1)));
        }
        source.records.push(ManifestRecord::Album(album(
            shared,
            &source.header.library_uuid,
            false,
            None,
        )));
        target.records.push(ManifestRecord::Album(album(
            shared,
            &source.header.library_uuid,
            false,
            Some(10),
        )));
        for hash in ['a', 'b'] {
            target.records.push(ManifestRecord::Member(MemberRecord {
                album_uuid: shared.into(),
                sha256: hash.to_string().repeat(64),
            }));
        }
        source.records.push(ManifestRecord::Member(MemberRecord {
            album_uuid: shared.into(),
            sha256: "b".repeat(64),
        }));
        let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
        let selected = plan.albums.iter().find(|a| a.uuid == shared).unwrap();
        assert_eq!(selected.action, Action::Replace);
        assert_eq!(selected.evaluated_members, vec!["b".repeat(64)]);
        assert_eq!(plan.conflicts[0].object_kind, "album");
        assert_eq!(plan.conflicts[0].reason, ConflictReason::UnknownRevision);
        assert_eq!(
            plan.media.len(),
            2,
            "removing an album member must not delete the original"
        );
    }

    #[test]
    fn planner_mapping_conflict_and_deletion_use_revisions_without_renaming_hidden_sources() {
        let mut source = manifest(true);
        let mut target = manifest(false);
        let mapping = |target: Option<&str>, revision: Option<i64>| MappingRecord {
            kind: MappingKind::Game,
            source_name: "Original".into(),
            target_name: target.map(str::to_owned),
            deleted: target.is_none(),
            revision: revision.map(time),
        };
        source
            .records
            .push(ManifestRecord::Mapping(mapping(None, Some(10))));
        target.records.push(ManifestRecord::Mapping(mapping(
            Some("Old display"),
            Some(1),
        )));
        let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
        assert!(plan.mappings[0].deleted);
        assert!(plan.conflicts.is_empty());
        source.records.pop();
        source.records.push(ManifestRecord::Mapping(mapping(
            Some("Source display"),
            None,
        )));
        let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
        assert_eq!(
            plan.mappings[0].target_name.as_deref(),
            Some("Source display")
        );
        assert_eq!(plan.conflicts[0].reason, ConflictReason::UnknownRevision);
        let mut newer_target = target.clone();
        newer_target.records.pop();
        newer_target
            .records
            .push(ManifestRecord::Mapping(mapping(None, Some(20))));
        source.records.pop();
        source.records.push(ManifestRecord::Mapping(mapping(
            Some("Source old"),
            Some(10),
        )));
        assert!(
            build_plan(&source, &newer_target, SyncMode::Merge)
                .unwrap()
                .mappings[0]
                .deleted
        );
    }

    #[test]
    fn strict_pages_and_manifest_reject_invalid_cursors_duplicates_and_byte_item_limits() {
        let source = manifest(true);
        let valid = ManifestPage {
            header: source.header.clone(),
            records: source.records.clone(),
            next: None,
        };
        let mut bad = valid.clone();
        bad.records = vec![source.records[0].clone(); MAX_PAGE_ITEMS + 1];
        assert!(ManifestPage::from_json(&serde_json::to_vec(&bad).unwrap()).is_err());
        assert!(ManifestPage::from_json(&vec![b' '; MAX_PAGE_BYTES + 1]).is_err());
        let mut unknown = serde_json::to_value(&valid).unwrap();
        unknown["untrusted_file_path"] = serde_json::json!("C:\\private");
        assert!(ManifestPage::from_json(&serde_json::to_vec(&unknown).unwrap()).is_err());
        bad = valid;
        bad.next = Some(ManifestCursor {
            library_uuid: "22222222-2222-4222-8222-222222222222".into(),
            generation: source.header.generation,
            section: 0,
            after: 1,
        });
        assert!(bad.validate().is_err());
        let mut duplicated = source.clone();
        let mut value = media('a', "", None);
        value.tags = vec![" tag ".into(), "TAG".into()];
        push_media(&mut duplicated, value);
        assert!(duplicated.validate().is_err());
    }

    fn long_tag_chain(count: usize) -> BTreeMap<(MappingKind, String), MappingRecord> {
        (0..count)
            .map(|index| {
                let source_name = format!("tag{index:06}");
                let target_name = if index + 1 == count {
                    "terminal".into()
                } else {
                    format!("tag{:06}", index + 1)
                };
                (
                    (MappingKind::Tag, source_name.clone()),
                    MappingRecord {
                        kind: MappingKind::Tag,
                        source_name,
                        target_name: Some(target_name),
                        revision: Some(time(index as i64)),
                        deleted: false,
                    },
                )
            })
            .collect()
    }

    #[test]
    fn review_fix_mapping_chain_finishes_with_linear_work_budget() {
        let mappings = long_tag_chain(3000);
        let result = resolve_mapping_graph(&mappings, 120_000).unwrap();
        assert!(result.work_units <= 120_000);
        eprintln!(
            "3000-node chain: {} mapping work units (limit 120000)",
            result.work_units
        );
        assert_eq!(
            result.records[&(MappingKind::Tag, "tag000000".into())]
                .target_name
                .as_deref(),
            Some("terminal")
        );
        assert_eq!(
            result.records[&(MappingKind::Tag, "tag000000".into())].revision,
            Some(time(2999))
        );
        let mut source = manifest(true);
        source
            .records
            .extend(mappings.into_values().map(ManifestRecord::Mapping));
        source.validate().unwrap();
        let target = manifest(false);
        let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
        assert!(plan
            .mappings
            .iter()
            .all(|mapping| mapping.target_name.as_deref() == Some("terminal")));
        plan.verify_against(&source, &target).unwrap();
    }

    #[test]
    fn review_fix_automatic_album_cartesian_expansion_is_rejected_by_budget() {
        let mut source = manifest(true);
        for index in 1..=300 {
            let mut value = media('a', "", Some(1));
            value.sha256 = format!("{index:064x}");
            push_media(&mut source, value);
            let uuid = uuid::Uuid::from_u128((1u128 << 124) + index).to_string();
            source.records.push(ManifestRecord::Album(album(
                &uuid,
                &source.header.library_uuid,
                true,
                Some(1),
            )));
            source.records.push(ManifestRecord::Rule(RuleRecord {
                album_uuid: uuid,
                group: 0,
                field: "type".into(),
                operator: "equals".into(),
                value: "image".into(),
            }));
        }
        assert!(serde_json::to_vec(&source).unwrap().len() < 1024 * 1024);
        let result = build_plan(&source, &manifest(false), SyncMode::Merge);
        assert!(
            matches!(result,Err(crate::error::CoreError::InvalidConfig(message)) if message.contains("budget")),
            "bounded input must not expand into 90,000 eager matching members"
        );
    }

    #[test]
    fn review_fix_game_source_namespace_does_not_flatten_or_propagate_other_revision() {
        let mut source = manifest(true);
        let mut target = manifest(false);
        source.records.push(ManifestRecord::Mapping(MappingRecord {
            kind: MappingKind::Game,
            source_name: "A".into(),
            target_name: Some("B".into()),
            revision: Some(time(1)),
            deleted: false,
        }));
        target.records.push(ManifestRecord::Mapping(MappingRecord {
            kind: MappingKind::Game,
            source_name: "B".into(),
            target_name: Some("C".into()),
            revision: Some(time(10)),
            deleted: false,
        }));
        let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
        let original_a = plan
            .mappings
            .iter()
            .find(|mapping| mapping.source_name == "A")
            .unwrap();
        assert_eq!(original_a.target_name.as_deref(), Some("B"));
        assert_eq!(original_a.revision, Some(time(1)));
    }

    #[test]
    fn review_fix_deep_cycles_are_rejected_for_both_mapping_kinds_without_recursion() {
        for kind in [MappingKind::Tag, MappingKind::Game] {
            let mut chain = long_tag_chain(20_000);
            chain
                .get_mut(&(MappingKind::Tag, "tag019999".into()))
                .unwrap()
                .target_name = Some("tag000000".into());
            let cycle = chain
                .into_iter()
                .map(|((_, key), mut record)| {
                    record.kind = kind;
                    ((kind, key), record)
                })
                .collect();
            let result = resolve_mapping_graph(&cycle, 800_000);
            assert!(
                matches!(result,Err(crate::error::CoreError::InvalidConfig(message)) if message.contains("cycle"))
            );
        }
    }

    #[test]
    fn review_fix_shared_tails_cache_unknown_revision_and_stop_at_tombstone() {
        let mut mappings = BTreeMap::new();
        for index in 0..2000 {
            let name = format!("root{index:06}");
            mappings.insert(
                (MappingKind::Tag, name.clone()),
                MappingRecord {
                    kind: MappingKind::Tag,
                    source_name: name,
                    target_name: Some("tail".into()),
                    revision: if index == 0 { None } else { Some(time(2)) },
                    deleted: false,
                },
            );
        }
        mappings.insert(
            (MappingKind::Tag, "tail".into()),
            MappingRecord {
                kind: MappingKind::Tag,
                source_name: "tail".into(),
                target_name: Some("tomb".into()),
                revision: Some(time(9)),
                deleted: false,
            },
        );
        mappings.insert(
            (MappingKind::Tag, "tomb".into()),
            MappingRecord {
                kind: MappingKind::Tag,
                source_name: "tomb".into(),
                target_name: None,
                revision: Some(time(99)),
                deleted: true,
            },
        );
        let resolution = resolve_mapping_graph(&mappings, 80_000).unwrap();
        assert!(resolution.work_units <= 80_000);
        assert_eq!(
            resolution.records[&(MappingKind::Tag, "root000000".into())].revision,
            None
        );
        assert_eq!(
            resolution.records[&(MappingKind::Tag, "root000001".into())].revision,
            Some(time(9))
        );
        assert_eq!(
            resolution.records[&(MappingKind::Tag, "root000001".into())]
                .target_name
                .as_deref(),
            Some("tomb")
        );
        assert!(!resolution
            .records
            .contains_key(&(MappingKind::Tag, "tomb".into())));
        assert!(resolve_mapping_graph(&mappings, 1).is_err());
    }

    #[test]
    fn review_fix_preview_budget_checks_before_append_and_preserves_normal_album_members() {
        let mut budget = EvaluationBudget {
            work: 0,
            member_bytes: MAX_EVALUATED_MEMBER_BYTES - 67,
            ..Default::default()
        };
        let mut members = Vec::new();
        budget.append(&mut members, &"a".repeat(64)).unwrap();
        assert!(budget.append(&mut members, &"b".repeat(64)).is_err());
        assert_eq!(
            members,
            vec!["a".repeat(64)],
            "failure must precede string append"
        );
        let mut work = EvaluationBudget {
            work: MAX_ALBUM_EVALUATION_WORK_UNITS,
            member_bytes: 0,
            ..Default::default()
        };
        assert!(work.work(1).is_err());
        let mut source = manifest(true);
        let manual = "33333333-3333-4333-8333-333333333333";
        let automatic = "44444444-4444-4444-8444-444444444444";
        source.records.push(ManifestRecord::Album(album(
            manual,
            &source.header.library_uuid,
            false,
            Some(1),
        )));
        source.records.push(ManifestRecord::Album(album(
            automatic,
            &source.header.library_uuid,
            true,
            Some(1),
        )));
        source.records.push(ManifestRecord::Rule(RuleRecord {
            album_uuid: automatic.into(),
            group: 0,
            field: "type".into(),
            operator: "equals".into(),
            value: "image".into(),
        }));
        for index in 1..=300 {
            let mut value = media('a', "", Some(1));
            value.sha256 = format!("{index:064x}");
            value.favorite = index % 2 == 0;
            source.records.push(ManifestRecord::Member(MemberRecord {
                album_uuid: manual.into(),
                sha256: value.sha256.clone(),
            }));
            push_media(&mut source, value);
        }
        let target = manifest(false);
        let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
        for (uuid, count) in [(FAVORITES_UUID, 150), (manual, 300), (automatic, 300)] {
            assert_eq!(
                plan.albums
                    .iter()
                    .find(|album| album.uuid == uuid)
                    .unwrap()
                    .evaluated_members
                    .len(),
                count
            );
        }
        let smart = plan
            .albums
            .iter()
            .find(|album| album.uuid == automatic)
            .unwrap()
            .final_state
            .as_ref()
            .unwrap();
        assert!(smart.members.is_empty());
        assert_eq!(smart.rules.len(), 1);
        plan.verify_against(&source, &target).unwrap();
    }
}
