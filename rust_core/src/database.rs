use std::path::Path;
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde::de::DeserializeOwned;
use serde::Serialize;

use crate::album::{kind_from_type, readable_import_media_name, readable_media_name};
use crate::device_sync::library_guard::{
    ExclusiveLease, LibraryGate, OriginalIdentity, OriginalRootOwner, PublicationPin,
    SourceSnapshotLease, WriteLease, ORIGINAL_ROOT_OWNER_FILE,
};
use crate::device_sync::manifest as ds;
use crate::error::{CoreError, CoreResult};
use crate::models::{
    AlbumRule, AlbumSummary, GalleryKindFilter, GalleryQuery, GameTagAliasSummary, GameTagSummary,
    LibraryRootProbe, MediaAsset, MediaCandidate, MediaKind, SyncProgress, TagUsageSummary,
};
use crate::settings::AppSettings;
use crate::smart_album::matches_album_rules;

type AlbumFilter = (
    String,
    Option<String>,
    Vec<AlbumRule>,
    std::collections::HashSet<i64>,
);

#[cfg(test)]
#[path = "device_sync/receiver/fix1_sql_tests.rs"]
mod receiver_fix1_sql_tests;

#[cfg(test)]
#[path = "device_sync/receiver/driver_guard_tests.rs"]
mod receiver_driver_guard_tests;

#[cfg(test)]
#[path = "device_sync/receiver/album_source_tests.rs"]
mod album_source_display_tests;
#[cfg(test)]
#[path = "device_sync/runtime_tests.rs"]
mod device_sync_runtime_tests;
#[cfg(test)]
#[path = "device_sync/receiver/backup_control_tests.rs"]
mod receiver_backup_control_tests;
#[cfg(test)]
#[path = "device_sync/receiver/finalize_guard_tests.rs"]
mod receiver_finalize_guard_tests;
#[cfg(test)]
#[path = "device_sync/receiver/work_read_tests.rs"]
mod receiver_work_read_tests;

#[cfg(test)]
mod receiver_recovery_gate_tests {
    use crate::api::CoreApi;

    // A reopened unresolved operation must not admit a normal tag write.
    #[test]
    fn receiver_pending_reopen_is_readable_but_not_normally_writable() {
        let directory = tempfile::tempdir().unwrap();
        let api = CoreApi::open(directory.path()).unwrap();
        api.database().create_tag("before crash").unwrap();
        let database = api.database();
        database
            .connection
            .lock()
            .unwrap()
            .execute_batch(
                "PRAGMA foreign_keys=OFF;
                 CREATE TABLE IF NOT EXISTS device_sync_apply_journal(
                   operation_uuid TEXT PRIMARY KEY,version INTEGER NOT NULL,
                   library_uuid TEXT NOT NULL,stage TEXT NOT NULL,
                   backup_uuid TEXT NOT NULL,preview_digest TEXT NOT NULL,
                   external_reference TEXT);
                 INSERT INTO device_sync_apply_journal
                   SELECT '10000000-0000-4000-8000-000000000001',1,library_uuid,'prepare',
                     '10000000-0000-4000-8000-000000000002',
                     'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',NULL
                   FROM library_sync;
                 PRAGMA foreign_keys=ON;",
            )
            .unwrap();
        drop(database);
        drop(api);
        let reopened = CoreApi::open(directory.path()).unwrap();
        assert!(reopened
            .database()
            .list_tags()
            .unwrap()
            .contains(&"before crash".into()));
        assert!(
            matches!(
                reopened.database().create_tag("must not exist"),
                Err(crate::error::CoreError::LibraryBusy)
            ),
            "an unresolved durable journal must block direct Database writes"
        );
        assert!(matches!(
            reopened.database().device_sync_exclusive(),
            Err(crate::error::CoreError::LibraryBusy)
        ));
    }
}

#[cfg(test)]
mod receiver_sql_tests {
    use super::*;
    use crate::api::CoreApi;
    use crate::device_sync::planner::SyncMode;
    use crate::device_sync::receiver::{ReceiveOperation, Snapshot};
    use crate::device_sync::recovery::RecoveryOperation;
    use crate::sync::CancellationToken;

    async fn import(api: &CoreApi, bytes: &[u8], name: &str) -> MediaAsset {
        let input = tempfile::tempdir().unwrap();
        let path = input.path().join(name);
        std::fs::write(&path, bytes).unwrap();
        api.import_local_files(vec![path.to_string_lossy().into_owned()])
            .await
            .unwrap();
        api.list_media(GalleryQuery::default()).unwrap().remove(0)
    }

    async fn import_with_game(
        api: &CoreApi,
        bytes: &[u8],
        name: &str,
        game_name: &str,
    ) -> MediaAsset {
        let input = tempfile::tempdir().unwrap();
        let path = input.path().join(name);
        std::fs::write(&path, bytes).unwrap();
        api.import_custom_files(
            vec![path.to_string_lossy().into_owned()],
            game_name.to_owned(),
        )
        .await
        .unwrap();
        api.list_media(GalleryQuery::default()).unwrap().remove(0)
    }

    #[tokio::test]
    async fn receiver_sql_failure_rolls_back_metadata_aliases_preserve_and_new_publication() {
        let source = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        let a = CoreApi::open(source.path()).unwrap();
        let b = CoreApi::open(target.path()).unwrap();
        let incoming = import(&a, b"new transaction bytes", "source.jpg").await;
        let existing = import(&b, b"old transaction bytes", "target.jpg").await;
        b.database()
            .set_note(existing.id, "preserve my note")
            .unwrap();
        let before = Snapshot::read(&b.database(), "Local B").unwrap();
        let database = b.database();
        database.connection.lock().unwrap().execute_batch(
            "CREATE TEMP TRIGGER synthetic_receiver_failure BEFORE INSERT ON device_sync_source_name
             WHEN NEW.display_name='Incoming A'
             BEGIN SELECT RAISE(ABORT,'synthetic receiver SQL failure'); END;",
        ).unwrap();
        let mut operation = ReceiveOperation::prepare(
            database.clone(),
            Snapshot::read(&a.database(), "Incoming A").unwrap(),
            "Local B",
            SyncMode::Overwrite,
        )
        .unwrap();
        let id = operation.operation_id();
        operation
            .staging_mut()
            .begin_file(id, &incoming.sha256)
            .unwrap();
        operation
            .staging_mut()
            .write_chunk(id, &incoming.sha256, 0, b"new transaction bytes")
            .unwrap();
        operation
            .staging_mut()
            .finish_file(
                id,
                &incoming.sha256,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        let mut auth = operation.authorize().unwrap();
        assert!(operation
            .apply(
                Some(&mut auth),
                None,
                &CancellationToken::default(),
                &mut |_| {}
            )
            .is_err());
        assert_eq!(
            Snapshot::read_with_header(&database, before.manifest.header.clone(), Some("Local B"))
                .unwrap(),
            before
        );
        assert_eq!(
            std::fs::read(&existing.storage_path).unwrap(),
            b"old transaction bytes"
        );
        let new_path = target
            .path()
            .join("originals")
            .join(&incoming.sha256[..2])
            .join(&incoming.sha256[2..4])
            .join(format!("{}.jpg", incoming.sha256));
        assert!(
            !new_path.exists(),
            "failed SQL must explicitly compensate its new CAS"
        );
        assert!(!database.device_sync_recovery_pending());
        assert_eq!(
            database
                .connection
                .lock()
                .unwrap()
                .query_row(
                    "SELECT preserve_revisions FROM sync_write_context WHERE id=1",
                    [],
                    |r| r.get::<_, i64>(0),
                )
                .unwrap(),
            0
        );
        assert_eq!(
            database
                .device_sync_backup_reference_owners()
                .unwrap()
                .len(),
            1
        );
    }

    // The durable backup metadata must prevent releasing its owning refs by the
    // older low-level release API; a SQLite error is not the stable contract.
    #[test]
    fn receiver_completed_backup_owner_cannot_be_released_as_a_bare_reference_owner() {
        let a_root = tempfile::tempdir().unwrap();
        let b_root = tempfile::tempdir().unwrap();
        let a = CoreApi::open(a_root.path()).unwrap();
        let b = CoreApi::open(b_root.path()).unwrap();
        let mut operation = ReceiveOperation::prepare(
            b.database(),
            Snapshot::read(&a.database(), "A").unwrap(),
            "B",
            SyncMode::Merge,
        )
        .unwrap();
        let mut auth = operation.authorize().unwrap();
        let receipt = operation
            .apply(
                Some(&mut auth),
                None,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        let database = b.database();
        let lease = database.device_sync_exclusive().unwrap();
        assert!(matches!(
            database.device_sync_release_backup(&lease, receipt.backup_uuid),
            Err(crate::error::CoreError::LibraryReferenced)
        ));
    }

    #[tokio::test]
    async fn receiver_restore_keeps_private_sources_and_excludes_settings_jobs_from_backup() {
        let a_root = tempfile::tempdir().unwrap();
        let b_root = tempfile::tempdir().unwrap();
        let a = CoreApi::open(a_root.path()).unwrap();
        let b = CoreApi::open(b_root.path()).unwrap();
        let original = import(&b, b"retained local original", "old.jpg").await;
        let database = b.database();
        database
            .set_setting("synthetic.private", &"PRIVATE_SETTINGS_SENTINEL")
            .unwrap();
        database.connection.lock().unwrap().execute(
            "INSERT INTO media_source(media_id,source_type,source_path,remote_id,provider,discovered_at)
             VALUES(?1,'nso','LOCAL_SOURCE_PATH_SENTINEL','synthetic-remote','synthetic-provider','2020-01-01T00:00:00Z')",
            [original.id],
        ).unwrap();
        database
            .connection
            .lock()
            .unwrap()
            .execute_batch(
                "INSERT INTO sync_job(id,provider,status,cursor,created_at,updated_at)
             VALUES('synthetic-job','synthetic','idle','PRIVATE_CURSOR_SENTINEL','','');",
            )
            .unwrap();
        let before = Snapshot::read(&database, "B").unwrap();
        assert!(!serde_json::to_string(&before)
            .unwrap()
            .contains("LOCAL_SOURCE_PATH_SENTINEL"));
        let mut operation = ReceiveOperation::prepare(
            database.clone(),
            Snapshot::read(&a.database(), "A").unwrap(),
            "B",
            SyncMode::Overwrite,
        )
        .unwrap();
        let mut auth = operation.authorize().unwrap();
        let receipt = operation
            .apply(
                Some(&mut auth),
                None,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        assert_eq!(
            std::fs::read(&original.storage_path).unwrap(),
            b"retained local original"
        );
        assert!(!database
            .has_remote_media("synthetic-provider", "synthetic-remote")
            .unwrap());
        let payload: String = database
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT CAST(payload AS TEXT) FROM device_sync_backup WHERE backup_uuid=?1",
                [receipt.backup_uuid.to_string()],
                |r| r.get(0),
            )
            .unwrap();
        assert!(payload.contains("LOCAL_SOURCE_PATH_SENTINEL"));
        assert!(!payload.contains("PRIVATE_SETTINGS_SENTINEL"));
        assert!(!payload.contains("PRIVATE_CURSOR_SENTINEL"));
        let generation = database.device_sync_header().unwrap().generation;
        let mut restore =
            RecoveryOperation::preview_backup(database.clone(), receipt.backup_uuid, "B").unwrap();
        let mut auth = restore.authorize().unwrap();
        restore
            .restore(Some(&mut auth), &CancellationToken::default())
            .unwrap();
        assert_eq!(
            database.media_asset(original.id).unwrap().storage_path,
            original.storage_path
        );
        assert!(database
            .has_remote_media("synthetic-provider", "synthetic-remote")
            .unwrap());
        assert!(database.device_sync_header().unwrap().generation > generation);
        assert_eq!(
            database
                .get_setting::<String>("synthetic.private")
                .unwrap()
                .unwrap(),
            "PRIVATE_SETTINGS_SENTINEL"
        );
        assert_eq!(
            database
                .connection
                .lock()
                .unwrap()
                .query_row(
                    "SELECT cursor FROM sync_job WHERE id='synthetic-job'",
                    [],
                    |r| r.get::<_, String>(0),
                )
                .unwrap(),
            "PRIVATE_CURSOR_SENTINEL"
        );
    }

    #[tokio::test]
    async fn receiver_missing_or_corrupt_backup_never_changes_current_state() {
        let a_root = tempfile::tempdir().unwrap();
        let b_root = tempfile::tempdir().unwrap();
        let a = CoreApi::open(a_root.path()).unwrap();
        let b = CoreApi::open(b_root.path()).unwrap();
        let old = import(&b, b"backup original bytes", "old.jpg").await;
        let mut receive = ReceiveOperation::prepare(
            b.database(),
            Snapshot::read(&a.database(), "A").unwrap(),
            "B",
            SyncMode::Overwrite,
        )
        .unwrap();
        let mut auth = receive.authorize().unwrap();
        let receipt = receive
            .apply(
                Some(&mut auth),
                None,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        let database = b.database();
        let before = Snapshot::read(&database, "B").unwrap();
        let owners = database.device_sync_backup_reference_owners().unwrap();
        let hidden = std::path::PathBuf::from(format!("{}.synthetic-hidden", old.storage_path));
        std::fs::rename(&old.storage_path, &hidden).unwrap();
        let mut restore =
            RecoveryOperation::preview_backup(database.clone(), receipt.backup_uuid, "B").unwrap();
        let mut auth = restore.authorize().unwrap();
        assert!(restore
            .restore(Some(&mut auth), &CancellationToken::default())
            .is_err());
        assert_eq!(
            database.device_sync_backup_reference_owners().unwrap(),
            owners
        );
        assert_eq!(
            Snapshot::read_with_header(&database, before.manifest.header.clone(), Some("B"))
                .unwrap(),
            before
        );
        std::fs::rename(hidden, &old.storage_path).unwrap();
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE device_sync_backup SET payload=x'7b7d' WHERE backup_uuid=?1",
                [receipt.backup_uuid.to_string()],
            )
            .unwrap();
        assert!(
            RecoveryOperation::preview_backup(database.clone(), receipt.backup_uuid, "B").is_err()
        );
        assert_eq!(
            Snapshot::read_with_header(&database, before.manifest.header.clone(), Some("B"))
                .unwrap(),
            before
        );
    }

    #[test]
    fn receiver_snapshot_ignores_unrelated_historical_source_names() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let database = api.database();
        database
            .device_sync_register_local_name("Local owner")
            .unwrap();
        {
            let mut connection = database.connection.lock().unwrap();
            let transaction = connection.transaction().unwrap();
            for index in 1..=1050 {
                transaction.execute(
                    "INSERT INTO device_sync_source_name(library_uuid,display_name) VALUES(?1,'Historical, not referenced')",
                    [format!("20000000-0000-4000-8000-{index:012x}")],
                ).unwrap();
            }
            transaction.commit().unwrap();
        }
        let snapshot = Snapshot::read(&database, "Local owner").unwrap();
        assert_eq!(snapshot.sources.entries.len(), 1);
        assert_eq!(snapshot.sources.entries[0].display_name, "Local owner");
    }

    #[tokio::test]
    async fn receiver_revision_only_preserves_id_path_and_null_history_on_reopen() {
        let source = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        let a = CoreApi::open(source.path()).unwrap();
        let b = CoreApi::open(target.path()).unwrap();
        import_with_game(&a, b"same revision bytes", "a.jpeg", "Same game").await;
        let old = import_with_game(&b, b"same revision bytes", "b.jpg", "Same game").await;
        b.database()
            .connection
            .lock()
            .unwrap()
            .execute_batch(
                "UPDATE sync_write_context SET preserve_revisions=1;
             UPDATE media_asset SET imported_at='',info_revision=NULL;
             UPDATE sync_write_context SET preserve_revisions=0;",
            )
            .unwrap();
        let snapshot = Snapshot::read(&a.database(), "A").unwrap();
        let source_revision = snapshot.manifest.validate().unwrap().media[&old.sha256].revision;
        let mut receive =
            ReceiveOperation::prepare(b.database(), snapshot.clone(), "B", SyncMode::Merge)
                .unwrap();
        assert!(receive.plan().media[0].revision_only);
        assert_eq!(
            receive.plan().media[0].action,
            crate::device_sync::planner::Action::Keep
        );
        let mut auth = receive.authorize().unwrap();
        receive
            .apply(
                Some(&mut auth),
                None,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        let current = b.database().media_asset(old.id).unwrap();
        assert_eq!(current.storage_path, old.storage_path);
        assert_eq!(current.imported_at, None);
        drop(receive);
        drop(b);
        let reopened = CoreApi::open(target.path()).unwrap();
        let manifest = Snapshot::read(&reopened.database(), "B")
            .unwrap()
            .manifest
            .validate()
            .unwrap();
        assert_eq!(manifest.media[&old.sha256].revision, source_revision);
        assert_eq!(manifest.media[&old.sha256].imported_at, None);
        let repeated =
            ReceiveOperation::prepare(reopened.database(), snapshot, "B", SyncMode::Merge).unwrap();
        assert!(!repeated.plan().media[0].revision_only);
    }

    #[test]
    fn receiver_prepare_metadata_and_owner_are_atomic_on_sql_failure() {
        let source = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        let a = CoreApi::open(source.path()).unwrap();
        let b = CoreApi::open(target.path()).unwrap();
        a.database().create_tag("incoming").unwrap();
        let database = b.database();
        database
            .connection
            .lock()
            .unwrap()
            .execute_batch(
                "CREATE TEMP TRIGGER synthetic_backup_failure BEFORE INSERT ON device_sync_backup
             BEGIN SELECT RAISE(ABORT,'synthetic backup persistence failure'); END;",
            )
            .unwrap();
        let mut receive = ReceiveOperation::prepare(
            database.clone(),
            Snapshot::read(&a.database(), "A").unwrap(),
            "B",
            SyncMode::Merge,
        )
        .unwrap();
        let mut auth = receive.authorize().unwrap();
        assert!(receive
            .apply(
                Some(&mut auth),
                None,
                &CancellationToken::default(),
                &mut |_| {}
            )
            .is_err());
        assert!(database
            .device_sync_backup_reference_owners()
            .unwrap()
            .is_empty());
        assert!(database.device_sync_pending_journal().unwrap().is_none());
        assert!(!database.device_sync_recovery_pending());
        assert!(database.list_tags().unwrap().is_empty());
    }

    #[test]
    #[ignore = "Explicit synthetic startup fixture peer; requires its own TEMP root"]
    fn device_sync_startup_pending_fixture_peer() {
        let root = std::path::PathBuf::from(
            std::env::var("NSOALBUM_DEVICE_SYNC_STARTUP_FIXTURE_ROOT")
                .expect("explicit synthetic startup root"),
        );
        assert!(root.is_absolute());
        assert!(root
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("nsoalbum-startup-bridge-"));
        assert!(root
            .canonicalize()
            .unwrap()
            .starts_with(std::env::temp_dir().canonicalize().unwrap()));
        let source = tempfile::tempdir().unwrap();
        let a = CoreApi::open(source.path()).unwrap();
        let b = CoreApi::open(&root).unwrap();
        a.database().create_tag("incoming library").unwrap();
        let database = b.database();
        database.create_tag("old library").unwrap();
        let settings = crate::settings::AppSettings {
            proxy_url: None,
            library_path: root.to_string_lossy().into_owned(),
            theme: "ocean".into(),
            language: "en".into(),
            gallery_columns: 4,
            gallery_rows: 3,
            show_note_preview: true,
            show_game_tag: true,
            compact_tag_display: true,
            auto_play_video: false,
            auto_sync_on_launch: false,
            close_behavior: "ask".into(),
            custom_font_paths: Vec::new(),
            sync_policy: crate::settings::SyncPolicy {
                enabled: false,
                active_interval_minutes: 10,
                sleep_after_hours: 6,
            },
        };
        database.set_setting("app.settings", &settings).unwrap();
        database
            .connection
            .lock()
            .unwrap()
            .execute_batch(
                "CREATE TEMP TRIGGER synthetic_startup_finalization_failure
                 BEFORE UPDATE ON device_sync_apply_journal WHEN NEW.stage='finalized'
                 BEGIN SELECT RAISE(ABORT,'synthetic startup finalization failure'); END;",
            )
            .unwrap();
        let mut receive = ReceiveOperation::prepare(
            database.clone(),
            Snapshot::read(&a.database(), "Synthetic source").unwrap(),
            "Synthetic target",
            SyncMode::Overwrite,
        )
        .unwrap();
        let mut authorization = receive.authorize().unwrap();
        assert!(receive
            .apply(
                Some(&mut authorization),
                None,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .is_err());
        let journal = database.device_sync_pending_journal().unwrap().unwrap();
        assert!(journal.external_reference.is_none());
        assert!(database.device_sync_recovery_pending());
    }

    #[test]
    fn receiver_failed_finalize_and_rollback_leave_real_recoverable_pending_journals() {
        for failed_stage in ["finalized", "rolled_back"] {
            let source = tempfile::tempdir().unwrap();
            let target = tempfile::tempdir().unwrap();
            let a = CoreApi::open(source.path()).unwrap();
            let b = CoreApi::open(target.path()).unwrap();
            a.database().create_tag("incoming").unwrap();
            b.database().create_tag("original").unwrap();
            let database = b.database();
            database.connection.lock().unwrap().execute_batch(&format!(
                "CREATE TEMP TRIGGER synthetic_journal_failure BEFORE UPDATE ON device_sync_apply_journal
                 WHEN NEW.stage='{failed_stage}' BEGIN SELECT RAISE(ABORT,'synthetic journal persistence failure'); END;"
            )).unwrap();
            let mut receive = ReceiveOperation::prepare(
                database.clone(),
                Snapshot::read(&a.database(), "A").unwrap(),
                "B",
                SyncMode::Overwrite,
            )
            .unwrap();
            let mut auth = receive.authorize().unwrap();
            let cancel = CancellationToken::default();
            assert!(receive
                .apply(Some(&mut auth), None, &cancel, &mut |stage| {
                    if failed_stage == "rolled_back"
                        && stage == crate::device_sync::receiver::ApplyBoundary::Prepared
                    {
                        cancel.cancel();
                    }
                })
                .is_err());
            assert!(database.device_sync_recovery_pending());
            assert!(matches!(
                database.create_tag("blocked"),
                Err(crate::error::CoreError::LibraryBusy)
            ));
            let journal = database.device_sync_pending_journal().unwrap().unwrap();
            assert_eq!(
                database.list_tags().unwrap().contains(&"incoming".into()),
                failed_stage == "finalized"
            );
            drop(receive);
            drop(database);
            drop(b);
            let reopened = CoreApi::open(target.path()).unwrap();
            let mut recover = RecoveryOperation::preview_pending(
                reopened.database(),
                journal.operation_uuid,
                "B",
            )
            .unwrap();
            let mut auth = recover.authorize().unwrap();
            recover
                .restore(Some(&mut auth), &CancellationToken::default())
                .unwrap();
            assert!(reopened
                .database()
                .list_tags()
                .unwrap()
                .contains(&"original".into()));
            assert!(!reopened.database().device_sync_recovery_pending());
        }
    }
}

#[cfg(test)]
mod device_sync_guard_tests {
    use crate::api::CoreApi;
    use crate::error::CoreError;
    use crate::models::GalleryQuery;
    use std::path::Path;

    async fn backup_fixture(root: &Path) -> (CoreApi, crate::models::MediaAsset, uuid::Uuid) {
        let input = tempfile::tempdir().unwrap();
        let path = input.path().join("capture.jpg");
        std::fs::write(&path, b"legacy retained original").unwrap();
        let api = CoreApi::open(root).unwrap();
        api.import_local_files(vec![path.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let media = api.list_media(GalleryQuery::default()).unwrap().remove(0);
        let database = api.database();
        let exclusive = database.device_sync_exclusive().unwrap();
        let backup = database
            .device_sync_retain_backup(&exclusive, root)
            .unwrap();
        (api, media, backup)
    }

    fn stored_backup_key(api: &CoreApi, owner: uuid::Uuid, value: &str) {
        assert_eq!(
            api.database()
                .connection
                .lock()
                .unwrap()
                .execute(
                    "UPDATE device_sync_original_owner SET root_path=?1 WHERE owner_uuid=?2",
                    rusqlite::params![value, owner.to_string()],
                )
                .unwrap(),
            1
        );
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn review_fix2_legacy_unicode_backup_key_retains_across_reopens_until_owner_release() {
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("\u{00c4}");
        let (api, media, backup) = backup_fixture(&root).await;
        let canonical = root.canonicalize().unwrap();
        let old_key = canonical.to_string_lossy().to_lowercase();
        let new_key = canonical.to_string_lossy().to_ascii_lowercase();
        assert_ne!(old_key, new_key);
        assert_eq!(
            std::fs::read(media.storage_path.to_lowercase()).unwrap(),
            b"legacy retained original"
        );
        stored_backup_key(&api, backup, &old_key);
        drop(api);
        let reopened = CoreApi::open(&root).unwrap();
        reopened.delete_media(media.id).unwrap();
        assert_eq!(
            std::fs::read(&media.storage_path).unwrap(),
            b"legacy retained original"
        );
        assert_eq!(
            reopened
                .database()
                .device_sync_backup_reference_owners()
                .unwrap(),
            vec![backup]
        );
        drop(reopened);
        let reopened = CoreApi::open(&root).unwrap();
        let database = reopened.database();
        assert!(!database
            .cleanup_original(&root, Path::new(&media.storage_path), &media.sha256, None)
            .unwrap());
        assert_eq!(
            database
                .connection
                .lock()
                .unwrap()
                .query_row(
                    "SELECT root_path FROM device_sync_original_owner WHERE owner_uuid=?1",
                    [backup.to_string()],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            old_key
        );
        let exclusive = database.device_sync_exclusive().unwrap();
        database
            .device_sync_release_backup(&exclusive, backup)
            .unwrap();
        drop(exclusive);
        assert!(database
            .cleanup_original(&root, Path::new(&media.storage_path), &media.sha256, None)
            .unwrap());
        assert!(!Path::new(&media.storage_path).exists());
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn review_fix2_old_and_new_backup_owners_do_not_release_each_other() {
        for release_new_first in [true, false] {
            let parent = tempfile::tempdir().unwrap();
            let root = parent.path().join("\u{00c4}");
            let (api, media, old) = backup_fixture(&root).await;
            let database = api.database();
            let exclusive = database.device_sync_exclusive().unwrap();
            let new = database
                .device_sync_retain_backup(&exclusive, &root)
                .unwrap();
            drop(exclusive);
            let old_key = root
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .to_lowercase();
            stored_backup_key(&api, old, &old_key);
            api.delete_media(media.id).unwrap();
            let (released, remaining) = if release_new_first {
                (new, old)
            } else {
                (old, new)
            };
            let exclusive = database.device_sync_exclusive().unwrap();
            database
                .device_sync_release_backup(&exclusive, released)
                .unwrap();
            drop(exclusive);
            assert_eq!(
                database.device_sync_backup_reference_owners().unwrap(),
                vec![remaining]
            );
            assert!(!database
                .cleanup_original(&root, Path::new(&media.storage_path), &media.sha256, None)
                .unwrap());
            assert_eq!(
                std::fs::read(&media.storage_path).unwrap(),
                b"legacy retained original"
            );
            let exclusive = database.device_sync_exclusive().unwrap();
            database
                .device_sync_release_backup(&exclusive, remaining)
                .unwrap();
            drop(exclusive);
            assert!(database
                .cleanup_original(&root, Path::new(&media.storage_path), &media.sha256, None)
                .unwrap());
        }
    }

    #[tokio::test]
    async fn review_fix2_unknown_persistent_root_key_fails_closed_without_path_io() {
        let root = tempfile::tempdir().unwrap();
        let (api, media, backup) = backup_fixture(root.path()).await;
        stored_backup_key(&api, backup, "unrecognized-root-key:not-a-filesystem-path");
        let database = api.database();
        database.delete_media_record(media.id).unwrap();
        assert!(matches!(
            database.cleanup_original(
                root.path(),
                Path::new(&media.storage_path),
                &media.sha256,
                None
            ),
            Err(CoreError::LibraryReferenced)
        ));
        assert_eq!(
            std::fs::read(&media.storage_path).unwrap(),
            b"legacy retained original"
        );
        assert_eq!(
            database.device_sync_backup_reference_owners().unwrap(),
            vec![backup]
        );
        let exclusive = database.device_sync_exclusive().unwrap();
        database
            .device_sync_release_backup(&exclusive, backup)
            .unwrap();
        drop(exclusive);
        assert!(database
            .cleanup_original(
                root.path(),
                Path::new(&media.storage_path),
                &media.sha256,
                None
            )
            .unwrap());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn review_fix2_unix_does_not_accept_windows_unicode_fold_as_root_identity() {
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("\u{00c4}");
        let (api, media, backup) = backup_fixture(&root).await;
        let canonical = root.canonicalize().unwrap();
        let folded = canonical.to_string_lossy().to_lowercase();
        assert_ne!(folded, canonical.to_string_lossy());
        stored_backup_key(&api, backup, &folded);
        let database = api.database();
        database.delete_media_record(media.id).unwrap();
        assert!(matches!(
            database.cleanup_original(&root, Path::new(&media.storage_path), &media.sha256, None),
            Err(CoreError::LibraryReferenced)
        ));
        assert_eq!(
            std::fs::read(&media.storage_path).unwrap(),
            b"legacy retained original"
        );
    }

    #[tokio::test]
    async fn device_sync_guard_sql_delete_failure_keeps_active_original() {
        let directory = tempfile::tempdir().unwrap();
        let input = tempfile::tempdir().unwrap();
        let path = input.path().join("capture.jpg");
        std::fs::write(&path, b"active after SQL rollback").unwrap();
        let api = CoreApi::open(directory.path()).unwrap();
        api.import_local_files(vec![path.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let media = api.list_media(GalleryQuery::default()).unwrap().remove(0);
        let database = api.database();
        database
            .connection
            .lock()
            .unwrap()
            .execute_batch(
                "CREATE TEMP TRIGGER synthetic_delete_failure BEFORE DELETE ON media_asset
             BEGIN SELECT RAISE(ABORT,'synthetic SQL failure'); END;",
            )
            .unwrap();
        assert!(api.delete_media(media.id).is_err());
        assert_eq!(
            std::fs::read(&media.storage_path).unwrap(),
            b"active after SQL rollback"
        );
        assert_eq!(
            api.list_media(GalleryQuery::default()).unwrap()[0].id,
            media.id
        );
    }

    #[tokio::test]
    async fn device_sync_guard_failed_import_removes_only_unreferenced_originals() {
        let directory = tempfile::tempdir().unwrap();
        let input = tempfile::tempdir().unwrap();
        let api = CoreApi::open(directory.path()).unwrap();
        let success_path = input.path().join("good.jpg");
        std::fs::write(&success_path, b"shared original").unwrap();
        api.import_local_files(vec![success_path.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let media = api.list_media(GalleryQuery::default()).unwrap().remove(0);
        let database = api.database();
        database
            .connection
            .lock()
            .unwrap()
            .execute_batch(
                "CREATE TEMP TRIGGER synthetic_import_failure BEFORE INSERT ON media_source
             WHEN NEW.source_path LIKE '%fail.jpg'
             BEGIN SELECT RAISE(ABORT,'synthetic SQL failure'); END;",
            )
            .unwrap();
        let failed_path = input.path().join("fail.jpg");
        std::fs::write(&failed_path, b"shared original").unwrap();
        let summary = api
            .import_local_files(vec![failed_path.to_string_lossy().into_owned()])
            .await
            .unwrap();
        assert_eq!(summary.failed, 1);
        assert_eq!(
            std::fs::read(&media.storage_path).unwrap(),
            b"shared original"
        );
        std::fs::write(&failed_path, b"new failed original").unwrap();
        let summary = api
            .import_local_files(vec![failed_path.to_string_lossy().into_owned()])
            .await
            .unwrap();
        assert_eq!(summary.failed, 1);
        let files = walkdir::WalkDir::new(directory.path().join("originals"))
            .into_iter()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_type().is_file())
            .count();
        assert_eq!(files, 1);
        assert_eq!(api.list_media(GalleryQuery::default()).unwrap().len(), 1);
    }
}

#[derive(Debug, Clone)]
pub struct MediaStorageEntry {
    pub id: i64,
    pub sha256: String,
    pub storage_path: String,
    pub kind: MediaKind,
}

#[derive(Debug, Clone)]
pub struct MediaExportEntry {
    pub id: i64,
    pub original_name: String,
    pub storage_path: String,
    pub game_name: String,
    pub timestamp: Option<DateTime<Utc>>,
    pub tags: Vec<String>,
    pub note: String,
}

pub struct Database {
    connection: Mutex<Connection>,
    gate: std::sync::Arc<LibraryGate>,
    database_path: std::path::PathBuf,
    default_media_root: std::path::PathBuf,
    game_alias_cache: Mutex<GameAliasCache>,
    #[cfg(test)]
    alias_validation_runs: std::sync::atomic::AtomicUsize,
}

const MAX_GAME_ALIAS_ROW_BYTES: usize = 1024 * 1024;
const MAX_GAME_ALIAS_PROOF_BYTES: usize = 8 * 1024 * 1024;
const MAX_GAME_ALIAS_PROOF_NODES: usize = 65_536;

#[derive(Clone, PartialEq, Eq)]
struct GameAliasEpoch {
    revision: i64,
    stamp: String,
}

#[derive(Default)]
struct GameAliasCache {
    epoch: Option<GameAliasEpoch>,
    sources: std::collections::BTreeSet<String>,
    source_bytes: usize,
}

struct GameAliasProof {
    epoch: GameAliasEpoch,
    sources: std::collections::BTreeSet<String>,
    source_bytes: usize,
    read_bytes: usize,
    read_nodes: usize,
}

impl GameAliasProof {
    fn new(epoch: GameAliasEpoch) -> Self {
        Self {
            epoch,
            sources: Default::default(),
            source_bytes: 0,
            read_bytes: 0,
            read_nodes: 0,
        }
    }
}

struct GameAliasRow {
    source: String,
    target: String,
}

#[cfg(test)]
mod device_sync_revision_tests {
    use super::*;
    use crate::models::SourceType;

    fn candidate() -> MediaCandidate {
        MediaCandidate {
            remote_id: None,
            title_id: None,
            game_name: "Original game".into(),
            kind: MediaKind::Image,
            content_url: None,
            thumbnail_url: None,
            expected_size: None,
            captured_at: None,
            uploaded_at: None,
            expires_at: None,
            original_name: Some("picture.jpg".into()),
            file_extension: Some("jpg".into()),
            source_type: SourceType::Folder,
            source_path: None,
        }
    }

    fn has_sync_schema(database: &Database) -> bool {
        database
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='library_sync')",
                [],
                |row| row.get(0),
            )
            .unwrap()
    }

    #[test]
    fn device_sync_library_uuid_is_stable_and_not_shared_between_libraries() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("one.sqlite3");
        let database = Database::open(&path).unwrap();
        assert!(
            has_sync_schema(&database),
            "stable library identity is missing"
        );
        let identity = |db: &Database| -> String {
            db.connection
                .lock()
                .unwrap()
                .query_row(
                    "SELECT library_uuid FROM library_sync WHERE id=1",
                    [],
                    |row| row.get(0),
                )
                .unwrap()
        };
        let first = identity(&database);
        assert!(uuid::Uuid::parse_str(&first).is_ok());
        drop(database);
        assert_eq!(identity(&Database::open(&path).unwrap()), first);
        assert_ne!(
            identity(&Database::open(directory.path().join("two.sqlite3")).unwrap()),
            first
        );
    }

    #[test]
    fn device_sync_legacy_ordinary_album_one_does_not_block_system_favorites() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("legacy.sqlite3");
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch(
                    "CREATE TABLE schema_version(version INTEGER NOT NULL);
                 INSERT INTO schema_version VALUES(7);
                 CREATE TABLE album(
                   id INTEGER PRIMARY KEY, name TEXT NOT NULL, album_type TEXT NOT NULL,
                   pinned INTEGER NOT NULL DEFAULT 0, system_key TEXT UNIQUE,
                   created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
                 INSERT INTO album VALUES(1,'My album','manual',0,NULL,'2020-01-01','2020-01-01');",
                )
                .unwrap();
        }
        let database = Database::open(&path).unwrap();
        let albums = database.list_albums().unwrap();
        assert_eq!(
            albums
                .iter()
                .filter(|a| a.system_key.as_deref() == Some("favorites"))
                .count(),
            1
        );
        assert_eq!(albums.iter().find(|a| a.id == 1).unwrap().name, "My album");
        assert!(database.list_album_rules(1).unwrap().is_empty());
        let before = database.device_sync_header().unwrap();
        let favorites = albums
            .iter()
            .find(|a| a.system_key.as_deref() == Some("favorites"))
            .unwrap()
            .id;
        assert_eq!(database.list_album_rules(favorites).unwrap().len(), 1);
        drop(database);
        let reopened = Database::open(&path).unwrap();
        assert_eq!(
            reopened.device_sync_header().unwrap().generation,
            before.generation
        );
        assert_eq!(reopened.list_album_rules(favorites).unwrap().len(), 1);
    }

    #[test]
    fn device_sync_real_metadata_writes_track_complete_revision_and_noops_do_not() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        assert!(
            has_sync_schema(&database),
            "complete metadata revisions are missing"
        );
        let (id, _) = database
            .register_media(
                &"a".repeat(64),
                12,
                Path::new("secret/picture.jpg"),
                &candidate(),
                None,
            )
            .unwrap();
        let state = || -> (i64, Option<String>) {
            database.connection.lock().unwrap().query_row(
                "SELECT generation, (SELECT info_revision FROM media_asset WHERE id=?1) FROM library_sync WHERE id=1",
                [id], |r| Ok((r.get(0)?, r.get(1)?)),
            ).unwrap()
        };
        assert!(state().1.is_some());
        database.set_note(id, "kept").unwrap();
        let before = state();
        database.set_note(id, "kept").unwrap();
        assert_eq!(
            state(),
            before,
            "unchanged note must not manufacture revision"
        );
        database.set_note(id, "").unwrap();
        assert!(state().0 > before.0);
        database.set_favorite(id, true).unwrap();
        let favorites = database
            .list_albums()
            .unwrap()
            .into_iter()
            .find(|a| a.system_key.as_deref() == Some("favorites"))
            .unwrap();
        let before = state();
        database.remove_media_from_album(favorites.id, id).unwrap();
        assert!(
            state().0 > before.0,
            "indirect favorite removal must be tracked"
        );
        let tag = database.add_tag(id, "Old").unwrap();
        let before = state();
        database.rename_tag(tag, "New").unwrap();
        assert!(
            state().0 > before.0,
            "renaming an attached tag changes complete metadata"
        );
        let before = state();
        database.replace_tags(id, &["New".into()]).unwrap();
        assert_eq!(
            state(),
            before,
            "identical replacement must not manufacture revision"
        );
        database.delete_tag(tag).unwrap();
        assert!(state().0 > before.0);
    }

    fn collect(database: &Database) -> ds::Manifest {
        let header = database.device_sync_header().unwrap();
        let mut records = Vec::new();
        let mut cursor = None;
        loop {
            let page = database
                .device_sync_manifest_page(&header, cursor.as_ref(), 17)
                .unwrap();
            assert!(serde_json::to_vec(&page).unwrap().len() <= ds::MAX_PAGE_BYTES);
            records.extend(page.records);
            cursor = page.next;
            if cursor.is_none() {
                break;
            }
        }
        ds::Manifest { header, records }
    }

    #[test]
    fn device_sync_pages_are_bounded_segment_members_and_reject_changed_generation() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let album = database.create_album("Large", "", false).unwrap();
        for index in 1..=160 {
            let (id, _) = database
                .register_media(
                    &format!("{index:064x}"),
                    12,
                    Path::new("C:/private/library/media.jpg"),
                    &candidate(),
                    None,
                )
                .unwrap();
            database.add_media_to_album(album, id).unwrap();
        }
        database.create_tag("Unassigned").unwrap();
        database
            .set_setting("secret", &"credential-DO-NOT-EXPORT")
            .unwrap();
        let manifest = collect(&database);
        let encoded = serde_json::to_string(&manifest).unwrap();
        assert!(!encoded.contains("C:/private"));
        assert!(!encoded.contains("credential-DO-NOT-EXPORT"));
        let checked = manifest.validate().unwrap();
        assert_eq!(checked.media.len(), 160);
        assert_eq!(
            checked
                .albums
                .values()
                .find(|a| a.definition.name == "Large")
                .unwrap()
                .members
                .len(),
            160
        );
        assert!(checked.tags.contains_key("unassigned"));
        let header = database.device_sync_header().unwrap();
        let page = database
            .device_sync_manifest_page(&header, None, 1)
            .unwrap();
        assert_eq!(page.records.len(), 1);
        database.set_note(1, "Changed").unwrap();
        assert!(database
            .device_sync_manifest_page(&header, page.next.as_ref(), 1)
            .is_err());
        assert!(database
            .device_sync_manifest_page(&database.device_sync_header().unwrap(), None, 0)
            .is_err());
        assert!(database
            .device_sync_manifest_page(&database.device_sync_header().unwrap(), None, 129)
            .is_err());
    }

    #[test]
    fn device_sync_reopening_legacy_history_does_not_invent_complete_revisions() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("legacy.sqlite3");
        let connection = Connection::open(&path).unwrap();
        connection.execute_batch(
            "CREATE TABLE schema_version(version INTEGER NOT NULL);
             INSERT INTO schema_version VALUES(7);
             CREATE TABLE media_asset(
               id INTEGER PRIMARY KEY,sha256 TEXT NOT NULL UNIQUE,size INTEGER NOT NULL,mime TEXT,
               media_type TEXT NOT NULL,width INTEGER,height INTEGER,duration_ms INTEGER,
               captured_at TEXT,uploaded_at TEXT,imported_at TEXT NOT NULL,game_title_id TEXT,
               source_game_name TEXT NOT NULL DEFAULT '',game_name TEXT NOT NULL,
               original_name TEXT NOT NULL,storage_path TEXT NOT NULL,favorite INTEGER NOT NULL DEFAULT 0,
               status TEXT NOT NULL DEFAULT 'ready');
             INSERT INTO media_asset(id,sha256,size,media_type,imported_at,source_game_name,game_name,original_name,storage_path)
               VALUES(9,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',12,'image',
               '2020-01-01T00:00:00Z','A','B','x.jpg','C:/secret/x.jpg');
             CREATE TABLE game_tag_alias(source_name TEXT PRIMARY KEY COLLATE NOCASE,target_name TEXT NOT NULL,
               is_intermediate INTEGER NOT NULL DEFAULT 0);
             INSERT INTO game_tag_alias VALUES('A','B',0);"
        ).unwrap();
        drop(connection);
        let database = Database::open(&path).unwrap();
        let first = collect(&database).validate().unwrap();
        assert!(first.media.values().all(|media| media.revision.is_none()));
        assert!(first
            .albums
            .values()
            .all(|album| album.definition.revision.is_none()));
        assert!(first
            .mappings
            .values()
            .all(|mapping| mapping.revision.is_none()));
        drop(database);
        let second = collect(&Database::open(path).unwrap()).validate().unwrap();
        assert_eq!(first.header.library_uuid, second.header.library_uuid);
        assert_eq!(first.header.generation, second.header.generation);
        assert_eq!(first.media, second.media);
        assert_eq!(first.albums, second.albums);
    }

    #[test]
    fn device_sync_source_revision_only_apply_invalidates_snapshot_and_scope_rolls_back() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let (id, _) = database
            .register_media(&"a".repeat(64), 12, Path::new("x.jpg"), &candidate(), None)
            .unwrap();
        let before = database.device_sync_header().unwrap();
        {
            let mut connection = database.connection.lock().unwrap();
            let transaction = connection.transaction().unwrap();
            transaction
                .execute(
                    "UPDATE sync_write_context SET preserve_revisions=1 WHERE id=1",
                    [],
                )
                .unwrap();
            transaction.execute(
                "UPDATE media_asset SET favorite=1,info_revision='2000-01-01T00:00:00Z' WHERE id=?1",[id],
            ).unwrap();
            let revision: String = transaction
                .query_row(
                    "SELECT info_revision FROM media_asset WHERE id=?1",
                    [id],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(revision, "2000-01-01T00:00:00Z");
            // Dropping the failed apply rolls back both content and context.
        }
        assert_eq!(
            database.device_sync_header().unwrap().generation,
            before.generation
        );
        let preserved: i64 = database
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT preserve_revisions FROM sync_write_context WHERE id=1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(preserved, 0);
        {
            let mut connection = database.connection.lock().unwrap();
            let transaction = connection.transaction().unwrap();
            transaction
                .execute(
                    "UPDATE sync_write_context SET preserve_revisions=1 WHERE id=1",
                    [],
                )
                .unwrap();
            transaction
                .execute(
                    "UPDATE media_asset SET info_revision='2000-01-01T00:00:00Z' WHERE id=?1",
                    [id],
                )
                .unwrap();
            transaction
                .execute(
                    "UPDATE sync_write_context SET preserve_revisions=0 WHERE id=1",
                    [],
                )
                .unwrap();
            transaction.commit().unwrap();
        }
        assert!(
            database.device_sync_header().unwrap().generation > before.generation,
            "revision-only application must invalidate preview and paginated snapshots"
        );
    }

    #[test]
    fn device_sync_all_metadata_write_paths_update_revisions_but_noops_stay_stable() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let (id, _) = database
            .register_media(&"a".repeat(64), 12, Path::new("x.jpg"), &candidate(), None)
            .unwrap();
        let mut other = candidate();
        other.game_name = "Other game".into();
        other.kind = MediaKind::Video;
        other.original_name = Some("movie.mp4".into());
        other.file_extension = Some("mp4".into());
        let (other_id, _) = database
            .register_media(&"b".repeat(64), 24, Path::new("movie.mp4"), &other, None)
            .unwrap();
        let reset = |table: &str, id: i64| {
            database
                .connection
                .lock()
                .unwrap()
                .execute(
                    &format!("UPDATE {table} SET info_revision=NULL WHERE id=?1"),
                    [id],
                )
                .unwrap();
        };
        let revision = |table: &str, id: i64| -> Option<String> {
            database
                .connection
                .lock()
                .unwrap()
                .query_row(
                    &format!("SELECT info_revision FROM {table} WHERE id=?1"),
                    [id],
                    |r| r.get(0),
                )
                .unwrap()
        };
        let generation = || database.device_sync_header().unwrap().generation;
        reset("media_asset", id);
        database.set_favorite(id, true).unwrap();
        assert!(revision("media_asset", id).is_some());
        let before = generation();
        database.set_favorite(id, true).unwrap();
        assert_eq!(generation(), before);
        reset("media_asset", id);
        let first = database.add_tag(id, " One ").unwrap();
        assert!(revision("media_asset", id).is_some());
        let before = generation();
        database.add_tag(id, "one").unwrap();
        assert_eq!(generation(), before);
        reset("media_asset", id);
        database.replace_tags(id, &["Two".into()]).unwrap();
        assert!(revision("media_asset", id).is_some());
        let second = database
            .list_tag_usage()
            .unwrap()
            .into_iter()
            .find(|t| t.name == "Two")
            .unwrap()
            .id;
        reset("media_asset", id);
        database.remove_tag(id, second).unwrap();
        assert!(revision("media_asset", id).is_some());
        let before = generation();
        database.remove_tag(id, second).unwrap();
        assert_eq!(generation(), before);
        database.add_tag(id, "One").unwrap();
        database.add_tag(id, "Two").unwrap();
        let smart = database.create_album("Auto", "", true).unwrap();
        database
            .replace_album_rules(
                smart,
                &[AlbumRule {
                    rule_group: 0,
                    field: "tag".into(),
                    operator: "equals".into(),
                    value: "One".into(),
                }],
            )
            .unwrap();
        reset("media_asset", id);
        reset("album", smart);
        database.rename_tag(first, "One renamed").unwrap();
        assert!(revision("media_asset", id).is_some());
        assert!(revision("album", smart).is_some());
        reset("media_asset", id);
        reset("album", smart);
        database.merge_tags(&[first, second], "Merged").unwrap();
        assert!(revision("media_asset", id).is_some());
        assert!(revision("album", smart).is_some());
        database
            .replace_album_rules(
                smart,
                &[AlbumRule {
                    rule_group: 0,
                    field: "game".into(),
                    operator: "equals".into(),
                    value: "Original game".into(),
                }],
            )
            .unwrap();
        reset("media_asset", id);
        reset("album", smart);
        database
            .rename_game_tag("Original game", "Display")
            .unwrap();
        assert!(revision("media_asset", id).is_some());
        assert!(revision("album", smart).is_some());
        database
            .replace_album_rules(
                smart,
                &[AlbumRule {
                    rule_group: 0,
                    field: "game".into(),
                    operator: "equals".into(),
                    value: "Display".into(),
                }],
            )
            .unwrap();
        reset("media_asset", id);
        reset("album", smart);
        database
            .merge_game_tags(&["Display".into(), "Other game".into()], "Final")
            .unwrap();
        assert!(revision("media_asset", id).is_some());
        assert!(revision("album", smart).is_some());
        let manual = database.create_album("Manual", "", false).unwrap();
        assert!(revision("album", manual).is_some());
        reset("album", manual);
        database.add_media_to_album(manual, id).unwrap();
        assert!(revision("album", manual).is_some());
        let before = generation();
        database.add_media_to_album(manual, id).unwrap();
        assert_eq!(generation(), before);
        reset("album", manual);
        database.remove_media_from_album(manual, id).unwrap();
        assert!(revision("album", manual).is_some());
        let before = generation();
        database.remove_media_from_album(manual, id).unwrap();
        assert_eq!(generation(), before);
        reset("album", manual);
        database
            .update_album(manual, "Renamed", "Description", false)
            .unwrap();
        assert!(revision("album", manual).is_some());
        let before = generation();
        database
            .update_album(manual, "Renamed", "Description", false)
            .unwrap();
        assert_eq!(generation(), before);
        let rules = database.list_album_rules(smart).unwrap();
        let before = generation();
        database.replace_album_rules(smart, &rules).unwrap();
        assert_eq!(generation(), before);
        reset("album", smart);
        database.replace_album_rules(smart, &[]).unwrap();
        assert!(revision("album", smart).is_some());
        database.add_media_to_album(manual, id).unwrap();
        reset("album", manual);
        reset("media_asset", other_id);
        database
            .copy_media_metadata(&[id], other_id, "Edited")
            .unwrap();
        assert!(revision("media_asset", other_id).is_some());
        assert!(revision("album", manual).is_some());
        reset("media_asset", other_id);
        database
            .replace_media_content(
                other_id,
                &"b".repeat(64),
                &"c".repeat(64),
                30,
                Path::new("new.mp4"),
                "Edited",
            )
            .unwrap();
        assert!(revision("media_asset", other_id).is_some());
        let before = generation();
        database.delete_album(manual).unwrap();
        assert!(generation() > before);
        let before = generation();
        database.delete_media_record(other_id).unwrap();
        assert!(generation() > before);
        let final_snapshot = collect(&database).validate().unwrap();
        assert_eq!(
            final_snapshot.media[&"a".repeat(64)].source_game_name,
            "Original game"
        );
        assert_eq!(final_snapshot.media[&"a".repeat(64)].game_name, "Final");
        assert!(final_snapshot
            .mappings
            .values()
            .any(|m| m.kind == ds::MappingKind::Tag
                && m.source_name == "one"
                && m.target_name.as_deref() == Some("Merged")));
    }

    #[test]
    fn device_sync_tag_rename_and_merge_flatten_incoming_edges_and_delete_tombstones_them() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let tag = database.create_tag(" A ").unwrap();
        database.rename_tag(tag, "B").unwrap();
        database.rename_tag(tag, "C").unwrap();
        let other = database.create_tag("D").unwrap();
        database.merge_tags(&[tag, other], "Final").unwrap();
        let snapshot = collect(&database).validate().unwrap();
        for source in ["a", "b", "c", "d"] {
            assert_eq!(
                snapshot.mappings[&(ds::MappingKind::Tag, source.into())]
                    .target_name
                    .as_deref(),
                Some("Final")
            );
        }
        let final_id = database
            .list_tag_usage()
            .unwrap()
            .into_iter()
            .find(|t| t.name == "Final")
            .unwrap()
            .id;
        database.delete_tag(final_id).unwrap();
        let deleted = collect(&database).validate().unwrap();
        for source in ["a", "b", "c", "d", "final"] {
            assert!(
                deleted.mappings[&(ds::MappingKind::Tag, source.into())].deleted,
                "deleting the rename target must tombstone incoming mapping {source}"
            );
        }
    }

    #[test]
    fn device_sync_page_byte_limit_splits_large_media_and_rejects_oversized_metadata() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let tags = (0..256)
            .map(|index| format!("{index:03}{}", "x".repeat(125)))
            .collect::<Vec<_>>();
        for hash in ["a", "b"] {
            let (id, _) = database
                .register_media(&hash.repeat(64), 12, Path::new("x.jpg"), &candidate(), None)
                .unwrap();
            database.replace_tags(id, &tags).unwrap();
            database.set_note(id, &"n".repeat(8192)).unwrap();
        }
        let header = database.device_sync_header().unwrap();
        let page = database
            .device_sync_manifest_page(&header, None, 128)
            .unwrap();
        assert_eq!(
            page.records.len(),
            1,
            "byte cap must split before the item limit"
        );
        assert!(serde_json::to_vec(&page).unwrap().len() <= ds::MAX_PAGE_BYTES);
        assert_eq!(collect(&database).validate().unwrap().media.len(), 2);
        database.set_note(1, &"x".repeat(8193)).unwrap();
        assert!(database
            .device_sync_manifest_page(&database.device_sync_header().unwrap(), None, 128)
            .is_err());
    }

    #[test]
    fn device_sync_unicode_tag_normalization_updates_incoming_maps_rules_and_deletions() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let tag = database.create_tag("Alpha").unwrap();
        database.rename_tag(tag, "Öld").unwrap();
        let smart = database.create_album("Auto", "", true).unwrap();
        database
            .replace_album_rules(
                smart,
                &[AlbumRule {
                    rule_group: 0,
                    field: "tag".into(),
                    operator: "equals".into(),
                    value: " ÖLD ".into(),
                }],
            )
            .unwrap();
        database.rename_tag(tag, "Final").unwrap();
        assert_eq!(database.list_album_rules(smart).unwrap()[0].value, "Final");
        let snapshot = collect(&database).validate().unwrap();
        assert_eq!(
            snapshot.mappings[&(ds::MappingKind::Tag, "alpha".into())]
                .target_name
                .as_deref(),
            Some("Final")
        );
        let other = database.create_tag("Beta").unwrap();
        database.rename_tag(other, "Ä").unwrap();
        database.rename_tag(other, "ä").unwrap();
        database.delete_tag(other).unwrap();
        let snapshot = collect(&database).validate().unwrap();
        assert!(snapshot.mappings[&(ds::MappingKind::Tag, "beta".into())].deleted);
    }

    #[test]
    fn review_fix_independent_raw_game_mappings_survive_plan_and_future_import() {
        let directory = tempfile::tempdir().unwrap();
        let source = Database::open(directory.path().join("source.sqlite3")).unwrap();
        let target = Database::open(directory.path().join("target.sqlite3")).unwrap();
        let mut raw_a = candidate();
        raw_a.game_name = "A".into();
        source
            .register_media(&"a".repeat(64), 12, Path::new("a.jpg"), &raw_a, None)
            .unwrap();
        source.rename_game_tag("A", "B").unwrap();
        let mut raw_b = candidate();
        raw_b.game_name = "B".into();
        target
            .register_media(&"b".repeat(64), 12, Path::new("b.jpg"), &raw_b, None)
            .unwrap();
        target.rename_game_tag("B", "C").unwrap();
        let source_manifest = collect(&source);
        let target_manifest = collect(&target);
        let original_revision = source_manifest.validate().unwrap().mappings
            [&(ds::MappingKind::Game, "a".into())]
            .revision;
        let plan = crate::device_sync::planner::build_plan(
            &source_manifest,
            &target_manifest,
            crate::device_sync::planner::SyncMode::Merge,
        )
        .unwrap();
        let alias = plan
            .mappings
            .iter()
            .find(|mapping| mapping.kind == ds::MappingKind::Game && mapping.source_name == "A")
            .unwrap();
        assert_eq!(alias.target_name.as_deref(), Some("B"));
        assert_eq!(alias.revision, original_revision);
        let receiver = Database::open(directory.path().join("receiver.sqlite3")).unwrap();
        {
            let connection = receiver.connection.lock().unwrap();
            for mapping in &plan.mappings {
                if mapping.kind == ds::MappingKind::Game && !mapping.deleted {
                    connection.execute(
                        "INSERT INTO game_tag_alias(source_name,target_name,is_intermediate) VALUES(?1,?2,0)",
                        params![mapping.source_name,mapping.target_name],
                    ).unwrap();
                }
            }
        }
        for (hash, candidate, display) in [("c", &raw_a, "B"), ("d", &raw_b, "C")] {
            let (id, _) = receiver
                .register_media(
                    &hash.repeat(64),
                    12,
                    Path::new("future.jpg"),
                    candidate,
                    None,
                )
                .unwrap();
            assert_eq!(receiver.media_asset(id).unwrap().game_name, display);
        }
    }

    #[test]
    fn review_fix_existing_independent_aliases_resolve_only_one_hop_on_import() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        {
            let connection = database.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO game_tag_alias(source_name,target_name,is_intermediate)
                 VALUES('A','B',0),('B','C',0)",
                    [],
                )
                .unwrap();
        }
        let mut value = candidate();
        value.game_name = "A".into();
        let (id, _) = database
            .register_media(&"e".repeat(64), 12, Path::new("x.jpg"), &value, None)
            .unwrap();
        assert_eq!(database.media_asset(id).unwrap().game_name, "B");
    }

    #[test]
    fn review_fix_display_rename_and_merge_preserve_unrelated_raw_source_aliases() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let mut ids = std::collections::BTreeMap::new();
        for (hash, raw, display) in [("a", "A", "B"), ("d", "D", "E"), ("f", "F", "G")] {
            let mut value = candidate();
            value.game_name = raw.into();
            let (id, _) = database
                .register_media(&hash.repeat(64), 12, Path::new("x.jpg"), &value, None)
                .unwrap();
            database.rename_game_tag(raw, display).unwrap();
            ids.insert(raw, id);
        }
        database.rename_game_tag("B", "D").unwrap();
        assert_eq!(database.media_asset(ids["A"]).unwrap().game_name, "D");
        assert_eq!(database.media_asset(ids["D"]).unwrap().game_name, "E");
        database
            .merge_game_tags(&["D".into(), "E".into()], "F")
            .unwrap();
        let aliases = database.list_game_tag_aliases().unwrap();
        for (raw, display) in [("A", "F"), ("D", "F"), ("F", "G")] {
            assert!(aliases
                .iter()
                .any(|mapping| mapping.source_name == raw && mapping.target_name == display));
        }
        let mut value = candidate();
        value.game_name = "A".into();
        let (id, _) = database
            .register_media(&"b".repeat(64), 12, Path::new("future.jpg"), &value, None)
            .unwrap();
        assert_eq!(database.media_asset(id).unwrap().game_name, "F");
        assert_eq!(database.media_asset(ids["F"]).unwrap().game_name, "G");
        let before = database.device_sync_header().unwrap().generation;
        assert!(
            database.rename_game_tag("G", "A").is_err(),
            "new cycles must be rejected atomically"
        );
        assert_eq!(database.media_asset(ids["F"]).unwrap().game_name, "G");
        assert_eq!(database.device_sync_header().unwrap().generation, before);
    }

    #[test]
    fn review_fix2_unchanged_alias_batch_reuses_validation_despite_media_writes() {
        use std::sync::atomic::Ordering;
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO game_tag_alias(source_name,target_name) VALUES('A','B'),('B','C')",
                [],
            )
            .unwrap();
        database.alias_validation_runs.store(0, Ordering::Relaxed);
        let mut value = candidate();
        value.game_name = "A".into();
        let before = database.device_sync_header().unwrap().generation;
        for index in 100..140 {
            let (id, _) = database
                .register_media(
                    &format!("{index:064x}"),
                    12,
                    Path::new("x.jpg"),
                    &value,
                    None,
                )
                .unwrap();
            assert_eq!(database.media_asset(id).unwrap().game_name, "B");
            database.set_note(id, &format!("note {index}")).unwrap();
        }
        assert!(database.device_sync_header().unwrap().generation > before);
        assert_eq!(
            database.alias_validation_runs.load(Ordering::Relaxed),
            1,
            "media insertion/revision must not revalidate the unchanged alias graph"
        );
    }

    #[test]
    fn review_fix2_unmapped_import_ignores_large_unrelated_alias_graph() {
        use std::sync::atomic::Ordering;
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        {
            let mut connection = database.connection.lock().unwrap();
            let transaction = connection.transaction().unwrap();
            {
                let mut insert = transaction
                    .prepare("INSERT INTO game_tag_alias(source_name,target_name) VALUES(?1,?2)")
                    .unwrap();
                for index in 0..6000 {
                    insert
                        .execute(params![
                            format!("unused{index:06}{}", "x".repeat(790)),
                            format!("display{index:06}{}", "y".repeat(790)),
                        ])
                        .unwrap();
                }
            }
            transaction.commit().unwrap();
        }
        database.alias_validation_runs.store(0, Ordering::Relaxed);
        let mut value = candidate();
        value.game_name = "Unrelated new game".into();
        let (id, _) = database
            .register_media(&"f".repeat(64), 12, Path::new("x.jpg"), &value, None)
            .expect("ordinary unmapped import must not inherit device-sync graph budgets");
        assert_eq!(
            database.media_asset(id).unwrap().game_name,
            "Unrelated new game"
        );
        assert_eq!(database.alias_validation_runs.load(Ordering::Relaxed), 0);
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO game_tag_alias(source_name,target_name) VALUES('A','B')",
                [],
            )
            .unwrap();
        value.game_name = "A".into();
        let (id, _) = database
            .register_media(&"e".repeat(64), 12, Path::new("mapped.jpg"), &value, None)
            .unwrap();
        assert_eq!(database.media_asset(id).unwrap().game_name, "B");
        assert_eq!(
            database.alias_validation_runs.load(Ordering::Relaxed),
            1,
            "a small hit component must also ignore the large unrelated graph"
        );
    }

    #[test]
    fn review_fix2_lookup_limits_row_copy_without_blocking_unrelated_import() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO game_tag_alias(source_name,target_name) VALUES('Oversized',?1)",
                ["x".repeat(2 * 1024 * 1024)],
            )
            .unwrap();
        let mut value = candidate();
        value.game_name = "Oversized".into();
        assert!(
            database
                .register_media(&"a".repeat(64), 12, Path::new("x.jpg"), &value, None)
                .is_err(),
            "row length must be checked before copying oversized alias text"
        );
        assert_eq!(
            database
                .alias_validation_runs
                .load(std::sync::atomic::Ordering::Relaxed),
            0
        );
        value.game_name = "Unrelated".into();
        let (id, _) = database
            .register_media(&"b".repeat(64), 12, Path::new("x.jpg"), &value, None)
            .unwrap();
        assert_eq!(database.media_asset(id).unwrap().game_name, "Unrelated");
    }

    #[test]
    fn review_fix2_alias_changes_receive_and_external_damage_invalidate_only_alias_cache() {
        use std::sync::atomic::Ordering;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library.sqlite3");
        let database = Database::open(&path).unwrap();
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO game_tag_alias(source_name,target_name) VALUES('A','B')",
                [],
            )
            .unwrap();
        let mut value = candidate();
        value.game_name = "A".into();
        let import = |index: u64| {
            database.register_media(
                &format!("{index:064x}"),
                12,
                Path::new("x.jpg"),
                &value,
                None,
            )
        };
        assert_eq!(
            database
                .media_asset(import(1).unwrap().0)
                .unwrap()
                .game_name,
            "B"
        );
        assert_eq!(database.alias_validation_runs.load(Ordering::Relaxed), 1);
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE game_tag_alias SET target_name='B' WHERE source_name='A'",
                [],
            )
            .unwrap();
        import(2).unwrap();
        assert_eq!(
            database.alias_validation_runs.load(Ordering::Relaxed),
            1,
            "no-op mapping write must reuse proof"
        );
        {
            let mut connection = database.connection.lock().unwrap();
            let transaction = connection.transaction().unwrap();
            transaction
                .execute(
                    "UPDATE sync_write_context SET preserve_revisions=1 WHERE id=1",
                    [],
                )
                .unwrap();
            transaction
                .execute(
                    "UPDATE game_tag_alias SET target_name='C' WHERE source_name='A'",
                    [],
                )
                .unwrap();
            transaction
                .execute(
                    "UPDATE sync_write_context SET preserve_revisions=0 WHERE id=1",
                    [],
                )
                .unwrap();
            transaction.commit().unwrap();
        }
        assert_eq!(
            database
                .media_asset(import(3).unwrap().0)
                .unwrap()
                .game_name,
            "C"
        );
        assert_eq!(database.alias_validation_runs.load(Ordering::Relaxed), 2);
        let external = Connection::open(&path).unwrap();
        external
            .execute(
                "UPDATE game_tag_alias SET target_name='A' WHERE source_name='A'",
                [],
            )
            .unwrap();
        assert!(import(4).unwrap_err().to_string().contains("cycle"));
        assert_eq!(database.alias_validation_runs.load(Ordering::Relaxed), 3);
        external
            .execute(
                "UPDATE game_tag_alias SET target_name='D' WHERE source_name='A'",
                [],
            )
            .unwrap();
        assert_eq!(
            database
                .media_asset(import(5).unwrap().0)
                .unwrap()
                .game_name,
            "D"
        );
        assert_eq!(database.alias_validation_runs.load(Ordering::Relaxed), 4);
    }

    #[test]
    fn review_fix2_rollback_proofs_do_not_poison_same_numeric_epoch_or_failed_import() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO game_tag_alias(source_name,target_name) VALUES('A','B')",
                [],
            )
            .unwrap();
        let mut value = candidate();
        value.game_name = "A".into();
        database
            .register_media(&"a".repeat(64), 12, Path::new("x.jpg"), &value, None)
            .unwrap();
        let committed = database
            .game_alias_cache
            .lock()
            .unwrap()
            .epoch
            .clone()
            .unwrap();
        let rolled_back_epoch;
        {
            let mut connection = database.connection.lock().unwrap();
            let transaction = connection.transaction().unwrap();
            transaction
                .execute(
                    "UPDATE game_tag_alias SET target_name='C' WHERE source_name='A'",
                    [],
                )
                .unwrap();
            let (display, proof) = database
                .resolve_import_game_alias(&transaction, "A")
                .unwrap();
            assert_eq!(display, "C");
            rolled_back_epoch = proof.unwrap().epoch;
            assert!(database.game_alias_cache.lock().unwrap().epoch.as_ref() == Some(&committed));
            // No commit: both epoch and graph are rolled back, and the staged proof is dropped.
        }
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE game_tag_alias SET target_name='A' WHERE source_name='A'",
                [],
            )
            .unwrap();
        {
            let mut connection = database.connection.lock().unwrap();
            let transaction = connection.transaction().unwrap();
            let bad_epoch = game_alias_epoch(&transaction).unwrap();
            assert_eq!(bad_epoch.revision, rolled_back_epoch.revision);
            assert_ne!(bad_epoch.stamp, rolled_back_epoch.stamp);
        }
        assert!(database
            .register_media(&"b".repeat(64), 12, Path::new("x.jpg"), &value, None)
            .unwrap_err()
            .to_string()
            .contains("cycle"));
        assert!(database.game_alias_cache.lock().unwrap().epoch.as_ref() == Some(&committed));

        let failed = Database::open(directory.path().join("failed.sqlite3")).unwrap();
        failed
            .connection
            .lock()
            .unwrap()
            .execute_batch(
                "INSERT INTO game_tag_alias(source_name,target_name) VALUES('A','B');
             CREATE TRIGGER fail_media BEFORE INSERT ON media_asset BEGIN
               SELECT RAISE(ABORT,'synthetic import failure');
             END;",
            )
            .unwrap();
        assert!(failed
            .register_media(&"c".repeat(64), 12, Path::new("x.jpg"), &value, None)
            .is_err());
        assert!(
            failed.game_alias_cache.lock().unwrap().epoch.is_none(),
            "validation preceding a failed business write must not publish its proof"
        );
    }

    #[test]
    fn review_fix2_restart_and_legacy_first_hit_validate_without_persisted_trust() {
        use std::sync::atomic::Ordering;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("legacy.sqlite3");
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch(
                    "CREATE TABLE schema_version(version INTEGER NOT NULL);
                 INSERT INTO schema_version VALUES(7);
                 CREATE TABLE game_tag_alias(source_name TEXT PRIMARY KEY COLLATE NOCASE,
                   target_name TEXT NOT NULL,is_intermediate INTEGER NOT NULL DEFAULT 0);
                 INSERT INTO game_tag_alias(source_name,target_name) VALUES('A','B'),('B','C');",
                )
                .unwrap();
        }
        let mut value = candidate();
        value.game_name = "A".into();
        let database = Database::open(&path).unwrap();
        assert_eq!(database.alias_validation_runs.load(Ordering::Relaxed), 0);
        let (id, _) = database
            .register_media(&"a".repeat(64), 12, Path::new("x.jpg"), &value, None)
            .unwrap();
        assert_eq!(database.media_asset(id).unwrap().game_name, "B");
        assert_eq!(database.alias_validation_runs.load(Ordering::Relaxed), 1);
        drop(database);
        let reopened = Database::open(&path).unwrap();
        assert_eq!(reopened.alias_validation_runs.load(Ordering::Relaxed), 0);
        reopened
            .register_media(&"b".repeat(64), 12, Path::new("x.jpg"), &value, None)
            .unwrap();
        assert_eq!(reopened.alias_validation_runs.load(Ordering::Relaxed), 1);
        {
            let mut connection = reopened.connection.lock().unwrap();
            let transaction = connection.transaction().unwrap();
            assert!(read_game_alias_source(&transaction, "A", 1, true).is_err());
            assert!(
                read_game_alias_source(&transaction, "A", MAX_GAME_ALIAS_ROW_BYTES, false).is_err()
            );
        }
    }
}

pub fn probe_library_root(root: impl AsRef<Path>) -> CoreResult<LibraryRootProbe> {
    let root = root.as_ref();
    if !root.exists() {
        return Ok(LibraryRootProbe {
            exists: false,
            database_exists: false,
            database_readable: false,
            media_count: 0,
            account_count: 0,
            settings_count: 0,
        });
    }
    let database_path = root.join("database").join("library.sqlite3");
    if !database_path.exists() {
        return Ok(LibraryRootProbe {
            exists: true,
            database_exists: false,
            database_readable: false,
            media_count: 0,
            account_count: 0,
            settings_count: 0,
        });
    }
    let connection = match Connection::open_with_flags(
        &database_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    ) {
        Ok(connection) => connection,
        Err(_) => {
            return Ok(LibraryRootProbe {
                exists: true,
                database_exists: true,
                database_readable: false,
                media_count: 0,
                account_count: 0,
                settings_count: 0,
            });
        }
    };
    let table_exists = |table: &str| -> rusqlite::Result<bool> {
        connection.query_row(
            "SELECT EXISTS(
               SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1
             )",
            [table],
            |row| row.get(0),
        )
    };
    let count = |sql: &str| -> rusqlite::Result<u64> {
        connection
            .query_row(sql, [], |row| row.get::<_, i64>(0))
            .map(|value| value.max(0) as u64)
    };
    let media_count = if table_exists("media_asset")? {
        count("SELECT COUNT(*) FROM media_asset")?
    } else {
        0
    };
    let settings_count = if table_exists("app_setting")? {
        count("SELECT COUNT(*) FROM app_setting")?
    } else {
        0
    };
    let account_count = if table_exists("app_setting")? {
        connection
            .query_row(
                "SELECT COUNT(*) FROM app_setting WHERE key LIKE 'sync.runtime.%'",
                [],
                |row| row.get::<_, i64>(0),
            )?
            .max(0) as u64
    } else {
        0
    };
    Ok(LibraryRootProbe {
        exists: true,
        database_exists: true,
        database_readable: true,
        media_count,
        account_count,
        settings_count,
    })
}

#[cfg(test)]
pub(crate) mod staging_test_support {
    use super::*;

    pub(crate) fn row(
        database: &Database,
        lease: &ExclusiveLease,
        path: &Path,
        sha: &str,
        commit: bool,
    ) -> CoreResult<()> {
        lease.validate(&database.gate)?;
        let mut connection = database.connection.lock().unwrap();
        let transaction = connection.transaction()?;
        transaction.execute(
            "INSERT INTO media_asset(
               sha256,size,media_type,imported_at,game_name,original_name,storage_path
             ) VALUES(?1,3,'image','2026-01-01T00:00:00Z','Synthetic','capture.jpg',?2)",
            params![sha, path.to_string_lossy()],
        )?;
        if !commit {
            transaction.execute_batch("SELECT device_sync_injected_missing_sql_function()")?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub(crate) fn remove_row(database: &Database, lease: &ExclusiveLease, sha: &str) {
        lease.validate(&database.gate).unwrap();
        database
            .connection
            .lock()
            .unwrap()
            .execute("DELETE FROM media_asset WHERE sha256=?1", [sha])
            .unwrap();
    }
}

impl Database {
    pub(crate) fn device_sync_metadata_cost(
        &self,
        snapshot: &crate::device_sync::receiver::Snapshot,
        plan: &crate::device_sync::planner::SyncPlan,
        work: &crate::device_sync::work::WorkControl,
    ) -> CoreResult<crate::device_sync::space_budget::MetadataCost> {
        work.check()?;
        let parent = self
            .database_path
            .parent()
            .ok_or_else(|| ds::invalid("database parent unavailable"))?
            .to_path_buf();
        let connection = self.connection.lock().expect("database mutex poisoned");
        let pages: u64 = connection.query_row("PRAGMA page_count", [], |row| row.get(0))?;
        let page_size: u64 = connection.query_row("PRAGMA page_size", [], |row| row.get(0))?;
        let database_bytes = pages
            .checked_mul(page_size)
            .ok_or_else(|| ds::invalid("database size overflow"))?;
        let backup = ReceiverBackup {
            version: 1,
            snapshot: snapshot.clone(),
            tables: capture_receiver_tables(&connection, &work.cancellation())?,
        };
        let backup_bytes = bounded_json_count(&backup, work)?;
        let plan_bytes = bounded_json_count(plan, work)?;
        work.check()?;
        Ok(crate::device_sync::space_budget::MetadataCost {
            database_bytes,
            backup_bytes,
            plan_bytes,
            database_parent: parent,
        })
    }

    pub(crate) fn validate_existing_original_root(
        &self,
        root: &Path,
    ) -> CoreResult<std::path::PathBuf> {
        use std::io::Read;
        let root = root.canonicalize()?;
        let marker = root.join(ORIGINAL_ROOT_OWNER_FILE);
        let metadata = std::fs::symlink_metadata(&marker)?;
        if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > 65_536 {
            return Err(crate::error::CoreError::LibraryRootOwnership);
        }
        let mut data = Vec::new();
        std::fs::File::open(&marker)?
            .take(65_537)
            .read_to_end(&mut data)?;
        let stored: OriginalRootOwner = serde_json::from_slice(&data)
            .map_err(|_| crate::error::CoreError::LibraryRootOwnership)?;
        if stored.version != 1
            || stored.library_uuid != self.device_sync_header()?.library_uuid
            || crate::device_sync::library_guard::path_key(&stored.database_path)
                != crate::device_sync::library_guard::path_key(&self.database_path)
        {
            return Err(crate::error::CoreError::LibraryRootOwnership);
        }
        Ok(root)
    }

    pub fn device_sync_recovery_pending(&self) -> bool {
        self.gate.pending()
    }

    pub(crate) fn ensure_original_root(&self, root: &Path) -> CoreResult<std::path::PathBuf> {
        if self.device_sync_recovery_pending() {
            return self.validate_existing_original_root(root);
        }
        use std::io::{Read, Write};
        let _ownership = self
            .gate
            .root_ownership
            .lock()
            .map_err(|_| crate::error::CoreError::LibraryBusy)?;
        std::fs::create_dir_all(root)?;
        let root = root.canonicalize()?;
        let marker = root.join(ORIGINAL_ROOT_OWNER_FILE);
        let owner = OriginalRootOwner {
            version: 1,
            database_path: self.database_path.clone(),
            library_uuid: self.device_sync_header()?.library_uuid,
        };
        let validate = || -> CoreResult<()> {
            let metadata = std::fs::symlink_metadata(&marker)?;
            if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > 65_536 {
                return Err(crate::error::CoreError::LibraryRootOwnership);
            }
            let mut data = Vec::new();
            std::fs::File::open(&marker)?
                .take(65_537)
                .read_to_end(&mut data)?;
            let stored: OriginalRootOwner = serde_json::from_slice(&data)
                .map_err(|_| crate::error::CoreError::LibraryRootOwnership)?;
            if stored.version != 1
                || stored.library_uuid != owner.library_uuid
                || crate::device_sync::library_guard::path_key(&stored.database_path)
                    != crate::device_sync::library_guard::path_key(&self.database_path)
            {
                return Err(crate::error::CoreError::LibraryRootOwnership);
            }
            Ok(())
        };
        match std::fs::symlink_metadata(&marker) {
            Ok(_) => {
                validate()?;
                return Ok(root);
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let standard_database = root.join("database/library.sqlite3");
        if standard_database.exists()
            && crate::device_sync::library_guard::path_key(&standard_database.canonicalize()?)
                != crate::device_sync::library_guard::path_key(&self.database_path)
        {
            return Err(crate::error::CoreError::LibraryRootOwnership);
        }
        self.validate_legacy_original_root(&root)?;
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&marker)
        {
            Ok(mut file) => {
                file.write_all(&serde_json::to_vec(&owner)?)?;
                file.sync_all()?;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => validate()?,
            Err(error) => return Err(error.into()),
        }
        Ok(root)
    }

    fn validate_legacy_original_root(&self, root: &Path) -> CoreResult<()> {
        use sha2::{Digest, Sha256};
        use std::io::Read;
        let originals = root.join("originals");
        if !originals.exists() {
            return Ok(());
        }
        let entries = {
            let connection = self.connection.lock().expect("database mutex poisoned");
            let mut statement = connection
                .prepare("SELECT storage_path,sha256,size FROM media_asset WHERE status='ready'")?;
            let entries = statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            entries
        };
        let mut known = std::collections::HashMap::new();
        for (path, sha, length) in entries {
            if let Ok(identity) = OriginalIdentity::controlled(
                root,
                Path::new(&path),
                &sha,
                u64::try_from(length).unwrap_or(0),
            ) {
                known.insert(
                    crate::device_sync::library_guard::path_key(&identity.path()),
                    identity,
                );
            }
        }
        let mut buffer = vec![0_u8; 1024 * 1024];
        for entry in walkdir::WalkDir::new(&originals).follow_links(false) {
            let entry = entry.map_err(|_| crate::error::CoreError::LibraryRootOwnership)?;
            if entry.file_type().is_symlink() {
                return Err(crate::error::CoreError::LibraryRootOwnership);
            }
            if entry.file_type().is_dir() {
                continue;
            }
            let canonical = entry.path().canonicalize()?;
            let identity = known
                .get(&crate::device_sync::library_guard::path_key(&canonical))
                .ok_or(crate::error::CoreError::LibraryRootOwnership)?;
            let mut file = std::fs::File::open(&canonical)?;
            if file.metadata()?.len() != identity.length {
                return Err(crate::error::CoreError::LibraryRootOwnership);
            }
            let mut hasher = Sha256::new();
            loop {
                let read = file.read(&mut buffer)?;
                if read == 0 {
                    break;
                }
                hasher.update(&buffer[..read]);
            }
            if hex::encode(hasher.finalize()) != identity.sha256 {
                return Err(crate::error::CoreError::LibraryRootOwnership);
            }
        }
        Ok(())
    }

    pub(crate) fn release_original_root_if_unused(
        &self,
        lease: &ExclusiveLease,
        root: &Path,
    ) -> CoreResult<()> {
        lease.validate(&self.gate)?;
        self.assert_relocation_allowed()?;
        let root = self.ensure_original_root(root)?;
        let _ownership = self
            .gate
            .root_ownership
            .lock()
            .map_err(|_| crate::error::CoreError::LibraryBusy)?;
        let current = self.list_media_storage_entries()?;
        if current.iter().any(|entry| {
            Path::new(&entry.storage_path)
                .canonicalize()
                .is_ok_and(|path| path.starts_with(&root))
        }) {
            return Ok(());
        }
        let originals = root.join("originals");
        if originals.exists() {
            for entry in walkdir::WalkDir::new(&originals).follow_links(false) {
                let entry = entry.map_err(|_| crate::error::CoreError::LibraryRootOwnership)?;
                if !entry.file_type().is_dir() {
                    return Ok(());
                }
            }
        }
        std::fs::remove_file(root.join(ORIGINAL_ROOT_OWNER_FILE))?;
        Ok(())
    }

    fn check_managed_path_owner(&self, path: &Path, sha256: &str, length: u64) -> CoreResult<()> {
        if let Some(root) = path.ancestors().nth(4) {
            if OriginalIdentity::controlled(root, path, sha256, length).is_ok() {
                self.ensure_original_root(root)?;
            }
        }
        Ok(())
    }

    pub fn write_lease(&self) -> CoreResult<WriteLease> {
        self.gate.write()
    }

    pub fn device_sync_exclusive(&self) -> CoreResult<ExclusiveLease> {
        self.gate.exclusive()
    }

    pub(crate) fn device_sync_file_roots(
        &self,
    ) -> CoreResult<(std::path::PathBuf, std::path::PathBuf)> {
        let media = self
            .get_setting::<AppSettings>("app.settings")?
            .map(|settings| std::path::PathBuf::from(settings.library_path))
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or_else(|| self.default_media_root.clone());
        Ok((self.default_media_root.join("temporary/device-sync"), media))
    }

    pub(crate) fn device_sync_validate_exclusive(&self, lease: &ExclusiveLease) -> CoreResult<()> {
        lease.validate(&self.gate)
    }

    pub(crate) fn device_sync_original_path(
        &self,
        sha256: &str,
    ) -> CoreResult<Option<(std::path::PathBuf, u64)>> {
        let value: Option<(String, i64)> = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT storage_path,size FROM media_asset WHERE sha256=?1 AND status='ready'",
                [sha256],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        value
            .map(|(path, length)| {
                Ok((
                    path.into(),
                    u64::try_from(length).map_err(|_| ds::invalid("invalid original length"))?,
                ))
            })
            .transpose()
    }

    pub(crate) fn device_sync_pin_original_exclusive(
        &self,
        lease: &ExclusiveLease,
        root: &Path,
        path: &Path,
        sha256: &str,
        length: u64,
    ) -> CoreResult<PublicationPin> {
        lease.validate(&self.gate)?;
        self.pin_original(root, path, sha256, length)
    }

    pub(crate) fn device_sync_cleanup_published(
        &self,
        lease: &ExclusiveLease,
        root: &Path,
        path: &Path,
        sha256: &str,
        pin: &PublicationPin,
    ) -> CoreResult<bool> {
        lease.validate(&self.gate)?;
        self.cleanup_original_inner(root, path, sha256, Some(pin))
    }

    pub fn device_sync_retain_source(
        &self,
        lease: &ExclusiveLease,
        root: &Path,
    ) -> CoreResult<SourceSnapshotLease> {
        self.device_sync_retain_source_controlled(
            lease,
            root,
            &crate::device_sync::work::WorkControl::default(),
        )
    }

    pub fn device_sync_retain_source_controlled(
        &self,
        lease: &ExclusiveLease,
        root: &Path,
        work: &crate::device_sync::work::WorkControl,
    ) -> CoreResult<SourceSnapshotLease> {
        let _scope = work.begin(crate::device_sync::work::WorkStage::Pinning)?;
        work.checkpoint(crate::device_sync::work::WorkStage::Pinning, 0)?;
        lease.validate(&self.gate)?;
        let originals =
            self.controlled_originals_work(root, Some(&work.cancellation()), Some(work))?;
        work.check()?;
        let retained = self.gate.snapshot(originals);
        work.check()?;
        Ok(retained)
    }

    pub fn device_sync_retain_backup(
        &self,
        lease: &ExclusiveLease,
        root: &Path,
    ) -> CoreResult<uuid::Uuid> {
        lease.validate(&self.gate)?;
        let originals = self.controlled_originals(root)?;
        let owner = uuid::Uuid::new_v4();
        let root = crate::device_sync::library_guard::path_key(&root.canonicalize()?);
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        transaction.execute(
            "INSERT INTO device_sync_original_owner(owner_uuid,root_path) VALUES(?1,?2)",
            params![owner.to_string(), root.to_string_lossy()],
        )?;
        for identity in originals {
            transaction.execute(
                "INSERT INTO device_sync_original_ref(owner_uuid,file_path,sha256,length)
                 VALUES(?1,?2,?3,?4)",
                params![
                    owner.to_string(),
                    crate::device_sync::library_guard::path_key(&identity.relative)
                        .to_string_lossy(),
                    identity.sha256,
                    identity.length as i64
                ],
            )?;
        }
        transaction.commit()?;
        Ok(owner)
    }

    pub fn device_sync_backup_reference_owners(&self) -> CoreResult<Vec<uuid::Uuid>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection
            .prepare("SELECT owner_uuid FROM device_sync_original_owner ORDER BY owner_uuid")?;
        let values = statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        values
            .into_iter()
            .map(|value| {
                uuid::Uuid::parse_str(&value)
                    .map_err(|_| ds::invalid("invalid local backup reference owner"))
            })
            .collect()
    }

    pub fn device_sync_release_backup(
        &self,
        lease: &ExclusiveLease,
        owner: uuid::Uuid,
    ) -> CoreResult<()> {
        lease.validate(&self.gate)?;
        let is_backup: bool = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM device_sync_backup WHERE backup_uuid=?1)",
                [owner.to_string()],
                |row| row.get(0),
            )?;
        if is_backup {
            return Err(crate::error::CoreError::LibraryReferenced);
        }
        let changed = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "DELETE FROM device_sync_original_owner WHERE owner_uuid=?1",
                [owner.to_string()],
            )?;
        if changed == 0 {
            return Err(ds::invalid("backup reference owner does not exist"));
        }
        Ok(())
    }

    fn controlled_originals(&self, root: &Path) -> CoreResult<Vec<OriginalIdentity>> {
        self.controlled_originals_cancellable(root, None)
    }

    fn controlled_originals_cancellable(
        &self,
        root: &Path,
        cancel: Option<&crate::sync::CancellationToken>,
    ) -> CoreResult<Vec<OriginalIdentity>> {
        self.controlled_originals_work(root, cancel, None)
    }
    fn controlled_originals_work(
        &self,
        root: &Path,
        cancel: Option<&crate::sync::CancellationToken>,
        work: Option<&crate::device_sync::work::WorkControl>,
    ) -> CoreResult<Vec<OriginalIdentity>> {
        use sha2::{Digest, Sha256};
        use std::io::Read;
        self.ensure_original_root(root)?;
        let current = self
            .get_setting::<AppSettings>("app.settings")?
            .map(|settings| std::path::PathBuf::from(settings.library_path))
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or_else(|| self.default_media_root.clone());
        if crate::device_sync::library_guard::path_key(&root.canonicalize()?)
            != crate::device_sync::library_guard::path_key(&current.canonicalize()?)
        {
            return Err(ds::invalid(
                "original reference root is not the current local library",
            ));
        }
        let entries = {
            let mut connection = self.connection.lock().expect("database mutex poisoned");
            let interrupt =
                ScanSqlInterrupt::new(&mut connection, cancel.cloned().unwrap_or_default());
            let mut statement = interrupt.connection.prepare(
                "SELECT storage_path,sha256,size FROM media_asset WHERE status='ready' ORDER BY id",
            )?;
            let mut query = statement.query([])?;
            let mut values = Vec::new();
            while let Some(row) = query.next().map_err(|error| {
                if cancel.is_some_and(|token| token.check().is_err()) {
                    CoreError::Cancelled
                } else {
                    error.into()
                }
            })? {
                if let Some(cancel) = cancel {
                    cancel.check()?;
                }
                values.push((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ));
            }
            values
        };
        let mut originals = Vec::with_capacity(entries.len());
        let mut buffer = vec![0_u8; 1024 * 1024];
        for (path, sha, length) in entries {
            if let Some(cancel) = cancel {
                cancel.check()?;
            }
            let identity = OriginalIdentity::controlled(
                root,
                Path::new(&path),
                &sha,
                u64::try_from(length).map_err(|_| ds::invalid("invalid local original length"))?,
            )?;
            let mut file = std::fs::File::open(identity.path())?;
            if file.metadata()?.len() != identity.length {
                return Err(ds::invalid("local original length mismatch"));
            }
            let mut digest = Sha256::new();
            loop {
                if let Some(cancel) = cancel {
                    cancel.check()?;
                }
                let read = file.read(&mut buffer)?;
                if read == 0 {
                    break;
                }
                digest.update(&buffer[..read]);
                if let Some(work) = work {
                    work.checkpoint(crate::device_sync::work::WorkStage::Pinning, read)?;
                }
            }
            if hex::encode(digest.finalize()) != identity.sha256 {
                return Err(ds::invalid("local original SHA mismatch"));
            }
            originals.push(identity);
        }
        Ok(originals)
    }

    pub(crate) fn pin_original(
        &self,
        root: &Path,
        path: &Path,
        sha256: &str,
        length: u64,
    ) -> CoreResult<PublicationPin> {
        self.ensure_original_root(root)?;
        Ok(self
            .gate
            .pin(OriginalIdentity::controlled(root, path, sha256, length)?))
    }

    pub(crate) fn cleanup_original(
        &self,
        root: &Path,
        path: &Path,
        sha256: &str,
        own_pin: Option<&PublicationPin>,
    ) -> CoreResult<bool> {
        let _writing = self.write_lease()?;
        self.cleanup_original_inner(root, path, sha256, own_pin)
    }

    pub(crate) fn cleanup_original_exclusive(
        &self,
        lease: &ExclusiveLease,
        root: &Path,
        path: &Path,
        sha256: &str,
    ) -> CoreResult<bool> {
        lease.validate(&self.gate)?;
        self.cleanup_original_inner(root, path, sha256, None)
    }

    fn cleanup_original_inner(
        &self,
        root: &Path,
        path: &Path,
        sha256: &str,
        own_pin: Option<&PublicationPin>,
    ) -> CoreResult<bool> {
        self.ensure_original_root(root)?;
        if let Some(pin) = own_pin {
            pin.validate(&self.gate)?;
        }
        let metadata = match std::fs::symlink_metadata(path) {
            Ok(value) => value,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(error.into()),
        };
        let identity = OriginalIdentity::controlled(root, path, sha256, metadata.len().max(1))?;
        // Always acquire original protection before SQLite, including the actual unlink.
        let protection = self
            .gate
            .originals
            .lock()
            .map_err(|_| crate::error::CoreError::LibraryBusy)?;
        if protection.retains(&identity, own_pin) {
            return Ok(false);
        }
        let connection = self.connection.lock().expect("database mutex poisoned");
        let active: Option<String> = connection
            .query_row(
                "SELECT storage_path FROM media_asset WHERE sha256=?1",
                params![sha256],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(active) = active {
            if let Ok(actual) = Path::new(&active).canonicalize() {
                if crate::device_sync::library_guard::path_key(&actual)
                    == crate::device_sync::library_guard::path_key(&identity.path())
                {
                    return Ok(false);
                }
            }
        }
        let root_key = crate::device_sync::library_guard::path_key(&identity.root);
        // Legacy keys are comparison identities only, never filesystem paths.
        let legacy_key = if cfg!(windows) {
            identity.root.to_string_lossy().to_lowercase()
        } else {
            root_key.to_string_lossy().into_owned()
        };
        let mut statement = connection.prepare(
            "SELECT o.root_path=?1 OR o.root_path=?2
             FROM device_sync_original_ref r
             JOIN device_sync_original_owner o USING(owner_uuid)
             WHERE r.file_path=?3 AND r.sha256=?4",
        )?;
        let mut retained = false;
        for matching_root in statement.query_map(
            params![
                root_key.to_string_lossy(),
                legacy_key,
                crate::device_sync::library_guard::path_key(&identity.relative).to_string_lossy(),
                sha256
            ],
            |row| row.get::<_, bool>(0),
        )? {
            if !matching_root? {
                return Err(crate::error::CoreError::LibraryReferenced);
            }
            retained = true;
        }
        if retained {
            return Ok(false);
        }
        std::fs::remove_file(identity.path())?;
        Ok(true)
    }

    fn assert_relocation_allowed(&self) -> CoreResult<()> {
        let protection = self
            .gate
            .originals
            .lock()
            .map_err(|_| crate::error::CoreError::LibraryBusy)?;
        let retained: bool = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM device_sync_original_owner)",
                [],
                |row| row.get(0),
            )?;
        if protection.prevents_relocation() || retained {
            Err(crate::error::CoreError::LibraryReferenced)
        } else {
            Ok(())
        }
    }

    pub(crate) fn check_relocation(&self, lease: &ExclusiveLease) -> CoreResult<()> {
        lease.validate(&self.gate)?;
        self.assert_relocation_allowed()
    }

    pub fn device_sync_header(&self) -> CoreResult<ds::ManifestHeader> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        device_sync_header(&connection)
    }

    pub fn device_sync_manifest_page(
        &self,
        header: &ds::ManifestHeader,
        cursor: Option<&ds::ManifestCursor>,
        limit: usize,
    ) -> CoreResult<ds::ManifestPage> {
        self.device_sync_manifest_page_controlled(
            header,
            cursor,
            limit,
            &crate::device_sync::work::WorkControl::default(),
        )
    }

    pub fn device_sync_manifest_page_controlled(
        &self,
        header: &ds::ManifestHeader,
        cursor: Option<&ds::ManifestCursor>,
        limit: usize,
        work: &crate::device_sync::work::WorkControl,
    ) -> CoreResult<ds::ManifestPage> {
        work.check()?;
        ds::validate_header(header)?;
        if !(1..=ds::MAX_PAGE_ITEMS).contains(&limit) {
            return Err(ds::invalid("invalid page item limit"));
        }
        let mut position = cursor.cloned().unwrap_or_else(|| ds::ManifestCursor {
            library_uuid: header.library_uuid.clone(),
            generation: header.generation,
            section: 0,
            after: 0,
        });
        if position.library_uuid != header.library_uuid
            || position.generation != header.generation
            || position.section > 5
            || position.after < 0
        {
            return Err(ds::invalid("invalid or foreign page cursor"));
        }
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let interrupt = ScanSqlInterrupt::new(&mut connection, work.cancellation());
        // An interrupted SQL VM must be reported as cancellation, not as an
        // ordinary library failure. The guard removes the handler on every exit.
        let result = (|| {
            let transaction = interrupt.connection.transaction()?;
            let current = device_sync_header(&transaction)?;
            if current.library_uuid != header.library_uuid
                || current.generation != header.generation
            {
                return Err(ds::invalid("library changed; restart the manifest"));
            }
            let mut page = ds::ManifestPage {
                header: header.clone(),
                records: Vec::new(),
                next: None,
            };
            while position.section < 6 {
                work.check()?;
                let Some((key, record)) =
                    device_sync_next_record(&transaction, position.section, position.after)?
                else {
                    position.section += 1;
                    position.after = 0;
                    continue;
                };
                ds::validate_record(&record)?;
                let previous = position.clone();
                position.after = key;
                page.records.push(record);
                page.next = Some(position.clone());
                if serde_json::to_vec(&page)?.len() > ds::MAX_PAGE_BYTES {
                    page.records.pop();
                    if page.records.is_empty() {
                        return Err(ds::invalid("single record exceeds page byte limit"));
                    }
                    page.next = Some(previous);
                    transaction.commit()?;
                    return Ok(page);
                }
                if page.records.len() == limit {
                    transaction.commit()?;
                    return Ok(page);
                }
            }
            page.next = None;
            transaction.commit()?;
            Ok(page)
        })();
        work.check()?;
        result
    }

    pub fn open(path: impl AsRef<Path>) -> CoreResult<Self> {
        let gate = LibraryGate::for_database(path.as_ref())?;
        let _opening = gate.opening()?;
        let path = gate.database_path();
        let absolute = path
            .parent()
            .filter(|value| !value.as_os_str().is_empty())
            .unwrap_or(Path::new("."))
            .canonicalize()?;
        let default_media_root = if absolute.file_name().is_some_and(|name| name == "database") {
            absolute.parent().unwrap_or(&absolute).to_path_buf()
        } else {
            absolute
        };
        let connection = Connection::open(path)?;
        let pending = device_sync_has_pending(&connection)?;
        gate.publish_pending(pending);
        let database_path = connection
            .path()
            .map(Path::new)
            .ok_or_else(|| ds::invalid("local database path is unavailable"))?
            .canonicalize()?;
        connection.execute_batch("PRAGMA foreign_keys = ON;")?;
        if !pending {
            connection.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")?;
        }
        let database = Self {
            connection: Mutex::new(connection),
            gate,
            database_path,
            default_media_root,
            game_alias_cache: Mutex::new(GameAliasCache::default()),
            #[cfg(test)]
            alias_validation_runs: std::sync::atomic::AtomicUsize::new(0),
        };
        if !pending {
            database.migrate()?;
        }
        Ok(database)
    }

    fn migrate(&self) -> CoreResult<()> {
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        transaction.execute_batch(
            "CREATE TABLE IF NOT EXISTS schema_version (
               version INTEGER NOT NULL
             );
             INSERT INTO schema_version(version)
             SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version);

             CREATE TABLE IF NOT EXISTS media_asset (
               id INTEGER PRIMARY KEY,
               sha256 TEXT NOT NULL UNIQUE,
               size INTEGER NOT NULL,
               mime TEXT,
               media_type TEXT NOT NULL,
               width INTEGER,
               height INTEGER,
               duration_ms INTEGER,
               captured_at TEXT,
               uploaded_at TEXT,
               imported_at TEXT NOT NULL,
               game_title_id TEXT,
               source_game_name TEXT NOT NULL DEFAULT '',
               game_name TEXT NOT NULL,
               original_name TEXT NOT NULL,
               storage_path TEXT NOT NULL,
               favorite INTEGER NOT NULL DEFAULT 0,
               status TEXT NOT NULL DEFAULT 'ready'
             );

             CREATE TABLE IF NOT EXISTS media_source (
               id INTEGER PRIMARY KEY,
               media_id INTEGER NOT NULL REFERENCES media_asset(id) ON DELETE CASCADE,
               source_type TEXT NOT NULL,
               source_path TEXT,
               remote_id TEXT,
               provider TEXT,
               discovered_at TEXT NOT NULL,
               UNIQUE(media_id, source_type, source_path, remote_id)
             );

             CREATE TABLE IF NOT EXISTS tag (
               id INTEGER PRIMARY KEY,
               name TEXT NOT NULL COLLATE NOCASE UNIQUE,
               normalized_name TEXT NOT NULL UNIQUE,
               created_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS media_tag (
               media_id INTEGER NOT NULL REFERENCES media_asset(id) ON DELETE CASCADE,
               tag_id INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
               PRIMARY KEY(media_id, tag_id)
             );

             CREATE TABLE IF NOT EXISTS note (
               media_id INTEGER PRIMARY KEY REFERENCES media_asset(id) ON DELETE CASCADE,
               text TEXT NOT NULL,
               updated_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS album (
               id INTEGER PRIMARY KEY,
               name TEXT NOT NULL,
               album_type TEXT NOT NULL CHECK(album_type IN ('manual', 'smart')),
               pinned INTEGER NOT NULL DEFAULT 0,
               system_key TEXT UNIQUE,
               created_at TEXT NOT NULL,
               updated_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS album_media (
               album_id INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
               media_id INTEGER NOT NULL REFERENCES media_asset(id) ON DELETE CASCADE,
               PRIMARY KEY(album_id, media_id)
             );

             CREATE TABLE IF NOT EXISTS album_rule (
               id INTEGER PRIMARY KEY,
               album_id INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
               rule_group INTEGER NOT NULL DEFAULT 0,
               field TEXT NOT NULL,
               operator TEXT NOT NULL,
               value TEXT NOT NULL,
               created_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS app_setting (
               key TEXT PRIMARY KEY,
               value_json TEXT NOT NULL,
               updated_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS game_filter_usage (
               game_name TEXT PRIMARY KEY COLLATE NOCASE,
               selection_count INTEGER NOT NULL DEFAULT 0,
               last_selected_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS game_tag_alias (
               source_name TEXT PRIMARY KEY COLLATE NOCASE,
               target_name TEXT NOT NULL,
               is_intermediate INTEGER NOT NULL DEFAULT 0
             );

             CREATE TABLE IF NOT EXISTS sync_job (
               id TEXT PRIMARY KEY,
               provider TEXT NOT NULL,
               status TEXT NOT NULL,
               total_items INTEGER NOT NULL DEFAULT 0,
               completed_items INTEGER NOT NULL DEFAULT 0,
               failed_items INTEGER NOT NULL DEFAULT 0,
               cursor TEXT,
               error TEXT,
               created_at TEXT NOT NULL,
               updated_at TEXT NOT NULL
             );

             INSERT INTO album(
               name, album_type, pinned, system_key, created_at, updated_at
             ) SELECT '收藏', 'smart', 1, 'favorites', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
               WHERE NOT EXISTS(SELECT 1 FROM album WHERE system_key='favorites');
             INSERT INTO album_rule(
               album_id, rule_group, field, operator, value, created_at
             ) SELECT id, 0, 'favorite', 'equals', 'true', CURRENT_TIMESTAMP
               FROM album WHERE system_key='favorites'
               AND NOT EXISTS(SELECT 1 FROM album_rule WHERE album_id=album.id);",
        )?;
        let schema_version: i64 =
            transaction.query_row("SELECT version FROM schema_version LIMIT 1", [], |row| {
                row.get(0)
            })?;
        ensure_game_alias_epoch(&transaction)?;
        if schema_version < 2 {
            backfill_legacy_nso_names(&transaction)?;
            transaction.execute("UPDATE schema_version SET version = 2", [])?;
        }
        if schema_version < 3 {
            let has_description = transaction
                .prepare("PRAGMA table_info(album)")?
                .query_map([], |row| row.get::<_, String>(1))?
                .collect::<Result<Vec<_>, _>>()?
                .iter()
                .any(|name| name == "description");
            if !has_description {
                transaction.execute(
                    "ALTER TABLE album ADD COLUMN description TEXT NOT NULL DEFAULT ''",
                    [],
                )?;
            }
            transaction.execute("UPDATE schema_version SET version = 3", [])?;
        }
        if schema_version < 4 {
            backfill_mtp_display_names(&transaction)?;
            transaction.execute("UPDATE schema_version SET version = 4", [])?;
        }
        if schema_version < 5 {
            let has_intermediate = transaction
                .prepare("PRAGMA table_info(game_tag_alias)")?
                .query_map([], |row| row.get::<_, String>(1))?
                .collect::<Result<Vec<_>, _>>()?
                .iter()
                .any(|name| name == "is_intermediate");
            if !has_intermediate {
                transaction.execute(
                    "ALTER TABLE game_tag_alias
                     ADD COLUMN is_intermediate INTEGER NOT NULL DEFAULT 0",
                    [],
                )?;
            }
            migrate_game_tag_aliases(&transaction)?;
            transaction.execute("UPDATE schema_version SET version = 5", [])?;
        }
        if schema_version < 6 {
            let has_source_game_name = transaction
                .prepare("PRAGMA table_info(media_asset)")?
                .query_map([], |row| row.get::<_, String>(1))?
                .collect::<Result<Vec<_>, _>>()?
                .iter()
                .any(|name| name == "source_game_name");
            if !has_source_game_name {
                transaction.execute(
                    "ALTER TABLE media_asset
                     ADD COLUMN source_game_name TEXT NOT NULL DEFAULT ''",
                    [],
                )?;
            }
            migrate_hidden_source_game_names(&transaction)?;
            transaction.execute("UPDATE schema_version SET version = 6", [])?;
        }
        ensure_required_columns(&transaction)?;
        transaction.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_media_capture
               ON media_asset(captured_at DESC, imported_at DESC);
             CREATE INDEX IF NOT EXISTS idx_media_game ON media_asset(game_title_id, game_name);
             CREATE INDEX IF NOT EXISTS idx_source_remote ON media_source(provider, remote_id);",
        )?;
        if schema_version < 7 {
            transaction.execute("UPDATE schema_version SET version = 7", [])?;
        }
        migrate_device_sync(&transaction)?;
        transaction.execute_batch(
            "CREATE TABLE IF NOT EXISTS device_sync_original_owner(
               owner_uuid TEXT PRIMARY KEY, root_path TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS device_sync_original_ref(
               owner_uuid TEXT NOT NULL REFERENCES device_sync_original_owner(owner_uuid) ON DELETE CASCADE,
               file_path TEXT NOT NULL, sha256 TEXT NOT NULL, length INTEGER NOT NULL,
               PRIMARY KEY(owner_uuid,file_path)
             );
             CREATE INDEX IF NOT EXISTS idx_device_sync_original_path
               ON device_sync_original_ref(file_path,sha256);"
        )?;
        migrate_receiver(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn register_media(
        &self,
        sha256: &str,
        size: u64,
        storage_path: &Path,
        candidate: &MediaCandidate,
        provider: Option<&str>,
    ) -> CoreResult<(i64, bool)> {
        let _writing = self.write_lease()?;
        self.check_managed_path_owner(storage_path, sha256, size)?;
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let existing: Option<i64> = transaction
            .query_row(
                "SELECT id FROM media_asset WHERE sha256 = ?1",
                [sha256],
                |row| row.get(0),
            )
            .optional()?;
        let created = existing.is_none();
        let mut alias_proof = None;
        let media_id = if let Some(id) = existing {
            id
        } else {
            let imported_at = Utc::now().to_rfc3339();
            let raw_game_name = candidate.game_name.trim();
            let (game_name, proof) = self.resolve_import_game_alias(&transaction, raw_game_name)?;
            alias_proof = proof;
            let original_name = candidate
                .original_name
                .clone()
                .map(|name| rewrite_generated_name(&name, raw_game_name, &game_name))
                .unwrap_or_else(|| format!("{}.{}", sha256, candidate.storage_extension()));
            transaction.execute(
                "INSERT INTO media_asset(
                   sha256, size, media_type, captured_at, uploaded_at, imported_at,
                   game_title_id, source_game_name, game_name, original_name, storage_path
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    sha256,
                    size as i64,
                    kind_name(candidate.kind),
                    to_text(candidate.captured_at),
                    to_text(candidate.uploaded_at),
                    imported_at,
                    candidate.title_id.as_deref(),
                    raw_game_name,
                    game_name,
                    original_name,
                    storage_path.to_string_lossy(),
                ],
            )?;
            transaction.last_insert_rowid()
        };
        transaction.execute(
            "INSERT OR IGNORE INTO media_source(
               media_id, source_type, source_path, remote_id, provider, discovered_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                media_id,
                serde_json::to_string(&candidate.source_type)?.trim_matches('"'),
                candidate.source_path.as_deref(),
                candidate.remote_id.as_deref(),
                provider,
                Utc::now().to_rfc3339(),
            ],
        )?;
        transaction.commit()?;
        if let Some(proof) = alias_proof {
            self.remember_game_alias_proof(proof);
        }
        Ok((media_id, created))
    }

    fn resolve_import_game_alias(
        &self,
        transaction: &rusqlite::Transaction<'_>,
        source: &str,
    ) -> CoreResult<(String, Option<GameAliasProof>)> {
        let Some(row) =
            read_game_alias_source(transaction, source, MAX_GAME_ALIAS_ROW_BYTES, true)?
        else {
            return Ok((source.trim().into(), None));
        };
        let display = if row.target.trim().is_empty() {
            source.trim().into()
        } else {
            row.target.trim().into()
        };
        let epoch = game_alias_epoch(transaction)?;
        let cache = self
            .game_alias_cache
            .lock()
            .expect("alias cache mutex poisoned");
        let trusted = if cache.epoch.as_ref() == Some(&epoch) {
            Some(&cache.sources)
        } else {
            None
        };
        if trusted.is_some_and(|sources| sources.contains(&row.source)) {
            return Ok((display, None));
        }
        #[cfg(test)]
        self.alias_validation_runs
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut proof = GameAliasProof::new(epoch);
        validate_game_alias_component(transaction, row, trusted, &mut proof)?;
        Ok((display, Some(proof)))
    }

    fn validate_game_alias_target(
        &self,
        transaction: &rusqlite::Transaction<'_>,
        target: &str,
    ) -> CoreResult<GameAliasProof> {
        let epoch = game_alias_epoch(transaction)?;
        let cache = self
            .game_alias_cache
            .lock()
            .expect("alias cache mutex poisoned");
        let trusted = if cache.epoch.as_ref() == Some(&epoch) {
            Some(&cache.sources)
        } else {
            None
        };
        let mut proof = GameAliasProof::new(epoch);
        let mut after: Option<String> = None;
        loop {
            let row = transaction
                .query_row(
                    "SELECT source_name,target_name FROM game_tag_alias
                 WHERE target_name=?1 COLLATE NOCASE
                   AND (?2 IS NULL OR source_name>?2 COLLATE NOCASE)
                 ORDER BY source_name COLLATE NOCASE LIMIT 1",
                    params![target, after],
                    |row| {
                        bounded_game_alias_row(
                            row,
                            MAX_GAME_ALIAS_PROOF_BYTES - proof.read_bytes,
                            proof.read_nodes < MAX_GAME_ALIAS_PROOF_NODES,
                        )
                    },
                )
                .optional()?;
            let Some(row) = unpack_game_alias_row(row)? else {
                break;
            };
            after = Some(row.source.clone());
            validate_game_alias_component(transaction, row, trusted, &mut proof)?;
        }
        Ok(proof)
    }

    // Called only after the SQL transaction commits. A validated but rolled-back
    // graph never becomes trusted, even if a later transaction reuses its number.
    fn remember_game_alias_proof(&self, proof: GameAliasProof) {
        let mut cache = self
            .game_alias_cache
            .lock()
            .expect("alias cache mutex poisoned");
        if cache.epoch.as_ref() != Some(&proof.epoch)
            || cache.source_bytes.saturating_add(proof.source_bytes) > MAX_GAME_ALIAS_PROOF_BYTES
            || cache.sources.len().saturating_add(proof.sources.len()) > MAX_GAME_ALIAS_PROOF_NODES
        {
            cache.sources.clear();
            cache.source_bytes = 0;
        }
        cache.epoch = Some(proof.epoch);
        for source in proof.sources {
            if !cache.sources.contains(&source) {
                cache.source_bytes += source.len();
                cache.sources.insert(source);
            }
        }
    }

    pub fn has_remote_media(&self, provider: &str, remote_id: &str) -> CoreResult<bool> {
        let exists = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM media_source WHERE provider=?1 AND remote_id=?2)",
                params![provider, remote_id],
                |row| row.get(0),
            )?;
        Ok(exists)
    }

    pub fn begin_sync_job(&self, id: &str, provider: &str, cursor: Option<&str>) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let now = Utc::now().to_rfc3339();
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "INSERT INTO sync_job(id, provider, status, cursor, created_at, updated_at)
             VALUES (?1, ?2, 'running', ?3, ?4, ?4)",
                params![id, provider, cursor, now],
            )?;
        Ok(())
    }

    pub fn latest_sync_cursor(&self, provider: &str) -> CoreResult<Option<String>> {
        Ok(self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT cursor FROM sync_job
                 WHERE provider=?1 AND cursor IS NOT NULL
                 ORDER BY updated_at DESC LIMIT 1",
                [provider],
                |row| row.get(0),
            )
            .optional()?)
    }

    pub fn current_sync_progress(&self, provider: &str) -> CoreResult<Option<SyncProgress>> {
        Ok(self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT id, status, total_items, completed_items, failed_items
                 FROM sync_job
                 WHERE provider=?1 AND status='running'
                 ORDER BY updated_at DESC LIMIT 1",
                [provider],
                |row| {
                    let synchronized_items = row.get::<_, i64>(3)?.max(0) as usize;
                    let failed_items = row.get::<_, i64>(4)?.max(0) as usize;
                    Ok(SyncProgress {
                        job_id: row.get(0)?,
                        status: row.get(1)?,
                        total_items: row.get::<_, i64>(2)?.max(0) as usize,
                        processed_items: synchronized_items.saturating_add(failed_items),
                        synchronized_items,
                        failed_items,
                    })
                },
            )
            .optional()?)
    }

    pub fn current_sync_progress_any(&self) -> CoreResult<Option<SyncProgress>> {
        Ok(self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT id, status, total_items, completed_items, failed_items
                 FROM sync_job
                 WHERE status='running'
                 ORDER BY updated_at DESC LIMIT 1",
                [],
                |row| {
                    let synchronized_items = row.get::<_, i64>(3)?.max(0) as usize;
                    let failed_items = row.get::<_, i64>(4)?.max(0) as usize;
                    Ok(SyncProgress {
                        job_id: row.get(0)?,
                        status: row.get(1)?,
                        total_items: row.get::<_, i64>(2)?.max(0) as usize,
                        processed_items: synchronized_items.saturating_add(failed_items),
                        synchronized_items,
                        failed_items,
                    })
                },
            )
            .optional()?)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn update_sync_job(
        &self,
        id: &str,
        status: &str,
        total: usize,
        completed: usize,
        failed: usize,
        cursor: Option<&str>,
        error: Option<&str>,
    ) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "UPDATE sync_job SET status=?2, total_items=?3, completed_items=?4,
             failed_items=?5, cursor=?6, error=?7, updated_at=?8 WHERE id=?1",
                params![
                    id,
                    status,
                    total as i64,
                    completed as i64,
                    failed as i64,
                    cursor,
                    error,
                    Utc::now().to_rfc3339(),
                ],
            )?;
        Ok(())
    }

    pub fn set_favorite(&self, media_id: i64, favorite: bool) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "UPDATE media_asset SET favorite = ?2 WHERE id = ?1",
                params![media_id, favorite],
            )?;
        Ok(())
    }

    pub fn set_note(&self, media_id: i64, text: &str) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        self.connection.lock().expect("database mutex poisoned").execute(
            "INSERT INTO note(media_id, text, updated_at)
             SELECT ?1, ?2, ?3 WHERE COALESCE(
               (SELECT text FROM note WHERE media_id=?1), '')<>?2
             ON CONFLICT(media_id) DO UPDATE SET text=excluded.text, updated_at=excluded.updated_at",
            params![media_id, text, Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    pub fn add_tag(&self, media_id: i64, name: &str) -> CoreResult<i64> {
        let _writing = self.write_lease()?;
        let name = name.trim();
        if name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "tag cannot be empty".into(),
            ));
        }
        let normalized = name.to_lowercase();
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        transaction.execute(
            "INSERT OR IGNORE INTO tag(name, normalized_name, created_at) VALUES (?1, ?2, ?3)",
            params![name, normalized, Utc::now().to_rfc3339()],
        )?;
        let tag_id: i64 = transaction.query_row(
            "SELECT id FROM tag WHERE normalized_name=?1",
            [normalized],
            |row| row.get(0),
        )?;
        transaction.execute(
            "INSERT OR IGNORE INTO media_tag(media_id, tag_id) VALUES (?1, ?2)",
            params![media_id, tag_id],
        )?;
        transaction.commit()?;
        Ok(tag_id)
    }

    pub fn replace_tags(&self, media_id: i64, names: &[String]) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let wanted = names
            .iter()
            .map(|name| name.trim().to_lowercase())
            .filter(|name| !name.is_empty())
            .collect::<std::collections::BTreeSet<_>>();
        let existing = transaction.prepare(
            "SELECT t.normalized_name FROM tag t JOIN media_tag mt ON mt.tag_id=t.id WHERE mt.media_id=?1"
        )?.query_map([media_id], |row| row.get::<_, String>(0))?
            .collect::<Result<std::collections::BTreeSet<_>, _>>()?;
        if wanted == existing {
            return Ok(());
        }
        transaction.execute("DELETE FROM media_tag WHERE media_id=?1", [media_id])?;
        for name in names {
            let name = name.trim();
            if name.is_empty() {
                continue;
            }
            let normalized = name.to_lowercase();
            transaction.execute(
                "INSERT OR IGNORE INTO tag(name, normalized_name, created_at) VALUES (?1, ?2, ?3)",
                params![name, normalized, Utc::now().to_rfc3339()],
            )?;
            let tag_id: i64 = transaction.query_row(
                "SELECT id FROM tag WHERE normalized_name=?1",
                [normalized],
                |row| row.get(0),
            )?;
            transaction.execute(
                "INSERT OR IGNORE INTO media_tag(media_id, tag_id) VALUES (?1, ?2)",
                params![media_id, tag_id],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn remove_tag(&self, media_id: i64, tag_id: i64) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "DELETE FROM media_tag WHERE media_id=?1 AND tag_id=?2",
                params![media_id, tag_id],
            )?;
        Ok(())
    }

    pub fn list_tags(&self) -> CoreResult<Vec<String>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement =
            connection.prepare("SELECT name FROM tag ORDER BY name COLLATE NOCASE")?;
        let rows = statement.query_map([], |row| row.get(0))?;
        Ok(rows.collect::<Result<Vec<String>, _>>()?)
    }

    pub fn list_tag_usage(&self) -> CoreResult<Vec<TagUsageSummary>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection.prepare(
            "SELECT t.id, t.name,
                    COUNT(CASE WHEN ma.media_type='image' THEN 1 END),
                    COUNT(CASE WHEN ma.media_type='video' THEN 1 END)
             FROM tag t
             LEFT JOIN media_tag mt ON mt.tag_id=t.id
             LEFT JOIN media_asset ma ON ma.id=mt.media_id AND ma.status='ready'
             GROUP BY t.id, t.name
             ORDER BY t.name COLLATE NOCASE",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(TagUsageSummary {
                id: row.get(0)?,
                name: row.get(1)?,
                image_count: row.get(2)?,
                video_count: row.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn create_tag(&self, name: &str) -> CoreResult<i64> {
        let _writing = self.write_lease()?;
        let name = name.trim();
        if name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "tag cannot be empty".into(),
            ));
        }
        let normalized = name.to_lowercase();
        let connection = self.connection.lock().expect("database mutex poisoned");
        let existing: Option<i64> = connection
            .query_row(
                "SELECT id FROM tag WHERE normalized_name=?1",
                [&normalized],
                |row| row.get(0),
            )
            .optional()?;
        if existing.is_some() {
            return Err(crate::error::CoreError::InvalidConfig(
                "a tag with that name already exists".into(),
            ));
        }
        connection.execute(
            "INSERT INTO tag(name, normalized_name, created_at) VALUES (?1, ?2, ?3)",
            params![name, normalized, Utc::now().to_rfc3339()],
        )?;
        Ok(connection.last_insert_rowid())
    }

    pub fn rename_tag(&self, tag_id: i64, new_name: &str) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let new_name = new_name.trim();
        if new_name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "tag cannot be empty".into(),
            ));
        }
        let normalized = new_name.to_lowercase();
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let old_name: String = transaction
            .query_row("SELECT name FROM tag WHERE id=?1", [tag_id], |row| {
                row.get(0)
            })
            .optional()?
            .ok_or_else(|| crate::error::CoreError::InvalidConfig("tag does not exist".into()))?;
        let duplicate: Option<i64> = transaction
            .query_row(
                "SELECT id FROM tag WHERE normalized_name=?1 AND id<>?2",
                params![&normalized, tag_id],
                |row| row.get(0),
            )
            .optional()?;
        if duplicate.is_some() {
            return Err(crate::error::CoreError::InvalidConfig(
                "a tag with that name already exists".into(),
            ));
        }
        transaction.execute(
            "UPDATE tag SET name=?2, normalized_name=?3 WHERE id=?1",
            params![tag_id, new_name, normalized],
        )?;
        rewrite_tag_album_rules(&transaction, &old_name, new_name)?;
        record_tag_mapping(&transaction, &old_name, new_name)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn delete_tag(&self, tag_id: i64) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let name: String = transaction
            .query_row("SELECT name FROM tag WHERE id=?1", [tag_id], |row| {
                row.get(0)
            })
            .optional()?
            .ok_or_else(|| crate::error::CoreError::InvalidConfig("tag does not exist".into()))?;
        for source in tag_mapping_sources_for_target(&transaction, &name)? {
            transaction.execute(
                "UPDATE sync_mapping SET target_name=NULL,deleted=1,
                 revision=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE kind='tag' AND source_name=?1",
                [source],
            )?;
        }
        transaction.execute("DELETE FROM tag WHERE id=?1", [tag_id])?;
        transaction.commit()?;
        Ok(())
    }

    pub fn merge_tags(&self, tag_ids: &[i64], target_name: &str) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let target_name = target_name.trim();
        if target_name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "merged tag name cannot be empty".into(),
            ));
        }
        let unique_ids = tag_ids
            .iter()
            .copied()
            .collect::<std::collections::BTreeSet<_>>();
        if unique_ids.len() < 2 {
            return Err(crate::error::CoreError::InvalidConfig(
                "select at least two tags to merge".into(),
            ));
        }

        let normalized = target_name.to_lowercase();
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let mut selected = Vec::with_capacity(unique_ids.len());
        for tag_id in unique_ids {
            let name: String = transaction
                .query_row("SELECT name FROM tag WHERE id=?1", [tag_id], |row| {
                    row.get(0)
                })
                .optional()?
                .ok_or_else(|| {
                    crate::error::CoreError::InvalidConfig("tag does not exist".into())
                })?;
            selected.push((tag_id, name));
        }

        let existing_target: Option<i64> = transaction
            .query_row(
                "SELECT id FROM tag WHERE normalized_name=?1",
                [&normalized],
                |row| row.get(0),
            )
            .optional()?;
        let target_id = if let Some(id) = existing_target {
            transaction.execute(
                "UPDATE tag SET name=?2 WHERE id=?1",
                params![id, target_name],
            )?;
            id
        } else {
            transaction.execute(
                "INSERT INTO tag(name, normalized_name, created_at) VALUES (?1, ?2, ?3)",
                params![target_name, normalized, Utc::now().to_rfc3339()],
            )?;
            transaction.last_insert_rowid()
        };

        for (tag_id, old_name) in &selected {
            transaction.execute(
                "INSERT OR IGNORE INTO media_tag(media_id, tag_id)
                 SELECT media_id, ?1 FROM media_tag WHERE tag_id=?2",
                params![target_id, tag_id],
            )?;
            rewrite_tag_album_rules(&transaction, old_name, target_name)?;
        }
        // Move incoming aliases before delete triggers retire their old targets.
        for (_, old_name) in &selected {
            record_tag_mapping(&transaction, old_name, target_name)?;
        }
        for (tag_id, _) in &selected {
            if *tag_id != target_id {
                transaction.execute("DELETE FROM tag WHERE id=?1", [tag_id])?;
            }
        }
        for (_, old_name) in selected {
            record_tag_mapping(&transaction, &old_name, target_name)?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn list_game_tags(&self) -> CoreResult<Vec<GameTagSummary>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection.prepare(
            "SELECT TRIM(ma.game_name),
                    COUNT(CASE WHEN ma.media_type='image' THEN 1 END),
                    COUNT(CASE WHEN ma.media_type='video' THEN 1 END),
                    COALESCE(gfu.selection_count, 0)
             FROM media_asset ma
             LEFT JOIN game_filter_usage gfu
               ON gfu.game_name=TRIM(ma.game_name)
             WHERE ma.status='ready' AND TRIM(ma.game_name) <> ''
             GROUP BY TRIM(ma.game_name)
             ORDER BY COALESCE(gfu.selection_count, 0) DESC,
                      COUNT(ma.id) DESC,
                      TRIM(ma.game_name) COLLATE NOCASE",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(GameTagSummary {
                name: row.get(0)?,
                image_count: row.get(1)?,
                video_count: row.get(2)?,
                selection_count: row.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn list_game_tag_aliases(&self) -> CoreResult<Vec<GameTagAliasSummary>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection.prepare(
            "SELECT source_name, target_name
             FROM game_tag_alias
             WHERE is_intermediate=0
             ORDER BY target_name COLLATE NOCASE, source_name COLLATE NOCASE",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(GameTagAliasSummary {
                source_name: row.get(0)?,
                target_name: row.get(1)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn record_game_tag_selection(&self, game_name: &str) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let game_name = game_name.trim();
        if game_name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "game tag cannot be empty".into(),
            ));
        }
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "INSERT INTO game_filter_usage(game_name, selection_count, last_selected_at)
                 VALUES (?1, 1, ?2)
                 ON CONFLICT(game_name) DO UPDATE SET
                   selection_count=selection_count + 1,
                   last_selected_at=excluded.last_selected_at",
                params![game_name, Utc::now().to_rfc3339()],
            )?;
        Ok(())
    }

    pub fn merge_game_tags(&self, game_names: &[String], target_name: &str) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let requested_target = target_name.trim();
        if requested_target.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "merged game tag name cannot be empty".into(),
            ));
        }
        let unique_names = game_names
            .iter()
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
            .map(|value| (value.to_lowercase(), value.to_owned()))
            .collect::<std::collections::BTreeMap<_, _>>()
            .into_values()
            .collect::<Vec<_>>();
        if unique_names.len() < 2 {
            return Err(crate::error::CoreError::InvalidConfig(
                "select at least two game tags to merge".into(),
            ));
        }

        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let target_name = requested_target.to_owned();
        let mut selection_count = 0_i64;
        let target_was_selected = unique_names
            .iter()
            .any(|name| name.eq_ignore_ascii_case(&target_name));
        for old_name in &unique_names {
            let exists: bool = transaction.query_row(
                "SELECT EXISTS(SELECT 1 FROM media_asset WHERE game_name=?1 COLLATE NOCASE)",
                [old_name],
                |row| row.get(0),
            )?;
            if !exists {
                return Err(crate::error::CoreError::InvalidConfig(format!(
                    "game tag does not exist: {old_name}"
                )));
            }
            selection_count += transaction
                .query_row(
                    "SELECT selection_count FROM game_filter_usage
                     WHERE game_name=?1 COLLATE NOCASE",
                    [old_name],
                    |row| row.get(0),
                )
                .optional()?
                .unwrap_or(0);
            let source_names = source_game_names_for_display(&transaction, old_name)?;
            rewrite_generated_media_names(&transaction, old_name, &target_name)?;
            transaction.execute(
                "UPDATE media_asset SET game_name=?1 WHERE game_name=?2 COLLATE NOCASE",
                params![target_name, old_name],
            )?;
            transaction.execute(
                "UPDATE album_rule SET value=?1
                 WHERE field IN ('game', 'game_tag') AND lower(trim(value))=?2",
                params![target_name, old_name.to_lowercase()],
            )?;
            transaction.execute(
                "UPDATE game_tag_alias SET target_name=?1
                 WHERE target_name=?2 COLLATE NOCASE",
                params![target_name, old_name],
            )?;
            for source_name in source_names {
                if !source_name.eq_ignore_ascii_case(&target_name) {
                    upsert_game_tag_alias(&transaction, &source_name, &target_name)?;
                } else {
                    transaction.execute(
                        "DELETE FROM game_tag_alias WHERE source_name=?1 COLLATE NOCASE",
                        [&source_name],
                    )?;
                }
            }
            transaction.execute(
                "DELETE FROM game_filter_usage WHERE game_name=?1 COLLATE NOCASE",
                [old_name],
            )?;
        }
        let alias_proof = self.validate_game_alias_target(&transaction, &target_name)?;
        if selection_count > 0 {
            if target_was_selected {
                transaction.execute(
                    "INSERT INTO game_filter_usage(game_name, selection_count, last_selected_at)
                     VALUES (?1, ?2, ?3)",
                    params![target_name, selection_count, Utc::now().to_rfc3339()],
                )?;
            } else {
                transaction.execute(
                    "INSERT INTO game_filter_usage(game_name, selection_count, last_selected_at)
                     VALUES (?1, ?2, ?3)
                     ON CONFLICT(game_name) DO UPDATE SET
                       selection_count=selection_count + excluded.selection_count,
                       last_selected_at=excluded.last_selected_at",
                    params![target_name, selection_count, Utc::now().to_rfc3339()],
                )?;
            }
        }
        transaction.commit()?;
        self.remember_game_alias_proof(alias_proof);
        Ok(())
    }

    pub fn rename_game_tag(&self, game_name: &str, target_name: &str) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let game_name = game_name.trim();
        let requested_target = target_name.trim();
        if game_name.is_empty() || requested_target.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "game tag name cannot be empty".into(),
            ));
        }

        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let target_name = requested_target.to_owned();
        let exists: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM media_asset WHERE game_name=?1 COLLATE NOCASE)",
            [game_name],
            |row| row.get(0),
        )?;
        if !exists {
            return Err(crate::error::CoreError::InvalidConfig(
                "game tag does not exist".into(),
            ));
        }
        if !game_name.eq_ignore_ascii_case(&target_name) {
            let duplicate: bool = transaction.query_row(
                "SELECT EXISTS(SELECT 1 FROM media_asset WHERE game_name=?1 COLLATE NOCASE)",
                [&target_name],
                |row| row.get(0),
            )?;
            if duplicate {
                return Err(crate::error::CoreError::InvalidConfig(
                    "a game tag with that name already exists; use merge game tags instead".into(),
                ));
            }
        }

        let selection_count = transaction
            .query_row(
                "SELECT selection_count FROM game_filter_usage
                 WHERE game_name=?1 COLLATE NOCASE",
                [game_name],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .unwrap_or(0);
        let source_names = source_game_names_for_display(&transaction, game_name)?;
        rewrite_generated_media_names(&transaction, game_name, &target_name)?;
        transaction.execute(
            "UPDATE media_asset SET game_name=?1 WHERE game_name=?2 COLLATE NOCASE",
            params![target_name, game_name],
        )?;
        transaction.execute(
            "UPDATE album_rule SET value=?1
             WHERE field IN ('game', 'game_tag') AND lower(trim(value))=?2",
            params![target_name, game_name.to_lowercase()],
        )?;
        transaction.execute(
            "UPDATE game_tag_alias SET target_name=?1
             WHERE target_name=?2 COLLATE NOCASE",
            params![target_name, game_name],
        )?;
        for source_name in source_names {
            if !source_name.eq_ignore_ascii_case(&target_name) {
                upsert_game_tag_alias(&transaction, &source_name, &target_name)?;
            } else {
                transaction.execute(
                    "DELETE FROM game_tag_alias WHERE source_name=?1 COLLATE NOCASE",
                    [&source_name],
                )?;
            }
        }
        let alias_proof = self.validate_game_alias_target(&transaction, &target_name)?;
        transaction.execute(
            "DELETE FROM game_filter_usage WHERE game_name=?1 COLLATE NOCASE",
            [game_name],
        )?;
        if selection_count > 0 {
            transaction.execute(
                "INSERT INTO game_filter_usage(game_name, selection_count, last_selected_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(game_name) DO UPDATE SET
                   selection_count=excluded.selection_count,
                   last_selected_at=excluded.last_selected_at",
                params![target_name, selection_count, Utc::now().to_rfc3339()],
            )?;
        }
        transaction.commit()?;
        self.remember_game_alias_proof(alias_proof);
        Ok(())
    }

    pub fn list_albums(&self) -> CoreResult<Vec<AlbumSummary>> {
        let mut albums = {
            let connection = self.connection.lock().expect("database mutex poisoned");
            // Pending legacy libraries deliberately skip migrations on open.
            // Display projection must remain read-only, including when only
            // part of the provenance schema is present.
            let has_sources: bool = connection.query_row(
                "SELECT EXISTS(
                   SELECT 1 FROM pragma_table_info('album') WHERE name='source_library_uuid')
                   AND EXISTS(SELECT 1 FROM pragma_table_info('device_sync_source_name')
                     WHERE name='library_uuid')
                   AND EXISTS(SELECT 1 FROM pragma_table_info('device_sync_source_name')
                     WHERE name='display_name')",
                [],
                |row| row.get(0),
            )?;
            let sql = if has_sources {
                "SELECT a.id, a.name, a.description, a.album_type, a.pinned, a.system_key,
                   CASE WHEN a.system_key='favorites' THEN NULL
                        ELSE NULLIF(trim(s.display_name),'') END
                 FROM album a LEFT JOIN device_sync_source_name s
                   ON s.library_uuid=a.source_library_uuid
                 ORDER BY CASE WHEN a.system_key='favorites' THEN 0 ELSE 1 END,
                          a.pinned DESC, a.updated_at DESC"
            } else {
                "SELECT a.id, a.name, a.description, a.album_type, a.pinned, a.system_key,NULL
                 FROM album a
                 ORDER BY CASE WHEN a.system_key='favorites' THEN 0 ELSE 1 END,
                          a.pinned DESC, a.updated_at DESC"
            };
            let mut statement = connection.prepare(sql)?;
            let rows = statement.query_map([], |row| {
                Ok(AlbumSummary {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    album_type: row.get(3)?,
                    pinned: row.get::<_, i64>(4)? != 0,
                    system_key: row.get(5)?,
                    media_count: 0,
                    source_device_name: row.get(6)?,
                })
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        let media = self.load_all_media()?;
        for album in &mut albums {
            let (album_type, system_key, rules, manual_ids) = self.album_filter(album.id)?;
            album.media_count = media
                .iter()
                .filter(|asset| {
                    if system_key.as_deref() == Some("favorites") {
                        asset.favorite
                    } else if album_type == "smart" {
                        matches_album_rules(asset, &rules)
                    } else {
                        manual_ids.contains(&asset.id)
                    }
                })
                .count() as u64;
        }
        Ok(albums)
    }

    pub fn create_album(&self, name: &str, description: &str, smart: bool) -> CoreResult<i64> {
        let _writing = self.write_lease()?;
        let name = name.trim();
        if name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "album name cannot be empty".into(),
            ));
        }
        let now = Utc::now().to_rfc3339();
        let connection = self.connection.lock().expect("database mutex poisoned");
        connection.execute(
            "INSERT INTO album(name, description, album_type, pinned, created_at, updated_at)
             VALUES (?1, ?2, ?3, 0, ?4, ?4)",
            params![
                name,
                description.trim(),
                if smart { "smart" } else { "manual" },
                now
            ],
        )?;
        Ok(connection.last_insert_rowid())
    }

    pub fn update_album(
        &self,
        album_id: i64,
        name: &str,
        description: &str,
        smart: bool,
    ) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let name = name.trim();
        if name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "album name cannot be empty".into(),
            ));
        }
        let (old_type, system_key, old_rules, _) = self.album_filter(album_id)?;
        if system_key.is_some() {
            return Err(crate::error::CoreError::InvalidConfig(
                "system albums cannot be renamed or converted".into(),
            ));
        }
        let matched_ids = if old_type == "smart" && !smart {
            self.load_all_media()?
                .into_iter()
                .filter(|media| matches_album_rules(media, &old_rules))
                .map(|media| media.id)
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE album SET name=?2, description=?3, album_type=?4, updated_at=?5
             WHERE id=?1 AND system_key IS NULL
             AND (name IS NOT ?2 OR description IS NOT ?3 OR album_type IS NOT ?4)",
            params![
                album_id,
                name,
                description.trim(),
                if smart { "smart" } else { "manual" },
                Utc::now().to_rfc3339()
            ],
        )?;
        if changed == 0 {
            return Ok(());
        }
        if old_type != if smart { "smart" } else { "manual" } {
            transaction.execute("DELETE FROM album_media WHERE album_id=?1", [album_id])?;
            transaction.execute("DELETE FROM album_rule WHERE album_id=?1", [album_id])?;
            if !smart {
                for media_id in matched_ids {
                    transaction.execute(
                        "INSERT OR IGNORE INTO album_media(album_id, media_id) VALUES (?1, ?2)",
                        params![album_id, media_id],
                    )?;
                }
            }
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn list_album_rules(&self, album_id: i64) -> CoreResult<Vec<AlbumRule>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection.prepare(
            "SELECT rule_group, field, operator, value FROM album_rule
             WHERE album_id=?1 ORDER BY rule_group, id",
        )?;
        let rows = statement.query_map([album_id], |row| {
            Ok(AlbumRule {
                rule_group: row.get(0)?,
                field: row.get(1)?,
                operator: row.get(2)?,
                value: row.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn delete_album(&self, album_id: i64) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let changed = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "DELETE FROM album WHERE id=?1 AND system_key IS NULL",
                [album_id],
            )?;
        if changed == 0 {
            return Err(crate::error::CoreError::InvalidConfig(
                "system albums cannot be deleted".into(),
            ));
        }
        Ok(())
    }

    pub fn replace_album_rules(&self, album_id: i64, rules: &[AlbumRule]) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let album_type: String = transaction.query_row(
            "SELECT album_type FROM album WHERE id=?1",
            [album_id],
            |row| row.get(0),
        )?;
        if album_type != "smart" {
            return Err(crate::error::CoreError::InvalidConfig(
                "rules can only be assigned to smart albums".into(),
            ));
        }
        let canonical = |rules: &[AlbumRule]| {
            rules
                .iter()
                .map(|rule| {
                    (
                        rule.rule_group,
                        rule.field.clone(),
                        rule.operator.clone(),
                        rule.value.clone(),
                    )
                })
                .collect::<std::collections::BTreeSet<_>>()
        };
        let old_rules = transaction
            .prepare("SELECT rule_group, field, operator, value FROM album_rule WHERE album_id=?1")?
            .query_map([album_id], |row| {
                Ok(AlbumRule {
                    rule_group: row.get(0)?,
                    field: row.get(1)?,
                    operator: row.get(2)?,
                    value: row.get(3)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        if canonical(&old_rules) == canonical(rules) {
            return Ok(());
        }
        transaction.execute("DELETE FROM album_rule WHERE album_id=?1", [album_id])?;
        for rule in rules {
            transaction.execute(
                "INSERT INTO album_rule(album_id, rule_group, field, operator, value, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    album_id,
                    rule.rule_group,
                    &rule.field,
                    &rule.operator,
                    &rule.value,
                    Utc::now().to_rfc3339()
                ],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn add_media_to_album(&self, album_id: i64, media_id: i64) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "INSERT OR IGNORE INTO album_media(album_id, media_id)
                 SELECT ?1, ?2 WHERE EXISTS(
                   SELECT 1 FROM album WHERE id=?1 AND album_type='manual'
                 )",
                params![album_id, media_id],
            )?;
        Ok(())
    }

    pub fn remove_media_from_album(&self, album_id: i64, media_id: i64) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let (album_type, system_key): (String, Option<String>) = transaction.query_row(
            "SELECT album_type, system_key FROM album WHERE id=?1",
            [album_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        if system_key.as_deref() == Some("favorites") {
            transaction.execute("UPDATE media_asset SET favorite=0 WHERE id=?1", [media_id])?;
        } else if album_type == "manual" {
            transaction.execute(
                "DELETE FROM album_media WHERE album_id=?1 AND media_id=?2",
                params![album_id, media_id],
            )?;
        } else {
            return Err(crate::error::CoreError::InvalidConfig(
                "media cannot be manually removed from a rule-based smart album".into(),
            ));
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn media_album_membership_count(&self, media_id: i64) -> CoreResult<u64> {
        let media = self
            .load_all_media()?
            .into_iter()
            .find(|asset| asset.id == media_id)
            .ok_or_else(|| {
                crate::error::CoreError::InvalidConfig("media item does not exist".into())
            })?;
        let albums = {
            let connection = self.connection.lock().expect("database mutex poisoned");
            let mut statement =
                connection.prepare("SELECT id, album_type, system_key FROM album ORDER BY id")?;
            let rows = statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            rows
        };
        let mut count = 0_u64;
        for (album_id, album_type, system_key) in albums {
            if system_key.as_deref() == Some("favorites") {
                count += u64::from(media.favorite);
                continue;
            }
            let (_, _, rules, manual_ids) = self.album_filter(album_id)?;
            let included = if album_type == "smart" {
                matches_album_rules(&media, &rules)
            } else {
                manual_ids.contains(&media_id)
            };
            count += u64::from(included);
        }
        Ok(count)
    }

    pub fn media_storage_entry(&self, media_id: i64) -> CoreResult<MediaStorageEntry> {
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT id, sha256, storage_path, media_type
                 FROM media_asset WHERE id=?1",
                [media_id],
                |row| {
                    let kind: String = row.get(3)?;
                    Ok(MediaStorageEntry {
                        id: row.get(0)?,
                        sha256: row.get(1)?,
                        storage_path: row.get(2)?,
                        kind: if kind == "video" {
                            MediaKind::Video
                        } else {
                            MediaKind::Image
                        },
                    })
                },
            )
            .map_err(Into::into)
    }

    pub fn media_asset(&self, media_id: i64) -> CoreResult<MediaAsset> {
        self.load_all_media()?
            .into_iter()
            .find(|media| media.id == media_id)
            .ok_or_else(|| {
                crate::error::CoreError::InvalidConfig("media item does not exist".into())
            })
    }

    pub fn replace_media_content(
        &self,
        media_id: i64,
        expected_sha256: &str,
        sha256: &str,
        size: u64,
        storage_path: &Path,
        generated_tag: &str,
    ) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let (stored_sha256, media_type): (String, String) = transaction
            .query_row(
                "SELECT sha256, media_type FROM media_asset WHERE id=?1 AND status='ready'",
                [media_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?
            .ok_or_else(|| {
                crate::error::CoreError::InvalidConfig("media item does not exist".into())
            })?;
        if stored_sha256 != expected_sha256 {
            return Err(crate::error::CoreError::InvalidConfig(
                "media changed while the video editor was open".into(),
            ));
        }
        if media_type != "video" {
            return Err(crate::error::CoreError::InvalidConfig(
                "only videos can be overwritten by the video editor".into(),
            ));
        }
        let collision: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM media_asset WHERE sha256=?1 AND id<>?2)",
            params![sha256, media_id],
            |row| row.get(0),
        )?;
        if collision {
            return Err(crate::error::CoreError::InvalidConfig(
                "the edited video is identical to another item in the library".into(),
            ));
        }
        transaction.execute(
            "UPDATE media_asset SET sha256=?2, size=?3, storage_path=?4 WHERE id=?1",
            params![
                media_id,
                sha256,
                size as i64,
                storage_path.to_string_lossy()
            ],
        )?;
        add_tag_in_transaction(&transaction, media_id, generated_tag)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn copy_media_metadata(
        &self,
        source_ids: &[i64],
        target_id: i64,
        generated_tag: &str,
    ) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let target_exists: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM media_asset WHERE id=?1)",
            [target_id],
            |row| row.get(0),
        )?;
        if !target_exists {
            return Err(crate::error::CoreError::InvalidConfig(
                "target media item does not exist".into(),
            ));
        }

        let mut favorite = false;
        let mut note = None;
        for source_id in source_ids {
            let source_favorite: Option<bool> = transaction
                .query_row(
                    "SELECT favorite<>0 FROM media_asset WHERE id=?1",
                    [source_id],
                    |row| row.get(0),
                )
                .optional()?;
            let Some(source_favorite) = source_favorite else {
                continue;
            };
            favorite |= source_favorite;
            if note.is_none() {
                note = transaction
                    .query_row(
                        "SELECT text FROM note WHERE media_id=?1 AND trim(text)<>''",
                        [source_id],
                        |row| row.get::<_, String>(0),
                    )
                    .optional()?;
            }
            transaction.execute(
                "INSERT OR IGNORE INTO media_tag(media_id, tag_id)
                 SELECT ?2, tag_id FROM media_tag WHERE media_id=?1",
                params![source_id, target_id],
            )?;
            transaction.execute(
                "INSERT OR IGNORE INTO album_media(album_id, media_id)
                 SELECT am.album_id, ?2 FROM album_media am
                 JOIN album a ON a.id=am.album_id
                 WHERE am.media_id=?1 AND a.album_type='manual'",
                params![source_id, target_id],
            )?;
        }
        transaction.execute(
            "UPDATE media_asset SET favorite=?2 WHERE id=?1",
            params![target_id, favorite],
        )?;
        if let Some(note) = note {
            transaction.execute(
                "INSERT INTO note(media_id, text, updated_at) VALUES (?1, ?2, ?3)
                 ON CONFLICT(media_id) DO UPDATE SET text=excluded.text, updated_at=excluded.updated_at",
                params![target_id, note, Utc::now().to_rfc3339()],
            )?;
        }
        add_tag_in_transaction(&transaction, target_id, generated_tag)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn list_media_storage_entries(&self) -> CoreResult<Vec<MediaStorageEntry>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection.prepare(
            "SELECT id, sha256, storage_path, media_type
             FROM media_asset WHERE status='ready' ORDER BY id",
        )?;
        let entries = statement
            .query_map([], |row| {
                let kind: String = row.get(3)?;
                Ok(MediaStorageEntry {
                    id: row.get(0)?,
                    sha256: row.get(1)?,
                    storage_path: row.get(2)?,
                    kind: if kind == "video" {
                        MediaKind::Video
                    } else {
                        MediaKind::Image
                    },
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(entries)
    }

    pub fn media_export_entries(&self, media_ids: &[i64]) -> CoreResult<Vec<MediaExportEntry>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut entries = Vec::with_capacity(media_ids.len());
        for media_id in media_ids {
            let entry = connection
                .query_row(
                    "SELECT ma.id, ma.original_name, ma.storage_path, ma.game_name,
                            ma.captured_at, NULLIF(ma.imported_at, ''),
                            COALESCE(n.text, ''),
                            COALESCE((
                              SELECT group_concat(name, char(31)) FROM (
                                SELECT t.name AS name
                                FROM media_tag mt
                                JOIN tag t ON t.id=mt.tag_id
                                WHERE mt.media_id=ma.id
                                ORDER BY t.name COLLATE NOCASE
                              )
                            ), '')
                     FROM media_asset ma
                     LEFT JOIN note n ON n.media_id=ma.id
                     WHERE ma.id=?1 AND ma.status='ready'",
                    [media_id],
                    |row| {
                        Ok((
                            row.get::<_, i64>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, String>(3)?,
                            row.get::<_, Option<String>>(4)?,
                            row.get::<_, Option<String>>(5)?,
                            row.get::<_, String>(6)?,
                            row.get::<_, String>(7)?,
                        ))
                    },
                )
                .optional()?;
            let Some((id, original_name, storage_path, game_name, captured, imported, note, tags)) =
                entry
            else {
                continue;
            };
            let captured = parse_datetime(captured.as_deref())?;
            let imported = parse_imported_at(imported.as_deref())?;
            let timestamp = captured.or(imported);
            entries.push(MediaExportEntry {
                id,
                original_name,
                storage_path,
                game_name,
                timestamp,
                tags: tags
                    .split('\u{1f}')
                    .filter(|value| !value.is_empty())
                    .map(ToOwned::to_owned)
                    .collect(),
                note,
            });
        }
        Ok(entries)
    }

    pub fn delete_media_record(&self, media_id: i64) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let entry = self.media_storage_entry(media_id)?;
        self.check_managed_path_owner(Path::new(&entry.storage_path), &entry.sha256, 1)?;
        let changed = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .execute("DELETE FROM media_asset WHERE id=?1", [media_id])?;
        if changed == 0 {
            return Err(crate::error::CoreError::InvalidConfig(
                "media item does not exist".into(),
            ));
        }
        Ok(())
    }

    pub fn relocate_media_paths_and_settings(
        &self,
        paths: &[(i64, String)],
        settings: &AppSettings,
    ) -> CoreResult<()> {
        let lease = self.device_sync_exclusive()?;
        self.relocate_media_paths_and_settings_exclusive(&lease, paths, settings)
    }

    pub(crate) fn relocate_media_paths_and_settings_exclusive(
        &self,
        lease: &ExclusiveLease,
        paths: &[(i64, String)],
        settings: &AppSettings,
    ) -> CoreResult<()> {
        lease.validate(&self.gate)?;
        self.assert_relocation_allowed()?;
        self.ensure_original_root(Path::new(&settings.library_path))?;
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        for (media_id, path) in paths {
            transaction.execute(
                "UPDATE media_asset SET storage_path=?2 WHERE id=?1",
                params![media_id, path],
            )?;
        }
        transaction.execute(
            "INSERT INTO app_setting(key, value_json, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=excluded.updated_at",
            params![
                "app.settings",
                serde_json::to_string(settings)?,
                Utc::now().to_rfc3339()
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn list_media(&self, query: &GalleryQuery) -> CoreResult<Vec<MediaAsset>> {
        let mut media = self.load_all_media()?;
        media.retain(|asset| match query.kind {
            GalleryKindFilter::All => true,
            GalleryKindFilter::Image => asset.kind == MediaKind::Image,
            GalleryKindFilter::Video => asset.kind == MediaKind::Video,
        });
        if query.favorite_only {
            media.retain(|asset| asset.favorite);
        }
        if !query.game_names.is_empty() {
            media.retain(|asset| query.game_names.contains(&asset.game_name));
        }
        if query.captured_from.is_some() || query.captured_until.is_some() {
            media.retain(|asset| {
                asset
                    .captured_at
                    .or(asset.imported_at)
                    .is_some_and(|timestamp| {
                        query.captured_from.is_none_or(|from| timestamp >= from)
                            && query.captured_until.is_none_or(|until| timestamp < until)
                    })
            });
        }
        if let Some(album_id) = query.album_id {
            let (album_type, system_key, rules, manual_ids) = self.album_filter(album_id)?;
            if system_key.as_deref() == Some("favorites") {
                media.retain(|asset| asset.favorite);
            } else if album_type == "smart" {
                media.retain(|asset| matches_album_rules(asset, &rules));
            } else {
                media.retain(|asset| manual_ids.contains(&asset.id));
            }
        }
        if !query.newest_first {
            media.reverse();
        }
        let start = query.offset as usize;
        let end = start
            .saturating_add(query.limit.clamp(1, 500) as usize)
            .min(media.len());
        if start >= media.len() {
            return Ok(Vec::new());
        }
        Ok(media[start..end].to_vec())
    }

    fn load_all_media(&self) -> CoreResult<Vec<MediaAsset>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection.prepare(
            "SELECT m.id, m.sha256, m.original_name, m.storage_path, m.media_type,
                    m.captured_at, m.imported_at, m.game_title_id, m.game_name,
                    m.favorite, n.text
             FROM media_asset m LEFT JOIN note n ON n.media_id=m.id
             WHERE m.status='ready'
             ORDER BY COALESCE(m.captured_at, NULLIF(m.imported_at, '')) DESC, m.id DESC",
        )?;
        let base_rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, String>(8)?,
                row.get::<_, i64>(9)? != 0,
                row.get::<_, Option<String>>(10)?,
            ))
        })?;
        let mut media = Vec::new();
        for row in base_rows {
            let (
                id,
                sha256,
                original_name,
                storage_path,
                kind,
                captured,
                imported,
                title_id,
                game_name,
                favorite,
                note,
            ) = row?;
            let mut tag_statement = connection.prepare(
                "SELECT t.name FROM tag t JOIN media_tag mt ON mt.tag_id=t.id
                 WHERE mt.media_id=?1 ORDER BY t.name COLLATE NOCASE",
            )?;
            let tags = tag_statement
                .query_map([id], |row| row.get(0))?
                .collect::<Result<Vec<String>, _>>()?;
            media.push(MediaAsset {
                id,
                sha256,
                original_name,
                storage_path,
                kind: if kind == "video" {
                    MediaKind::Video
                } else {
                    MediaKind::Image
                },
                captured_at: parse_datetime(captured.as_deref())?,
                imported_at: parse_imported_at(Some(&imported))?,
                game_title_id: title_id,
                game_name,
                favorite,
                note,
                tags,
            });
        }
        Ok(media)
    }

    fn album_filter(&self, album_id: i64) -> CoreResult<AlbumFilter> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let (album_type, system_key) = connection.query_row(
            "SELECT album_type, system_key FROM album WHERE id=?1",
            [album_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let mut rule_statement = connection.prepare(
            "SELECT rule_group, field, operator, value FROM album_rule
             WHERE album_id=?1 ORDER BY rule_group, id",
        )?;
        let rules = rule_statement
            .query_map([album_id], |row| {
                Ok(AlbumRule {
                    rule_group: row.get(0)?,
                    field: row.get(1)?,
                    operator: row.get(2)?,
                    value: row.get(3)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut media_statement =
            connection.prepare("SELECT media_id FROM album_media WHERE album_id=?1")?;
        let manual_ids = media_statement
            .query_map([album_id], |row| row.get(0))?
            .collect::<Result<std::collections::HashSet<i64>, _>>()?;
        Ok((album_type, system_key, rules, manual_ids))
    }

    pub fn set_setting<T: Serialize>(&self, key: &str, value: &T) -> CoreResult<()> {
        let mut writing = Some(self.write_lease()?);
        let value = serde_json::to_value(value)?;
        let root_change = if key == "app.settings" {
            let previous = self.get_setting::<serde_json::Value>(key)?;
            let previous = previous
                .as_ref()
                .and_then(|v| v.get("library_path"))
                .and_then(|v| v.as_str())
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| self.default_media_root.clone());
            let next = value
                .get("library_path")
                .and_then(|v| v.as_str())
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| self.default_media_root.clone());
            crate::device_sync::library_guard::path_key(
                &previous.canonicalize().unwrap_or(previous),
            ) != crate::device_sync::library_guard::path_key(&next.canonicalize().unwrap_or(next))
        } else {
            false
        };
        let _exclusive = if root_change {
            let lease = writing
                .take()
                .expect("configuration writer exists")
                .try_exclusive()?;
            self.assert_relocation_allowed()?;
            Some(lease)
        } else {
            None
        };
        if key == "app.settings" {
            let next = value
                .get("library_path")
                .and_then(|v| v.as_str())
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| self.default_media_root.clone());
            self.ensure_original_root(&next)?;
        }
        self.connection.lock().expect("database mutex poisoned").execute(
            "INSERT INTO app_setting(key, value_json, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=excluded.updated_at",
            params![key, serde_json::to_string(&value)?, Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    pub fn get_setting<T: DeserializeOwned>(&self, key: &str) -> CoreResult<Option<T>> {
        let json: Option<String> = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT value_json FROM app_setting WHERE key = ?1",
                [key],
                |row| row.get(0),
            )
            .optional()?;
        json.map(|value| serde_json::from_str(&value).map_err(Into::into))
            .transpose()
    }
}

const MAX_RECEIVER_BACKUP_BYTES: usize = 128 * 1024 * 1024;

#[cfg(test)]
mod receiver_metadata_cost_tests {
    use super::*;
    use crate::device_sync::{
        planner::{build_plan, SyncMode},
        receiver::Snapshot,
        work::WorkControl,
    };

    // A changed backup shape, estimated DB size, or a hidden write breaks this.
    #[test]
    fn measured_backup_matches_real_bounded_payload_and_preserves_database() {
        let root = tempfile::tempdir().unwrap();
        let api = crate::api::CoreApi::open(root.path()).unwrap();
        let db = api.database();
        db.create_tag("quoted \" metadata").unwrap();
        let snapshot = Snapshot::read(&db, "Target").unwrap();
        let plan = build_plan(&snapshot.manifest, &snapshot.manifest, SyncMode::Merge).unwrap();
        let work = WorkControl::default();
        let before = snapshot.digest().unwrap();
        let changes_before = db.connection.lock().unwrap().total_changes();
        let expected = {
            let connection = db.connection.lock().unwrap();
            bounded_backup_json(&ReceiverBackup {
                version: 1,
                snapshot: snapshot.clone(),
                tables: capture_receiver_tables(&connection, &work.cancellation()).unwrap(),
            })
            .unwrap()
        };
        let cost = db
            .device_sync_metadata_cost(&snapshot, &plan, &work)
            .unwrap();
        let logical_bytes: u64 = db
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(cost.database_bytes, logical_bytes);
        assert_eq!(cost.backup_bytes, expected.len() as u64);
        assert_eq!(
            cost.plan_bytes,
            serde_json::to_vec(&plan).unwrap().len() as u64
        );
        assert!(cost.database_bytes > 0 && cost.database_bytes.is_multiple_of(4096));
        assert_eq!(
            cost.database_parent,
            root.path().join("database").canonicalize().unwrap()
        );
        assert_eq!(
            Snapshot::read_with_header(&db, snapshot.manifest.header.clone(), Some("Target"))
                .unwrap()
                .digest()
                .unwrap(),
            before
        );
        assert!(db.device_sync_backup_reference_owners().unwrap().is_empty());
        assert!(!db.device_sync_recovery_pending());
        assert_eq!(
            db.connection.lock().unwrap().total_changes(),
            changes_before
        );
        let after = {
            let connection = db.connection.lock().unwrap();
            bounded_backup_json(&ReceiverBackup {
                version: 1,
                snapshot,
                tables: capture_receiver_tables(&connection, &work.cancellation()).unwrap(),
            })
            .unwrap()
        };
        assert_eq!(after, expected);
    }

    #[test]
    fn cancelled_metadata_measurement_does_not_create_backup() {
        let root = tempfile::tempdir().unwrap();
        let api = crate::api::CoreApi::open(root.path()).unwrap();
        let db = api.database();
        let snapshot = Snapshot::read(&db, "Target").unwrap();
        let plan = build_plan(&snapshot.manifest, &snapshot.manifest, SyncMode::Merge).unwrap();
        let cancel = crate::sync::CancellationToken::default();
        cancel.cancel();
        assert!(matches!(
            db.device_sync_metadata_cost(&snapshot, &plan, &WorkControl::new(cancel)),
            Err(CoreError::Cancelled)
        ));
        assert!(!db.device_sync_recovery_pending());
    }

    #[test]
    fn counting_serialization_honors_cancellation_between_actual_json_writes() {
        struct CancelBetweenFields(crate::sync::CancellationToken);
        impl serde::Serialize for CancelBetweenFields {
            fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                use serde::ser::SerializeTuple;
                let mut fields = serializer.serialize_tuple(2)?;
                fields.serialize_element("actual first field")?;
                self.0.cancel();
                fields.serialize_element("must not complete")?;
                fields.end()
            }
        }
        let cancel = crate::sync::CancellationToken::default();
        assert!(matches!(
            bounded_json_count(
                &CancelBetweenFields(cancel.clone()),
                &crate::device_sync::work::WorkControl::new(cancel)
            ),
            Err(CoreError::Cancelled)
        ));
    }
}
const MAX_RECEIVER_BACKUP_ROWS: usize = 2_000_000;
const MAX_LOCAL_CELL_BYTES: usize = 1024 * 1024;

// This allowlist is intentionally separate from the path-free network snapshot.
// In particular, settings, jobs, cursors and credentials never enter the payload.
const RECEIVER_TABLES: &[(&str, &str)] = &[
    ("media_asset", "id,sha256,size,mime,media_type,width,height,duration_ms,captured_at,uploaded_at,imported_at,game_title_id,source_game_name,game_name,original_name,storage_path,favorite,status,info_revision"),
    ("tag", "id,name,normalized_name,created_at"),
    ("media_source", "id,media_id,source_type,source_path,remote_id,provider,discovered_at"),
    ("note", "media_id,text,updated_at"),
    ("media_tag", "media_id,tag_id"),
    ("album", "id,name,album_type,pinned,system_key,created_at,updated_at,description,sync_uuid,source_library_uuid,info_revision"),
    ("album_rule", "id,album_id,rule_group,field,operator,value,created_at"),
    ("album_media", "album_id,media_id"),
    ("game_tag_alias", "source_name,target_name,is_intermediate"),
    ("sync_tag_state", "normalized_name,name,revision,deleted"),
    ("sync_mapping", "kind,source_name,target_name,revision,deleted"),
    ("device_sync_source_name", "library_uuid,display_name"),
];

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(untagged)]
enum LocalCell {
    Null,
    Integer(i64),
    Text(String),
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct LocalTable {
    name: String,
    rows: Vec<Vec<LocalCell>>,
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct ReceiverBackup {
    version: u32,
    snapshot: crate::device_sync::receiver::Snapshot,
    tables: Vec<LocalTable>,
}

fn migrate_receiver(transaction: &rusqlite::Transaction<'_>) -> CoreResult<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS device_sync_source_name(
           library_uuid TEXT PRIMARY KEY,display_name TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS device_sync_backup(
           backup_uuid TEXT PRIMARY KEY REFERENCES device_sync_original_owner(owner_uuid) ON DELETE RESTRICT,
           version INTEGER NOT NULL,library_uuid TEXT NOT NULL,payload BLOB NOT NULL,digest TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS device_sync_apply_journal(
           operation_uuid TEXT PRIMARY KEY,version INTEGER NOT NULL,
           library_uuid TEXT NOT NULL,stage TEXT NOT NULL,
           backup_uuid TEXT NOT NULL REFERENCES device_sync_backup(backup_uuid) ON DELETE RESTRICT,
           preview_digest TEXT NOT NULL,external_reference TEXT);
         CREATE UNIQUE INDEX IF NOT EXISTS idx_device_sync_single_pending
           ON device_sync_apply_journal((1)) WHERE stage NOT IN ('finalized','rolled_back');",
    )?;
    ensure_backup_created_at(transaction)?;
    ensure_backup_ownership(transaction)?;
    for event in ["INSERT", "UPDATE", "DELETE"] {
        let when = if event == "UPDATE" {
            "WHEN OLD.display_name IS NOT NEW.display_name"
        } else {
            ""
        };
        transaction.execute_batch(&format!(
            "CREATE TRIGGER IF NOT EXISTS ds_source_name_{event} AFTER {event}
             ON device_sync_source_name {when} BEGIN
               UPDATE library_sync SET generation=CASE WHEN generation=9223372036854775807
                 THEN RAISE(ABORT,'device sync generation overflow') ELSE generation+1 END WHERE id=1;
             END;"
        ))?;
    }
    Ok(())
}

fn backup_has_created_at(connection: &Connection) -> CoreResult<bool> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM pragma_table_info('device_sync_backup') WHERE name='created_at')",
        [], |row| row.get(0),
    )?)
}

fn backup_metadata_sql(saved: &str, ownership: bool, exact: bool) -> String {
    let ownership_columns = if ownership {
        "o.version,o.kind,o.operation_uuid,o.external_reference,o.source_backup_uuid"
    } else {
        "NULL,NULL,NULL,NULL,NULL"
    };
    let ownership_join = if ownership {
        "LEFT JOIN device_sync_backup_ownership o ON o.backup_uuid=b.backup_uuid"
    } else {
        ""
    };
    let lineage = if ownership {
        "(SELECT library_uuid FROM device_sync_backup x WHERE x.backup_uuid=o.source_backup_uuid)"
    } else {
        "NULL"
    };
    let predicate = if exact {
        "b.backup_uuid=?2"
    } else {
        "b.rowid>=?1"
    };
    format!(
        "SELECT b.rowid,b.backup_uuid,b.library_uuid,{saved},n.display_name,b.version,
                j.library_uuid,j.version,j.stage,j.external_reference,
                (SELECT count(*) FROM device_sync_apply_journal x WHERE x.backup_uuid=b.backup_uuid),
                j.operation_uuid,j.preview_digest,{ownership_columns},
                b.digest,length(b.payload),typeof(b.payload),
                CASE WHEN length(b.payload)<=4096 THEN b.payload ELSE NULL END,{lineage}
         FROM device_sync_backup b
         LEFT JOIN device_sync_source_name n ON n.library_uuid=b.library_uuid
         LEFT JOIN device_sync_apply_journal j ON j.rowid=(
           SELECT x.rowid FROM device_sync_apply_journal x WHERE x.backup_uuid=b.backup_uuid LIMIT 1)
         {ownership_join}
         WHERE {predicate}
         ORDER BY b.rowid LIMIT ?3"
    )
}

fn backup_has_ownership(connection: &Connection) -> CoreResult<bool> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='device_sync_backup_ownership')",
        [], |row| row.get(0),
    )?)
}

fn ensure_backup_ownership(connection: &Connection) -> CoreResult<()> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS device_sync_backup_ownership(
           backup_uuid TEXT PRIMARY KEY REFERENCES device_sync_backup(backup_uuid) ON DELETE RESTRICT,
           version INTEGER NOT NULL,kind TEXT NOT NULL,operation_uuid TEXT NOT NULL,
           external_reference TEXT,source_backup_uuid TEXT
             REFERENCES device_sync_backup(backup_uuid) ON DELETE RESTRICT);",
    )?;
    Ok(())
}

fn insert_backup_ownership(
    connection: &Connection,
    backup: uuid::Uuid,
    kind: &str,
    operation: uuid::Uuid,
    external: Option<uuid::Uuid>,
    source: Option<uuid::Uuid>,
) -> CoreResult<()> {
    // Legacy pending opens are read-only. This DDL belongs to the same
    // authorized save transaction as the backup and rolls back with it.
    ensure_backup_ownership(connection)?;
    connection.execute(
        "INSERT INTO device_sync_backup_ownership
         (backup_uuid,version,kind,operation_uuid,external_reference,source_backup_uuid)
         VALUES(?1,1,?2,?3,?4,?5)",
        params![
            backup.to_string(),
            kind,
            operation.to_string(),
            external.map(|id| id.to_string()),
            source.map(|id| id.to_string())
        ],
    )?;
    Ok(())
}

fn ensure_backup_created_at(connection: &Connection) -> CoreResult<()> {
    if !backup_has_created_at(connection)? {
        connection.execute_batch("ALTER TABLE device_sync_backup ADD COLUMN created_at TEXT")?;
    }
    Ok(())
}

fn capture_receiver_tables(
    connection: &Connection,
    cancel: &crate::sync::CancellationToken,
) -> CoreResult<Vec<LocalTable>> {
    let mut tables = Vec::new();
    let mut bytes = 0usize;
    let mut count = 0usize;
    for &(name, columns) in RECEIVER_TABLES {
        let mut statement =
            connection.prepare(&format!("SELECT {columns} FROM {name} ORDER BY rowid"))?;
        let columns = statement.column_count();
        let mut query = statement.query([])?;
        let mut rows = Vec::new();
        while let Some(row) = query.next()? {
            cancel.check()?;
            count = count
                .checked_add(1)
                .ok_or_else(|| ds::invalid("backup row overflow"))?;
            if count > MAX_RECEIVER_BACKUP_ROWS {
                return Err(ds::invalid("backup row limit exceeded"));
            }
            let mut cells = Vec::with_capacity(columns);
            for column in 0..columns {
                let value = row.get_ref(column)?;
                let size = match value {
                    rusqlite::types::ValueRef::Null => 4,
                    rusqlite::types::ValueRef::Integer(_) => 24,
                    rusqlite::types::ValueRef::Text(value) => value.len(),
                    _ => return Err(ds::invalid("unsupported local backup cell")),
                };
                bytes = bytes
                    .checked_add(size + 8)
                    .ok_or_else(|| ds::invalid("backup byte overflow"))?;
                if size > MAX_LOCAL_CELL_BYTES || bytes > MAX_RECEIVER_BACKUP_BYTES {
                    return Err(ds::invalid("local backup read limit exceeded"));
                }
                cells.push(match value {
                    rusqlite::types::ValueRef::Null => LocalCell::Null,
                    rusqlite::types::ValueRef::Integer(value) => LocalCell::Integer(value),
                    rusqlite::types::ValueRef::Text(value) => LocalCell::Text(
                        std::str::from_utf8(value)
                            .map_err(|_| ds::invalid("invalid local backup text"))?
                            .into(),
                    ),
                    _ => unreachable!(),
                });
            }
            rows.push(cells);
        }
        tables.push(LocalTable {
            name: name.into(),
            rows,
        });
    }
    Ok(tables)
}

fn bounded_json_count(
    value: &impl serde::Serialize,
    work: &crate::device_sync::work::WorkControl,
) -> CoreResult<u64> {
    struct Counter<'a> {
        bytes: u64,
        work: &'a crate::device_sync::work::WorkControl,
    }
    impl std::io::Write for Counter<'_> {
        fn write(&mut self, value: &[u8]) -> std::io::Result<usize> {
            self.work.check().map_err(std::io::Error::other)?;
            self.bytes = self
                .bytes
                .checked_add(value.len() as u64)
                .filter(|n| *n <= MAX_RECEIVER_BACKUP_BYTES as u64)
                .ok_or_else(|| std::io::Error::other("backup byte budget exceeded"))?;
            Ok(value.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut output = Counter { bytes: 0, work };
    let result = serde_json::to_writer(&mut output, value);
    work.check()?;
    result?;
    Ok(output.bytes)
}

fn bounded_backup_json(value: &ReceiverBackup) -> CoreResult<Vec<u8>> {
    struct Bounded(Vec<u8>);
    impl std::io::Write for Bounded {
        fn write(&mut self, value: &[u8]) -> std::io::Result<usize> {
            if self
                .0
                .len()
                .checked_add(value.len())
                .is_none_or(|n| n > MAX_RECEIVER_BACKUP_BYTES)
            {
                return Err(std::io::Error::other("backup byte budget exceeded"));
            }
            self.0.extend_from_slice(value);
            Ok(value.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut output = Bounded(Vec::new());
    serde_json::to_writer(&mut output, value)?;
    Ok(output.0)
}

fn insert_receiver_backup(
    transaction: &rusqlite::Transaction<'_>,
    backup: uuid::Uuid,
    root: &Path,
    originals: &[OriginalIdentity],
    payload: &[u8],
    library_uuid: &str,
) -> CoreResult<()> {
    use sha2::{Digest, Sha256};
    // A legacy pending library intentionally skips normal migration on open.
    // Only its actual authorized save transaction may add this nullable column.
    ensure_backup_created_at(transaction)?;
    ensure_backup_ownership(transaction)?;
    transaction.execute(
        "INSERT INTO device_sync_original_owner(owner_uuid,root_path) VALUES(?1,?2)",
        params![
            backup.to_string(),
            crate::device_sync::library_guard::path_key(root).to_string_lossy()
        ],
    )?;
    for identity in originals {
        transaction.execute(
            "INSERT INTO device_sync_original_ref(owner_uuid,file_path,sha256,length) VALUES(?1,?2,?3,?4)",
            params![backup.to_string(), crate::device_sync::library_guard::path_key(&identity.relative).to_string_lossy(),
                identity.sha256, identity.length],
        )?;
    }
    transaction.execute(
        "INSERT INTO device_sync_backup(backup_uuid,version,library_uuid,payload,digest,created_at) VALUES(?1,1,?2,?3,?4,?5)",
        params![backup.to_string(), library_uuid, payload, hex::encode(Sha256::digest(payload)),
            Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)],
    )?;
    Ok(())
}

impl Database {
    pub fn device_sync_source_names(
        &self,
    ) -> CoreResult<Vec<crate::device_sync::source_names::SourceDescription>> {
        self.device_sync_source_names_controlled(&crate::device_sync::work::WorkControl::default())
    }
    pub fn device_sync_source_names_controlled(
        &self,
        work: &crate::device_sync::work::WorkControl,
    ) -> CoreResult<Vec<crate::device_sync::source_names::SourceDescription>> {
        work.check()?;
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let interrupt = ScanSqlInterrupt::new(&mut connection, work.cancellation());
        let result = (|| {
            let mut statement = interrupt.connection.prepare(
                "SELECT library_uuid,display_name FROM device_sync_source_name
             WHERE library_uuid=(SELECT library_uuid FROM library_sync WHERE id=1)
                OR library_uuid IN(SELECT source_library_uuid FROM album)
             ORDER BY library_uuid LIMIT 1025",
            )?;
            let mut query = statement.query([])?;
            let mut names = Vec::new();
            while let Some(row) = query.next()? {
                work.check()?;
                if names.len() == crate::device_sync::source_names::MAX_SOURCES {
                    return Err(ds::invalid("local source description count limit exceeded"));
                }
                let uuid = row
                    .get_ref(0)?
                    .as_str()
                    .map_err(|_| ds::invalid("invalid source UUID text"))?;
                let name = row
                    .get_ref(1)?
                    .as_str()
                    .map_err(|_| ds::invalid("invalid source name text"))?;
                if uuid.len() != 36 || name.len() > 512 {
                    return Err(ds::invalid("invalid local source description size"));
                }
                names.push(crate::device_sync::source_names::SourceDescription::new(
                    uuid.into(),
                    name.into(),
                )?);
            }
            Ok(names)
        })();
        work.check()?;
        result
    }

    pub fn device_sync_source_name(
        &self,
        library_uuid: &str,
    ) -> CoreResult<Option<crate::device_sync::source_names::SourceDescription>> {
        ds::validate_uuid(library_uuid)?;
        let connection = self.connection.lock().expect("database mutex poisoned");
        let name = connection
            .query_row(
                "SELECT display_name FROM device_sync_source_name WHERE library_uuid=?1",
                [library_uuid],
                |row| {
                    let name = row.get_ref(0)?.as_str().map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(error),
                        )
                    })?;
                    if name.len() > 512 {
                        return Err(rusqlite::Error::InvalidQuery);
                    }
                    Ok(name.to_owned())
                },
            )
            .optional()?;
        name.map(|display_name| {
            crate::device_sync::source_names::SourceDescription::new(
                library_uuid.into(),
                display_name,
            )
        })
        .transpose()
    }

    pub fn device_sync_register_local_name(&self, display_name: &str) -> CoreResult<()> {
        let _writing = self.write_lease()?;
        let value = crate::device_sync::source_names::SourceDescription::new(
            self.device_sync_header()?.library_uuid,
            display_name.into(),
        )?;
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "INSERT INTO device_sync_source_name(library_uuid,display_name) VALUES(?1,?2)
             ON CONFLICT(library_uuid) DO UPDATE SET display_name=excluded.display_name
               WHERE display_name IS NOT excluded.display_name",
                params![value.library_uuid, value.display_name],
            )?;
        Ok(())
    }

    pub(crate) fn receiver_prepare(
        &self,
        lease: &ExclusiveLease,
        operation: uuid::Uuid,
        preview_digest: &str,
        snapshot: &crate::device_sync::receiver::Snapshot,
        external: Option<uuid::Uuid>,
        cancel: &crate::sync::CancellationToken,
    ) -> CoreResult<uuid::Uuid> {
        lease.validate(&self.gate)?;
        if self.gate.pending() {
            return Err(crate::error::CoreError::LibraryBusy);
        }
        snapshot.validate()?;
        ds::validate_uuid(&operation.to_string())?;
        if let Some(reference) = external {
            ds::validate_uuid(&reference.to_string())?;
        }
        ds::validate_sha(preview_digest)?;
        cancel.check()?;
        let (_, root) = self.device_sync_file_roots()?;
        let originals = self.controlled_originals_cancellable(&root, Some(cancel))?;
        cancel.check()?;
        let root = root.canonicalize()?;
        let backup = uuid::Uuid::new_v4();
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        connection.execute_batch("PRAGMA synchronous=FULL;")?;
        let transaction = connection.transaction()?;
        let payload = bounded_backup_json(&ReceiverBackup {
            version: 1,
            snapshot: snapshot.clone(),
            tables: capture_receiver_tables(&transaction, cancel)?,
        })?;
        // Conservative metadata headroom, not a reservation or filesystem guarantee.
        let required = (payload.len() as u64)
            .checked_mul(2)
            .and_then(|n| n.checked_add(1024 * 1024))
            .ok_or_else(|| ds::invalid("backup space overflow"))?;
        if fs2::available_space(&self.default_media_root)? < required {
            return Err(ds::invalid("insufficient metadata backup space"));
        }
        cancel.check()?;
        insert_receiver_backup(
            &transaction,
            backup,
            &root,
            &originals,
            &payload,
            &snapshot.manifest.header.library_uuid,
        )?;
        insert_backup_ownership(&transaction, backup, "overwrite", operation, external, None)?;
        transaction.execute(
            "INSERT INTO device_sync_apply_journal(operation_uuid,version,library_uuid,stage,backup_uuid,preview_digest,external_reference)
             VALUES(?1,1,?2,'prepare',?3,?4,?5)",
            params![operation.to_string(), snapshot.manifest.header.library_uuid, backup.to_string(),
                preview_digest, external.map(|id| id.to_string())],
        )?;
        cancel.check()?;
        transaction.commit()?;
        self.gate.publish_pending(true);
        Ok(backup)
    }

    pub(crate) fn receiver_finish_prepared(
        &self,
        lease: &ExclusiveLease,
        operation: uuid::Uuid,
    ) -> CoreResult<()> {
        lease.validate(&self.gate)?;
        let changed = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "UPDATE device_sync_apply_journal SET stage='rolled_back'
             WHERE operation_uuid=?1 AND stage='prepare'",
                [operation.to_string()],
            )?;
        if changed != 1 {
            return Err(ds::invalid("operation is not prepared"));
        }
        self.gate.publish_pending(false);
        Ok(())
    }

    pub(crate) fn receiver_finalize(
        &self,
        lease: &ExclusiveLease,
        operation: uuid::Uuid,
    ) -> CoreResult<()> {
        lease.validate(&self.gate)?;
        let changed = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "UPDATE device_sync_apply_journal SET stage='finalized'
             WHERE operation_uuid=?1 AND stage='library_applied' AND external_reference IS NULL",
                [operation.to_string()],
            )?;
        if changed != 1 {
            return Err(ds::invalid(
                "operation cannot finalize without external coordination",
            ));
        }
        self.gate.publish_pending(false);
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn receiver_apply(
        &self,
        lease: &ExclusiveLease,
        operation: uuid::Uuid,
        plan: &crate::device_sync::planner::SyncPlan,
        source: &crate::device_sync::receiver::Snapshot,
        target: &crate::device_sync::receiver::Snapshot,
        publications: &[crate::device_sync::staging::PublishedOriginal<'_>],
        cancel: &crate::sync::CancellationToken,
        guard: Option<std::sync::Arc<dyn crate::device_sync::receiver::CommitGuard>>,
    ) -> CoreResult<()> {
        use crate::device_sync::planner::Action;
        lease.validate(&self.gate)?;
        plan.verify_against(&source.manifest, &target.manifest)?;
        source.validate()?;
        target.validate()?;
        let live_tags: std::collections::BTreeSet<_> = plan
            .tags
            .iter()
            .filter(|tag| !tag.deleted)
            .map(|tag| ds::normalized(&tag.name))
            .collect();
        for record in plan
            .media
            .iter()
            .filter_map(|decision| decision.final_record.as_ref())
        {
            if record
                .tags
                .iter()
                .any(|tag| !live_tags.contains(&ds::normalized(tag)))
            {
                return Err(ds::invalid(
                    "final media tag is not a live catalog identity",
                ));
            }
        }
        let (_, root) = self.device_sync_file_roots()?;
        let mut paths = std::collections::BTreeMap::new();
        for published in publications {
            let identity = published.identity();
            let checked = OriginalIdentity::controlled(
                &root,
                &identity.path(),
                identity.sha256(),
                identity.length(),
            )?;
            if checked != *identity
                || paths
                    .insert(identity.sha256().to_owned(), identity.path())
                    .is_some()
            {
                return Err(ds::invalid("invalid or duplicate published original"));
            }
        }
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let interrupt_cancel = cancel.clone();
        let interrupt_guard = guard.clone();
        if let Some(guard) = &guard {
            guard.sql_started();
            guard.check()?;
        }
        let sql_started = std::time::Instant::now();
        connection.progress_handler(
            2048,
            Some(move || {
                if let Some(guard) = &interrupt_guard {
                    guard.sql_progress();
                }
                interrupt_cancel.check().is_err()
                    || sql_started.elapsed() >= std::time::Duration::from_secs(300)
                    || interrupt_guard.as_ref().is_some_and(|g| g.check().is_err())
            }),
        );
        let sql_progress = ReceiverSqlProgress {
            connection: &mut connection,
        };
        let result = (|| -> CoreResult<()> {
            let transaction = sql_progress.connection.transaction()?;
            let current = device_sync_header(&transaction)?;
            if current.library_uuid != target.manifest.header.library_uuid
                || current.generation != plan.target_generation
            {
                return Err(ds::invalid("confirmed target changed"));
            }
            let stage: String = transaction.query_row(
            "SELECT stage FROM device_sync_apply_journal WHERE operation_uuid=?1 AND library_uuid=?2",
            params![operation.to_string(), current.library_uuid], |row| row.get(0),
        )?;
            if stage != "prepare" {
                return Err(ds::invalid("operation is not prepared"));
            }
            transaction.execute(
                "UPDATE sync_write_context SET preserve_revisions=1 WHERE id=1",
                [],
            )?;
            for decision in &plan.media {
                cancel.check()?;
                let id: Option<i64> = transaction
                    .query_row(
                        "SELECT id FROM media_asset WHERE sha256=?1",
                        [&decision.sha256],
                        |row| row.get(0),
                    )
                    .optional()?;
                if decision.action == Action::Remove {
                    transaction.execute(
                        "DELETE FROM media_asset WHERE sha256=?1",
                        [&decision.sha256],
                    )?;
                    continue;
                }
                let record = decision
                    .final_record
                    .as_ref()
                    .ok_or_else(|| ds::invalid("missing final media"))?;
                if decision.action == Action::Keep {
                    if decision.revision_only {
                        transaction.execute(
                            "UPDATE media_asset SET info_revision=?2 WHERE sha256=?1",
                            params![record.sha256, record.revision.map(|v| v.to_rfc3339())],
                        )?;
                    }
                    continue;
                }
                let id = if let Some(id) = id {
                    transaction.execute(
                    "UPDATE media_asset SET size=?2,media_type=?3,captured_at=?4,imported_at=?5,
                       game_title_id=?6,source_game_name=?7,game_name=?8,original_name=?9,favorite=?10,
                       info_revision=?11 WHERE id=?1",
                    params![id,record.length,if record.kind == MediaKind::Image {"image"} else {"video"},record.captured_at.map(|v|v.to_rfc3339()),
                        record.imported_at.map(|v|v.to_rfc3339()).unwrap_or_default(),record.game_title_id,
                        record.source_game_name,record.game_name,record.original_display_name,record.favorite,
                        record.revision.map(|v|v.to_rfc3339())],
                )?;
                    id
                } else {
                    let path = paths
                        .remove(&record.sha256)
                        .ok_or_else(|| ds::invalid("new media lacks pinned publication"))?;
                    transaction.execute(
                    "INSERT INTO media_asset(sha256,size,media_type,captured_at,imported_at,game_title_id,
                       source_game_name,game_name,original_name,storage_path,favorite,info_revision)
                     VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
                    params![record.sha256,record.length,if record.kind == MediaKind::Image {"image"} else {"video"},record.captured_at.map(|v|v.to_rfc3339()),
                        record.imported_at.map(|v|v.to_rfc3339()).unwrap_or_default(),record.game_title_id,
                        record.source_game_name,record.game_name,record.original_display_name,path.to_string_lossy(),
                        record.favorite,record.revision.map(|v|v.to_rfc3339())],
                )?;
                    transaction.last_insert_rowid()
                };
                transaction.execute("DELETE FROM media_tag WHERE media_id=?1", [id])?;
                for tag in &record.tags {
                    add_tag_in_transaction(&transaction, id, tag)?;
                }
                transaction.execute("DELETE FROM note WHERE media_id=?1", [id])?;
                if !record.note.is_empty() {
                    transaction.execute(
                        "INSERT INTO note(media_id,text,updated_at) VALUES(?1,?2,?3)",
                        params![
                            id,
                            record.note,
                            record.revision.map(|v| v.to_rfc3339()).unwrap_or_default()
                        ],
                    )?;
                }
                transaction.execute(
                    "UPDATE media_asset SET info_revision=?2 WHERE id=?1",
                    params![id, record.revision.map(|v| v.to_rfc3339())],
                )?;
            }
            if !paths.is_empty() {
                return Err(ds::invalid("unexpected publication"));
            }
            for decision in &plan.albums {
                cancel.check()?;
                if decision.action == Action::Remove {
                    transaction.execute(
                        "DELETE FROM album WHERE sync_uuid=?1 AND system_key IS NULL",
                        [&decision.uuid],
                    )?;
                    continue;
                }
                let state = decision
                    .final_state
                    .as_ref()
                    .ok_or_else(|| ds::invalid("missing final album"))?;
                let record = &state.definition;
                if record.system_key.as_deref() == Some("favorites") {
                    continue;
                }
                if matches!(decision.action, Action::Add | Action::Replace) {
                    transaction.execute(
                    "INSERT INTO album(name,album_type,pinned,system_key,created_at,updated_at,description,sync_uuid,source_library_uuid,info_revision)
                     VALUES(?1,?2,?3,NULL,'','',?4,?5,?6,?7)
                     ON CONFLICT(sync_uuid) DO UPDATE SET name=excluded.name,album_type=excluded.album_type,
                       pinned=excluded.pinned,description=excluded.description,info_revision=excluded.info_revision",
                    params![record.name,record.album_type,record.pinned,record.description,record.uuid,
                        record.source_library_uuid,record.revision.map(|v|v.to_rfc3339())],
                )?;
                    let id: i64 = transaction.query_row(
                        "SELECT id FROM album WHERE sync_uuid=?1",
                        [&record.uuid],
                        |row| row.get(0),
                    )?;
                    transaction.execute("DELETE FROM album_media WHERE album_id=?1", [id])?;
                    transaction.execute("DELETE FROM album_rule WHERE album_id=?1", [id])?;
                    if record.album_type == "manual" {
                        for sha in &state.members {
                            transaction.execute(
                            "INSERT INTO album_media(album_id,media_id) SELECT ?1,id FROM media_asset WHERE sha256=?2",
                            params![id,sha],
                        )?;
                        }
                    } else {
                        for rule in &state.rules {
                            transaction.execute(
                            "INSERT INTO album_rule(album_id,rule_group,field,operator,value,created_at) VALUES(?1,?2,?3,?4,?5,'')",
                            params![id,rule.group,rule.field,rule.operator,rule.value],
                        )?;
                        }
                    }
                }
                if decision.revision_only
                    || matches!(decision.action, Action::Add | Action::Replace)
                {
                    transaction.execute(
                        "UPDATE album SET info_revision=?2 WHERE sync_uuid=?1",
                        params![record.uuid, record.revision.map(|v| v.to_rfc3339())],
                    )?;
                }
            }
            receiver_catalogs(&transaction, plan, cancel)?;
            receiver_source_names(&transaction, source, target, cancel)?;
            let described_sources: u64 = transaction.query_row(
                "SELECT COUNT(*) FROM device_sync_source_name
             WHERE library_uuid=(SELECT library_uuid FROM library_sync WHERE id=1)
                OR library_uuid IN(SELECT source_library_uuid FROM album)",
                [],
                |row| row.get(0),
            )?;
            if described_sources > crate::device_sync::source_names::MAX_SOURCES as u64 {
                return Err(ds::invalid("final source description count limit exceeded"));
            }
            receiver_validate_applied_catalogs(
                &transaction,
                plan,
                target.manifest.header.clone(),
                cancel,
            )?;
            cancel.check()?;
            transaction.execute(
                "UPDATE sync_write_context SET preserve_revisions=0 WHERE id=1",
                [],
            )?;
            transaction.execute(
            "UPDATE device_sync_apply_journal SET stage='library_applied' WHERE operation_uuid=?1 AND stage='prepare'",
            [operation.to_string()],
        )?;
            cancel.check()?;
            if let Some(guard) = &guard {
                guard.check()?;
            }
            transaction.commit()?;
            Ok(())
        })();
        result
    }
}

struct ReceiverFinalizeCommit<'a> {
    connection: &'a mut Connection,
}
impl Drop for ReceiverFinalizeCommit<'_> {
    fn drop(&mut self) {
        self.connection.commit_hook(None::<fn() -> bool>);
    }
}

struct ScanSqlInterrupt<'a> {
    connection: &'a mut Connection,
}
impl<'a> ScanSqlInterrupt<'a> {
    fn new(connection: &'a mut Connection, cancel: crate::sync::CancellationToken) -> Self {
        connection.progress_handler(1024, Some(move || cancel.check().is_err()));
        Self { connection }
    }
    fn bounded(connection: &'a mut Connection, maximum_work: u64) -> Self {
        let mut work = 0_u64;
        connection.progress_handler(
            1024,
            Some(move || {
                work = work.saturating_add(1024);
                work > maximum_work
            }),
        );
        Self { connection }
    }
}
impl Drop for ScanSqlInterrupt<'_> {
    fn drop(&mut self) {
        self.connection.progress_handler(0, None::<fn() -> bool>);
    }
}

struct ReceiverSqlProgress<'a> {
    connection: &'a mut Connection,
}
impl Drop for ReceiverSqlProgress<'_> {
    fn drop(&mut self) {
        self.connection.progress_handler(0, None::<fn() -> bool>);
    }
}

fn receiver_catalogs(
    transaction: &rusqlite::Transaction<'_>,
    plan: &crate::device_sync::planner::SyncPlan,
    cancel: &crate::sync::CancellationToken,
) -> CoreResult<()> {
    use std::collections::{BTreeMap, BTreeSet};
    let desired_tags: BTreeSet<_> = plan
        .tags
        .iter()
        .filter(|t| !t.deleted)
        .map(|t| ds::normalized(&t.name))
        .collect();
    let existing = transaction
        .prepare("SELECT id,normalized_name FROM tag")?
        .query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    for (id, name) in existing {
        cancel.check()?;
        if !desired_tags.contains(&name) {
            transaction.execute("DELETE FROM tag WHERE id=?1", [id])?;
        }
    }
    for tag in plan.tags.iter().filter(|t| !t.deleted) {
        cancel.check()?;
        transaction.execute(
            "INSERT INTO tag(name,normalized_name,created_at) VALUES(?1,?2,'')
             ON CONFLICT(normalized_name) DO UPDATE SET name=excluded.name
               WHERE name COLLATE BINARY IS NOT excluded.name COLLATE BINARY",
            params![tag.name, ds::normalized(&tag.name)],
        )?;
    }
    let desired_game: BTreeMap<_, _> = plan
        .mappings
        .iter()
        .filter(|m| m.kind == ds::MappingKind::Game && !m.deleted)
        .map(|m| (ds::normalized(&m.source_name), m))
        .collect();
    let existing = transaction
        .prepare("SELECT source_name,target_name,is_intermediate FROM game_tag_alias")?
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, bool>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut retained = BTreeSet::new();
    for (source, target, intermediate) in existing {
        cancel.check()?;
        let key = ds::normalized(&source);
        if let Some(record) = desired_game.get(&key) {
            if source != record.source_name {
                transaction.execute("DELETE FROM game_tag_alias WHERE source_name=?1", [source])?;
                continue;
            }
            retained.insert(key);
            if intermediate || record.target_name.as_deref() != Some(&target) {
                transaction.execute(
                    "UPDATE game_tag_alias SET target_name=?2,is_intermediate=0 WHERE source_name=?1",
                    params![source,record.target_name],
                )?;
            }
        } else {
            transaction.execute("DELETE FROM game_tag_alias WHERE source_name=?1", [source])?;
        }
    }
    for (key, record) in desired_game {
        cancel.check()?;
        if !retained.contains(&key) {
            transaction.execute(
                "INSERT INTO game_tag_alias(source_name,target_name,is_intermediate) VALUES(?1,?2,0)",
                params![record.source_name,record.target_name],
            )?;
        }
    }
    let keys: BTreeSet<_> = plan.tags.iter().map(|t| ds::normalized(&t.name)).collect();
    let current = transaction
        .prepare("SELECT normalized_name FROM sync_tag_state")?
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    for key in current {
        cancel.check()?;
        if !keys.contains(&key) {
            transaction.execute("DELETE FROM sync_tag_state WHERE normalized_name=?1", [key])?;
        }
    }
    for tag in &plan.tags {
        cancel.check()?;
        transaction.execute(
            "INSERT INTO sync_tag_state(normalized_name,name,revision,deleted) VALUES(?1,?2,?3,?4)
             ON CONFLICT(normalized_name) DO UPDATE SET name=excluded.name,revision=excluded.revision,deleted=excluded.deleted",
            params![ds::normalized(&tag.name),tag.name,tag.revision.map(|v|v.to_rfc3339()),tag.deleted],
        )?;
    }
    let desired: BTreeMap<_, _> = plan
        .mappings
        .iter()
        .map(|m| {
            (
                (
                    if m.kind == ds::MappingKind::Tag {
                        "tag".to_owned()
                    } else {
                        "game".to_owned()
                    },
                    ds::normalized(&m.source_name),
                ),
                m,
            )
        })
        .collect();
    let current = transaction
        .prepare("SELECT kind,source_name FROM sync_mapping")?
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
        .collect::<Result<Vec<_>, _>>()?;
    for (kind, source) in current {
        cancel.check()?;
        // Alias triggers may have recreated the old spelling. SQLite NOCASE
        // does not implement the manifest's Unicode normalized identity.
        if !desired
            .get(&(kind.clone(), ds::normalized(&source)))
            .is_some_and(|record| record.source_name == source)
        {
            transaction.execute(
                "DELETE FROM sync_mapping WHERE kind=?1 AND source_name=?2",
                params![kind, source],
            )?;
        }
    }
    for mapping in &plan.mappings {
        cancel.check()?;
        transaction.execute(
            "INSERT INTO sync_mapping(kind,source_name,target_name,revision,deleted) VALUES(?1,?2,?3,?4,?5)
             ON CONFLICT(kind,source_name) DO UPDATE SET target_name=excluded.target_name,revision=excluded.revision,deleted=excluded.deleted",
            params![if mapping.kind==ds::MappingKind::Tag {"tag"}else{"game"},mapping.source_name,
                mapping.target_name,mapping.revision.map(|v|v.to_rfc3339()),mapping.deleted],
        )?;
    }
    Ok(())
}

fn receiver_validate_applied_catalogs(
    transaction: &rusqlite::Transaction<'_>,
    plan: &crate::device_sync::planner::SyncPlan,
    header: ds::ManifestHeader,
    cancel: &crate::sync::CancellationToken,
) -> CoreResult<()> {
    let actual = receiver_manifest_connection(transaction, header, cancel)?.validate()?;
    if !actual.tags.values().eq(plan.tags.iter())
        || !actual.mappings.values().eq(plan.mappings.iter())
    {
        return Err(ds::invalid("applied catalogs disagree with confirmed plan"));
    }
    let actual_tags = transaction
        .prepare("SELECT normalized_name,name FROM tag ORDER BY normalized_name")?
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let expected_tags: Vec<_> = plan
        .tags
        .iter()
        .filter(|tag| !tag.deleted)
        .map(|tag| (ds::normalized(&tag.name), tag.name.clone()))
        .collect();
    let actual_aliases = transaction
        .prepare(
            "SELECT source_name,target_name,is_intermediate FROM game_tag_alias
             ORDER BY source_name COLLATE BINARY",
        )?
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, bool>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut expected_aliases: Vec<_> = plan
        .mappings
        .iter()
        .filter(|mapping| mapping.kind == ds::MappingKind::Game && !mapping.deleted)
        .map(|mapping| {
            Ok((
                mapping.source_name.clone(),
                mapping
                    .target_name
                    .clone()
                    .ok_or_else(|| ds::invalid("missing game mapping target"))?,
                false,
            ))
        })
        .collect::<CoreResult<_>>()?;
    expected_aliases.sort();
    cancel.check()?;
    if actual_tags != expected_tags || actual_aliases != expected_aliases {
        return Err(ds::invalid(
            "applied local catalogs disagree with confirmed plan",
        ));
    }
    Ok(())
}

fn receiver_source_names(
    transaction: &rusqlite::Transaction<'_>,
    source: &crate::device_sync::receiver::Snapshot,
    target: &crate::device_sync::receiver::Snapshot,
    cancel: &crate::sync::CancellationToken,
) -> CoreResult<()> {
    for entry in &source.sources.entries {
        cancel.check()?;
        if entry.library_uuid == target.manifest.header.library_uuid {
            continue;
        }
        transaction.execute(
            "INSERT INTO device_sync_source_name(library_uuid,display_name) VALUES(?1,?2)
             ON CONFLICT(library_uuid) DO UPDATE SET display_name=CASE WHEN ?3 THEN excluded.display_name ELSE display_name END
             WHERE ?3 AND display_name IS NOT excluded.display_name",
            params![entry.library_uuid,entry.display_name,entry.library_uuid==source.manifest.header.library_uuid],
        )?;
    }
    for entry in &target.sources.entries {
        cancel.check()?;
        transaction.execute(
            "INSERT INTO device_sync_source_name(library_uuid,display_name) VALUES(?1,?2)
             ON CONFLICT(library_uuid) DO UPDATE SET display_name=excluded.display_name
               WHERE library_uuid=?3 AND display_name IS NOT excluded.display_name",
            params![
                entry.library_uuid,
                entry.display_name,
                target.manifest.header.library_uuid
            ],
        )?;
    }
    Ok(())
}

#[cfg(test)]
fn load_receiver_backup(
    connection: &mut Connection,
    backup: uuid::Uuid,
    library: &str,
) -> CoreResult<ReceiverBackup> {
    load_receiver_backup_controlled(connection, backup, library, &Default::default())
}

fn load_receiver_backup_controlled(
    connection: &mut Connection,
    backup: uuid::Uuid,
    library: &str,
    work: &crate::device_sync::work::WorkControl,
) -> CoreResult<ReceiverBackup> {
    use crate::device_sync::work::{BackupWork, WorkStage};
    use sha2::{Digest, Sha256};
    let _scope = work.begin(WorkStage::Validating)?;
    let interrupt = ScanSqlInterrupt::new(connection, work.cancellation());
    let result = (|| {
        let mut statement = interrupt.connection.prepare(
        "SELECT version,library_uuid,digest,payload FROM device_sync_backup WHERE backup_uuid=?1",
    )?;
        let mut rows = statement.query([backup.to_string()])?;
        let row = rows.next()?.ok_or(rusqlite::Error::QueryReturnedNoRows)?;
        let value = row.get_ref(3)?.as_blob().map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                3,
                rusqlite::types::Type::Blob,
                Box::new(error),
            )
        })?;
        if value.len() > MAX_RECEIVER_BACKUP_BYTES {
            return Err(rusqlite::Error::InvalidQuery.into());
        }
        let version = row.get::<_, u32>(0)?;
        let owner = row.get::<_, String>(1)?;
        let digest = row.get::<_, String>(2)?;
        work.backup_begin(BackupWork::Copying)?;
        let mut payload = Vec::with_capacity(value.len());
        for chunk in value.chunks(65_536) {
            work.check()?;
            payload.extend_from_slice(chunk);
            work.backup_processed(chunk.len());
        }
        drop(rows);
        drop(statement);
        work.backup_begin(BackupWork::Hashing)?;
        let mut hash = Sha256::new();
        for chunk in payload.chunks(65_536) {
            work.check()?;
            hash.update(chunk);
            work.backup_processed(chunk.len());
        }
        if version != 1 || owner != library || hex::encode(hash.finalize()) != digest {
            return Err(ds::invalid("backup identity, version or digest is invalid"));
        }
        struct ControlledInput<'a> {
            bytes: &'a [u8],
            offset: usize,
            observed: usize,
            work: &'a crate::device_sync::work::WorkControl,
        }
        impl std::io::Read for ControlledInput<'_> {
            fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
                if self.offset - self.observed >= 16_384 || self.offset == self.bytes.len() {
                    self.work.backup_processed(self.offset - self.observed);
                    self.observed = self.offset;
                    self.work
                        .check()
                        .map_err(|_| std::io::Error::other("cancelled"))?;
                }
                let count = output.len().min(16_384).min(self.bytes.len() - self.offset);
                output[..count].copy_from_slice(&self.bytes[self.offset..self.offset + count]);
                self.offset += count;
                Ok(count)
            }
        }
        work.backup_begin(BackupWork::Decoding)?;
        let decoded = serde_json::from_reader(ControlledInput {
            bytes: &payload,
            offset: 0,
            observed: 0,
            work,
        });
        work.check()?;
        let backup: ReceiverBackup = decoded?;
        if backup.version != 1
            || backup.snapshot.manifest.header.library_uuid != library
            || backup.tables.len() != RECEIVER_TABLES.len()
        {
            return Err(ds::invalid("invalid local backup shape"));
        }
        work.backup_begin(BackupWork::Manifest)?;
        backup.snapshot.validate_controlled(work)?;
        work.backup_begin(BackupWork::Rows)?;
        let mut count = 0usize;
        for (table, &(name, columns)) in backup.tables.iter().zip(RECEIVER_TABLES) {
            if table.name != name {
                return Err(ds::invalid("invalid local backup table"));
            }
            let columns = columns.split(',').count();
            for row in &table.rows {
                work.check()?;
                count = count
                    .checked_add(1)
                    .ok_or_else(|| ds::invalid("backup row overflow"))?;
                if count > MAX_RECEIVER_BACKUP_ROWS
                    || row.len() != columns
                    || row.iter().any(
                        |c| matches!(c,LocalCell::Text(text) if text.len()>MAX_LOCAL_CELL_BYTES),
                    )
                {
                    return Err(ds::invalid("invalid local backup row"));
                }
                work.backup_processed(1);
            }
        }
        Ok(backup)
    })();
    work.check()?;
    result
}

fn receiver_backup_originals(
    backup: &ReceiverBackup,
    root: &Path,
    work: &crate::device_sync::work::WorkControl,
) -> CoreResult<Vec<OriginalIdentity>> {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    let cancel = work.cancellation();
    let media = backup.snapshot.manifest.validate_controlled(work)?.media;
    let table = &backup.tables[0];
    let mut seen = std::collections::BTreeSet::new();
    let mut originals = Vec::new();
    let mut buffer = vec![0u8; 65_536];
    for row in &table.rows {
        cancel.check()?;
        let (
            LocalCell::Text(sha),
            LocalCell::Integer(length),
            LocalCell::Text(path),
            LocalCell::Text(status),
        ) = (&row[1], &row[2], &row[15], &row[17])
        else {
            return Err(ds::invalid("invalid backup original row"));
        };
        if status != "ready" || *length <= 0 {
            return Err(ds::invalid("unsupported backup media state"));
        }
        let record = media
            .get(sha)
            .ok_or_else(|| ds::invalid("backup original is absent from snapshot"))?;
        if record.length != *length as u64 || !seen.insert(sha) {
            return Err(ds::invalid("backup original declaration mismatch"));
        }
        let identity = OriginalIdentity::controlled(root, Path::new(path), sha, *length as u64)?;
        let mut file = std::fs::File::open(identity.path())?;
        if file.metadata()?.len() != identity.length {
            return Err(ds::invalid("backup original length mismatch"));
        }
        let mut hasher = Sha256::new();
        loop {
            cancel.check()?;
            let read = file.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
        }
        if hex::encode(hasher.finalize()) != *sha {
            return Err(ds::invalid("backup original checksum mismatch"));
        }
        originals.push(identity);
    }
    if seen.len() != media.len() {
        return Err(ds::invalid("backup original rows are incomplete"));
    }
    Ok(originals)
}

fn restore_receiver_tables(
    transaction: &rusqlite::Transaction<'_>,
    backup: &ReceiverBackup,
    cancel: &crate::sync::CancellationToken,
) -> CoreResult<()> {
    for table in backup.tables.iter().rev() {
        transaction.execute(&format!("DELETE FROM {}", table.name), [])?;
    }
    for (table, &(name, columns)) in backup.tables.iter().zip(RECEIVER_TABLES) {
        // Business triggers can recreate these states during earlier deletes/inserts.
        if matches!(name, "sync_tag_state" | "sync_mapping") {
            transaction.execute(&format!("DELETE FROM {name}"), [])?;
        }
        let parameters = (1..=columns.split(',').count())
            .map(|n| format!("?{n}"))
            .collect::<Vec<_>>()
            .join(",");
        let mut statement = transaction.prepare(&format!(
            "INSERT INTO {name}({columns}) VALUES({parameters})"
        ))?;
        for row in &table.rows {
            cancel.check()?;
            let values = row.iter().map(|cell| match cell {
                LocalCell::Null => rusqlite::types::Value::Null,
                LocalCell::Integer(value) => rusqlite::types::Value::Integer(*value),
                LocalCell::Text(value) => rusqlite::types::Value::Text(value.clone()),
            });
            statement.execute(rusqlite::params_from_iter(values))?;
        }
    }
    // A caller-supplied local label was part of the approved snapshot even if it
    // had not previously been persisted by register_local_name.
    for entry in &backup.snapshot.sources.entries {
        transaction.execute(
            "INSERT INTO device_sync_source_name(library_uuid,display_name) VALUES(?1,?2)
             ON CONFLICT(library_uuid) DO UPDATE SET display_name=excluded.display_name",
            params![entry.library_uuid, entry.display_name],
        )?;
    }
    Ok(())
}

fn receiver_manifest_connection(
    connection: &Connection,
    header: ds::ManifestHeader,
    cancel: &crate::sync::CancellationToken,
) -> CoreResult<ds::Manifest> {
    let mut records = Vec::new();
    let mut bytes = 0usize;
    for section in 0..6 {
        let mut after = 0;
        while let Some((key, record)) = device_sync_next_record(connection, section, after)? {
            cancel.check()?;
            ds::validate_record(&record)?;
            let size = serde_json::to_vec(&record)?.len();
            bytes = bytes
                .checked_add(size + 1)
                .ok_or_else(|| ds::invalid("restore snapshot overflow"))?;
            if records.len() == ds::MAX_MANIFEST_RECORDS || bytes > ds::MAX_MANIFEST_BYTES {
                return Err(ds::invalid("restore snapshot budget exceeded"));
            }
            records.push(record);
            after = key;
        }
    }
    let manifest = ds::Manifest { header, records };
    manifest.validate()?;
    Ok(manifest)
}

impl Database {
    pub fn device_sync_journal(
        &self,
        operation: uuid::Uuid,
    ) -> CoreResult<Option<crate::device_sync::recovery::JournalEntry>> {
        use crate::device_sync::recovery::{JournalEntry, JournalStage};
        let connection = self.connection.lock().expect("database mutex poisoned");
        let row = connection
            .query_row(
                "SELECT version,library_uuid,stage,backup_uuid,preview_digest,external_reference
             FROM device_sync_apply_journal WHERE operation_uuid=?1",
                [operation.to_string()],
                |r| {
                    Ok((
                        r.get::<_, u32>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                        r.get::<_, Option<String>>(5)?,
                    ))
                },
            )
            .optional()?;
        let Some((version, library, stage, backup, digest, external)) = row else {
            return Ok(None);
        };
        if version != 1 || library != device_sync_header(&connection)?.library_uuid {
            return Err(ds::invalid(
                "journal version or library identity is invalid",
            ));
        }
        ds::validate_uuid(&library)?;
        ds::validate_uuid(&backup)?;
        ds::validate_sha(&digest)?;
        if let Some(value) = &external {
            ds::validate_uuid(value)?;
        }
        let stage = match stage.as_str() {
            "prepare" => JournalStage::Prepared,
            "library_applied" => JournalStage::LibraryApplied,
            "rolled_back" => JournalStage::RolledBack,
            "finalized" => JournalStage::Finalized,
            _ => return Err(ds::invalid("unknown durable journal stage")),
        };
        Ok(Some(JournalEntry {
            operation_uuid: operation,
            library_uuid: library,
            stage,
            backup_uuid: uuid::Uuid::parse_str(&backup)
                .map_err(|_| ds::invalid("invalid backup identity"))?,
            preview_digest: digest,
            external_reference: external
                .map(|v| {
                    uuid::Uuid::parse_str(&v).map_err(|_| ds::invalid("invalid external identity"))
                })
                .transpose()?,
        }))
    }

    pub fn device_sync_pending_journal(
        &self,
    ) -> CoreResult<Option<crate::device_sync::recovery::JournalEntry>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let values = connection.prepare(
            "SELECT operation_uuid FROM device_sync_apply_journal WHERE stage NOT IN ('finalized','rolled_back') OR stage IS NULL LIMIT 2",
        )?.query_map([],|r|r.get::<_,String>(0))?.collect::<Result<Vec<_>,_>>()?;
        drop(connection);
        if values.len() > 1 {
            return Err(ds::invalid("multiple pending journal operations"));
        }
        values
            .first()
            .map(|v| {
                ds::validate_uuid(v)?;
                self.device_sync_journal(
                    uuid::Uuid::parse_str(v)
                        .map_err(|_| ds::invalid("invalid operation identity"))?,
                )
                .and_then(|entry| entry.ok_or_else(|| ds::invalid("pending journal disappeared")))
            })
            .transpose()
    }

    /// Scope is proven by durable ownership and its exact journal, never by
    /// presence or absence of a Flutter protected-store index.
    pub fn device_sync_backup_metadata_page(
        &self,
        after: Option<&str>,
        limit: usize,
    ) -> CoreResult<Vec<crate::device_sync::read_model::BackupMetadata>> {
        let after = after
            .map(|value| {
                value
                    .parse::<i64>()
                    .map_err(|_| ds::invalid("invalid backup position"))
            })
            .transpose()?;
        Ok(self
            .device_sync_backup_metadata_scan(after, limit)?
            .into_iter()
            .map(|(_, item)| item)
            .collect())
    }

    pub(crate) fn device_sync_backup_metadata_scan(
        &self,
        after: Option<i64>,
        limit: usize,
    ) -> CoreResult<Vec<(i64, crate::device_sync::read_model::BackupMetadata)>> {
        if !(1..=129).contains(&limit) {
            return Err(ds::invalid("invalid backup metadata limit"));
        }
        self.backup_metadata_query(after, None, limit)
    }

    pub fn device_sync_backup_metadata(
        &self,
        backup: uuid::Uuid,
    ) -> CoreResult<crate::device_sync::read_model::BackupMetadata> {
        self.backup_metadata_query(None, Some(&backup.to_string()), 1)?
            .pop()
            .map(|(_, item)| item)
            .ok_or(CoreError::DeviceSyncRecoveryRequired)
    }

    fn backup_metadata_query(
        &self,
        after: Option<i64>,
        exact: Option<&str>,
        limit: usize,
    ) -> CoreResult<Vec<(i64, crate::device_sync::read_model::BackupMetadata)>> {
        use crate::device_sync::read_model::{BackupMetadata, BackupUnavailableReason as Reason};
        let mut connection = self.connection.try_lock().map_err(|error| match error {
            std::sync::TryLockError::WouldBlock => CoreError::LibraryBusy,
            std::sync::TryLockError::Poisoned(_) => CoreError::LibraryLockUnavailable,
        })?;
        // Old journals need no new persistent index. A bounded metadata read
        // yields Unavailable rather than monopolizing SQL on a very large store.
        let interrupt = ScanSqlInterrupt::bounded(&mut connection, 16_000_000);
        let connection = &*interrupt.connection;
        let library = device_sync_header(connection)?.library_uuid;
        let start = match after {
            Some(i64::MAX) => return Ok(Vec::new()),
            Some(value) => value + 1,
            None => i64::MIN,
        };
        let saved = if backup_has_created_at(connection)? {
            "b.created_at"
        } else {
            "NULL"
        };
        let sql = backup_metadata_sql(saved, backup_has_ownership(connection)?, exact.is_some());
        let mut statement = connection.prepare(&sql)?;
        let mut rows = statement.query(params![start, exact, limit as i64])?;
        let mut result = Vec::new();
        while let Some(row) = rows.next()? {
            let text = |index, maximum| -> Result<Option<String>, Reason> {
                let raw = row.get_ref(index).map_err(|_| Reason::InvalidMetadata)?;
                if raw == rusqlite::types::ValueRef::Null {
                    return Ok(None);
                }
                let value = raw.as_str().map_err(|_| Reason::InvalidMetadata)?;
                if value.len() > maximum {
                    return Err(Reason::InvalidMetadata);
                }
                Ok(Some(value.to_owned()))
            };
            let uuid = |index| -> Result<String, Reason> {
                let value = text(index, 36)?.ok_or(Reason::InvalidIdentity)?;
                ds::validate_uuid(&value).map_err(|_| Reason::InvalidIdentity)?;
                Ok(value)
            };
            // Even an undecodable primary key retains an internal SQL position.
            // Only validated safe identifiers leave this layer.
            let mut item = BackupMetadata {
                backup: uuid(1).ok(),
                source_library_uuid: None,
                source_name: None,
                created_at: None,
                includes_accounts: None,
                unavailable_reason: None,
            };
            let validation = (|| -> Result<(), Reason> {
                let backup = item.backup.as_ref().ok_or(Reason::InvalidIdentity)?;
                let source = uuid(2)?;
                if source != library || row.get::<_, i64>(5).ok() != Some(1) {
                    return Err(Reason::InvalidIdentity);
                }
                item.source_library_uuid = Some(source.clone());
                let created_at = text(3, 40)?;
                if let Some(saved) = &created_at {
                    let time =
                        DateTime::parse_from_rfc3339(saved).map_err(|_| Reason::InvalidMetadata)?;
                    if time.offset().local_minus_utc() != 0 {
                        return Err(Reason::InvalidMetadata);
                    }
                }
                item.created_at = created_at;
                let source_name = text(4, 512)?;
                if let Some(name) = &source_name {
                    crate::device_sync::source_names::SourceDescription::new(source, name.clone())
                        .map_err(|_| Reason::InvalidMetadata)?;
                }
                item.source_name = source_name;
                let digest = text(18, 64)?.ok_or(Reason::InvalidPayload)?;
                ds::validate_sha(&digest).map_err(|_| Reason::InvalidPayload)?;
                let size = row.get::<_, i64>(19).map_err(|_| Reason::InvalidPayload)?;
                if !(2..=MAX_RECEIVER_BACKUP_BYTES as i64).contains(&size)
                    || text(20, 8)?.as_deref() != Some("blob")
                {
                    return Err(Reason::InvalidPayload);
                }
                // At most 4 KiB per scanned row. Large payloads deliberately
                // remain unchecked here, including their digest and originals.
                match row.get::<_, Option<Vec<u8>>>(21) {
                    Ok(Some(bytes)) => {
                        let value: serde_json::Value =
                            serde_json::from_slice(&bytes).map_err(|_| Reason::InvalidPayload)?;
                        if value.get("version").and_then(|v| v.as_u64()) != Some(1)
                            || !value.get("snapshot").is_some_and(|v| v.is_object())
                            || !value.get("tables").is_some_and(|v| v.is_array())
                        {
                            return Err(Reason::InvalidPayload);
                        }
                    }
                    Ok(None) => {}
                    Err(_) => return Err(Reason::InvalidPayload),
                }
                let owner_version = row
                    .get::<_, Option<i64>>(13)
                    .map_err(|_| Reason::OwnershipInvalid)?;
                let kind = text(14, 32).map_err(|_| Reason::OwnershipInvalid)?;
                let owner_operation = text(15, 36).map_err(|_| Reason::OwnershipInvalid)?;
                let owner_external = text(16, 36).map_err(|_| Reason::OwnershipInvalid)?;
                let owner_source = text(17, 36).map_err(|_| Reason::OwnershipInvalid)?;
                if owner_version.is_some() {
                    if owner_version != Some(1)
                        || !matches!(
                            kind.as_deref(),
                            Some("overwrite" | "user_restore" | "compensation")
                        )
                        || owner_operation
                            .as_ref()
                            .is_none_or(|v| ds::validate_uuid(v).is_err())
                        || owner_external
                            .as_ref()
                            .is_some_and(|v| ds::validate_uuid(v).is_err())
                        || owner_source
                            .as_ref()
                            .is_some_and(|v| ds::validate_uuid(v).is_err() || v == backup)
                        || (kind.as_deref() == Some("overwrite")) != owner_source.is_none()
                        || (owner_source.is_some()
                            && text(22, 36).ok().flatten().as_deref() != Some(library.as_str()))
                    {
                        return Err(Reason::OwnershipInvalid);
                    }
                    if kind.as_deref() == Some("compensation") {
                        if owner_external.is_some() {
                            return Err(Reason::OwnershipInvalid);
                        }
                        return Err(Reason::InternalCompensation);
                    }
                } else if kind.is_some()
                    || owner_operation.is_some()
                    || owner_external.is_some()
                    || owner_source.is_some()
                {
                    return Err(Reason::OwnershipInvalid);
                }
                let count = row.get::<_, i64>(10).map_err(|_| Reason::JournalInvalid)?;
                if count == 0 && owner_version.is_none() {
                    return Err(Reason::OwnershipUnknown);
                }
                let operation = uuid(11).map_err(|_| Reason::JournalInvalid)?;
                let external = text(9, 36).map_err(|_| Reason::JournalInvalid)?;
                let stage = text(8, 32).map_err(|_| Reason::JournalInvalid)?;
                let journal_digest = text(12, 64).map_err(|_| Reason::JournalInvalid)?;
                if count != 1
                    || uuid(6).ok().as_deref() != Some(library.as_str())
                    || row.get::<_, Option<i64>>(7).ok().flatten() != Some(1)
                    || external
                        .as_ref()
                        .is_some_and(|v| ds::validate_uuid(v).is_err())
                    || journal_digest
                        .as_ref()
                        .is_none_or(|v| ds::validate_sha(v).is_err())
                    || !matches!(
                        stage.as_deref(),
                        Some("prepare" | "library_applied" | "finalized" | "rolled_back")
                    )
                    || (owner_version.is_some()
                        && (owner_operation.as_ref() != Some(&operation)
                            || owner_external != external))
                {
                    return Err(Reason::JournalInvalid);
                }
                item.includes_accounts = Some(external.is_some());
                if !matches!(stage.as_deref(), Some("finalized" | "rolled_back")) {
                    return Err(Reason::IncompleteOperation);
                }
                Ok(())
            })();
            item.unavailable_reason = validation.err();
            // Never publish an unknown or damaged item's alleged account scope.
            if !matches!(
                item.unavailable_reason,
                None | Some(Reason::IncompleteOperation)
            ) {
                item.includes_accounts = None;
            }
            result.push((row.get(0)?, item));
        }
        Ok(result)
    }

    pub fn device_sync_backup_journal(
        &self,
        backup: uuid::Uuid,
    ) -> CoreResult<crate::device_sync::recovery::JournalEntry> {
        self.backup_journal_controlled(backup, &Default::default())
    }

    fn backup_journal_controlled(
        &self,
        backup: uuid::Uuid,
        work: &crate::device_sync::work::WorkControl,
    ) -> CoreResult<crate::device_sync::recovery::JournalEntry> {
        use crate::device_sync::read_model::BackupUnavailableReason;
        work.check()?;
        let metadata = self.device_sync_backup_metadata(backup)?;
        if !matches!(
            metadata.unavailable_reason,
            None | Some(BackupUnavailableReason::IncompleteOperation)
        ) {
            return Err(CoreError::DeviceSyncRecoveryRequired);
        }
        self.receiver_backup_snapshot_controlled(backup, work)?;
        let connection = self.connection.lock().expect("database mutex poisoned");
        let operations = connection
            .prepare(
                "SELECT operation_uuid FROM device_sync_apply_journal WHERE backup_uuid=?1 LIMIT 2",
            )?
            .query_map([backup.to_string()], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        drop(connection);
        if operations.len() != 1 {
            return Err(ds::invalid(
                "backup journal ownership is missing or ambiguous",
            ));
        }
        ds::validate_uuid(&operations[0])?;
        let operation = uuid::Uuid::parse_str(&operations[0])
            .map_err(|_| ds::invalid("invalid backup operation identity"))?;
        self.device_sync_journal(operation)?
            .filter(|entry| entry.backup_uuid == backup)
            .ok_or_else(|| ds::invalid("backup journal ownership disappeared"))
    }

    pub(crate) fn device_sync_restore_proof(
        &self,
        backup: uuid::Uuid,
        work: &crate::device_sync::work::WorkControl,
    ) -> CoreResult<(crate::device_sync::recovery::JournalEntry, String)> {
        use crate::device_sync::recovery::JournalStage;
        let journal = self.backup_journal_controlled(backup, work)?;
        if !matches!(
            journal.stage,
            JournalStage::Finalized | JournalStage::RolledBack
        ) {
            return Err(CoreError::DeviceSyncRecoveryRequired);
        }
        let connection = self.connection.lock().expect("database mutex poisoned");
        let ownership = if backup_has_ownership(&connection)? {
            connection
                .query_row(
                    "SELECT version,kind,operation_uuid,external_reference,source_backup_uuid
                     FROM device_sync_backup_ownership WHERE backup_uuid=?1",
                    [backup.to_string()],
                    |row| {
                        Ok((
                            row.get::<_, i64>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, Option<String>>(3)?,
                            row.get::<_, Option<String>>(4)?,
                        ))
                    },
                )
                .optional()?
        } else {
            None
        };
        let proof = work.digest_json(&(
            1_u32,
            backup,
            ownership,
            journal.operation_uuid,
            journal.external_reference,
            &journal.preview_digest,
            matches!(journal.stage, JournalStage::Finalized),
        ))?;
        Ok((journal, proof))
    }

    #[allow(dead_code)] // Kept as the default-control compatibility entry.
    pub(crate) fn receiver_recovery_lease(
        &self,
        operation: uuid::Uuid,
    ) -> CoreResult<crate::device_sync::library_guard::RecoveryLease> {
        self.receiver_recovery_lease_controlled(operation, &Default::default())
    }

    pub(crate) fn receiver_recovery_lease_controlled(
        &self,
        operation: uuid::Uuid,
        work: &crate::device_sync::work::WorkControl,
    ) -> CoreResult<crate::device_sync::library_guard::RecoveryLease> {
        work.check()?;
        let lease = self.gate.recover(operation)?;
        let entry = self
            .device_sync_pending_journal()?
            .ok_or_else(|| ds::invalid("there is no pending operation"))?;
        if entry.operation_uuid != operation {
            return Err(ds::invalid(
                "recovery operation does not match pending journal",
            ));
        }
        self.receiver_backup_snapshot_controlled(entry.backup_uuid, work)?;
        // Recovery never runs migrations or silently accepts a newer schema.
        let version: i64 = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row("SELECT version FROM schema_version", [], |r| r.get(0))?;
        if version != 8 {
            return Err(ds::invalid(
                "pending library schema is not supported for recovery",
            ));
        }
        Ok(lease)
    }

    #[cfg(test)]
    pub(crate) fn receiver_backup_snapshot(
        &self,
        backup: uuid::Uuid,
    ) -> CoreResult<crate::device_sync::receiver::Snapshot> {
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let library = device_sync_header(&connection)?.library_uuid;
        Ok(load_receiver_backup(&mut connection, backup, &library)?.snapshot)
    }

    pub(crate) fn receiver_backup_snapshot_controlled(
        &self,
        backup: uuid::Uuid,
        work: &crate::device_sync::work::WorkControl,
    ) -> CoreResult<crate::device_sync::receiver::Snapshot> {
        work.check()?;
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        work.check()?;
        let library = device_sync_header(&connection)?.library_uuid;
        Ok(load_receiver_backup_controlled(&mut connection, backup, &library, work)?.snapshot)
    }
    fn validate_recovery_access(
        &self,
        access: &crate::device_sync::recovery::RecoveryAccess,
        operation: uuid::Uuid,
    ) -> CoreResult<()> {
        use crate::device_sync::recovery::RecoveryAccess;
        match access {
            RecoveryAccess::New(lease) => {
                lease.validate(&self.gate)?;
                if self.gate.pending() {
                    return Err(crate::error::CoreError::LibraryBusy);
                }
            }
            RecoveryAccess::Pending(lease, expected) => {
                if operation != *expected {
                    return Err(ds::invalid("recovery operation identity mismatch"));
                }
                lease.validate(&self.gate, operation)?;
                let entry = self
                    .device_sync_pending_journal()?
                    .ok_or_else(|| ds::invalid("pending operation disappeared"))?;
                if entry.operation_uuid != operation {
                    return Err(ds::invalid("pending operation changed"));
                }
            }
        }
        Ok(())
    }

    pub(crate) fn receiver_finalize_recovery(
        &self,
        access: &crate::device_sync::recovery::RecoveryAccess,
        operation: uuid::Uuid,
        external: Option<uuid::Uuid>,
        cancel: &crate::sync::CancellationToken,
        guard: Option<std::sync::Arc<dyn crate::device_sync::receiver::CommitGuard>>,
    ) -> CoreResult<()> {
        let check = || -> CoreResult<()> {
            cancel.check()?;
            if let Some(guard) = &guard {
                guard.check()?;
            }
            Ok(())
        };
        check()?;
        self.validate_recovery_access(access, operation)?;
        if !matches!(
            access,
            crate::device_sync::recovery::RecoveryAccess::Pending(..)
        ) {
            return Err(ds::invalid(
                "finalization requires a pending recovery capability",
            ));
        }
        let entry = self
            .device_sync_journal(operation)?
            .ok_or_else(|| ds::invalid("operation disappeared"))?;
        if entry.stage != crate::device_sync::recovery::JournalStage::LibraryApplied
            || entry.external_reference != external
        {
            return Err(ds::invalid("external coordination is not confirmed"));
        }
        check()?;
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        check()?;
        let commit_cancel = cancel.clone();
        let commit_guard = guard.clone();
        connection.commit_hook(Some(move || {
            commit_cancel.check().is_err()
                || commit_guard
                    .as_ref()
                    .is_some_and(|guard| guard.check().is_err())
        }));
        let finalization = ReceiverFinalizeCommit {
            connection: &mut connection,
        };
        let result = (|| -> CoreResult<()> {
            let transaction = finalization
                .connection
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            check()?;
            let rows = transaction.execute(
                "UPDATE device_sync_apply_journal SET stage='finalized'
                 WHERE operation_uuid=?1 AND stage='library_applied' AND external_reference IS ?2",
                params![operation.to_string(), external.map(|id| id.to_string())],
            )?;
            if rows != 1 {
                return Err(ds::invalid("pending finalization changed"));
            }
            check()?;
            transaction.commit()?;
            Ok(())
        })();
        drop(finalization);
        result?;
        self.gate.publish_pending(false);
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn receiver_restore(
        &self,
        access: &crate::device_sync::recovery::RecoveryAccess,
        operation: uuid::Uuid,
        backup: uuid::Uuid,
        current: &crate::device_sync::receiver::Snapshot,
        digest: &str,
        work: &crate::device_sync::work::WorkControl,
        external: Option<uuid::Uuid>,
    ) -> CoreResult<uuid::Uuid> {
        use crate::device_sync::recovery::RecoveryAccess;
        let cancel = &work.cancellation();
        work.check()?;
        self.validate_recovery_access(access, operation)?;
        if matches!(access, RecoveryAccess::New(_)) {
            let (ownership, _) = self.device_sync_restore_proof(backup, work)?;
            if ownership.external_reference.is_some() != external.is_some() {
                return Err(CoreError::DeviceSyncRecoveryRequired);
            }
        }
        let (_, root) = self.device_sync_file_roots()?;
        self.validate_existing_original_root(&root)?;
        let data = {
            let mut connection = self.connection.lock().expect("database mutex poisoned");
            let library = device_sync_header(&connection)?.library_uuid;
            load_receiver_backup_controlled(&mut connection, backup, &library, work)?
        };
        // No current state is changed, nor any owner created, before every
        // original in the selected backup has passed its full length/SHA check.
        let verified = receiver_backup_originals(&data, &root, work)?;
        let pins: Vec<_> = verified
            .into_iter()
            .map(|identity| self.gate.pin(identity))
            .collect();
        let originals = self.controlled_originals_cancellable(&root, Some(cancel))?;
        cancel.check()?;
        let safety = uuid::Uuid::new_v4();
        {
            let mut connection = self.connection.lock().expect("database mutex poisoned");
            connection.execute_batch("PRAGMA synchronous=FULL;")?;
            let transaction = connection.transaction()?;
            let payload = bounded_backup_json(&ReceiverBackup {
                version: 1,
                snapshot: current.clone(),
                tables: capture_receiver_tables(&transaction, cancel)?,
            })?;
            insert_receiver_backup(
                &transaction,
                safety,
                &root.canonicalize()?,
                &originals,
                &payload,
                &current.manifest.header.library_uuid,
            )?;
            let pending = matches!(access, RecoveryAccess::Pending(..));
            insert_backup_ownership(
                &transaction,
                safety,
                if pending {
                    "compensation"
                } else {
                    "user_restore"
                },
                operation,
                if pending { None } else { external },
                Some(backup),
            )?;
            if matches!(access, RecoveryAccess::New(_)) {
                transaction.execute(
                    "INSERT INTO device_sync_apply_journal(operation_uuid,version,library_uuid,stage,backup_uuid,preview_digest,external_reference)
                     VALUES(?1,1,?2,'prepare',?3,?4,?5)",
                    params![operation.to_string(),current.manifest.header.library_uuid,safety.to_string(),digest,external.map(|id|id.to_string())],
                )?;
            }
            cancel.check()?;
            transaction.commit()?;
            self.gate.publish_pending(true);
        }
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        cancel.check()?;
        transaction.execute(
            "UPDATE sync_write_context SET preserve_revisions=1 WHERE id=1",
            [],
        )?;
        restore_receiver_tables(&transaction, &data, cancel)?;
        let restored = receiver_manifest_connection(
            &transaction,
            data.snapshot.manifest.header.clone(),
            cancel,
        )?;
        if restored.validate_controlled(work)?.digest
            != data.snapshot.manifest.validate_controlled(work)?.digest
        {
            return Err(ds::invalid("local backup rows disagree with snapshot"));
        }
        if transaction.execute(
            "UPDATE library_sync SET generation=generation+1 WHERE id=1 AND generation<9223372036854775807",[],
        )? != 1 {
            return Err(ds::invalid("device sync generation overflow"));
        }
        transaction.execute(
            "UPDATE sync_write_context SET preserve_revisions=0 WHERE id=1",
            [],
        )?;
        cancel.check()?;
        transaction.execute(
            "UPDATE device_sync_apply_journal SET stage=?2 WHERE operation_uuid=?1",
            params![
                operation.to_string(),
                if matches!(access, RecoveryAccess::Pending(..)) {
                    "rolled_back"
                } else {
                    "library_applied"
                }
            ],
        )?;
        transaction.commit()?;
        drop(connection);
        drop(pins);
        if matches!(access, RecoveryAccess::New(_)) && external.is_none() {
            self.connection.lock().expect("database mutex poisoned").execute(
                "UPDATE device_sync_apply_journal SET stage='finalized' WHERE operation_uuid=?1 AND stage='library_applied'",
                [operation.to_string()],
            )?;
        }
        self.gate
            .publish_pending(matches!(access, RecoveryAccess::New(_)) && external.is_some());
        Ok(safety)
    }
}

fn device_sync_has_pending(connection: &Connection) -> CoreResult<bool> {
    let exists: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='device_sync_apply_journal')",
        [], |row| row.get(0),
    )?;
    if !exists {
        return Ok(false);
    }
    // Unknown/corrupt journal shapes remain closed to normal writes.
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM device_sync_apply_journal WHERE stage NOT IN ('finalized','rolled_back') OR stage IS NULL)",
        [], |row| row.get(0),
    ).unwrap_or(true))
}

fn device_sync_header(connection: &Connection) -> CoreResult<ds::ManifestHeader> {
    Ok(connection.query_row(
        "SELECT library_uuid,generation FROM library_sync WHERE id=1",
        [],
        |row| {
            Ok(ds::ManifestHeader {
                version: ds::VERSION,
                library_uuid: row.get(0)?,
                generation: row.get(1)?,
                observed_at: Utc::now(),
            })
        },
    )?)
}

fn device_sync_next_record(
    connection: &Connection,
    section: u8,
    after: i64,
) -> CoreResult<Option<(i64, ds::ManifestRecord)>> {
    Ok(match section {
        0 => {
            let row=connection.query_row(
                "SELECT ma.id,ma.sha256,ma.size,ma.media_type,ma.original_name,
                   ma.captured_at,ma.imported_at,ma.game_title_id,ma.source_game_name,ma.game_name,
                   COALESCE(n.text,''),ma.favorite,ma.info_revision
                 FROM media_asset ma LEFT JOIN note n ON n.media_id=ma.id
                 WHERE ma.id>?1 AND ma.status='ready' ORDER BY ma.id LIMIT 1",
                [after], |row| Ok((
                    row.get::<_, i64>(0)?,row.get::<_,String>(1)?,row.get::<_,u64>(2)?,
                    row.get::<_,String>(3)?,row.get::<_,String>(4)?,row.get::<_,Option<String>>(5)?,
                    row.get::<_,Option<String>>(6)?,row.get::<_,Option<String>>(7)?,
                    row.get::<_,String>(8)?,row.get::<_,String>(9)?,row.get::<_,String>(10)?,
                    row.get::<_,bool>(11)?,row.get::<_,Option<String>>(12)?,
                )),
            ).optional()?;
            let Some((id,sha256,length,kind,name,captured,imported,game_title_id,
                source_game_name,game_name,note,favorite,revision))=row else {return Ok(None);};
            let kind=match kind.as_str() {
                "image"=>MediaKind::Image,"video"=>MediaKind::Video,
                _=>return Err(ds::invalid("invalid stored media type")),
            };
            let original_display_name=name.rsplit(['/', '\\']).next().unwrap_or("media")
                .replace(':',"_");
            let extension=Path::new(&original_display_name).extension().and_then(|v|v.to_str())
                .map(str::to_ascii_lowercase).filter(|v|matches!(v.as_str(),"jpg"|"jpeg"|"png"|"webp"|"mp4"|"mov"))
                .unwrap_or_else(||kind.extension().into());
            let tags=connection.prepare(
                "SELECT t.name FROM tag t JOIN media_tag mt ON mt.tag_id=t.id
                 WHERE mt.media_id=?1 ORDER BY t.normalized_name LIMIT 257"
            )?.query_map([id],|row|row.get::<_,String>(0))?.collect::<Result<Vec<_>,_>>()?;
            Some((id,ds::ManifestRecord::Media(ds::MediaRecord {
                sha256,length,kind,extension,original_display_name,
                captured_at:parse_datetime(captured.as_deref())?,
                imported_at:parse_imported_at(imported.as_deref())?,game_title_id,
                source_game_name,game_name,tags,note,favorite,revision:parse_datetime(revision.as_deref())?,
            })))
        },
        1 => connection.query_row(
            "SELECT id,sync_uuid,source_library_uuid,name,description,album_type,pinned,system_key,info_revision
             FROM album WHERE id>?1 ORDER BY id LIMIT 1",
            [after], |row| Ok((
                row.get::<_,i64>(0)?,ds::AlbumRecord {
                    uuid:row.get(1)?,source_library_uuid:row.get(2)?,name:row.get(3)?,
                    description:row.get(4)?,album_type:row.get(5)?,pinned:row.get(6)?,
                    system_key:row.get(7)?,revision:None,
                },row.get::<_,Option<String>>(8)?,
            )),
        ).optional()?.map(|(id,mut record,revision)| -> CoreResult<_> {
            record.revision=parse_datetime(revision.as_deref())?;
            Ok((id,ds::ManifestRecord::Album(record)))
        }).transpose()?,
        2 => connection.query_row(
            "SELECT r.id,a.sync_uuid,r.rule_group,r.field,r.operator,r.value
             FROM album_rule r JOIN album a ON a.id=r.album_id
             WHERE r.id>?1 AND a.album_type='smart' AND NOT EXISTS(
               SELECT 1 FROM album_rule older WHERE older.album_id=r.album_id
               AND older.id<r.id AND older.rule_group=r.rule_group AND older.field=r.field
               AND older.operator=r.operator AND older.value=r.value)
             ORDER BY r.id LIMIT 1",
            [after], |row| Ok((row.get(0)?,ds::ManifestRecord::Rule(ds::RuleRecord {
                album_uuid:row.get(1)?,group:row.get(2)?,field:row.get(3)?,
                operator:row.get(4)?,value:row.get(5)?,
            }))),
        ).optional()?,
        3 => connection.query_row(
            "SELECT am.rowid,a.sync_uuid,ma.sha256 FROM album_media am
             JOIN album a ON a.id=am.album_id JOIN media_asset ma ON ma.id=am.media_id
             WHERE am.rowid>?1 AND a.album_type='manual' AND ma.status='ready'
             ORDER BY am.rowid LIMIT 1",
            [after], |row| Ok((row.get(0)?,ds::ManifestRecord::Member(ds::MemberRecord {
                album_uuid:row.get(1)?,sha256:row.get(2)?,
            }))),
        ).optional()?,
        4 => connection.query_row(
            "SELECT rowid,name,revision,deleted FROM sync_tag_state WHERE rowid>?1 ORDER BY rowid LIMIT 1",
            [after], |row| Ok((row.get::<_,i64>(0)?,row.get::<_,String>(1)?,
                row.get::<_,Option<String>>(2)?,row.get::<_,bool>(3)?)),
        ).optional()?.map(|(id,name,revision,deleted)| -> CoreResult<_> {Ok((id,ds::ManifestRecord::Tag(ds::TagRecord {
            name,revision:parse_datetime(revision.as_deref())?,deleted,
        })))}).transpose()?,
        5 => connection.query_row(
            "SELECT rowid,kind,source_name,target_name,revision,deleted FROM sync_mapping
             WHERE rowid>?1 ORDER BY rowid LIMIT 1",
            [after], |row| Ok((row.get::<_,i64>(0)?,row.get::<_,String>(1)?,
                row.get::<_,String>(2)?,row.get::<_,Option<String>>(3)?,
                row.get::<_,Option<String>>(4)?,row.get::<_,bool>(5)?)),
        ).optional()?.map(|(id,kind,source_name,target_name,revision,deleted)| -> CoreResult<_> {
            let kind=match kind.as_str() {
                "tag"=>ds::MappingKind::Tag,"game"=>ds::MappingKind::Game,
                _=>return Err(ds::invalid("invalid mapping kind")),
            };
            Ok((id,ds::ManifestRecord::Mapping(ds::MappingRecord {
                kind,source_name,target_name,revision:parse_datetime(revision.as_deref())?,deleted,
            })))
        }).transpose()?,
        _=>return Err(ds::invalid("invalid manifest section")),
    })
}

fn add_tag_in_transaction(
    transaction: &rusqlite::Transaction<'_>,
    media_id: i64,
    name: &str,
) -> CoreResult<()> {
    let name = name.trim();
    if name.is_empty() {
        return Err(crate::error::CoreError::InvalidConfig(
            "tag cannot be empty".into(),
        ));
    }
    let normalized = name.to_lowercase();
    transaction.execute(
        "INSERT OR IGNORE INTO tag(name, normalized_name, created_at) VALUES (?1, ?2, ?3)",
        params![name, normalized, Utc::now().to_rfc3339()],
    )?;
    let tag_id: i64 = transaction.query_row(
        "SELECT id FROM tag WHERE normalized_name=?1",
        [normalized],
        |row| row.get(0),
    )?;
    transaction.execute(
        "INSERT OR IGNORE INTO media_tag(media_id, tag_id) VALUES (?1, ?2)",
        params![media_id, tag_id],
    )?;
    Ok(())
}

fn source_game_names_for_display(
    transaction: &rusqlite::Transaction<'_>,
    display_name: &str,
) -> CoreResult<Vec<String>> {
    let mut statement = transaction.prepare(
        "SELECT DISTINCT NULLIF(TRIM(source_game_name), '')
         FROM media_asset
         WHERE game_name=?1 COLLATE NOCASE",
    )?;
    let mut names = statement
        .query_map([display_name], |row| row.get::<_, Option<String>>(0))?
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
    if names.is_empty() {
        names.push(display_name.trim().to_owned());
    }
    Ok(names)
}

fn upsert_game_tag_alias(
    transaction: &rusqlite::Transaction<'_>,
    source_name: &str,
    target_name: &str,
) -> CoreResult<()> {
    let source_name = source_name.trim();
    let target_name = target_name.trim();
    if source_name.is_empty() || target_name.is_empty() {
        return Ok(());
    }
    transaction.execute(
        "INSERT INTO game_tag_alias(
           source_name, target_name, is_intermediate
         ) VALUES (?1, ?2, 0)
         ON CONFLICT(source_name) DO UPDATE SET
           target_name=excluded.target_name,
           is_intermediate=0",
        params![source_name, target_name],
    )?;
    Ok(())
}

fn resolve_game_tag_alias(
    transaction: &rusqlite::Transaction<'_>,
    source_name: &str,
) -> CoreResult<String> {
    // Historical migration already checked/repaired its old graph. Runtime
    // import separately checks the hit component and publishes only after commit.
    let direct = read_game_alias_source(transaction, source_name, MAX_GAME_ALIAS_ROW_BYTES, true)?;
    Ok(direct
        .map(|row| row.target)
        .filter(|target| !target.trim().is_empty())
        .map(|target| target.trim().into())
        .unwrap_or_else(|| source_name.trim().into()))
}

fn ensure_game_alias_epoch(transaction: &rusqlite::Transaction<'_>) -> CoreResult<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS game_alias_epoch(
           id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0),
           stamp TEXT NOT NULL CHECK(length(stamp)=32));
         CREATE INDEX IF NOT EXISTS idx_game_alias_target
           ON game_tag_alias(target_name COLLATE NOCASE,source_name COLLATE NOCASE);",
    )?;
    transaction.execute(
        "INSERT OR IGNORE INTO game_alias_epoch(id,stamp) VALUES(1,?1)",
        [uuid::Uuid::new_v4().simple().to_string()],
    )?;
    for event in ["INSERT", "UPDATE", "DELETE"] {
        let when = if event == "UPDATE" {
            "WHEN OLD.source_name IS NOT NEW.source_name OR OLD.target_name IS NOT NEW.target_name"
        } else {
            ""
        };
        transaction.execute_batch(&format!(
            "CREATE TRIGGER IF NOT EXISTS ga_epoch_{event} AFTER {event} ON game_tag_alias {when} BEGIN
               UPDATE game_alias_epoch SET revision=CASE WHEN revision=9223372036854775807
                 THEN RAISE(ABORT,'game alias epoch exhausted') ELSE revision+1 END,
                 stamp=lower(hex(randomblob(16))) WHERE id=1;
             END;"
        ))?;
    }
    Ok(())
}

fn game_alias_epoch(transaction: &rusqlite::Transaction<'_>) -> CoreResult<GameAliasEpoch> {
    Ok(transaction.query_row(
        "SELECT revision,stamp FROM game_alias_epoch WHERE id=1",
        [],
        |row| {
            Ok(GameAliasEpoch {
                revision: row.get(0)?,
                stamp: row.get(1)?,
            })
        },
    )?)
}

fn bounded_game_alias_row(
    row: &rusqlite::Row<'_>,
    maximum_bytes: usize,
    may_read_node: bool,
) -> rusqlite::Result<Option<GameAliasRow>> {
    let source = row.get_ref(0)?.as_str().map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
    })?;
    let target = row.get_ref(1)?.as_str().map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(error))
    })?;
    let Some(bytes) = source.len().checked_add(target.len()) else {
        return Ok(None);
    };
    if !may_read_node || bytes > maximum_bytes.min(MAX_GAME_ALIAS_ROW_BYTES) {
        return Ok(None);
    }
    // SQLite-owned text is inspected above; no Rust String/whole-table collect
    // happens until both the row and remaining component boundaries are checked.
    Ok(Some(GameAliasRow {
        source: source.into(),
        target: target.into(),
    }))
}

fn unpack_game_alias_row(row: Option<Option<GameAliasRow>>) -> CoreResult<Option<GameAliasRow>> {
    match row {
        Some(None) => Err(crate::error::CoreError::InvalidConfig(
            "game alias validation read boundary exceeded".into(),
        )),
        Some(Some(row)) => Ok(Some(row)),
        None => Ok(None),
    }
}

fn read_game_alias_source(
    transaction: &rusqlite::Transaction<'_>,
    source: &str,
    maximum_bytes: usize,
    may_read_node: bool,
) -> CoreResult<Option<GameAliasRow>> {
    unpack_game_alias_row(transaction.query_row(
        "SELECT source_name,target_name FROM game_tag_alias WHERE source_name=?1 COLLATE NOCASE",
        [source.trim()],|row|bounded_game_alias_row(row,maximum_bytes,may_read_node),
    ).optional()?)
}

fn validate_game_alias_component(
    transaction: &rusqlite::Transaction<'_>,
    first: GameAliasRow,
    trusted: Option<&std::collections::BTreeSet<String>>,
    proof: &mut GameAliasProof,
) -> CoreResult<()> {
    let mut seen = std::collections::BTreeSet::new();
    let mut current = first;
    loop {
        if !seen.insert(ds::normalized(&current.source)) {
            return Err(crate::error::CoreError::InvalidConfig(
                "game tag alias cycle detected".into(),
            ));
        }
        if trusted.is_some_and(|sources| sources.contains(&current.source))
            || proof.sources.contains(&current.source)
        {
            return Ok(());
        }
        let bytes = current
            .source
            .len()
            .checked_add(current.target.len())
            .ok_or_else(|| {
                crate::error::CoreError::InvalidConfig("game alias validation size overflow".into())
            })?;
        if proof.read_nodes >= MAX_GAME_ALIAS_PROOF_NODES
            || bytes > MAX_GAME_ALIAS_PROOF_BYTES - proof.read_bytes
        {
            return Err(crate::error::CoreError::InvalidConfig(
                "game alias validation boundary exceeded".into(),
            ));
        }
        proof.read_nodes += 1;
        proof.read_bytes += bytes;
        proof.source_bytes += current.source.len();
        proof.sources.insert(current.source);
        let target = current.target.trim();
        if target.is_empty() {
            return Ok(());
        }
        if seen.contains(&ds::normalized(target)) {
            return Err(crate::error::CoreError::InvalidConfig(
                "game tag alias cycle detected".into(),
            ));
        }
        let Some(next) = read_game_alias_source(
            transaction,
            target,
            MAX_GAME_ALIAS_PROOF_BYTES - proof.read_bytes,
            proof.read_nodes < MAX_GAME_ALIAS_PROOF_NODES,
        )?
        else {
            return Ok(());
        };
        current = next;
    }
}

fn rewrite_generated_name(name: &str, old_game_name: &str, new_game_name: &str) -> String {
    let old_prefixes = [
        format!("{} - ", crate::album::sanitize_game_folder(old_game_name)),
        format!("{old_game_name} - "),
    ];
    let new_prefix = format!("{} - ", crate::album::sanitize_game_folder(new_game_name));
    old_prefixes
        .iter()
        .find_map(|prefix| name.strip_prefix(prefix))
        .map(|suffix| format!("{new_prefix}{suffix}"))
        .unwrap_or_else(|| name.to_owned())
}

fn rewrite_generated_media_names(
    transaction: &rusqlite::Transaction<'_>,
    old_game_name: &str,
    new_game_name: &str,
) -> CoreResult<()> {
    let names = {
        let mut statement = transaction.prepare(
            "SELECT id, original_name
             FROM media_asset
             WHERE game_name=?1 COLLATE NOCASE",
        )?;
        let rows = statement
            .query_map([old_game_name], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };

    for (media_id, original_name) in names {
        let rewritten = rewrite_generated_name(&original_name, old_game_name, new_game_name);
        if rewritten != original_name {
            transaction.execute(
                "UPDATE media_asset SET original_name=?1 WHERE id=?2",
                params![rewritten, media_id],
            )?;
        }
    }
    Ok(())
}

fn kind_name(kind: MediaKind) -> &'static str {
    match kind {
        MediaKind::Image => "image",
        MediaKind::Video => "video",
    }
}

fn to_text(value: Option<DateTime<Utc>>) -> Option<String> {
    value.map(|value| value.to_rfc3339())
}

fn parse_datetime(value: Option<&str>) -> CoreResult<Option<DateTime<Utc>>> {
    value
        .map(|value| {
            DateTime::parse_from_rfc3339(value)
                .map(|value| value.with_timezone(&Utc))
                .map_err(|error| {
                    crate::error::CoreError::Provider(format!("invalid stored timestamp: {error}"))
                })
        })
        .transpose()
}

// Only imported_at uses the exact empty SQL string to preserve unknown history.
fn parse_imported_at(value: Option<&str>) -> CoreResult<Option<DateTime<Utc>>> {
    parse_datetime(value.filter(|value| !value.is_empty()))
}

fn backfill_legacy_nso_names(connection: &Connection) -> CoreResult<()> {
    let mut statement = connection.prepare(
        "SELECT m.id, m.sha256, m.original_name, m.game_name, m.media_type,
                m.captured_at, m.uploaded_at, m.imported_at,
                (SELECT s.remote_id FROM media_source s
                 WHERE s.media_id = m.id AND s.source_type = 'nso'
                 ORDER BY s.id LIMIT 1)
         FROM media_asset m
         WHERE EXISTS (
           SELECT 1 FROM media_source s
           WHERE s.media_id = m.id AND s.source_type = 'nso'
         )",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, String>(7)?,
                row.get::<_, Option<String>>(8)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);

    for (
        id,
        sha256,
        original_name,
        game_name,
        media_type,
        captured,
        uploaded,
        imported,
        remote_id,
    ) in rows
    {
        if !is_hash_fallback_name(&original_name, &sha256) {
            continue;
        }
        let timestamp = captured
            .as_deref()
            .or(uploaded.as_deref())
            .unwrap_or(&imported);
        let Ok(timestamp) = DateTime::parse_from_rfc3339(timestamp) else {
            continue;
        };
        let kind = if media_type.eq_ignore_ascii_case("video") {
            MediaKind::Video
        } else {
            MediaKind::Image
        };
        let readable_name = readable_media_name(
            &game_name,
            timestamp.with_timezone(&Utc),
            remote_id.as_deref(),
            kind,
        );
        connection.execute(
            "UPDATE media_asset SET original_name = ?1 WHERE id = ?2",
            params![readable_name, id],
        )?;
    }
    Ok(())
}

fn backfill_mtp_display_names(connection: &Connection) -> CoreResult<()> {
    let entries = {
        let mut statement = connection.prepare(
            "SELECT DISTINCT ma.id, ma.game_name, ma.media_type, ma.captured_at,
                    ms.source_path
             FROM media_asset ma
             JOIN media_source ms ON ms.media_id=ma.id
             WHERE ms.source_type='mtp' AND ma.captured_at IS NOT NULL",
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    for (index, (media_id, game_name, media_type, captured_at, source_path)) in
        entries.into_iter().enumerate()
    {
        let Ok(timestamp) = DateTime::parse_from_rfc3339(&captured_at) else {
            continue;
        };
        let sequence = source_path
            .as_deref()
            .and_then(mtp_sequence_from_path)
            .unwrap_or((index + 1) as u32);
        let name = readable_import_media_name(
            &game_name,
            timestamp.with_timezone(&Utc),
            sequence,
            kind_from_type(&media_type),
        );
        connection.execute(
            "UPDATE media_asset SET original_name=?1 WHERE id=?2",
            params![name, media_id],
        )?;
    }
    Ok(())
}

fn migrate_game_tag_aliases(transaction: &rusqlite::Transaction<'_>) -> CoreResult<()> {
    let aliases = {
        let mut statement = transaction.prepare(
            "SELECT source_name, target_name
             FROM game_tag_alias
             ORDER BY source_name COLLATE NOCASE",
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    let direct = aliases
        .iter()
        .map(|(source, target)| (source.to_lowercase(), target.clone()))
        .collect::<std::collections::HashMap<_, _>>();
    let intermediate_sources = aliases
        .iter()
        .map(|(_, target)| target.to_lowercase())
        .collect::<std::collections::HashSet<_>>();

    for (source, target) in &aliases {
        let final_target = resolve_alias_from_map(target, &direct)?;
        transaction.execute(
            "UPDATE game_tag_alias
             SET target_name=?1, is_intermediate=?2
             WHERE source_name=?3 COLLATE NOCASE",
            params![
                final_target,
                intermediate_sources.contains(&source.to_lowercase()) as i64,
                source
            ],
        )?;
    }

    let game_names = {
        let mut statement = transaction.prepare(
            "SELECT DISTINCT game_name FROM media_asset
             WHERE TRIM(game_name) <> ''",
        )?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    for old_name in game_names {
        let final_name = resolve_game_tag_alias(transaction, &old_name)?;
        if old_name.eq_ignore_ascii_case(&final_name) {
            continue;
        }
        rewrite_generated_media_names(transaction, &old_name, &final_name)?;
        transaction.execute(
            "UPDATE media_asset SET game_name=?1
             WHERE game_name=?2 COLLATE NOCASE",
            params![final_name, old_name],
        )?;
        transaction.execute(
            "UPDATE album_rule SET value=?1
             WHERE field IN ('game', 'game_tag')
               AND lower(trim(value))=?2",
            params![final_name, old_name.to_lowercase()],
        )?;
        let usage = transaction
            .query_row(
                "SELECT selection_count FROM game_filter_usage
                 WHERE game_name=?1 COLLATE NOCASE",
                [&old_name],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .unwrap_or(0);
        transaction.execute(
            "DELETE FROM game_filter_usage WHERE game_name=?1 COLLATE NOCASE",
            [&old_name],
        )?;
        if usage > 0 {
            transaction.execute(
                "INSERT INTO game_filter_usage(game_name, selection_count, last_selected_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(game_name) DO UPDATE SET
                   selection_count=selection_count + excluded.selection_count,
                   last_selected_at=excluded.last_selected_at",
                params![final_name, usage, Utc::now().to_rfc3339()],
            )?;
        }
    }
    Ok(())
}

fn migrate_hidden_source_game_names(transaction: &rusqlite::Transaction<'_>) -> CoreResult<()> {
    let visible_aliases = {
        let mut statement = transaction.prepare(
            "SELECT source_name, target_name
             FROM game_tag_alias
             WHERE is_intermediate=0
             ORDER BY source_name COLLATE NOCASE",
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    for (source_name, target_name) in visible_aliases {
        transaction.execute(
            "UPDATE media_asset
             SET source_game_name=?1
             WHERE game_name=?2 COLLATE NOCASE
               AND TRIM(source_game_name) = ''",
            params![source_name, target_name],
        )?;
    }
    transaction.execute(
        "UPDATE media_asset
         SET source_game_name=game_name
         WHERE TRIM(source_game_name) = ''",
        [],
    )?;
    transaction.execute("DELETE FROM game_tag_alias WHERE is_intermediate=1", [])?;
    transaction.execute("UPDATE game_tag_alias SET is_intermediate=0", [])?;
    Ok(())
}

fn ensure_required_columns(connection: &Connection) -> CoreResult<()> {
    let required = [
        ("album", "description", "TEXT NOT NULL DEFAULT ''"),
        (
            "game_tag_alias",
            "is_intermediate",
            "INTEGER NOT NULL DEFAULT 0",
        ),
        (
            "media_asset",
            "source_game_name",
            "TEXT NOT NULL DEFAULT ''",
        ),
        ("media_asset", "info_revision", "TEXT"),
        ("media_asset", "favorite", "INTEGER NOT NULL DEFAULT 0"),
        ("media_asset", "uploaded_at", "TEXT"),
        ("album", "sync_uuid", "TEXT NOT NULL DEFAULT ''"),
        ("album", "source_library_uuid", "TEXT NOT NULL DEFAULT ''"),
        ("album", "info_revision", "TEXT"),
    ];
    for (table, column, definition) in required {
        let exists: bool = connection
            .prepare(&format!("PRAGMA table_info({table})"))?
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?
            .iter()
            .any(|name| name == column);
        if !exists {
            connection.execute(
                &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
                [],
            )?;
        }
    }
    Ok(())
}

fn migrate_device_sync(transaction: &rusqlite::Transaction<'_>) -> CoreResult<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS library_sync(
           id INTEGER PRIMARY KEY CHECK(id=1), library_uuid TEXT NOT NULL,
           generation INTEGER NOT NULL DEFAULT 0 CHECK(generation>=0));
         CREATE TABLE IF NOT EXISTS sync_write_context(
           id INTEGER PRIMARY KEY CHECK(id=1), preserve_revisions INTEGER NOT NULL DEFAULT 0);
         INSERT OR IGNORE INTO sync_write_context(id) VALUES(1);
         CREATE TABLE IF NOT EXISTS sync_tag_state(
           normalized_name TEXT PRIMARY KEY, name TEXT NOT NULL,
           revision TEXT, deleted INTEGER NOT NULL DEFAULT 0);
         CREATE TABLE IF NOT EXISTS sync_mapping(
           kind TEXT NOT NULL CHECK(kind IN ('tag','game')),
           source_name TEXT NOT NULL COLLATE NOCASE, target_name TEXT,
           revision TEXT, deleted INTEGER NOT NULL DEFAULT 0,
           PRIMARY KEY(kind,source_name));",
    )?;
    transaction.execute(
        "INSERT OR IGNORE INTO library_sync(id,library_uuid) VALUES(1,?1)",
        [uuid::Uuid::new_v4().to_string()],
    )?;
    let library_uuid: String = transaction.query_row(
        "SELECT library_uuid FROM library_sync WHERE id=1",
        [],
        |row| row.get(0),
    )?;
    let albums = transaction
        .prepare("SELECT id,system_key FROM album WHERE sync_uuid=''")?
        .query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    for (id, system_key) in albums {
        let identity = if system_key.as_deref() == Some("favorites") {
            crate::device_sync::manifest::FAVORITES_UUID.to_owned()
        } else {
            uuid::Uuid::new_v4().to_string()
        };
        transaction.execute(
            "UPDATE album SET sync_uuid=?2,source_library_uuid=?3 WHERE id=?1",
            params![id, identity, library_uuid],
        )?;
    }
    transaction.execute_batch(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_album_sync_uuid ON album(sync_uuid);
         CREATE INDEX IF NOT EXISTS idx_album_rule_sync
           ON album_rule(album_id,rule_group,field,operator,value,id);
         INSERT OR IGNORE INTO sync_tag_state(normalized_name,name)
           SELECT normalized_name,name FROM tag;
         INSERT OR IGNORE INTO sync_mapping(kind,source_name,target_name)
           SELECT 'game',source_name,target_name FROM game_tag_alias WHERE is_intermediate=0;",
    )?;
    // Triggers share the business transaction, including cascades and indirect writes.
    // A receiver may set preserve_revisions=1 inside its atomic apply transaction,
    // supply source revisions, then reset it before commit. Rollback restores the flag.
    let now = "strftime('%Y-%m-%dT%H:%M:%fZ','now')";
    let local = "(SELECT preserve_revisions=0 FROM sync_write_context WHERE id=1)";
    let bump = "UPDATE library_sync SET generation=CASE
      WHEN generation=9223372036854775807 THEN RAISE(ABORT,'device sync generation overflow')
      ELSE generation+1 END WHERE id=1;";
    transaction.execute_batch(&format!(
        "CREATE TRIGGER IF NOT EXISTS ds_media_insert AFTER INSERT ON media_asset BEGIN
           UPDATE media_asset SET info_revision=CASE WHEN {local} THEN {now} ELSE NEW.info_revision END WHERE id=NEW.id;
           {bump}
         END;
         CREATE TRIGGER IF NOT EXISTS ds_media_update AFTER UPDATE OF
           sha256,size,media_type,captured_at,uploaded_at,imported_at,game_title_id,
           source_game_name,game_name,original_name,favorite,status ON media_asset
         WHEN OLD.sha256 IS NOT NEW.sha256 OR OLD.size IS NOT NEW.size
           OR OLD.media_type IS NOT NEW.media_type OR OLD.captured_at IS NOT NEW.captured_at
           OR OLD.uploaded_at IS NOT NEW.uploaded_at OR OLD.imported_at IS NOT NEW.imported_at
           OR OLD.game_title_id IS NOT NEW.game_title_id OR OLD.source_game_name IS NOT NEW.source_game_name
           OR OLD.game_name IS NOT NEW.game_name OR OLD.original_name IS NOT NEW.original_name
           OR OLD.favorite IS NOT NEW.favorite OR OLD.status IS NOT NEW.status BEGIN
           UPDATE media_asset SET info_revision=CASE WHEN {local} THEN {now} ELSE NEW.info_revision END WHERE id=NEW.id;
           UPDATE album SET info_revision=CASE WHEN {local} THEN {now} ELSE info_revision END
             WHERE id IN(SELECT album_id FROM album_media WHERE media_id=NEW.id)
               AND OLD.sha256 IS NOT NEW.sha256;
           {bump}
         END;
         CREATE TRIGGER IF NOT EXISTS ds_media_delete AFTER DELETE ON media_asset BEGIN {bump} END;
         CREATE TRIGGER IF NOT EXISTS ds_media_revision AFTER UPDATE OF info_revision ON media_asset
         WHEN OLD.info_revision IS NOT NEW.info_revision BEGIN {bump} END;
         CREATE TRIGGER IF NOT EXISTS ds_album_insert AFTER INSERT ON album BEGIN
           UPDATE album SET sync_uuid=CASE WHEN NEW.sync_uuid='' THEN
             lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-4'||
             substr(lower(hex(randomblob(2))),2)||'-8'||substr(lower(hex(randomblob(2))),2)||
             '-'||lower(hex(randomblob(6))) ELSE NEW.sync_uuid END,
             source_library_uuid=CASE WHEN NEW.source_library_uuid='' THEN
               (SELECT library_uuid FROM library_sync WHERE id=1) ELSE NEW.source_library_uuid END,
             info_revision=CASE WHEN {local} THEN {now} ELSE NEW.info_revision END
             WHERE id=NEW.id;
           {bump}
         END;
         CREATE TRIGGER IF NOT EXISTS ds_album_update AFTER UPDATE OF name,description,album_type,pinned ON album
         WHEN OLD.name IS NOT NEW.name OR OLD.description IS NOT NEW.description
           OR OLD.album_type IS NOT NEW.album_type OR OLD.pinned IS NOT NEW.pinned BEGIN
           UPDATE album SET info_revision=CASE WHEN {local} THEN {now} ELSE NEW.info_revision END WHERE id=NEW.id;
           {bump}
         END;
         CREATE TRIGGER IF NOT EXISTS ds_album_delete AFTER DELETE ON album BEGIN {bump} END;"
    ))?;
    transaction.execute_batch(&format!(
        "CREATE TRIGGER IF NOT EXISTS ds_album_revision AFTER UPDATE OF info_revision,sync_uuid,source_library_uuid ON album
         WHEN OLD.info_revision IS NOT NEW.info_revision OR OLD.sync_uuid IS NOT NEW.sync_uuid
           OR OLD.source_library_uuid IS NOT NEW.source_library_uuid BEGIN {bump} END;"
    ))?;
    for (table, owner, revision_table, changed) in [
        ("media_tag","media_id","media_asset","OLD.media_id IS NOT NEW.media_id OR OLD.tag_id IS NOT NEW.tag_id"),
        ("note","media_id","media_asset","OLD.text IS NOT NEW.text"),
        ("album_media","album_id","album","OLD.album_id IS NOT NEW.album_id OR OLD.media_id IS NOT NEW.media_id"),
        ("album_rule","album_id","album","OLD.rule_group IS NOT NEW.rule_group OR OLD.field IS NOT NEW.field OR OLD.operator IS NOT NEW.operator OR OLD.value IS NOT NEW.value"),
    ] {
        for (event, row) in [("INSERT","NEW"),("UPDATE","NEW"),("DELETE","OLD")] {
            let when = if event=="UPDATE" {format!("WHEN {changed}")} else {String::new()};
            transaction.execute_batch(&format!(
                "CREATE TRIGGER IF NOT EXISTS ds_{table}_{event} AFTER {event} ON {table} {when} BEGIN
                   UPDATE {revision_table} SET info_revision=CASE WHEN {local} THEN {now} ELSE info_revision END WHERE id={row}.{owner};
                   {bump}
                 END;"
            ))?;
        }
    }
    transaction.execute_batch(&format!(
        "CREATE TRIGGER IF NOT EXISTS ds_tag_insert AFTER INSERT ON tag BEGIN
           INSERT INTO sync_tag_state(normalized_name,name,revision,deleted)
           VALUES(NEW.normalized_name,NEW.name,CASE WHEN {local} THEN {now} ELSE NULL END,0)
           ON CONFLICT(normalized_name) DO UPDATE SET name=excluded.name,revision=excluded.revision,deleted=0;
           {bump}
         END;
         CREATE TRIGGER IF NOT EXISTS ds_tag_update AFTER UPDATE OF name,normalized_name ON tag
         WHEN OLD.name IS NOT NEW.name OR OLD.normalized_name IS NOT NEW.normalized_name BEGIN
           UPDATE media_asset SET info_revision=CASE WHEN {local} THEN {now} ELSE info_revision END
             WHERE id IN(SELECT media_id FROM media_tag WHERE tag_id=NEW.id);
           UPDATE sync_tag_state SET deleted=1,revision=CASE WHEN {local} THEN {now} ELSE revision END
             WHERE normalized_name=OLD.normalized_name AND OLD.normalized_name<>NEW.normalized_name;
           INSERT INTO sync_tag_state(normalized_name,name,revision,deleted)
           VALUES(NEW.normalized_name,NEW.name,CASE WHEN {local} THEN {now} ELSE NULL END,0)
           ON CONFLICT(normalized_name) DO UPDATE SET name=excluded.name,revision=excluded.revision,deleted=0;
           {bump}
         END;
         CREATE TRIGGER IF NOT EXISTS ds_tag_delete AFTER DELETE ON tag BEGIN
           UPDATE sync_tag_state SET deleted=1,revision=CASE WHEN {local} THEN {now} ELSE revision END
             WHERE normalized_name=OLD.normalized_name;
           UPDATE sync_mapping SET target_name=NULL,deleted=1,
             revision=CASE WHEN {local} THEN {now} ELSE revision END
             WHERE kind='tag' AND target_name=OLD.name COLLATE NOCASE AND deleted=0;
           INSERT INTO sync_mapping(kind,source_name,target_name,revision,deleted)
           VALUES('tag',OLD.normalized_name,NULL,CASE WHEN {local} THEN {now} ELSE NULL END,1)
           ON CONFLICT(kind,source_name) DO UPDATE SET target_name=NULL,revision=excluded.revision,deleted=1;
           {bump}
         END;"
    ))?;
    for event in ["INSERT", "UPDATE", "DELETE"] {
        let row = if event == "DELETE" { "OLD" } else { "NEW" };
        let target = if event == "DELETE" {
            "NULL".to_owned()
        } else {
            format!("{row}.target_name")
        };
        let deleted = if event == "DELETE" { 1 } else { 0 };
        let when = if event == "UPDATE" {
            "WHEN OLD.target_name IS NOT NEW.target_name OR OLD.is_intermediate IS NOT NEW.is_intermediate"
        } else {
            ""
        };
        transaction.execute_batch(&format!(
            "CREATE TRIGGER IF NOT EXISTS ds_game_{event} AFTER {event} ON game_tag_alias {when} BEGIN
               INSERT INTO sync_mapping(kind,source_name,target_name,revision,deleted)
               VALUES('game',{row}.source_name,{target},CASE WHEN {local} THEN {now} ELSE NULL END,{deleted})
               ON CONFLICT(kind,source_name) DO UPDATE SET target_name=excluded.target_name,revision=excluded.revision,deleted=excluded.deleted;
               {bump}
             END;"
        ))?;
    }
    for event in ["INSERT", "UPDATE", "DELETE"] {
        let when = if event == "UPDATE" {
            "WHEN OLD.name IS NOT NEW.name OR OLD.revision IS NOT NEW.revision OR OLD.deleted IS NOT NEW.deleted"
        } else {
            ""
        };
        transaction.execute_batch(&format!(
            "CREATE TRIGGER IF NOT EXISTS ds_tagstate_{event} AFTER {event} ON sync_tag_state {when} BEGIN {bump} END;"
        ))?;
        let when = if event == "UPDATE" {
            "WHEN OLD.target_name IS NOT NEW.target_name OR OLD.revision IS NOT NEW.revision OR OLD.deleted IS NOT NEW.deleted"
        } else {
            ""
        };
        transaction.execute_batch(&format!(
            "CREATE TRIGGER IF NOT EXISTS ds_mapping_{event} AFTER {event} ON sync_mapping {when} BEGIN {bump} END;"
        ))?;
    }
    transaction.execute("UPDATE schema_version SET version=8 WHERE version<8", [])?;
    Ok(())
}

fn record_tag_mapping(
    transaction: &rusqlite::Transaction<'_>,
    source: &str,
    target: &str,
) -> CoreResult<()> {
    let source = source.trim().to_lowercase();
    let target = target.trim().to_owned();
    if source == target.to_lowercase() {
        return Ok(());
    }
    for incoming in tag_mapping_sources_for_target(transaction, &source)? {
        transaction.execute(
            "UPDATE sync_mapping SET target_name=?1,revision=strftime('%Y-%m-%dT%H:%M:%fZ','now')
             WHERE kind='tag' AND source_name=?2",
            params![target, incoming],
        )?;
    }
    transaction.execute(
        "INSERT INTO sync_mapping(kind,source_name,target_name,revision,deleted)
         VALUES('tag',?1,?2,strftime('%Y-%m-%dT%H:%M:%fZ','now'),0)
         ON CONFLICT(kind,source_name) DO UPDATE SET target_name=excluded.target_name,revision=excluded.revision,deleted=0",
        params![source,target],
    )?;
    transaction.execute(
        "UPDATE sync_mapping SET target_name=NULL,deleted=1,revision=strftime('%Y-%m-%dT%H:%M:%fZ','now')
         WHERE kind='tag' AND source_name=?1 COLLATE NOCASE AND deleted=0",
        [ds::normalized(&target)],
    )?;
    Ok(())
}

fn tag_mapping_sources_for_target(
    transaction: &rusqlite::Transaction<'_>,
    target: &str,
) -> CoreResult<Vec<String>> {
    let target = ds::normalized(target);
    let mappings = transaction
        .prepare("SELECT source_name,target_name FROM sync_mapping WHERE kind='tag' AND deleted=0")?
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(mappings
        .into_iter()
        .filter(|(_, name)| ds::normalized(name) == target)
        .map(|(source, _)| source)
        .collect())
}

fn rewrite_tag_album_rules(
    transaction: &rusqlite::Transaction<'_>,
    source: &str,
    target: &str,
) -> CoreResult<()> {
    let source = ds::normalized(source);
    let rules = transaction
        .prepare("SELECT id,value FROM album_rule WHERE field='tag'")?
        .query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    for (id, value) in rules {
        if ds::normalized(&value) == source {
            transaction.execute(
                "UPDATE album_rule SET value=?1 WHERE id=?2",
                params![target, id],
            )?;
        }
    }
    Ok(())
}

fn resolve_alias_from_map(
    source_name: &str,
    aliases: &std::collections::HashMap<String, String>,
) -> CoreResult<String> {
    let mut current = source_name.trim().to_owned();
    let mut visited = std::collections::HashSet::new();
    loop {
        if !visited.insert(current.to_lowercase()) {
            return Err(crate::error::CoreError::InvalidConfig(format!(
                "game tag alias cycle detected at '{current}'"
            )));
        }
        let Some(next) = aliases.get(&current.to_lowercase()) else {
            return Ok(current);
        };
        current = next.trim().to_owned();
    }
}

fn mtp_sequence_from_path(value: &str) -> Option<u32> {
    let stem = Path::new(value).file_stem()?.to_str()?;
    let prefix = stem.get(..16)?;
    if !prefix.chars().all(|character| character.is_ascii_digit()) {
        return None;
    }
    prefix.get(14..16)?.parse().ok()
}

fn is_hash_fallback_name(name: &str, sha256: &str) -> bool {
    sha256.len() == 64
        && sha256.chars().all(|ch| ch.is_ascii_hexdigit())
        && Path::new(name)
            .file_stem()
            .and_then(|value| value.to_str())
            .is_some_and(|stem| stem.eq_ignore_ascii_case(sha256))
}

#[cfg(test)]
mod device_sync_backup_scope_tests {
    use crate::api::CoreApi;
    use crate::device_sync::planner::SyncMode;
    use crate::device_sync::receiver::{ReceiveOperation, Snapshot};
    use crate::sync::CancellationToken;

    #[test]
    fn account_backup_scope_rejects_missing_or_corrupt_journal_instead_of_library_only() {
        let source_root = tempfile::tempdir().unwrap();
        let target_root = tempfile::tempdir().unwrap();
        let source = CoreApi::open(source_root.path()).unwrap();
        let target = CoreApi::open(target_root.path()).unwrap();
        let database = target.database();
        let mut receive = ReceiveOperation::prepare(
            database.clone(),
            Snapshot::read(&source.database(), "Source").unwrap(),
            "Target",
            SyncMode::Overwrite,
        )
        .unwrap();
        let mut authorization = receive.authorize().unwrap();
        let external = uuid::Uuid::new_v4();
        let receipt = receive
            .apply(
                Some(&mut authorization),
                Some(external),
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        assert_eq!(
            database
                .device_sync_backup_journal(receipt.backup_uuid)
                .unwrap()
                .external_reference,
            Some(external)
        );
        database.connection.lock().unwrap().execute(
            "UPDATE device_sync_apply_journal SET external_reference='corrupt' WHERE operation_uuid=?1",
            [receipt.operation_uuid.to_string()],
        ).unwrap();
        assert!(database
            .device_sync_backup_journal(receipt.backup_uuid)
            .is_err());
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "DELETE FROM device_sync_apply_journal WHERE operation_uuid=?1",
                [receipt.operation_uuid.to_string()],
            )
            .unwrap();
        assert!(database
            .receiver_backup_snapshot(receipt.backup_uuid)
            .is_ok());
        assert!(database
            .device_sync_backup_journal(receipt.backup_uuid)
            .is_err());
    }
}

#[cfg(test)]
mod unknown_import_time_tests {
    use super::*;
    use crate::device_sync::manifest::ManifestCollector;

    fn insert(database: &Database, id: i64, captured: Option<&str>, imported: &str) {
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO media_asset(id,sha256,size,media_type,captured_at,imported_at,
               source_game_name,game_name,original_name,storage_path)
             VALUES(?1,?2,12,'image',?3,?4,'Game','Game','picture.jpg','missing.jpg')",
                params![id, format!("{id:064x}"), captured, imported],
            )
            .unwrap();
    }

    fn collect(database: &Database, header: &ds::ManifestHeader, limit: usize) -> ds::Manifest {
        let mut collector = ManifestCollector::new(header.clone()).unwrap();
        let mut cursor = None;
        loop {
            let page = database
                .device_sync_manifest_page(header, cursor.as_ref(), limit)
                .unwrap();
            cursor = page.next.clone();
            collector.push(page).unwrap();
            if cursor.is_none() {
                return collector.finish().unwrap();
            }
        }
    }

    #[test]
    fn unknown_import_time_reopen_and_paginated_manifest_preserve_history() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library.sqlite3");
        let database = Database::open(&path).unwrap();
        insert(&database, 1, None, "2020-02-03T04:05:06.123456+08:00");
        insert(&database, 2, None, "");
        let before = database
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT (SELECT version FROM schema_version),generation,
                (SELECT group_concat(imported_at||'/'||coalesce(info_revision,'null'),'|')
                 FROM (SELECT imported_at,info_revision FROM media_asset ORDER BY id))
             FROM library_sync WHERE id=1",
                [],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .unwrap();
        let header = database.device_sync_header().unwrap();
        let first = collect(&database, &header, 1).validate().unwrap();
        let wider = collect(&database, &header, 17).validate().unwrap();
        assert_eq!(first.digest, wider.digest);
        assert_eq!(first.media[&format!("{:064x}", 2)].imported_at, None);
        assert_eq!(
            first.media[&format!("{:064x}", 1)].imported_at,
            Some(
                DateTime::parse_from_rfc3339("2020-02-03T04:05:06.123456+08:00")
                    .unwrap()
                    .with_timezone(&Utc)
            )
        );
        let wire = serde_json::to_value(collect(&database, &header, 1)).unwrap();
        assert!(wire["records"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| record["value"]["imported_at"].is_null()
                && record["value"]["sha256"] == format!("{:064x}", 2)));
        let json = serde_json::to_value(database.media_asset(2).unwrap()).unwrap();
        assert!(json["imported_at"].is_null());
        drop(database);
        for _ in 0..2 {
            let reopened = Database::open(&path).unwrap();
            let after = reopened
                .connection
                .lock()
                .unwrap()
                .query_row(
                    "SELECT (SELECT version FROM schema_version),generation,
                    (SELECT group_concat(imported_at||'/'||coalesce(info_revision,'null'),'|')
                     FROM (SELECT imported_at,info_revision FROM media_asset ORDER BY id))
                 FROM library_sync WHERE id=1",
                    [],
                    |row| {
                        Ok((
                            row.get::<_, i64>(0)?,
                            row.get::<_, i64>(1)?,
                            row.get::<_, String>(2)?,
                        ))
                    },
                )
                .unwrap();
            assert_eq!(after, before);
            assert_eq!(
                collect(&reopened, &header, 1).validate().unwrap().digest,
                first.digest
            );
            assert_eq!(
                reopened.list_media(&GalleryQuery::default()).unwrap().len(),
                2
            );
        }
    }

    #[test]
    fn unknown_import_time_sorting_and_each_date_boundary_use_effective_date() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        insert(
            &database,
            1,
            Some("2020-01-01T00:00:00.000001Z"),
            "2026-01-01T00:00:00Z",
        );
        insert(&database, 2, None, "2021-01-01T00:00:00.123456Z");
        insert(&database, 3, None, "");
        insert(&database, 4, None, "");
        insert(&database, 5, Some("2022-01-01T00:00:00Z"), "");
        let ids = |query: GalleryQuery| {
            database
                .list_media(&query)
                .unwrap()
                .iter()
                .map(|media| media.id)
                .collect::<Vec<_>>()
        };
        assert_eq!(ids(GalleryQuery::default()), vec![5, 2, 1, 4, 3]);
        assert_eq!(
            ids(GalleryQuery {
                newest_first: false,
                ..Default::default()
            }),
            vec![3, 4, 1, 2, 5]
        );
        assert_eq!(
            ids(GalleryQuery {
                limit: 2,
                offset: 2,
                ..Default::default()
            }),
            vec![1, 4]
        );
        let date = |value| {
            DateTime::parse_from_rfc3339(value)
                .unwrap()
                .with_timezone(&Utc)
        };
        for (from, until, expected) in [
            (Some(date("2021-01-01T00:00:00Z")), None, vec![5, 2]),
            (None, Some(date("2021-01-01T00:00:00Z")), vec![1]),
            (
                Some(date("2019-01-01T00:00:00Z")),
                Some(date("2022-01-01T00:00:00Z")),
                vec![2, 1],
            ),
            (Some(date("2021-01-01T00:00:00.123457Z")), None, vec![5]),
            (None, Some(date("2020-01-01T00:00:00.000001Z")), vec![]),
        ] {
            assert_eq!(
                ids(GalleryQuery {
                    captured_from: from,
                    captured_until: until,
                    ..Default::default()
                }),
                expected
            );
        }
    }

    #[test]
    fn unknown_import_time_marker_is_narrow_and_invalid_dates_still_fail_consumers() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        insert(&database, 1, None, "");
        assert!(database.media_export_entries(&[1]).is_ok());
        for imported in [" ", "\t", "not-a-date", "2020-99-99T00:00:00Z"] {
            database.connection.lock().unwrap().execute(
                "UPDATE media_asset SET imported_at=?1,captured_at='2021-01-01T00:00:00Z' WHERE id=1", [imported],
            ).unwrap();
            assert!(matches!(
                database.list_media(&GalleryQuery::default()),
                Err(crate::error::CoreError::Provider(_))
            ));
            assert!(matches!(
                database.media_export_entries(&[1]),
                Err(crate::error::CoreError::Provider(_))
            ));
            assert!(database
                .device_sync_manifest_page(&database.device_sync_header().unwrap(), None, 17)
                .is_err());
        }
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE media_asset SET imported_at='',captured_at='' WHERE id=1",
                [],
            )
            .unwrap();
        assert!(database.list_media(&GalleryQuery::default()).is_err());
        assert!(database.media_export_entries(&[1]).is_err());
        assert!(database
            .device_sync_manifest_page(&database.device_sync_header().unwrap(), None, 17)
            .is_err());
        assert!(parse_datetime(Some("")).is_err());
        assert_eq!(parse_imported_at(None).unwrap(), None);
        assert_eq!(parse_imported_at(Some("")).unwrap(), None);
        database
            .connection
            .lock()
            .unwrap()
            .execute_batch(
                "UPDATE media_asset SET captured_at=NULL WHERE id=1;
                 UPDATE media_asset SET info_revision='' WHERE id=1;",
            )
            .unwrap();
        assert!(database
            .device_sync_manifest_page(&database.device_sync_header().unwrap(), None, 17)
            .is_err());
    }

    #[tokio::test]
    async fn unknown_import_time_real_export_and_edit_keep_unknown_source_history() {
        let directory = tempfile::tempdir().unwrap();
        let input = tempfile::tempdir().unwrap();
        let file = input.path().join("source.mp4");
        std::fs::write(&file, b"synthetic original video").unwrap();
        let api = crate::api::CoreApi::open(directory.path()).unwrap();
        let import_started = Utc::now();
        api.import_custom_files(vec![file.to_string_lossy().into_owned()], "Game".into())
            .await
            .unwrap();
        let source = api.list_media(GalleryQuery::default()).unwrap().remove(0);
        let imported = serde_json::to_value(&source).unwrap()["imported_at"].clone();
        assert!(
            imported.is_string(),
            "ordinary import must record its real admission time"
        );
        let actual = DateTime::parse_from_rfc3339(imported.as_str().unwrap())
            .unwrap()
            .with_timezone(&Utc);
        assert!(actual >= import_started && actual <= Utc::now());
        // Mutate only this synthetic fixture through the database-owned connection.
        let database =
            Database::open(directory.path().join("database").join("library.sqlite3")).unwrap();
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE media_asset SET captured_at=NULL,imported_at='' WHERE id=?1",
                [source.id],
            )
            .unwrap();
        for (language, expected) in [("zh", "未知日期.mp4"), ("en", "Unknown date.mp4")] {
            let settings = AppSettings {
                proxy_url: None,
                library_path: directory.path().to_string_lossy().into_owned(),
                theme: "ocean".into(),
                language: language.into(),
                gallery_columns: 4,
                gallery_rows: 3,
                show_note_preview: true,
                show_game_tag: true,
                compact_tag_display: true,
                auto_play_video: false,
                auto_sync_on_launch: false,
                close_behavior: "ask".into(),
                custom_font_paths: vec![],
                sync_policy: crate::settings::SyncPolicy::default(),
            };
            api.save_settings(&settings).unwrap();
            let destination = tempfile::tempdir().unwrap();
            let summary = api
                .export_media(
                    vec![source.id],
                    destination.path().to_string_lossy().into_owned(),
                    "{年月日}".into(),
                )
                .await
                .unwrap();
            assert_eq!(summary.exported, 1);
            assert_eq!(summary.failed, 0);
            assert_eq!(
                std::fs::read(destination.path().join(expected)).unwrap(),
                b"synthetic original video"
            );
        }
        let processed = input.path().join("edited.mp4");
        std::fs::write(&processed, b"synthetic edited video").unwrap();
        let started = Utc::now();
        let edited = api
            .commit_video_edit(source.id, processed.to_string_lossy().into_owned(), false)
            .await
            .unwrap();
        assert_eq!(edited.captured_at, None);
        let edited_json = serde_json::to_value(&edited).unwrap();
        let actual = DateTime::parse_from_rfc3339(edited_json["imported_at"].as_str().unwrap())
            .unwrap()
            .with_timezone(&Utc);
        assert!(actual >= started && actual <= Utc::now());
        assert!(serde_json::to_value(
            api.list_media(GalleryQuery::default())
                .unwrap()
                .into_iter()
                .find(|m| m.id == source.id)
                .unwrap()
        )
        .unwrap()["imported_at"]
            .is_null());
        assert_eq!(
            std::fs::read(source.storage_path).unwrap(),
            b"synthetic original video"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::SourceType;

    #[test]
    fn unknown_import_time_reads_as_null_in_public_media() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        database
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO media_asset(sha256,size,media_type,imported_at,source_game_name,
               game_name,original_name,storage_path)
             VALUES(?1,12,'image','','Game','Game','unknown.jpg','missing.jpg')",
                ["a".repeat(64)],
            )
            .unwrap();
        let media = database.list_media(&GalleryQuery::default()).unwrap();
        assert_eq!(media.len(), 1);
        assert_eq!(
            serde_json::to_value(&media[0]).unwrap()["imported_at"],
            serde_json::Value::Null
        );
    }

    #[test]
    fn creates_default_favorites_album() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let count: i64 = database
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM album WHERE system_key='favorites'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn migrates_album_descriptions_from_schema_v2() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library.sqlite3");
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch(
                    "CREATE TABLE schema_version(version INTEGER NOT NULL);
                     INSERT INTO schema_version(version) VALUES (2);
                     CREATE TABLE album(
                       id INTEGER PRIMARY KEY,
                       name TEXT NOT NULL,
                       album_type TEXT NOT NULL,
                       pinned INTEGER NOT NULL DEFAULT 0,
                       system_key TEXT UNIQUE,
                       created_at TEXT NOT NULL,
                       updated_at TEXT NOT NULL
                     );
                     INSERT INTO album(name, album_type, created_at, updated_at)
                     VALUES ('Legacy', 'manual', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);",
                )
                .unwrap();
        }

        let database = Database::open(&path).unwrap();
        let legacy = database
            .list_albums()
            .unwrap()
            .into_iter()
            .find(|album| album.name == "Legacy")
            .unwrap();
        assert_eq!(legacy.description, "");
        let version: i64 = database
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT version FROM schema_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, 8);
    }

    #[test]
    fn repairs_missing_required_columns_when_schema_version_is_current() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library.sqlite3");
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch(
                    "CREATE TABLE schema_version(version INTEGER NOT NULL);
                     INSERT INTO schema_version(version) VALUES (8);
                     CREATE TABLE album(
                       id INTEGER PRIMARY KEY, name TEXT NOT NULL,
                       album_type TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0,
                       system_key TEXT UNIQUE, created_at TEXT NOT NULL,
                       updated_at TEXT NOT NULL
                     );
                     CREATE TABLE game_tag_alias(
                       source_name TEXT PRIMARY KEY COLLATE NOCASE,
                       target_name TEXT NOT NULL
                     );
                     CREATE TABLE media_asset(
                       id INTEGER PRIMARY KEY, sha256 TEXT NOT NULL UNIQUE,
                       size INTEGER NOT NULL, media_type TEXT NOT NULL,
                       captured_at TEXT, game_title_id TEXT,
                       imported_at TEXT NOT NULL, game_name TEXT NOT NULL,
                       original_name TEXT NOT NULL, storage_path TEXT NOT NULL,
                       status TEXT NOT NULL
                     );",
                )
                .unwrap();
        }

        let database = Database::open(&path).unwrap();
        let connection = database.connection.lock().unwrap();
        for (table, column) in [
            ("album", "description"),
            ("game_tag_alias", "is_intermediate"),
            ("media_asset", "source_game_name"),
            ("media_asset", "info_revision"),
            ("album", "sync_uuid"),
            ("album", "source_library_uuid"),
            ("album", "info_revision"),
        ] {
            let found: i64 = connection
                .query_row(
                    &format!(
                        "SELECT COUNT(*) FROM pragma_table_info('{table}') WHERE name='{column}'"
                    ),
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(found, 1, "missing {table}.{column}");
        }
    }

    #[test]
    fn protects_the_system_favorites_album() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let favorites = database
            .list_albums()
            .unwrap()
            .into_iter()
            .find(|album| album.system_key.as_deref() == Some("favorites"))
            .unwrap();

        assert!(database
            .update_album(favorites.id, "Renamed", "", false)
            .is_err());
        assert!(database.delete_album(favorites.id).is_err());
    }

    #[test]
    fn converting_smart_album_to_manual_preserves_current_matches() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let media_id = {
            let connection = database.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO media_asset(
                       sha256, size, media_type, imported_at, game_name,
                       original_name, storage_path, status
                     ) VALUES (?1, 42, 'image', ?2, 'Splatoon 3',
                               'capture.jpg', 'capture.jpg', 'ready')",
                    params!["a".repeat(64), Utc::now().to_rfc3339()],
                )
                .unwrap();
            connection.last_insert_rowid()
        };
        database.add_tag(media_id, "festival").unwrap();
        let album_id = database
            .create_album("Festival", "Festival highlights", true)
            .unwrap();
        database
            .replace_album_rules(
                album_id,
                &[AlbumRule {
                    rule_group: 0,
                    field: "tag".into(),
                    operator: "equals".into(),
                    value: "festival".into(),
                }],
            )
            .unwrap();

        database
            .update_album(album_id, "Festival archive", "Archived matches", false)
            .unwrap();
        database.replace_tags(media_id, &[]).unwrap();

        let album = database
            .list_albums()
            .unwrap()
            .into_iter()
            .find(|album| album.id == album_id)
            .unwrap();
        assert_eq!(album.album_type, "manual");
        assert_eq!(album.name, "Festival archive");
        assert_eq!(album.description, "Archived matches");
        assert_eq!(album.media_count, 1);
        assert!(database.list_album_rules(album_id).unwrap().is_empty());
    }

    #[test]
    fn counts_album_media_with_the_same_membership_rules_as_gallery_queries() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        let mut media_ids = Vec::new();
        {
            let connection = database.connection.lock().unwrap();
            for (index, favorite, status) in [
                (1, true, "ready"),
                (2, false, "ready"),
                (3, false, "ready"),
                (4, true, "failed"),
            ] {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, imported_at, game_name,
                           original_name, storage_path, favorite, status
                         ) VALUES (?1, 42, 'image', ?2, 'Game', ?3, ?3, ?4, ?5)",
                        params![
                            format!("{index:064x}"),
                            &now,
                            format!("media-{index}.jpg"),
                            favorite,
                            status,
                        ],
                    )
                    .unwrap();
                media_ids.push(connection.last_insert_rowid());
            }
        }

        let manual_album = database.create_album("Manual", "", false).unwrap();
        database
            .add_media_to_album(manual_album, media_ids[2])
            .unwrap();
        let smart_album = database.create_album("Smart", "", true).unwrap();
        database.add_tag(media_ids[1], "庆典").unwrap();
        database
            .replace_album_rules(
                smart_album,
                &[AlbumRule {
                    rule_group: 0,
                    field: "tag".into(),
                    operator: "equals".into(),
                    value: "庆典".into(),
                }],
            )
            .unwrap();

        let albums = database.list_albums().unwrap();
        let count = |name: &str| {
            albums
                .iter()
                .find(|album| album.name == name)
                .unwrap()
                .media_count
        };
        assert_eq!(count("收藏"), 1);
        assert_eq!(count("Manual"), 1);
        assert_eq!(count("Smart"), 1);
    }

    #[test]
    fn reports_current_sync_progress() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        database.begin_sync_job("job-1", "nso_coral", None).unwrap();
        database
            .update_sync_job("job-1", "running", 10, 3, 1, None, None)
            .unwrap();

        let progress = database
            .current_sync_progress("nso_coral")
            .unwrap()
            .unwrap();
        assert_eq!(progress.total_items, 10);
        assert_eq!(progress.synchronized_items, 3);
        assert_eq!(progress.failed_items, 1);
        assert_eq!(progress.processed_items, 4);
    }

    #[test]
    fn keeps_sync_cursors_separate_by_nintendo_account() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        database
            .begin_sync_job("job-a", "nso_coral:account-a", Some("cursor-a"))
            .unwrap();
        database
            .begin_sync_job("job-b", "nso_coral:account-b", Some("cursor-b"))
            .unwrap();

        assert_eq!(
            database
                .latest_sync_cursor("nso_coral:account-a")
                .unwrap()
                .as_deref(),
            Some("cursor-a")
        );
        assert_eq!(
            database
                .latest_sync_cursor("nso_coral:account-b")
                .unwrap()
                .as_deref(),
            Some("cursor-b")
        );
    }

    #[test]
    fn lists_media_in_requested_capture_time_order() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        {
            let connection = database.connection.lock().unwrap();
            for (sha, name, captured) in [
                ("a".repeat(64), "older.jpg", "2026-10-01T08:00:00+00:00"),
                ("b".repeat(64), "newer.jpg", "2026-10-03T08:00:00+00:00"),
            ] {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, captured_at, imported_at,
                           game_name, original_name, storage_path
                         ) VALUES (?1, 42, 'image', ?2, ?2, 'Game', ?3, ?3)",
                        params![sha, captured, name],
                    )
                    .unwrap();
            }
        }

        let newest = database.list_media(&GalleryQuery::default()).unwrap();
        assert_eq!(newest[0].original_name, "newer.jpg");

        let oldest = database
            .list_media(&GalleryQuery {
                newest_first: false,
                ..GalleryQuery::default()
            })
            .unwrap();
        assert_eq!(oldest[0].original_name, "older.jpg");
    }

    #[test]
    fn lists_distinct_game_tags_from_the_whole_library() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        {
            let connection = database.connection.lock().unwrap();
            for (index, game) in ["Zelda", "Splatoon 3", "Zelda"].into_iter().enumerate() {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, imported_at,
                           game_name, original_name, storage_path
                         ) VALUES (?1, 42, 'image', ?2, ?3, ?4, ?4)",
                        params![
                            format!("{:064x}", index + 1),
                            Utc::now().to_rfc3339(),
                            game,
                            format!("game-{index}.jpg")
                        ],
                    )
                    .unwrap();
            }
        }

        assert_eq!(
            database.list_game_tags().unwrap(),
            vec![
                GameTagSummary {
                    name: "Zelda".into(),
                    image_count: 2,
                    video_count: 0,
                    selection_count: 0,
                },
                GameTagSummary {
                    name: "Splatoon 3".into(),
                    image_count: 1,
                    video_count: 0,
                    selection_count: 0,
                },
            ]
        );

        database.record_game_tag_selection("Splatoon 3").unwrap();
        database.record_game_tag_selection("Splatoon 3").unwrap();
        let ranked = database.list_game_tags().unwrap();
        assert_eq!(ranked[0].name, "Splatoon 3");
        assert_eq!(ranked[0].selection_count, 2);
    }

    #[test]
    fn manages_custom_tags_and_reports_media_usage() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        let media_ids = {
            let connection = database.connection.lock().unwrap();
            let mut ids = Vec::new();
            for (index, media_type) in [(1, "image"), (2, "video")] {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, imported_at, game_name,
                           original_name, storage_path, status
                         ) VALUES (?1, 42, ?2, ?3, 'Game', ?4, ?4, 'ready')",
                        params![
                            format!("{index:064x}"),
                            media_type,
                            &now,
                            format!("media-{index}")
                        ],
                    )
                    .unwrap();
                ids.push(connection.last_insert_rowid());
            }
            ids
        };
        let tag_id = database.add_tag(media_ids[0], "庆典").unwrap();
        database.add_tag(media_ids[1], "庆典").unwrap();
        let smart_album = database.create_album("庆典相册", "", true).unwrap();
        database
            .replace_album_rules(
                smart_album,
                &[AlbumRule {
                    rule_group: 0,
                    field: "tag".into(),
                    operator: "equals".into(),
                    value: "庆典".into(),
                }],
            )
            .unwrap();

        assert_eq!(
            database.list_tag_usage().unwrap(),
            vec![TagUsageSummary {
                id: tag_id,
                name: "庆典".into(),
                image_count: 1,
                video_count: 1,
            }]
        );

        database.rename_tag(tag_id, "祭典").unwrap();
        assert_eq!(database.list_tags().unwrap(), vec!["祭典".to_string()]);
        assert_eq!(
            database
                .list_albums()
                .unwrap()
                .into_iter()
                .find(|album| album.id == smart_album)
                .unwrap()
                .media_count,
            2
        );

        database.delete_tag(tag_id).unwrap();
        assert!(database.list_tag_usage().unwrap().is_empty());
        assert!(database
            .list_media(&GalleryQuery::default())
            .unwrap()
            .iter()
            .all(|media| media.tags.is_empty()));
    }

    #[test]
    fn creates_unassigned_custom_tags() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();

        let tag_id = database.create_tag("旅行").unwrap();
        let tags = database.list_tag_usage().unwrap();

        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0].id, tag_id);
        assert_eq!(tags[0].name, "旅行");
        assert_eq!(tags[0].image_count, 0);
        assert_eq!(tags[0].video_count, 0);
        assert!(database.create_tag("旅行").is_err());
    }

    #[test]
    fn merges_custom_tags_and_updates_smart_rules() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        let media_ids = {
            let connection = database.connection.lock().unwrap();
            let mut ids = Vec::new();
            for index in 1..=2 {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, imported_at, game_name,
                           original_name, storage_path, status
                         ) VALUES (?1, 42, 'image', ?2, 'Game', ?3, ?3, 'ready')",
                        params![format!("{index:064x}"), &now, format!("media-{index}.jpg")],
                    )
                    .unwrap();
                ids.push(connection.last_insert_rowid());
            }
            ids
        };
        let first = database.add_tag(media_ids[0], "Ranked").unwrap();
        let second = database.add_tag(media_ids[1], "Anarchy").unwrap();
        let album_id = database.create_album("Modes", "", true).unwrap();
        database
            .replace_album_rules(
                album_id,
                &[
                    AlbumRule {
                        rule_group: 0,
                        field: "tag".into(),
                        operator: "equals".into(),
                        value: "Ranked".into(),
                    },
                    AlbumRule {
                        rule_group: 1,
                        field: "tag".into(),
                        operator: "equals".into(),
                        value: "Anarchy".into(),
                    },
                ],
            )
            .unwrap();

        database
            .merge_tags(&[first, second], "Competitive")
            .unwrap();

        assert_eq!(database.list_tags().unwrap(), vec!["Competitive"]);
        assert!(database
            .list_media(&GalleryQuery::default())
            .unwrap()
            .iter()
            .all(|media| media.tags == ["Competitive"]));
        assert!(database
            .list_album_rules(album_id)
            .unwrap()
            .iter()
            .all(|rule| rule.value == "Competitive"));
        assert_eq!(
            database
                .list_albums()
                .unwrap()
                .into_iter()
                .find(|album| album.id == album_id)
                .unwrap()
                .media_count,
            2
        );
    }

    #[test]
    fn merges_game_tags_and_applies_aliases_to_future_imports() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        {
            let connection = database.connection.lock().unwrap();
            for (index, game) in [(1, "Splatoon 3"), (2, "斯普拉遁3")] {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, imported_at, game_name,
                           original_name, storage_path, status
                         ) VALUES (?1, 42, 'image', ?2, ?3, ?4, ?4, 'ready')",
                        params![
                            format!("{index:064x}"),
                            &now,
                            game,
                            format!("game-{index}.jpg")
                        ],
                    )
                    .unwrap();
            }
        }
        database.record_game_tag_selection("Splatoon 3").unwrap();
        database.record_game_tag_selection("Splatoon 3").unwrap();
        database.record_game_tag_selection("斯普拉遁3").unwrap();
        let album_id = database.create_album("Splatoon", "", true).unwrap();
        database
            .replace_album_rules(
                album_id,
                &[AlbumRule {
                    rule_group: 0,
                    field: "game".into(),
                    operator: "equals".into(),
                    value: "斯普拉遁3".into(),
                }],
            )
            .unwrap();

        database
            .merge_game_tags(
                &["Splatoon 3".into(), "斯普拉遁3".into()],
                "Splatoon 3 / 斯普拉遁3",
            )
            .unwrap();

        let games = database.list_game_tags().unwrap();
        assert_eq!(games.len(), 1);
        assert_eq!(games[0].name, "Splatoon 3 / 斯普拉遁3");
        assert_eq!(games[0].image_count, 2);
        assert_eq!(games[0].selection_count, 3);
        assert_eq!(
            database.list_album_rules(album_id).unwrap()[0].value,
            "Splatoon 3 / 斯普拉遁3"
        );

        let candidate = MediaCandidate {
            remote_id: None,
            title_id: None,
            game_name: "斯普拉遁3".into(),
            kind: MediaKind::Image,
            content_url: None,
            thumbnail_url: None,
            expected_size: None,
            captured_at: None,
            uploaded_at: None,
            expires_at: None,
            original_name: Some("future.jpg".into()),
            file_extension: Some("jpg".into()),
            source_type: SourceType::Folder,
            source_path: Some("future.jpg".into()),
        };
        database
            .register_media(
                &"f".repeat(64),
                42,
                Path::new("future.jpg"),
                &candidate,
                None,
            )
            .unwrap();
        assert!(database
            .list_media(&GalleryQuery::default())
            .unwrap()
            .iter()
            .all(|media| media.game_name == "Splatoon 3 / 斯普拉遁3"));
    }

    #[test]
    fn renames_game_tag_and_applies_alias_to_future_imports() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        {
            let connection = database.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO media_asset(
                       sha256, size, media_type, imported_at, game_name,
                       original_name, storage_path, status
                     ) VALUES (?1, 42, 'image', ?2, 'Zelda',
                               'Zelda - 2026-10-04 12-30-00 [12345678].jpg',
                               'originals/aa/bb/hash.jpg', 'ready')",
                    params!["1".repeat(64), now],
                )
                .unwrap();
        }

        database.rename_game_tag("Zelda", "塞尔达传说").unwrap();
        assert_eq!(database.list_game_tags().unwrap()[0].name, "塞尔达传说");
        let media = database.list_media(&GalleryQuery::default()).unwrap();
        assert_eq!(
            media[0].original_name,
            "塞尔达传说 - 2026-10-04 12-30-00 [12345678].jpg"
        );
        assert_eq!(media[0].storage_path, "originals/aa/bb/hash.jpg");
        assert_eq!(
            database
                .list_game_tag_aliases()
                .unwrap()
                .into_iter()
                .map(|alias| (alias.source_name, alias.target_name))
                .collect::<Vec<_>>(),
            vec![("Zelda".to_owned(), "塞尔达传说".to_owned())]
        );

        let candidate = MediaCandidate {
            remote_id: None,
            title_id: None,
            game_name: "Zelda".into(),
            kind: MediaKind::Image,
            content_url: None,
            thumbnail_url: None,
            expected_size: None,
            captured_at: None,
            uploaded_at: None,
            expires_at: None,
            original_name: Some("future.jpg".into()),
            file_extension: Some("jpg".into()),
            source_type: SourceType::Mtp,
            source_path: Some("Nintendo Switch/Album/Zelda/future.jpg".into()),
        };
        database
            .register_media(
                &"2".repeat(64),
                42,
                Path::new("future.jpg"),
                &candidate,
                Some("Nintendo Switch"),
            )
            .unwrap();
        assert!(database
            .list_media(&GalleryQuery::default())
            .unwrap()
            .iter()
            .all(|media| media.game_name == "塞尔达传说"));
    }

    #[test]
    fn game_tag_replacement_preserves_custom_names_and_updates_merge_names() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        {
            let connection = database.connection.lock().unwrap();
            for (index, game, name) in [
                (1, "BOTW", "BOTW - 2026-10-04 12-30-00 [01].mp4"),
                (2, "The Legend of Zelda", "user-picked-name.jpg"),
            ] {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, imported_at, game_name,
                           original_name, storage_path, status
                         ) VALUES (?1, 42, ?2, ?3, ?4, ?5, ?5, 'ready')",
                        params![
                            format!("{index:064x}"),
                            if index == 1 { "video" } else { "image" },
                            &now,
                            game,
                            name
                        ],
                    )
                    .unwrap();
            }
        }

        database
            .merge_game_tags(&["BOTW".into(), "The Legend of Zelda".into()], "王国之泪")
            .unwrap();

        let mut media = database.list_media(&GalleryQuery::default()).unwrap();
        media.sort_by_key(|item| item.id);
        assert_eq!(
            media[0].original_name,
            "王国之泪 - 2026-10-04 12-30-00 [01].mp4"
        );
        assert_eq!(media[1].original_name, "user-picked-name.jpg");
        assert_eq!(
            database
                .list_game_tag_aliases()
                .unwrap()
                .into_iter()
                .map(|alias| (alias.source_name, alias.target_name))
                .collect::<Vec<_>>(),
            vec![
                ("BOTW".to_owned(), "王国之泪".to_owned()),
                ("The Legend of Zelda".to_owned(), "王国之泪".to_owned()),
            ]
        );
    }

    #[test]
    fn replacing_game_tag_with_existing_target_requires_merge() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        let connection = database.connection.lock().unwrap();
        for (index, game) in [(1, "BOTW"), (2, "王国之泪")] {
            connection
                .execute(
                    "INSERT INTO media_asset(
                       sha256, size, media_type, imported_at, game_name,
                       original_name, storage_path, status
                     ) VALUES (?1, 42, 'image', ?2, ?3, ?4, ?4, 'ready')",
                    params![
                        format!("{index:064x}"),
                        &now,
                        game,
                        format!("{game} - 2026-10-04 12-30-00 [01].jpg")
                    ],
                )
                .unwrap();
        }
        drop(connection);

        let error = database.rename_game_tag("BOTW", "王国之泪").unwrap_err();
        assert!(error.to_string().contains("merge"));
    }

    #[test]
    fn flattens_repeated_game_tag_replacements_and_resolves_new_media() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        {
            let connection = database.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO media_asset(
                       sha256, size, media_type, imported_at, source_game_name, game_name,
                       original_name, storage_path, status
                     ) VALUES (?1, 42, 'image', ?2, 'A', 'A',
                               'A - 2026-10-04 12-30-00 [01].jpg',
                               'originals/aa/bb/a.jpg', 'ready')",
                    params!["a".repeat(64), &now],
                )
                .unwrap();
        }

        database.rename_game_tag("A", "B").unwrap();
        database.rename_game_tag("B", "C").unwrap();

        let aliases = database.list_game_tag_aliases().unwrap();
        assert_eq!(
            aliases
                .iter()
                .map(|alias| (&alias.source_name, &alias.target_name))
                .collect::<Vec<_>>(),
            vec![(&"A".to_owned(), &"C".to_owned())]
        );

        let candidate = MediaCandidate {
            remote_id: Some("remote-b".into()),
            title_id: None,
            game_name: "A".into(),
            kind: MediaKind::Image,
            content_url: None,
            thumbnail_url: None,
            expected_size: None,
            captured_at: Some(Utc::now()),
            uploaded_at: None,
            expires_at: None,
            original_name: Some("A - 2026-10-04 12-31-00 [02].jpg".into()),
            file_extension: Some("jpg".into()),
            source_type: SourceType::Nso,
            source_path: None,
        };
        database
            .register_media(
                &"b".repeat(64),
                42,
                Path::new("originals/aa/bb/b.jpg"),
                &candidate,
                Some("nso"),
            )
            .unwrap();

        let mut media = database.list_media(&GalleryQuery::default()).unwrap();
        media.sort_by_key(|item| item.id);
        assert_eq!(media[0].game_name, "C");
        assert_eq!(media[0].original_name, "C - 2026-10-04 12-30-00 [01].jpg");
        assert_eq!(media[1].game_name, "C");
        assert_eq!(media[1].original_name, "C - 2026-10-04 12-31-00 [02].jpg");
    }

    #[test]
    fn migrates_legacy_alias_chain_and_repairs_media_names() {
        let directory = tempfile::tempdir().unwrap();
        {
            let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
            let connection = database.connection.lock().unwrap();
            let now = Utc::now().to_rfc3339();
            connection
                .execute(
                    "INSERT INTO media_asset(
                       sha256, size, media_type, imported_at, game_name,
                       original_name, storage_path, status
                     ) VALUES (?1, 42, 'image', ?2, 'B',
                               'B - 2026-10-04 12-30-00 [01].jpg',
                               'originals/aa/bb/b.jpg', 'ready')",
                    params!["b".repeat(64), &now],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO game_tag_alias(
                       source_name, target_name, is_intermediate
                     ) VALUES ('A', 'B', 0), ('B', 'C', 0)",
                    [],
                )
                .unwrap();
            connection
                .execute("UPDATE schema_version SET version = 4", [])
                .unwrap();
        }

        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let aliases = database.list_game_tag_aliases().unwrap();
        assert_eq!(aliases.len(), 1);
        assert_eq!(aliases[0].source_name, "A");
        assert_eq!(aliases[0].target_name, "C");
        let media = database.list_media(&GalleryQuery::default()).unwrap();
        assert_eq!(media[0].game_name, "C");
        assert_eq!(media[0].original_name, "C - 2026-10-04 12-30-00 [01].jpg");
        let source_name: String = database
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT source_game_name FROM media_asset WHERE id=?1",
                [media[0].id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(source_name, "A");
    }

    #[test]
    fn rejects_game_tag_alias_cycles_during_import() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        {
            let connection = database.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO game_tag_alias(
                       source_name, target_name, is_intermediate
                     ) VALUES ('A', 'B', 0), ('B', 'A', 0)",
                    [],
                )
                .unwrap();
        }
        let candidate = MediaCandidate {
            remote_id: None,
            title_id: None,
            game_name: "A".into(),
            kind: MediaKind::Image,
            content_url: None,
            thumbnail_url: None,
            expected_size: None,
            captured_at: None,
            uploaded_at: None,
            expires_at: None,
            original_name: Some("A - 2026-10-04 12-30-00 [01].jpg".into()),
            file_extension: Some("jpg".into()),
            source_type: SourceType::Nso,
            source_path: None,
        };
        let error = database
            .register_media(
                &"c".repeat(64),
                42,
                Path::new("originals/aa/bb/c.jpg"),
                &candidate,
                Some("nso"),
            )
            .unwrap_err();
        assert!(error.to_string().contains("cycle"));
    }

    #[test]
    fn backfills_readable_mtp_display_names() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let connection = database.connection.lock().unwrap();
        connection
            .execute(
                "INSERT INTO media_asset(
                   sha256, size, media_type, captured_at, imported_at, game_name,
                   original_name, storage_path, status
                 ) VALUES (?1, 42, 'image', ?2, ?2, 'Zelda', ?3, ?3, 'ready')",
                params![
                    "3".repeat(64),
                    "2026-10-05T08:09:10+00:00",
                    "2026100516091007.jpg"
                ],
            )
            .unwrap();
        let media_id = connection.last_insert_rowid();
        connection
            .execute(
                "INSERT INTO media_source(
                   media_id, source_type, source_path, provider, discovered_at
                 ) VALUES (?1, 'mtp', ?2, 'Nintendo Switch 2', ?3)",
                params![
                    media_id,
                    "Nintendo Switch 2/Album/Zelda/2026100516091007.jpg",
                    Utc::now().to_rfc3339()
                ],
            )
            .unwrap();

        backfill_mtp_display_names(&connection).unwrap();
        let name: String = connection
            .query_row(
                "SELECT original_name FROM media_asset WHERE id=?1",
                [media_id],
                |row| row.get(0),
            )
            .unwrap();
        assert!(name.starts_with("Zelda - 2026-10-05 "));
        assert!(name.ends_with("[07].jpg"));
    }

    #[test]
    fn migrates_legacy_nso_hash_name_to_readable_name() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library.sqlite3");
        let sha256 = "a".repeat(64);
        {
            let database = Database::open(&path).unwrap();
            let connection = database.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO media_asset(
                       sha256, size, media_type, captured_at, imported_at,
                       game_name, original_name, storage_path
                     ) VALUES (?1, 42, 'image', ?2, ?2, 'Splatoon 3', ?3, 'originals/a.jpg')",
                    params![
                        &sha256,
                        "2026-10-04T07:30:12+00:00",
                        format!("{sha256}.jpg")
                    ],
                )
                .unwrap();
            let media_id = connection.last_insert_rowid();
            connection
                .execute(
                    "INSERT INTO media_source(
                       media_id, source_type, remote_id, provider, discovered_at
                     ) VALUES (?1, 'nso', 'remote-12345678', 'nso_coral', ?2)",
                    params![media_id, "2026-10-04T07:30:12+00:00"],
                )
                .unwrap();
            connection
                .execute("UPDATE schema_version SET version = 1", [])
                .unwrap();
        }

        let database = Database::open(&path).unwrap();
        let original_name: String = database
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT original_name FROM media_asset WHERE sha256 = ?1",
                [&sha256],
                |row| row.get(0),
            )
            .unwrap();
        assert!(original_name.starts_with("Splatoon 3 - 2026-10-04 "));
        assert!(original_name.ends_with("[12345678].jpg"));
    }
}
