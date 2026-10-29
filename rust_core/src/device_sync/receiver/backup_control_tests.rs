use super::*;
use crate::api::CoreApi;
use crate::device_sync::{
    planner::SyncMode,
    receiver::{ReceiveOperation, ReceiverError, Snapshot},
    recovery::{JournalStage, RecoveryOperation},
    work::{BackupWork, WorkControl},
};
use crate::sync::CancellationToken;

struct PendingBackup {
    _roots: [tempfile::TempDir; 3],
    api: CoreApi,
    operation: uuid::Uuid,
    backup: uuid::Uuid,
    payload_bytes: u64,
    backup_rows: u64,
    manifest_records: u64,
    generation: u64,
    original: std::path::PathBuf,
    tag_count: usize,
}

impl PendingBackup {
    async fn new() -> Self {
        Self::with_size(256, 512, 3, 1024 * 1024).await
    }

    async fn with_size(
        tag_count: usize,
        source_rows: usize,
        padded_rows: usize,
        minimum_payload_bytes: usize,
    ) -> Self {
        let roots = [
            tempfile::tempdir().unwrap(),
            tempfile::tempdir().unwrap(),
            tempfile::tempdir().unwrap(),
        ];
        let api = CoreApi::open(roots[0].path()).unwrap();
        let source = CoreApi::open(roots[1].path()).unwrap();
        let input = roots[2].path().join("synthetic-original.jpg");
        std::fs::write(&input, b"synthetic retained backup original").unwrap();
        api.import_local_files(vec![input.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let original = api
            .list_media(GalleryQuery::default())
            .unwrap()
            .remove(0)
            .storage_path;
        let database = api.database();
        {
            let mut connection = database.connection.lock().unwrap();
            let transaction = connection.transaction().unwrap();
            for index in 0..tag_count {
                transaction
                    .execute(
                        "INSERT INTO tag(name,normalized_name,created_at) VALUES(?1,?1,'2026-01-01T00:00:00Z')",
                        [format!("synthetic-{index:05}")],
                    )
                    .unwrap();
            }
            let mut statement = transaction
                .prepare(
                    "INSERT INTO media_source(media_id,source_type,source_path,remote_id,discovered_at)
                     SELECT id,'synthetic',?1,?2,'2026-01-01T00:00:00Z' FROM media_asset LIMIT 1",
                )
                .unwrap();
            let padding = "x".repeat(512 * 1024);
            for index in 0..source_rows {
                let path = if index < padded_rows {
                    format!("{index:03}-{padding}")
                } else {
                    format!("synthetic-{index:05}")
                };
                statement
                    .execute(params![path, format!("synthetic-{index}")])
                    .unwrap();
            }
            drop(statement);
            transaction.commit().unwrap();
        }
        source.create_tag("incoming".into()).unwrap();
        let mut receive = ReceiveOperation::prepare(
            database.clone(),
            Snapshot::read(&source.database(), "Source").unwrap(),
            "Target",
            SyncMode::Overwrite,
        )
        .unwrap();
        let mut authorization = receive.authorize().unwrap();
        let receipt = receive
            .apply(
                Some(&mut authorization),
                Some(uuid::Uuid::new_v4()),
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        let payload: Vec<u8> = database
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT payload FROM device_sync_backup WHERE backup_uuid=?1",
                [receipt.backup_uuid.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        let payload_bytes = payload.len() as u64;
        let backup: ReceiverBackup = serde_json::from_slice(&payload).unwrap();
        let backup_rows = backup
            .tables
            .iter()
            .map(|table| table.rows.len() as u64)
            .sum();
        let manifest_records = backup.snapshot.manifest.records.len() as u64;
        eprintln!(
            "actual fixture: {payload_bytes} payload bytes, {manifest_records} manifest records, {backup_rows} total backup rows"
        );
        assert!(payload_bytes > minimum_payload_bytes as u64);
        let generation = database.device_sync_header().unwrap().generation;
        Self {
            _roots: roots,
            api,
            operation: receipt.operation_uuid,
            backup: receipt.backup_uuid,
            payload_bytes,
            backup_rows,
            manifest_records,
            generation,
            original: original.into(),
            tag_count,
        }
    }

    fn unchanged_pending(&self) {
        let database = self.api.database();
        assert_eq!(
            database.device_sync_header().unwrap().generation,
            self.generation
        );
        let journal = database
            .device_sync_journal(self.operation)
            .unwrap()
            .unwrap();
        assert_eq!(journal.stage, JournalStage::LibraryApplied);
        assert_eq!(journal.backup_uuid, self.backup);
        assert_eq!(self.api.list_tags().unwrap(), ["incoming"]);
        assert_eq!(
            std::fs::read(&self.original).unwrap(),
            b"synthetic retained backup original"
        );
        assert!(self.api.create_tag("blocked while pending".into()).is_err());
        let total: i64 = database.connection.lock().unwrap().query_row(
            "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) SELECT sum(x) FROM n",
            [], |row| row.get(0),
        ).unwrap();
        assert_eq!(total, 50_005_000, "loader SQL handler must not leak");
        let lease = database.receiver_recovery_lease(self.operation).unwrap();
        drop(lease);
    }

    fn compensate(&self) {
        let mut recovery =
            RecoveryOperation::preview_pending(self.api.database(), self.operation, "Target")
                .unwrap();
        let mut authorization = recovery.authorize().unwrap();
        recovery
            .restore(Some(&mut authorization), &CancellationToken::default())
            .unwrap();
        assert!(!self.api.database().device_sync_recovery_pending());
        assert_eq!(self.api.list_tags().unwrap().len(), self.tag_count);
        self.api
            .create_tag("ordinary write after independent compensation".into())
            .unwrap();
    }
}

#[tokio::test]
async fn normal_backup_ownership_proof_cancellation_remains_typed_and_readonly() {
    let fixture = PendingBackup::new().await;
    let database = fixture.api.database();
    let external = database
        .device_sync_journal(fixture.operation)
        .unwrap()
        .unwrap()
        .external_reference;
    let mut pending =
        RecoveryOperation::preview_pending(database.clone(), fixture.operation, "Target").unwrap();
    let mut authorization = pending.authorize().unwrap();
    pending
        .finalize(Some(&mut authorization), external)
        .unwrap();
    drop(pending);
    let work = WorkControl::default();
    let restore = RecoveryOperation::preview_backup_controlled(
        database.clone(),
        fixture.backup,
        "Target",
        &work,
    )
    .unwrap();
    let owners = database.device_sync_backup_reference_owners().unwrap();
    let references = || {
        database.connection.lock().unwrap()
        .prepare("SELECT owner_uuid,file_path,sha256,length FROM device_sync_original_ref ORDER BY owner_uuid,file_path")
        .unwrap().query_map([], |row| Ok((
            row.get::<_, String>(0)?,row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,row.get::<_, i64>(3)?,
        ))).unwrap().collect::<Result<Vec<_>,_>>().unwrap()
    };
    let references_before = references();
    let changes_before: i64 = database
        .connection
        .lock()
        .unwrap()
        .query_row("SELECT total_changes()", [], |row| row.get(0))
        .unwrap();
    let counts = || {
        database.connection.lock().unwrap().query_row(
        "SELECT (SELECT count(*) FROM device_sync_backup),(SELECT count(*) FROM device_sync_apply_journal)",
        [], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
    ).unwrap()
    };
    let before_counts = counts();
    assert_eq!(
        database
            .device_sync_backup_metadata(fixture.backup)
            .unwrap()
            .includes_accounts,
        Some(true)
    );
    let result = std::thread::scope(|scope| {
        let worker = scope.spawn(|| restore.validate_preview());
        let until = std::time::Instant::now() + std::time::Duration::from_secs(30);
        loop {
            let observed = work.observe_backup();
            if observed.phase == BackupWork::Hashing && observed.completed >= 1024 * 1024 {
                work.cancellation().cancel();
                break;
            }
            assert!(
                !worker.is_finished(),
                "normal backup proof hashing must be observed"
            );
            assert!(
                std::time::Instant::now() < until,
                "normal proof hashing not reached"
            );
            std::thread::yield_now();
        }
        worker.join().unwrap()
    });
    let stopped = work.observe_backup();
    assert_eq!(stopped.phase, BackupWork::Hashing);
    assert!(stopped.completed >= 1024 * 1024 && stopped.completed < fixture.payload_bytes);
    assert_eq!(
        counts(),
        before_counts,
        "cancelled proof must create no safety or journal"
    );
    assert_eq!(
        database.device_sync_backup_reference_owners().unwrap(),
        owners
    );
    assert_eq!(references(), references_before);
    assert_eq!(
        database
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT total_changes()", [], |row| row.get::<_, i64>(0),)
            .unwrap(),
        changes_before,
        "cancelled proof is strictly read-only"
    );
    assert_eq!(
        database.device_sync_header().unwrap().generation,
        fixture.generation
    );
    assert_eq!(
        database
            .device_sync_journal(fixture.operation)
            .unwrap()
            .unwrap()
            .stage,
        JournalStage::Finalized
    );
    assert_eq!(
        database
            .device_sync_backup_metadata(fixture.backup)
            .unwrap()
            .includes_accounts,
        Some(true)
    );
    assert_eq!(fixture.api.list_tags().unwrap(), ["incoming"]);
    assert_eq!(
        std::fs::read(&fixture.original).unwrap(),
        b"synthetic retained backup original"
    );
    assert!(!database.device_sync_recovery_pending());
    fixture
        .api
        .create_tag("ordinary write after cancelled normal proof".into())
        .unwrap();
    assert!(
        matches!(result, Err(ReceiverError::Core(CoreError::Cancelled))),
        "normal proof must preserve typed cancellation, got {result:?}; stopped at {stopped:?}"
    );
}

// Ignoring the owner token anywhere inside the real loader must finish the
// remaining bytes/records/rows and fail these consumer-visible assertions.
#[tokio::test]
async fn controlled_backup_loader_cancels_actual_copy_hash_decode_manifest_and_rows() {
    let fixture = PendingBackup::new().await;
    for phase in [
        BackupWork::Copying,
        BackupWork::Hashing,
        BackupWork::Decoding,
        BackupWork::Manifest,
        BackupWork::Rows,
    ] {
        let bytes = matches!(
            phase,
            BackupWork::Copying | BackupWork::Hashing | BackupWork::Decoding
        );
        let work = WorkControl::default();
        let threshold = if bytes { 1024 * 1024 } else { 128 };
        let pause =
            crate::device_sync::work::test_observer::pause_backup_after(&work, phase, threshold);
        let database = fixture.api.database();
        let result = std::thread::scope(|scope| {
            let worker = scope.spawn(|| {
                RecoveryOperation::preview_pending_controlled(
                    database.clone(),
                    fixture.operation,
                    "Target",
                    &work,
                )
            });
            let observation = pause.wait();
            work.cancellation().cancel();
            pause.release(); // Also release reliably before asserting a timeout.
            let result = worker.join().unwrap();
            let observation = observation.expect("real loader checkpoint must be reached");
            assert_eq!(observation.phase, phase);
            assert_eq!(
                observation.completed, threshold,
                "real threshold, no estimate"
            );
            result
        });
        assert!(
            matches!(result, Err(ReceiverError::Core(CoreError::Cancelled))),
            "{phase:?}: cancellation must remain typed Cancelled"
        );
        let stopped = work.observe_backup();
        assert_eq!(stopped.phase, phase, "must not start the next loader phase");
        assert_eq!(stopped.completed, threshold, "no work after cancellation");
        let total = if bytes {
            fixture.payload_bytes
        } else if phase == BackupWork::Manifest {
            fixture.manifest_records
        } else {
            fixture.backup_rows
        };
        assert!(
            stopped.completed < total,
            "{phase:?} must stop before the remainder is processed: {stopped:?}"
        );
        fixture.unchanged_pending();
        eprintln!(
            "real backup loader {phase:?} stopped after {} actual units",
            stopped.completed
        );
    }
    fixture.compensate();
}

#[tokio::test]
async fn existing_headless_restore_owner_cancels_validate_mid_sql_without_consuming_preview() {
    use crate::device_sync::{headless, read_model::ReadError};
    use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
    let roots = [
        tempfile::tempdir().unwrap(),
        tempfile::tempdir().unwrap(),
        tempfile::tempdir().unwrap(),
    ];
    let target = CoreApi::open(roots[0].path()).unwrap();
    let source = CoreApi::open(roots[1].path()).unwrap();
    let input = roots[2].path().join("owner-original.jpg");
    std::fs::write(&input, b"synthetic original for existing owner").unwrap();
    target
        .import_local_files(vec![input.to_string_lossy().into_owned()])
        .await
        .unwrap();
    let original = target
        .list_media(GalleryQuery::default())
        .unwrap()
        .remove(0)
        .storage_path;
    target.create_tag("original target".into()).unwrap();
    source.create_tag("incoming".into()).unwrap();
    let mut receive = ReceiveOperation::prepare(
        target.database(),
        Snapshot::read(&source.database(), "Source").unwrap(),
        "Target",
        SyncMode::Overwrite,
    )
    .unwrap();
    let mut authorization = receive.authorize().unwrap();
    let receipt = receive
        .apply(
            Some(&mut authorization),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    for index in 0..260 {
        target
            .create_tag(format!("existing-owner-{index:03}"))
            .unwrap();
    }
    let generation = target.database().device_sync_header().unwrap().generation;
    let operation = receipt.operation_uuid;
    headless::owner_test_tools::with_existing_restore(
        roots[0].path().to_string_lossy().into_owned(),
        &receipt.backup_uuid.to_string(),
        |database, library, preview| {
            let counts = || {
                database.connection.lock().unwrap().query_row(
                    "SELECT (SELECT count(*) FROM device_sync_backup),(SELECT count(*) FROM device_sync_apply_journal)",
                    [], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
                ).unwrap()
            };
            let before = counts();
            let (reached, entered) = std::sync::mpsc::sync_channel(1);
            let (release, released) = std::sync::mpsc::sync_channel(1);
            let mut tags = 0;
            database.connection.lock().unwrap().authorizer(Some(
                move |context: AuthContext<'_>| {
                    if matches!(
                        context.action,
                        AuthAction::Read {
                            table_name: "sync_tag_state",
                            column_name: "name"
                        }
                    ) {
                        tags += 1;
                        if tags == 129 {
                            reached.send(tags).unwrap();
                            released
                                .recv_timeout(std::time::Duration::from_secs(10))
                                .unwrap();
                        }
                    }
                    Authorization::Allow
                },
            ));
            let result = std::thread::scope(|scope| {
                let worker =
                    scope.spawn(|| headless::validate_restore(&preview.handle, &preview.binding));
                assert_eq!(
                    entered
                        .recv_timeout(std::time::Duration::from_secs(10))
                        .unwrap(),
                    129
                );
                headless::cancel_restore(&preview.handle).unwrap();
                release.send(()).unwrap();
                worker.join().unwrap()
            });
            database
                .connection
                .lock()
                .unwrap()
                .authorizer(None::<fn(AuthContext<'_>) -> Authorization>);
            assert!(result.is_err(), "an already-existing restore owner's cancellation must reach validate→access during its real SQL scan");
            assert_eq!(
                headless::read_restore_summary(&preview.handle, &preview.binding).error,
                Some(ReadError::Cancelled)
            );
            assert_eq!(
                counts(),
                before,
                "validation must create neither backups nor journals"
            );
            assert_eq!(
                database.device_sync_header().unwrap().generation,
                generation
            );
            assert_eq!(
                database
                    .device_sync_journal(operation)
                    .unwrap()
                    .unwrap()
                    .stage,
                JournalStage::Finalized
            );
            assert_eq!(
                std::fs::read(&original).unwrap(),
                b"synthetic original for existing owner"
            );
            assert!(!database.device_sync_recovery_pending());
            target
                .create_tag("ordinary write after owner cancellation".into())
                .unwrap();
            let fresh =
                headless::preview_restore(library, &receipt.backup_uuid.to_string()).unwrap();
            headless::validate_restore(&fresh.handle, &fresh.binding).unwrap();
            assert!(
                headless::read_restore_summary(&fresh.handle, &fresh.binding)
                    .error
                    .is_none()
            );
            headless::close_restore(&fresh.handle).unwrap();
        },
    );
}

async fn headless_restore_response_case(late_cancel: bool) {
    use crate::device_sync::{headless, read_model::ReadError};
    use rusqlite::hooks::{Action, AuthAction, AuthContext, Authorization};
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };
    let roots = [
        tempfile::tempdir().unwrap(),
        tempfile::tempdir().unwrap(),
        tempfile::tempdir().unwrap(),
    ];
    let target = CoreApi::open(roots[0].path()).unwrap();
    let source = CoreApi::open(roots[1].path()).unwrap();
    let input = roots[2].path().join("late-cancel-original.jpg");
    std::fs::write(&input, b"retained original across restore response").unwrap();
    target
        .import_local_files(vec![input.to_string_lossy().into_owned()])
        .await
        .unwrap();
    let original = target
        .list_media(GalleryQuery::default())
        .unwrap()
        .remove(0)
        .storage_path;
    target.create_tag("original target".into()).unwrap();
    source.create_tag("incoming".into()).unwrap();
    let mut receive = ReceiveOperation::prepare(
        target.database(),
        Snapshot::read(&source.database(), "Source").unwrap(),
        "Target",
        SyncMode::Overwrite,
    )
    .unwrap();
    let mut authorization = receive.authorize().unwrap();
    let first = receive
        .apply(
            Some(&mut authorization),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    headless::owner_test_tools::with_restore_response(
        roots[0].path().to_string_lossy().into_owned(),
        &first.backup_uuid.to_string(),
        |database, library, preview, owner_cancel| {
            let before_generation = database.device_sync_header().unwrap().generation;
            let counts = || {
                database.connection.lock().unwrap().query_row(
                "SELECT (SELECT count(*) FROM device_sync_backup),(SELECT count(*) FROM device_sync_apply_journal)",
                [], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            ).unwrap()
            };
            let before_counts = counts();
            let handle = preview.handle.clone();
            let reached = Arc::new(AtomicUsize::new(0));
            let observed = reached.clone();
            if late_cancel {
                database.connection.lock().unwrap().update_hook(Some(
                    move |action, _: &str, table: &str, _| {
                        if action == Action::SQLITE_UPDATE
                            && table == "device_sync_apply_journal"
                            && observed.fetch_add(1, Ordering::SeqCst) + 1 == 2
                        {
                            // The data transaction has already committed. This
                            // callback runs inside the subsequent finalized SQL,
                            // not after that statement's autocommit.
                            headless::cancel_restore(&handle).unwrap();
                        }
                    },
                ));
            } else {
                database.connection.lock().unwrap().authorizer(Some(
                    move |context: AuthContext<'_>| {
                        if matches!(
                            context.action,
                            AuthAction::Read {
                                table_name: "device_sync_backup",
                                column_name: "payload"
                            }
                        ) && observed.fetch_add(1, Ordering::SeqCst) == 0
                        {
                            // A real restore has entered access/payload loading but
                            // has not captured a safety backup or written data.
                            headless::cancel_restore(&handle).unwrap();
                        }
                        Authorization::Allow
                    },
                ));
            }
            let result = headless::apply_restore(&preview.handle, &preview.binding, None);
            {
                let connection = database.connection.lock().unwrap();
                connection.update_hook(None::<fn(Action, &str, &str, i64)>);
                connection.authorizer(None::<fn(AuthContext<'_>) -> Authorization>);
            }
            assert!(
                reached.load(Ordering::SeqCst) > 0,
                "must cancel at the actual SQL boundary"
            );
            assert!(matches!(owner_cancel.check(), Err(CoreError::Cancelled)));
            let operation = uuid::Uuid::parse_str(&preview.operation).unwrap();
            if late_cancel {
                assert_eq!(reached.load(Ordering::SeqCst), 2);
                assert_eq!(
                    database
                        .device_sync_journal(operation)
                        .unwrap()
                        .unwrap()
                        .stage,
                    JournalStage::Finalized
                );
                assert_eq!(target.list_tags().unwrap(), ["original target"]);
                assert_eq!(target.list_media(GalleryQuery::default()).unwrap().len(), 1);
                assert!(!database.device_sync_recovery_pending());
                assert_eq!(
                    std::fs::read(&original).unwrap(),
                    b"retained original across restore response"
                );
                assert!(result.is_ok(), "a committed/finalized restore must return its real receipt despite late owner cancellation: {result:?}");
                let restored = result.unwrap();
                assert_eq!(restored.operation, preview.operation);
                assert_eq!(restored.library, preview.library);
                assert_eq!(restored.binding, preview.binding);
                assert_eq!(restored.current_digest, preview.current_digest);
                assert_eq!(restored.restored_digest, preview.restored_digest);
                let safety = restored.backup.as_deref().unwrap();
                assert_eq!(
                    headless::backup_journal(library, safety).unwrap().operation,
                    restored.operation
                );
                assert_eq!(
                    headless::read_restore_summary(&preview.handle, &preview.binding).error,
                    Some(ReadError::PreviewChanged)
                );
                assert!(
                    headless::apply_restore(&preview.handle, &preview.binding, None).is_err(),
                    "the real receipt must prevent duplicate apply"
                );
                target
                    .create_tag("ordinary write after finalized cancellation".into())
                    .unwrap();
                let reverse = headless::preview_restore(library, safety).unwrap();
                headless::validate_restore(&reverse.handle, &reverse.binding).unwrap();
                headless::apply_restore(&reverse.handle, &reverse.binding, None).unwrap();
                headless::close_restore(&reverse.handle).unwrap();
                assert_eq!(target.list_tags().unwrap(), ["incoming"]);
                assert_eq!(
                    std::fs::read(&original).unwrap(),
                    b"retained original across restore response"
                );
                eprintln!("real no-account restore: cancellation in finalized UPDATE after data commit preserved successful original-capability response and recoverable safety");
            } else {
                assert!(
                    result.is_err(),
                    "precommit owner cancellation must never invent a success receipt"
                );
                assert!(database.device_sync_journal(operation).unwrap().is_none());
                assert_eq!(counts(), before_counts);
                assert_eq!(
                    database.device_sync_header().unwrap().generation,
                    before_generation
                );
                assert_eq!(target.list_tags().unwrap(), ["incoming"]);
                assert!(target
                    .list_media(GalleryQuery::default())
                    .unwrap()
                    .is_empty());
                assert!(!database.device_sync_recovery_pending());
                assert_eq!(
                    headless::read_restore_summary(&preview.handle, &preview.binding).error,
                    Some(ReadError::Cancelled)
                );
                target
                    .create_tag("ordinary write after precommit cancellation".into())
                    .unwrap();
            }
        },
    );
}

#[tokio::test]
async fn headless_finalized_restore_response_survives_owner_cancel_in_finalized_sql() {
    headless_restore_response_case(true).await;
}

#[tokio::test]
async fn headless_precommit_restore_cancel_does_not_fabricate_success_receipt() {
    headless_restore_response_case(false).await;
}

#[test]
fn controlled_backup_loader_preserves_exact_content_and_rejects_malicious_payloads() {
    use sha2::{Digest, Sha256};
    let root = tempfile::tempdir().unwrap();
    let api = CoreApi::open(root.path()).unwrap();
    api.create_tag("synthetic stable content".into()).unwrap();
    let database = api.database();
    let snapshot = Snapshot::read(&database, "Synthetic").unwrap();
    let tables = capture_receiver_tables(
        &database.connection.lock().unwrap(),
        &CancellationToken::default(),
    )
    .unwrap();
    let payload = bounded_backup_json(&ReceiverBackup {
        version: 1,
        snapshot,
        tables,
    })
    .unwrap();
    let library = database.device_sync_header().unwrap().library_uuid;
    let backup = uuid::Uuid::new_v4();
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "CREATE TABLE device_sync_backup(
         backup_uuid TEXT PRIMARY KEY,version INTEGER,library_uuid TEXT,digest TEXT,payload BLOB)",
        )
        .unwrap();
    let save = |connection: &Connection, bytes: &[u8]| {
        connection
            .execute(
                "INSERT OR REPLACE INTO device_sync_backup VALUES(?1,1,?2,?3,?4)",
                params![
                    backup.to_string(),
                    library,
                    hex::encode(Sha256::digest(bytes)),
                    bytes
                ],
            )
            .unwrap();
    };
    save(&connection, &payload);
    let legacy = load_receiver_backup(&mut connection, backup, &library).unwrap();
    let controlled =
        load_receiver_backup_controlled(&mut connection, backup, &library, &WorkControl::default())
            .unwrap();
    assert_eq!(serde_json::to_vec(&legacy).unwrap(), payload);
    assert_eq!(serde_json::to_vec(&controlled).unwrap(), payload);
    let original: serde_json::Value = serde_json::from_slice(&payload).unwrap();
    for case in 0..7 {
        let mut invalid = original.clone();
        match case {
            0 => invalid["version"] = 2.into(),
            1 => invalid["snapshot"]["sources"]["manifest_digest"] = "0".repeat(64).into(),
            2 => invalid["unexpected"] = true.into(),
            3 => invalid["tables"][0]["name"] = "app_setting".into(),
            4 => invalid["tables"][1]["rows"][0] = serde_json::json!([]),
            5 => invalid["tables"][1]["rows"][0][1] = "x".repeat(MAX_LOCAL_CELL_BYTES + 1).into(),
            6 => invalid["snapshot"]["manifest"]["records"]
                .as_array_mut()
                .unwrap()
                .push(original["snapshot"]["manifest"]["records"][0].clone()),
            _ => unreachable!(),
        }
        save(&connection, &serde_json::to_vec(&invalid).unwrap());
        let result = load_receiver_backup_controlled(
            &mut connection,
            backup,
            &library,
            &WorkControl::default(),
        );
        assert!(
            result.is_err(),
            "malicious case {case} must retain its original validation"
        );
        assert!(!matches!(result, Err(CoreError::Cancelled)));
    }
    save(&connection, &payload);
    connection
        .execute("UPDATE device_sync_backup SET digest=?1", ["0".repeat(64)])
        .unwrap();
    assert!(load_receiver_backup_controlled(
        &mut connection,
        backup,
        &library,
        &WorkControl::default(),
    )
    .is_err());
    connection
        .execute(
            "UPDATE device_sync_backup SET payload=zeroblob(?1)",
            [MAX_RECEIVER_BACKUP_BYTES + 1],
        )
        .unwrap();
    assert!(load_receiver_backup_controlled(
        &mut connection, backup, &library, &WorkControl::default(),
    ).is_err(), "128MiB bound must reject before payload copying");
}
