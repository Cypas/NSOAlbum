use super::*;
use crate::api::CoreApi;
use crate::device_sync::planner::SyncMode;
use crate::device_sync::receiver::{ReceiveOperation, Snapshot};
use crate::device_sync::recovery::{JournalStage, RecoveryOperation};
use crate::sync::CancellationToken;

fn epoch(database: &Database) -> (i64, String) {
    database
        .connection
        .lock()
        .unwrap()
        .query_row(
            "SELECT revision,stamp FROM game_alias_epoch WHERE id=1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap()
}

fn local_sources(database: &Database) -> Vec<u8> {
    let connection = database.connection.lock().unwrap();
    let table = capture_receiver_tables(&connection, &CancellationToken::default())
        .unwrap()
        .into_iter()
        .find(|table| table.name == "media_source")
        .unwrap();
    serde_json::to_vec(&table).unwrap()
}

async fn corrupt_final_catalog_is_rolled_back(corruption: &str) {
    let source_root = tempfile::tempdir().unwrap();
    let target_root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let target = CoreApi::open(target_root.path()).unwrap();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("synthetic.jpg");
    std::fs::write(&path, b"shared catalog validation").unwrap();
    for (api, raw, display) in [
        (&source, "\u{00d6}\u{00c4}ld", "Incoming display"),
        (&target, "\u{00f6}\u{00e4}ld", "Existing display"),
    ] {
        api.import_custom_files(vec![path.to_string_lossy().into_owned()], raw.into())
            .await
            .unwrap();
        api.database().rename_game_tag(raw, display).unwrap();
    }
    source.create_tag("incoming".into()).unwrap();
    // Warm a real cached alias proof and retain target-only media/source rows.
    std::fs::write(&path, b"target cached alias").unwrap();
    target
        .import_custom_files(
            vec![path.to_string_lossy().into_owned()],
            "\u{00f6}\u{00e4}ld".into(),
        )
        .await
        .unwrap();
    let database = target.database();
    let before = Snapshot::read(&database, "Target").unwrap();
    let before_epoch = epoch(&database);
    let before_sources = local_sources(&database);
    database
        .connection
        .lock()
        .unwrap()
        .execute_batch(&format!(
            "CREATE TEMP TRIGGER receiver_fix1_corrupt AFTER INSERT ON device_sync_source_name
             WHEN NEW.display_name='Source' BEGIN {corruption}; END;"
        ))
        .unwrap();
    let mut operation = ReceiveOperation::prepare(
        database.clone(),
        Snapshot::read(&source.database(), "Source").unwrap(),
        "Target",
        SyncMode::Overwrite,
    )
    .unwrap();
    let id = operation.operation_id();
    let mut auth = operation.authorize().unwrap();
    assert!(
        operation
            .apply(
                Some(&mut auth),
                None,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .is_err(),
        "a corrupt or plan-divergent actual catalog must not be finalized"
    );
    assert_eq!(
        Snapshot::read_with_header(&database, before.manifest.header.clone(), Some("Target"))
            .unwrap(),
        before
    );
    assert_eq!(epoch(&database), before_epoch);
    assert_eq!(local_sources(&database), before_sources);
    assert!(!database.device_sync_recovery_pending());
    let journal = database.device_sync_journal(id).unwrap().unwrap();
    assert_eq!(journal.stage, JournalStage::RolledBack);
    assert_eq!(
        database
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT preserve_revisions FROM sync_write_context WHERE id=1",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        0
    );
    database
        .connection
        .lock()
        .unwrap()
        .execute_batch("DROP TRIGGER receiver_fix1_corrupt")
        .unwrap();
    let mut recovery =
        RecoveryOperation::preview_backup(database.clone(), journal.backup_uuid, "Target").unwrap();
    let mut auth = recovery.authorize().unwrap();
    recovery
        .restore(Some(&mut auth), &CancellationToken::default())
        .unwrap();
    assert_eq!(local_sources(&database), before_sources);
    // A rolled-back alias update must not publish a stale validation proof.
    std::fs::write(&path, b"post rollback alias import").unwrap();
    target
        .import_custom_files(
            vec![path.to_string_lossy().into_owned()],
            "\u{00f6}\u{00e4}ld".into(),
        )
        .await
        .unwrap();
    assert!(target
        .list_media(GalleryQuery::default())
        .unwrap()
        .iter()
        .all(|media| media.game_name == "Existing display"));
}

// Removing the pre-commit actual-manifest check would report success for each
// of these real SQLite writes after the normal catalog helper has finished.
#[tokio::test]
async fn receiver_fix1_final_validation_rejects_duplicate_normalized_mapping() {
    corrupt_final_catalog_is_rolled_back(
        "INSERT INTO sync_mapping(kind,source_name,target_name)
         VALUES('game','\u{00d6}\u{00e4}ld','Wrong display')",
    )
    .await;
}

#[tokio::test]
async fn receiver_fix1_final_validation_rejects_valid_but_wrong_mapping() {
    corrupt_final_catalog_is_rolled_back(
        "UPDATE sync_mapping SET target_name='Wrong display' WHERE kind='game'",
    )
    .await;
}

#[tokio::test]
async fn receiver_fix1_final_validation_rejects_wrong_tag_catalog() {
    corrupt_final_catalog_is_rolled_back(
        "UPDATE sync_tag_state SET name='Wrong catalog' WHERE normalized_name='incoming'",
    )
    .await;
}

#[tokio::test]
async fn receiver_fix1_unchanged_aliases_do_not_invalidate_epoch() {
    let root = tempfile::tempdir().unwrap();
    let api = CoreApi::open(root.path()).unwrap();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("same.jpg");
    std::fs::write(&path, b"stable mapped original").unwrap();
    api.import_custom_files(
        vec![path.to_string_lossy().into_owned()],
        "\u{00d6}ld".into(),
    )
    .await
    .unwrap();
    api.database()
        .rename_game_tag("\u{00d6}ld", "Display")
        .unwrap();
    let database = api.database();
    let before = epoch(&database);
    let mut operation = ReceiveOperation::prepare(
        database.clone(),
        Snapshot::read(&database, "Local").unwrap(),
        "Local",
        SyncMode::Merge,
    )
    .unwrap();
    let mut auth = operation.authorize().unwrap();
    operation
        .apply(
            Some(&mut auth),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(epoch(&database), before);
}
