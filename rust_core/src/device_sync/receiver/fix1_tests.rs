use super::*;
use crate::api::CoreApi;
use crate::device_sync::manifest::{ManifestRecord, MappingKind};
use crate::device_sync::recovery::RecoveryOperation;
use crate::models::GalleryQuery;

async fn unicode_mapping_roundtrip(kind: MappingKind, mode: SyncMode, deleted: bool) {
    let source_root = tempfile::tempdir().unwrap();
    let target_root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let target = CoreApi::open(target_root.path()).unwrap();
    let input = tempfile::tempdir().unwrap();
    let file = input.path().join("synthetic.jpg");
    std::fs::write(&file, b"shared unicode mapping media").unwrap();
    for (api, raw, display) in [
        (&source, "\u{00d6}ld", "Incoming display"),
        (&target, "\u{00f6}ld", "Existing display"),
    ] {
        api.import_custom_files(
            vec![file.to_string_lossy().into_owned()],
            if kind == MappingKind::Game {
                raw
            } else {
                "Game"
            }
            .into(),
        )
        .await
        .unwrap();
        if kind == MappingKind::Game {
            api.database().rename_game_tag(raw, display).unwrap();
        } else {
            let tag = api.database().create_tag(raw).unwrap();
            api.database().rename_tag(tag, display).unwrap();
        }
    }
    let source_before = Snapshot::read(&source.database(), "Source").unwrap();
    let before = Snapshot::read(&target.database(), "Target").unwrap();
    let local = target
        .list_media(GalleryQuery::default())
        .unwrap()
        .remove(0);
    let mut incoming = source_before.clone();
    // Valid wire input can preserve source spelling; local tag renames normally
    // emit lowercase. Fix the revision sample to exercise a newer-source Merge.
    let revision = before.manifest.header.observed_at + chrono::Duration::seconds(1);
    for record in &mut incoming.manifest.records {
        match record {
            ManifestRecord::Mapping(mapping) => {
                mapping.source_name = "\u{00d6}ld".into();
                mapping.revision = Some(revision);
                mapping.deleted = deleted;
                if deleted {
                    mapping.target_name = None;
                }
            }
            ManifestRecord::Media(media) => media.revision = Some(revision),
            ManifestRecord::Tag(tag) => tag.revision = Some(revision),
            _ => {}
        }
    }
    incoming.sources =
        SourceDescriptions::new(&incoming.manifest, incoming.sources.entries).unwrap();
    incoming.validate().unwrap();
    let mut operation =
        ReceiveOperation::prepare(target.database(), incoming.clone(), "Target", mode).unwrap();
    let plan = operation.plan().clone();
    assert_eq!(plan.mappings.len(), 1);
    assert_eq!(plan.mappings[0].kind, kind);
    assert_eq!(plan.mappings[0].source_name, "\u{00d6}ld");
    assert_eq!(
        plan.mappings[0].target_name.as_deref(),
        if deleted {
            None
        } else {
            Some("Incoming display")
        }
    );
    assert_eq!(plan.mappings[0].deleted, deleted);
    assert_eq!(plan.mappings[0].revision, Some(revision));
    let mut auth = operation.authorize().unwrap();
    let receipt = operation
        .apply(
            Some(&mut auth),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(receipt.state, ApplyState::Finalized);
    let result = Snapshot::read(&target.database(), "Target")
        .expect("a finalized Unicode mapping must produce a valid snapshot");
    let actual = result.manifest.validate().unwrap();
    assert_eq!(
        actual.mappings.into_values().collect::<Vec<_>>(),
        plan.mappings
    );
    assert_eq!(actual.tags.into_values().collect::<Vec<_>>(), plan.tags);
    let unchanged = target.database().media_asset(local.id).unwrap();
    assert_eq!(unchanged.id, local.id);
    assert_eq!(unchanged.storage_path, local.storage_path);
    if kind == MappingKind::Game {
        let aliases = target.database().list_game_tag_aliases().unwrap();
        if deleted {
            assert!(aliases.is_empty());
        } else {
            assert_eq!(aliases.len(), 1);
            assert_eq!(aliases[0].source_name, "\u{00d6}ld");
            assert_eq!(aliases[0].target_name, "Incoming display");
        }
    }
    RecoveryOperation::preview_backup(target.database(), receipt.backup_uuid, "Target").unwrap();
    drop(operation);
    drop(target);
    let reopened = CoreApi::open(target_root.path()).unwrap();
    Snapshot::read(&reopened.database(), "Target").unwrap();
    let mut repeated =
        ReceiveOperation::prepare(reopened.database(), incoming, "Target", mode).unwrap();
    assert!(repeated
        .plan()
        .media
        .iter()
        .all(|decision| decision.action == super::super::planner::Action::Keep));
    assert_eq!(repeated.plan().mappings, plan.mappings);
    let mut auth = repeated.authorize().unwrap();
    repeated
        .apply(
            Some(&mut auth),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    let after_repeat = Snapshot::read(&reopened.database(), "Target").unwrap();
    assert_eq!(
        after_repeat.manifest.validate().unwrap().mappings,
        result.manifest.validate().unwrap().mappings
    );
    if kind == MappingKind::Game {
        let future = input.path().join("future.jpg");
        std::fs::write(&future, b"future unicode raw game").unwrap();
        reopened
            .import_custom_files(
                vec![future.to_string_lossy().into_owned()],
                "\u{00d6}ld".into(),
            )
            .await
            .unwrap();
        let future_snapshot = Snapshot::read(&reopened.database(), "Target").unwrap();
        let future_manifest = future_snapshot.manifest.validate().unwrap();
        let future_sha = hex::encode(Sha256::digest(b"future unicode raw game"));
        let future_media = &future_manifest.media[&future_sha];
        assert_eq!(future_media.source_game_name, "\u{00d6}ld");
        assert_eq!(
            future_media.game_name,
            if deleted {
                "\u{00d6}ld"
            } else {
                "Incoming display"
            }
        );
    }
    let mut recovery =
        RecoveryOperation::preview_backup(reopened.database(), receipt.backup_uuid, "Target")
            .unwrap();
    let mut auth = recovery.authorize().unwrap();
    recovery
        .restore(Some(&mut auth), &CancellationToken::default())
        .unwrap();
    let restored = Snapshot::read(&reopened.database(), "Target").unwrap();
    assert!(restored.manifest.header.generation > before.manifest.header.generation);
    assert_eq!(
        restored.manifest.header.library_uuid,
        before.manifest.header.library_uuid
    );
    assert_eq!(restored.manifest.records, before.manifest.records);
    assert_eq!(restored.sources.entries, before.sources.entries);
    assert_eq!(
        Snapshot::read_with_header(
            &source.database(),
            source_before.manifest.header.clone(),
            Some("Source"),
        )
        .unwrap(),
        source_before
    );
}

// Relying on SQLite NOCASE instead of normalized identity breaks these real
// apply -> snapshot -> reopen -> repeat -> backup restore consumers.
#[tokio::test]
async fn receiver_fix1_unicode_game_overwrite_roundtrips() {
    unicode_mapping_roundtrip(MappingKind::Game, SyncMode::Overwrite, false).await;
}

#[tokio::test]
async fn receiver_fix1_unicode_game_newer_merge_roundtrips() {
    unicode_mapping_roundtrip(MappingKind::Game, SyncMode::Merge, false).await;
}

#[tokio::test]
async fn receiver_fix1_unicode_tag_overwrite_roundtrips() {
    unicode_mapping_roundtrip(MappingKind::Tag, SyncMode::Overwrite, false).await;
}

#[tokio::test]
async fn receiver_fix1_unicode_tag_newer_merge_roundtrips() {
    unicode_mapping_roundtrip(MappingKind::Tag, SyncMode::Merge, false).await;
}

#[tokio::test]
async fn receiver_fix1_unicode_game_tombstone_roundtrips() {
    unicode_mapping_roundtrip(MappingKind::Game, SyncMode::Overwrite, true).await;
}

#[tokio::test]
async fn receiver_fix1_unicode_tag_tombstone_roundtrips() {
    unicode_mapping_roundtrip(MappingKind::Tag, SyncMode::Overwrite, true).await;
}
