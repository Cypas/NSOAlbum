use super::*;
use crate::api::CoreApi;
use crate::device_sync::{
    headless,
    planner::SyncMode,
    read_model::ReadError,
    receiver::{ReceiveOperation, Snapshot},
    recovery::RecoveryOperation,
    work::{WorkControl, WorkStage},
};
use crate::sync::CancellationToken;

#[test]
fn task5a4_missing_ownership_is_local_to_one_backup_and_cursor_advances() {
    let source_root = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let target = CoreApi::open(root.path()).unwrap();
    let mut backups = Vec::new();
    for index in 0..3 {
        target.create_tag(format!("before-{index}")).unwrap();
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
        backups.push(receipt.backup_uuid);
    }
    target
        .database()
        .connection
        .lock()
        .unwrap()
        .execute(
            "DELETE FROM device_sync_apply_journal WHERE backup_uuid=?1",
            [backups[1].to_string()],
        )
        .unwrap();
    let opened = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    let mut after = None;
    let mut count = 0;
    let mut cursors = std::collections::BTreeSet::new();
    loop {
        let read = headless::read_backups(&opened.handle, after.as_deref(), 1);
        assert!(
            read.error.is_none(),
            "one unproven backup must not hide its neighbors: {:?}",
            read.error
        );
        let page = read.value.unwrap();
        assert_eq!(page.items.len(), 1);
        count += page.items.len();
        after = page.next;
        if let Some(cursor) = &after {
            assert!(cursors.insert(cursor.clone()), "cursor must move forward");
        } else {
            break;
        }
        assert!(count <= 3);
    }
    assert_eq!(count, 3);
    headless::close_library(&opened.handle).unwrap();
}

#[test]
fn backup_metadata_scan_orders_real_created_at_newest_first() {
    let source_root = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let api = CoreApi::open(root.path()).unwrap();
    let mut backups = Vec::new();
    for label in ["old", "new"] {
        api.create_tag(label.into()).unwrap();
        let mut receive = ReceiveOperation::prepare(
            api.database(),
            Snapshot::read(&source.database(), "Source").unwrap(),
            "Target",
            SyncMode::Overwrite,
        )
        .unwrap();
        let mut authorization = receive.authorize().unwrap();
        backups.push(
            receive
                .apply(
                    Some(&mut authorization),
                    None,
                    &CancellationToken::default(),
                    &mut |_| {},
                )
                .unwrap()
                .backup_uuid,
        );
    }
    let database = api.database();
    let connection = database.connection.lock().unwrap();
    connection
        .execute(
            "UPDATE device_sync_backup SET created_at=?1 WHERE backup_uuid=?2",
            rusqlite::params!["2026-01-01T00:00:00Z", backups[0].to_string()],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE device_sync_backup SET created_at=?1 WHERE backup_uuid=?2",
            rusqlite::params!["2026-02-01T00:00:00Z", backups[1].to_string()],
        )
        .unwrap();
    drop(connection);
    let page = api
        .database()
        .device_sync_backup_metadata_scan(None, 2)
        .unwrap();
    assert_eq!(
        page.iter()
            .map(|(_, item)| item.created_at.as_deref())
            .collect::<Vec<_>>(),
        vec![Some("2026-02-01T00:00:00Z"), Some("2026-01-01T00:00:00Z")]
    );
}

#[test]
fn task5a4_internal_compensation_cannot_be_manually_restored() {
    let source_root = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let target = CoreApi::open(root.path()).unwrap();
    target.create_tag("old".into()).unwrap();
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
            Some(uuid::Uuid::new_v4()),
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    drop(receive);
    let mut recovery =
        RecoveryOperation::preview_pending(target.database(), receipt.operation_uuid, "Target")
            .unwrap();
    let mut authorization = recovery.authorize().unwrap();
    let safety = recovery
        .restore(Some(&mut authorization), &CancellationToken::default())
        .unwrap()
        .backup_uuid;
    assert!(
        RecoveryOperation::preview_backup(target.database(), safety, "Target").is_err(),
        "partially coordinated safety has no complete account version and must be refused by Rust"
    );
    assert_eq!(target.list_tags().unwrap(), ["old"]);
    assert!(target
        .database()
        .device_sync_backup_reference_owners()
        .unwrap()
        .contains(&safety));
    drop(recovery);
    drop(target);
    let restarted = CoreApi::open(root.path()).unwrap();
    let internal = restarted
        .database()
        .device_sync_backup_metadata(safety)
        .unwrap();
    assert_eq!(internal.includes_accounts, None);
    assert_eq!(
        internal.unavailable_reason,
        Some(crate::device_sync::read_model::BackupUnavailableReason::InternalCompensation)
    );
    assert!(RecoveryOperation::preview_backup(restarted.database(), safety, "Target").is_err());
    assert!(
        restarted
            .database()
            .device_sync_backup_metadata(receipt.backup_uuid)
            .unwrap()
            .unavailable_reason
            .is_none(),
        "the proven original backup remains usable after rollback"
    );
    assert!(restarted
        .database()
        .device_sync_backup_reference_owners()
        .unwrap()
        .contains(&safety));
}

#[test]
fn task5a4_account_backup_requires_external_coordination_in_rust() {
    let source_root = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let target = CoreApi::open(root.path()).unwrap();
    target.create_tag("old".into()).unwrap();
    let mut receive = ReceiveOperation::prepare(
        target.database(),
        Snapshot::read(&source.database(), "Source").unwrap(),
        "Target",
        SyncMode::Overwrite,
    )
    .unwrap();
    let external = uuid::Uuid::new_v4();
    let mut authorization = receive.authorize().unwrap();
    let receipt = receive
        .apply(
            Some(&mut authorization),
            Some(external),
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    drop(receive);
    let mut finalization =
        RecoveryOperation::preview_pending(target.database(), receipt.operation_uuid, "Target")
            .unwrap();
    let mut authorization = finalization.authorize().unwrap();
    finalization
        .finalize(Some(&mut authorization), Some(external))
        .unwrap();
    drop(finalization);
    let before = Snapshot::read(&target.database(), "Target").unwrap();
    let mut recovery =
        RecoveryOperation::preview_backup(target.database(), receipt.backup_uuid, "Target")
            .unwrap();
    let mut authorization = recovery.authorize().unwrap();
    assert!(
        recovery
            .restore(Some(&mut authorization), &CancellationToken::default(),)
            .is_err(),
        "native library-only restore must not silently discard account scope"
    );
    assert_eq!(
        Snapshot::read_with_header(
            &target.database(),
            before.manifest.header.clone(),
            Some("Target"),
        )
        .unwrap(),
        before
    );
    assert!(target
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
}

#[test]
fn task5a4_mixed_bad_rows_are_bounded_local_and_do_not_expose_unknown_scope() {
    use crate::device_sync::read_model::BackupUnavailableReason as Reason;
    let source_root = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let target = CoreApi::open(root.path()).unwrap();
    let database = target.database();
    let mut backups = Vec::new();
    for index in 0..12 {
        target.create_tag(format!("state-{index}")).unwrap();
        let mut receive = ReceiveOperation::prepare(
            database.clone(),
            Snapshot::read(&source.database(), "Source").unwrap(),
            "Target",
            SyncMode::Overwrite,
        )
        .unwrap();
        let mut authorization = receive.authorize().unwrap();
        backups.push(
            receive
                .apply(
                    Some(&mut authorization),
                    None,
                    &CancellationToken::default(),
                    &mut |_| {},
                )
                .unwrap()
                .backup_uuid
                .to_string(),
        );
    }
    {
        let connection = database.connection.lock().unwrap();
        connection
            .execute(
                "DELETE FROM device_sync_backup_ownership WHERE backup_uuid=?1",
                [&backups[1]],
            )
            .unwrap();
        connection
            .execute(
                "DELETE FROM device_sync_apply_journal WHERE backup_uuid=?1",
                [&backups[1]],
            )
            .unwrap();
        connection
            .execute(
                "UPDATE device_sync_backup SET payload=x'7b7d' WHERE backup_uuid=?1",
                [&backups[2]],
            )
            .unwrap();
        connection
            .pragma_update(None, "foreign_keys", false)
            .unwrap();
        connection
            .execute(
                "UPDATE device_sync_backup SET backup_uuid=?2 WHERE backup_uuid=?1",
                params![backups[3], "x".repeat(1024 * 1024)],
            )
            .unwrap();
        connection
            .execute(
                "UPDATE device_sync_backup SET library_uuid=?2 WHERE backup_uuid=?1",
                params![backups[4], uuid::Uuid::new_v4().to_string()],
            )
            .unwrap();
        connection
            .execute(
                "UPDATE device_sync_backup SET version=99 WHERE backup_uuid=?1",
                [&backups[5]],
            )
            .unwrap();
        connection
            .execute(
                "UPDATE device_sync_backup SET created_at='not-a-time' WHERE backup_uuid=?1",
                [&backups[6]],
            )
            .unwrap();
        connection
            .execute(
                "UPDATE device_sync_backup_ownership SET version=2 WHERE backup_uuid=?1",
                [&backups[7]],
            )
            .unwrap();
        connection.execute("UPDATE device_sync_apply_journal SET external_reference='invalid' WHERE backup_uuid=?1", [&backups[8]]).unwrap();
        connection.execute(
            "INSERT INTO device_sync_apply_journal SELECT ?2,version,library_uuid,stage,backup_uuid,preview_digest,external_reference
             FROM device_sync_apply_journal WHERE backup_uuid=?1",
            params![backups[9], uuid::Uuid::new_v4().to_string()],
        ).unwrap();
        connection
            .execute(
                "UPDATE device_sync_backup SET backup_uuid=x'ff' WHERE backup_uuid=?1",
                [&backups[10]],
            )
            .unwrap();
        connection
            .pragma_update(None, "foreign_keys", true)
            .unwrap();
    }
    let opened = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    let generation = database.device_sync_header().unwrap().generation;
    let data_version: i64 = database
        .connection
        .lock()
        .unwrap()
        .pragma_query_value(None, "data_version", |row| row.get(0))
        .unwrap();
    let mut after = None;
    let mut cursors = std::collections::BTreeSet::new();
    let mut items = Vec::new();
    loop {
        let read = headless::read_backups(&opened.handle, after.as_deref(), 2);
        assert!(read.error.is_none(), "{:?}", read.error);
        assert!(serde_json::to_vec(&read).unwrap().len() <= 65_536);
        let page = read.value.unwrap();
        assert!((1..=2).contains(&page.items.len()));
        items.extend(page.items);
        after = page.next;
        if let Some(cursor) = &after {
            assert!(cursors.insert(cursor.clone()));
        } else {
            break;
        }
        assert!(items.len() <= 12);
    }
    assert_eq!(
        items.len(),
        12,
        "ambiguous journals must not duplicate rows"
    );
    let available: Vec<_> = items
        .iter()
        .filter(|item| item.unavailable_reason.is_none())
        .map(|item| item.backup.clone().unwrap())
        .collect();
    assert_eq!(available, [backups[11].clone(), backups[0].clone()]);
    let reasons: Vec<_> = items
        .iter()
        .filter_map(|item| item.unavailable_reason)
        .collect();
    for reason in [
        Reason::InvalidIdentity,
        Reason::JournalInvalid,
        Reason::OwnershipInvalid,
        Reason::InvalidMetadata,
        Reason::InvalidPayload,
        Reason::OwnershipUnknown,
    ] {
        assert!(reasons.contains(&reason));
    }
    assert_eq!(items.iter().filter(|item| item.backup.is_none()).count(), 2);
    assert!(items
        .iter()
        .filter(|item| item.unavailable_reason.is_some())
        .all(|item| item.includes_accounts.is_none()));
    for _ in 0..3 {
        assert!(headless::read_backups(&opened.handle, None, 128)
            .error
            .is_none());
    }
    assert_eq!(
        database.device_sync_header().unwrap().generation,
        generation
    );
    assert_eq!(
        database
            .connection
            .lock()
            .unwrap()
            .pragma_query_value(None, "data_version", |row| row.get::<_, i64>(0))
            .unwrap(),
        data_version
    );
    headless::close_library(&opened.handle).unwrap();
}

#[test]
fn task5a4_restore_rechecks_ownership_in_same_capability_without_writes() {
    let source_root = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let target = CoreApi::open(root.path()).unwrap();
    target.create_tag("old".into()).unwrap();
    let database = target.database();
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
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    drop(receive);
    let mut restore =
        RecoveryOperation::preview_backup(database.clone(), receipt.backup_uuid, "Target").unwrap();
    let before = Snapshot::read(&database, "Target").unwrap();
    database.connection.lock().unwrap().execute(
        "UPDATE device_sync_backup_ownership SET kind='compensation',source_backup_uuid=?2 WHERE backup_uuid=?1",
        params![receipt.backup_uuid.to_string(), uuid::Uuid::new_v4().to_string()],
    ).unwrap_err(); // A missing provenance target cannot be inserted.
    database
        .connection
        .lock()
        .unwrap()
        .execute(
            "UPDATE device_sync_backup_ownership SET version=2 WHERE backup_uuid=?1",
            [receipt.backup_uuid.to_string()],
        )
        .unwrap();
    assert!(restore.validate_preview().is_err());
    let mut authorization = restore.authorize().unwrap();
    assert!(restore
        .restore(Some(&mut authorization), &CancellationToken::default())
        .is_err());
    assert_eq!(
        Snapshot::read_with_header(&database, before.manifest.header.clone(), Some("Target"),)
            .unwrap(),
        before
    );
    assert!(database.device_sync_pending_journal().unwrap().is_none());
    assert_eq!(
        database
            .device_sync_backup_metadata_page(None, 129)
            .unwrap()
            .len(),
        1
    );
}

#[tokio::test]
async fn task5a4_normal_and_user_safety_restore_exact_originals_and_all_metadata() {
    let source_root = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let input = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let target = CoreApi::open(root.path()).unwrap();
    let old_file = input.path().join("old.jpg");
    std::fs::write(&old_file, b"old original bytes").unwrap();
    target
        .import_local_files(vec![old_file.to_string_lossy().into_owned()])
        .await
        .unwrap();
    let old = target
        .list_media(GalleryQuery::default())
        .unwrap()
        .remove(0);
    target.set_note(old.id, "old note".into()).unwrap();
    target.set_favorite(old.id, true).unwrap();
    target.add_tag(old.id, "old custom".into()).unwrap();
    let old_album = target
        .create_album("Old album".into(), "Old description".into(), false)
        .unwrap();
    target.add_media_to_album(old_album, old.id).unwrap();
    let mut receive = ReceiveOperation::prepare(
        target.database(),
        Snapshot::read(&source.database(), "Source").unwrap(),
        "Target",
        SyncMode::Overwrite,
    )
    .unwrap();
    let mut authorization = receive.authorize().unwrap();
    let backup = receive
        .apply(
            Some(&mut authorization),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap()
        .backup_uuid;
    drop(receive);
    let new_file = input.path().join("new.jpg");
    std::fs::write(&new_file, b"new original bytes").unwrap();
    target
        .import_local_files(vec![new_file.to_string_lossy().into_owned()])
        .await
        .unwrap();
    let new = target
        .list_media(GalleryQuery::default())
        .unwrap()
        .remove(0);
    target.set_note(new.id, "new note".into()).unwrap();
    target.add_tag(new.id, "new custom".into()).unwrap();
    let new_album = target
        .create_album("New album".into(), "New description".into(), false)
        .unwrap();
    target.add_media_to_album(new_album, new.id).unwrap();
    let mut restore =
        RecoveryOperation::preview_backup(target.database(), backup, "Target").unwrap();
    assert!(restore
        .restore(None, &CancellationToken::default())
        .is_err());
    let mut authorization = restore.authorize().unwrap();
    let safety = restore
        .restore(Some(&mut authorization), &CancellationToken::default())
        .unwrap()
        .backup_uuid;
    let restored = target
        .list_media(GalleryQuery::default())
        .unwrap()
        .remove(0);
    assert_eq!(restored.sha256, old.sha256);
    assert_eq!(restored.note.as_deref(), Some("old note"));
    assert!(restored.favorite);
    assert_eq!(restored.tags, ["old custom"]);
    assert_eq!(
        std::fs::read(&restored.storage_path).unwrap(),
        b"old original bytes"
    );
    assert_eq!(
        target
            .list_media(GalleryQuery {
                album_id: Some(old_album),
                ..Default::default()
            })
            .unwrap()
            .len(),
        1
    );
    let albums = target.list_albums().unwrap();
    assert!(albums
        .iter()
        .any(|album| album.name == "Old album" && album.description == "Old description"));
    assert!(!albums.iter().any(|album| album.name == "New album"));
    let metadata = target
        .database()
        .device_sync_backup_metadata(safety)
        .unwrap();
    assert_eq!(metadata.includes_accounts, Some(false));
    assert!(metadata.unavailable_reason.is_none());
    let mut reverse =
        RecoveryOperation::preview_backup(target.database(), safety, "Target").unwrap();
    let mut authorization = reverse.authorize().unwrap();
    reverse
        .restore(Some(&mut authorization), &CancellationToken::default())
        .unwrap();
    let restored = target
        .list_media(GalleryQuery::default())
        .unwrap()
        .remove(0);
    assert_eq!(restored.sha256, new.sha256);
    assert_eq!(restored.note.as_deref(), Some("new note"));
    assert!(!restored.favorite);
    assert_eq!(restored.tags, ["new custom"]);
    assert_eq!(
        std::fs::read(&restored.storage_path).unwrap(),
        b"new original bytes"
    );
    assert_eq!(
        target
            .list_media(GalleryQuery {
                album_id: Some(new_album),
                ..Default::default()
            })
            .unwrap()
            .len(),
        1
    );
    let albums = target.list_albums().unwrap();
    assert!(albums
        .iter()
        .any(|album| album.name == "New album" && album.description == "New description"));
    assert!(!albums.iter().any(|album| album.name == "Old album"));
    assert_eq!(
        std::fs::read(&old.storage_path).unwrap(),
        b"old original bytes"
    );
}

fn pending_account_finalize_scan_cancel(second_scan: bool) {
    use crate::device_sync::{
        clock::Clock,
        driver::{Direction, Driver, DriverError, State},
        manifest::ManifestRecord,
        recovery::JournalStage,
        Invitation, Qr, Role, Session, Transport,
    };
    use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
    use std::sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        Arc,
    };
    struct FinalizeClock {
        start: i64,
        elapsed: AtomicU64,
    }
    impl Clock for FinalizeClock {
        fn monotonic_ms(&self) -> u64 {
            self.elapsed.load(Ordering::SeqCst)
        }
        fn unix_ms(&self) -> i64 {
            self.start + self.monotonic_ms() as i64
        }
    }
    fn pump(a: &mut Driver, b: &mut Driver) {
        a.poll().unwrap();
        let bytes = a.drain_ciphertext().unwrap();
        for chunk in bytes.chunks(crate::device_sync::MAX_CIPHERTEXT) {
            b.ingest_ciphertext(chunk).unwrap();
        }
        a.ciphertext_written(bytes.len()).unwrap();
        std::thread::yield_now();
    }
    let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
    let source = CoreApi::open(roots[0].path()).unwrap();
    let target = CoreApi::open(roots[1].path()).unwrap();
    for index in 0..1024 {
        source.create_tag(format!("incoming-{index:04}")).unwrap();
    }
    target.create_tag("old target".into()).unwrap();
    let clock = Arc::new(FinalizeClock {
        start: Utc::now().timestamp_millis(),
        elapsed: AtomicU64::new(0),
    });
    let now = clock.unix_ms() / 1000;
    let mut invitation = Invitation::create(Transport::Usb, now).unwrap();
    let qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), now).unwrap();
    let mut a = invitation.accept(Role::Sender, "Source", now).unwrap();
    let mut b = Session::client(qr, Role::Receiver, "Target", now).unwrap();
    for _ in 0..12 {
        let bytes = a.drain_ciphertext(now).unwrap();
        if !bytes.is_empty() {
            b.ingest_ciphertext(&bytes, now).unwrap();
        }
        let bytes = b.drain_ciphertext(now).unwrap();
        if !bytes.is_empty() {
            a.ingest_ciphertext(&bytes, now).unwrap();
        }
    }
    a.confirm(now).unwrap();
    b.confirm(now).unwrap();
    for _ in 0..12 {
        let bytes = a.drain_ciphertext(now).unwrap();
        if !bytes.is_empty() {
            b.ingest_ciphertext(&bytes, now).unwrap();
        }
        let bytes = b.drain_ciphertext(now).unwrap();
        if !bytes.is_empty() {
            a.ingest_ciphertext(&bytes, now).unwrap();
        }
    }
    let mut a = Driver::new(a, source.database(), "Source", clock.clone()).unwrap();
    let mut b = Driver::new(b, target.database(), "Target", clock.clone()).unwrap();
    a.authorize_accounts_export(br#"{"version":1,"accounts":[]}"#, &"a".repeat(64))
        .unwrap();
    b.authorize_accounts_receive(&"b".repeat(64)).unwrap();
    a.configure(Direction::DesktopToPhone, SyncMode::Overwrite, true)
        .unwrap();
    let until = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while b.state() != State::AwaitingApproval {
        pump(&mut a, &mut b);
        pump(&mut b, &mut a);
        assert!(std::time::Instant::now() < until);
    }
    let external = uuid::Uuid::new_v4();
    let binding = b.preview_binding().unwrap().to_owned();
    b.approve_accounts_preview(&binding, &"b".repeat(64), external)
        .unwrap();
    while b.state() != State::AwaitingExternal {
        pump(&mut a, &mut b);
        pump(&mut b, &mut a);
        if b.state() == State::AwaitingTargetAccountFinal {
            b.approve_accounts_target_final(&"b".repeat(64)).unwrap();
        }
        if a.state() == State::AwaitingAccountFinal {
            a.approve_accounts_final(&"a".repeat(64)).unwrap();
        }
        assert!(std::time::Instant::now() < until);
    }
    let database = target.database();
    let operation = b.receipt().unwrap().operation_uuid;
    let generation = database.device_sync_header().unwrap().generation;
    let current = RecoveryOperation::preview_pending(database.clone(), operation, "Target")
        .unwrap()
        .current()
        .clone();
    let tags = current
        .manifest
        .records
        .iter()
        .filter(|record| matches!(record, ManifestRecord::Tag(_)))
        .count();
    assert!(tags >= 1024);
    // Each scan reads every real tag and one end-of-section query. Pause on a
    // subsequent real SQL read only after 128 tags of the selected scan ran.
    let boundary = usize::from(second_scan) * (tags + 1) + 129;
    let reads = Arc::new(AtomicUsize::new(0));
    let observed_reads = reads.clone();
    let (reached, entered) = std::sync::mpsc::sync_channel(1);
    let (release, released) = std::sync::mpsc::sync_channel(1);
    database
        .connection
        .lock()
        .unwrap()
        .authorizer(Some(move |context: AuthContext<'_>| {
            if matches!(
                context.action,
                AuthAction::Read {
                    table_name: "sync_tag_state",
                    column_name: "name",
                }
            ) {
                let count = observed_reads.fetch_add(1, Ordering::SeqCst) + 1;
                if count == boundary {
                    reached.send(count).unwrap();
                    released
                        .recv_timeout(std::time::Duration::from_secs(10))
                        .unwrap();
                }
            }
            Authorization::Allow
        }));
    let cancel = b.cancellation();
    let work = b.work_control();
    let scanned_before = work.observe().scanned_items;
    let result = std::thread::scope(|scope| {
        let worker = scope.spawn(|| b.finalize_accounts(external));
        assert_eq!(
            entered
                .recv_timeout(std::time::Duration::from_secs(10))
                .unwrap(),
            boundary
        );
        cancel.cancel();
        release.send(()).unwrap();
        worker.join().unwrap()
    });
    database
        .connection
        .lock()
        .unwrap()
        .authorizer(None::<fn(AuthContext<'_>) -> Authorization>);
    assert!(matches!(result, Err(DriverError::Cancelled)), "{result:?}");
    assert!(
        reads.load(Ordering::SeqCst) <= boundary + 2,
        "finalize must stop at the cancelled real scan boundary, not finish its remaining tag SQL"
    );
    let scanned = work.observe().scanned_items - scanned_before;
    let minimum = usize::from(second_scan) * current.manifest.records.len() + 128;
    assert!(scanned >= minimum as u64);
    assert!(scanned < (minimum + 256) as u64);
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
        JournalStage::LibraryApplied
    );
    assert!(target.create_tag("still blocked".into()).is_err());
    assert_ne!(b.state(), State::Completed);
    b.cancel();
    b.finish_shutdown();
    assert_eq!(b.state(), State::RecoveryPending);
    let mut compensation =
        RecoveryOperation::preview_pending(database.clone(), operation, "Target").unwrap();
    let mut authorization = compensation.authorize().unwrap();
    compensation
        .restore(Some(&mut authorization), &CancellationToken::default())
        .unwrap();
    assert_eq!(target.list_tags().unwrap(), ["old target"]);
    assert!(!database.device_sync_recovery_pending());
    target
        .create_tag("ordinary write after compensation".into())
        .unwrap();
    a.cancel();
    clock.elapsed.store(30_001, Ordering::SeqCst);
    a.cleanup_pending();
    a.finish_shutdown();
}

#[test]
fn pending_account_finalize_constructor_scan_cancel_stops_before_remaining_sql() {
    pending_account_finalize_scan_cancel(false);
}

#[test]
fn pending_account_finalize_access_scan_cancel_stops_before_remaining_sql() {
    pending_account_finalize_scan_cancel(true);
}

#[test]
fn metadata_read_vm_budget_prevents_large_scan_and_removes_handler() {
    let root = tempfile::tempdir().unwrap();
    let api = CoreApi::open(root.path()).unwrap();
    let database = api.database();
    let generation = database.device_sync_header().unwrap().generation;
    let library = database.device_sync_header().unwrap().library_uuid;
    {
        let mut connection = database.connection.lock().unwrap();
        let transaction = connection.transaction().unwrap();
        let mut owner = transaction
            .prepare("INSERT INTO device_sync_original_owner VALUES(?1,?2)")
            .unwrap();
        let mut backup = transaction.prepare(
            "INSERT INTO device_sync_backup(backup_uuid,version,library_uuid,payload,digest) VALUES(?1,1,?2,x'7b7d',?3)",
        ).unwrap();
        let mut journal = transaction
            .prepare("INSERT INTO device_sync_apply_journal VALUES(?1,1,?2,'finalized',?3,?4,NULL)")
            .unwrap();
        for index in 1..=32_000 {
            let b = format!("40000000-0000-4000-8000-{index:012}");
            let j = format!("50000000-0000-4000-8000-{index:012}");
            owner
                .execute(params![b, root.path().to_string_lossy()])
                .unwrap();
            backup.execute(params![b, library, "0".repeat(64)]).unwrap();
            journal
                .execute(params![j, library, b, "0".repeat(64)])
                .unwrap();
        }
        drop(owner);
        drop(backup);
        drop(journal);
        transaction.commit().unwrap();
    }
    {
        use std::sync::{
            atomic::{AtomicU64, Ordering},
            Arc,
        };
        let connection = database.connection.lock().unwrap();
        let measure = || {
            let steps = Arc::new(AtomicU64::new(0));
            let observed = steps.clone();
            connection.progress_handler(
                1024,
                Some(move || {
                    observed.fetch_add(1024, Ordering::Relaxed);
                    false
                }),
            );
            let sql = backup_metadata_sql("b.created_at", true, false);
            let mut statement = connection.prepare(&sql).unwrap();
            let mut rows = statement
                .query(params![None::<i64>, None::<String>, 129])
                .unwrap();
            let mut count = 0;
            while rows.next().unwrap().is_some() {
                count += 1;
            }
            assert_eq!(count, 129);
            connection.progress_handler(0, None::<fn() -> bool>);
            steps.load(Ordering::Relaxed)
        };
        connection
            .pragma_update(None, "automatic_index", true)
            .unwrap();
        let normal = measure();
        eprintln!("metadata identical SQL VM lower bound: default automatic_index=ON, 32000 backups, {normal} steps");
        assert!(
            normal > 16_000_000,
            "fixture must actually exceed the unchanged production VM budget"
        );
    }
    let result = database.device_sync_backup_metadata_page(None, 129);
    assert_eq!(
        result.as_ref().err().map(ReadError::core),
        Some(ReadError::Unavailable),
        "metadata SQL must stop at its own bounded VM budget, not occupy the DB indefinitely"
    );
    assert_eq!(
        database.device_sync_header().unwrap().generation,
        generation
    );
    api.create_tag("ordinary-write-after-read-budget".into())
        .unwrap();
    let total: i64 = database.connection.lock().unwrap().query_row(
        "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) SELECT sum(x) FROM n",
        [], |row| row.get(0),
    ).unwrap();
    assert_eq!(total, 50_005_000);
}

#[test]
fn controlled_snapshot_final_recheck_cancel_is_real_and_sql_handler_is_removed() {
    use rusqlite::hooks::{AuthContext, Authorization};
    let root = tempfile::tempdir().unwrap();
    let api = CoreApi::open(root.path()).unwrap();
    for index in 0..260 {
        api.create_tag(format!("final-{index:03}")).unwrap();
    }
    let database = api.database();
    let generation = database.device_sync_header().unwrap().generation;
    let control = WorkControl::default();
    let observed = control.clone();
    let (reached, entered) = std::sync::mpsc::sync_channel(1);
    let (release, released) = std::sync::mpsc::sync_channel(1);
    let mut fired = false;
    database
        .connection
        .lock()
        .unwrap()
        .authorizer(Some(move |_: AuthContext<'_>| {
            if observed.observe().stage == WorkStage::FinalCheck && !fired {
                fired = true;
                reached.send(observed.observe().scanned_items).unwrap();
                released
                    .recv_timeout(std::time::Duration::from_secs(10))
                    .unwrap();
            }
            Authorization::Allow
        }));
    std::thread::scope(|scope| {
        let worker = scope.spawn(|| Snapshot::read_controlled(&database, "Local", &control));
        assert!(
            entered
                .recv_timeout(std::time::Duration::from_secs(10))
                .unwrap()
                >= 261
        );
        control.cancellation().cancel();
        release.send(()).unwrap();
        assert!(matches!(worker.join().unwrap(), Err(CoreError::Cancelled)));
    });
    {
        let connection = database.connection.lock().unwrap();
        connection.authorizer(None::<fn(AuthContext<'_>) -> Authorization>);
        let total: i64 = connection.query_row(
            "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) SELECT sum(x) FROM n",
            [], |row| row.get(0),
        ).unwrap();
        assert_eq!(
            total, 50_005_000,
            "cancelled SQL progress handler must not leak"
        );
    }
    assert_eq!(
        database.device_sync_header().unwrap().generation,
        generation
    );
    api.create_tag("after-final-cancel".into()).unwrap();
}

#[tokio::test]
async fn controlled_source_pin_cancel_after_real_hash_bytes_leaves_no_retained_pin() {
    use std::io::Write;
    let root = tempfile::tempdir().unwrap();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("synthetic-pin.jpg");
    let mut file = std::fs::File::create(&path).unwrap();
    for _ in 0..32 {
        file.write_all(&vec![0x42; 1024 * 1024]).unwrap();
    }
    drop(file);
    let api = CoreApi::open(root.path()).unwrap();
    api.import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    let asset = api.list_media(GalleryQuery::default()).unwrap().remove(0);
    // The indexed fast path skips unchanged originals; extend this managed
    // file so retention must enter the deep checksum path before cancellation.
    let mut stored = std::fs::OpenOptions::new()
        .append(true)
        .open(&asset.storage_path)
        .unwrap();
    stored.write_all(&[0x43]).unwrap();
    stored.sync_all().unwrap();
    drop(stored);
    let database = api.database();
    let generation = database.device_sync_header().unwrap().generation;
    let control = WorkControl::default();
    std::thread::scope(|scope| {
        let worker = scope.spawn(|| Snapshot::retain_controlled(&database, "Local", &control));
        let until = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            let progress = control.observe();
            if progress.stage == WorkStage::Pinning && progress.work_items >= 1024 * 1024 {
                break;
            }
            assert!(!worker.is_finished());
            assert!(std::time::Instant::now() < until);
            std::thread::yield_now();
        }
        control.cancellation().cancel();
        assert!(matches!(worker.join().unwrap(), Err(CoreError::Cancelled)));
    });
    assert_eq!(
        database.device_sync_header().unwrap().generation,
        generation
    );
    assert!(database
        .device_sync_backup_reference_owners()
        .unwrap()
        .is_empty());
    api.set_note(asset.id, "write after pin cancellation".into())
        .unwrap();
    api.delete_media(asset.id).unwrap();
    assert!(api.list_media(GalleryQuery::default()).unwrap().is_empty());
}

#[test]
fn backup_read_metadata_pages_bound_small_payload_checks_and_fail_closed_per_item() {
    let root = tempfile::tempdir().unwrap();
    let api = CoreApi::open(root.path()).unwrap();
    let database = api.database();
    let library = database.device_sync_header().unwrap().library_uuid;
    {
        let mut connection = database.connection.lock().unwrap();
        let transaction = connection.transaction().unwrap();
        transaction
            .execute(
                "INSERT INTO device_sync_source_name VALUES(?1,?2)",
                params![library, "\u{1f600}".repeat(128)],
            )
            .unwrap();
        for index in 1..=260 {
            let backup = format!("20000000-0000-4000-8000-{index:012}");
            let operation = format!("30000000-0000-4000-8000-{index:012}");
            transaction
                .execute(
                    "INSERT INTO device_sync_original_owner VALUES(?1,?2)",
                    params![backup, root.path().to_string_lossy()],
                )
                .unwrap();
            // The deliberately invalid payload proves metadata reads never
            // deserialize a backup or pretend that listing validates restore.
            transaction.execute(
                "INSERT INTO device_sync_backup(backup_uuid,version,library_uuid,payload,digest) VALUES(?1,1,?2,?4,?3)",
                params![backup, library, "0".repeat(64),
                    br#"{"version":1,"snapshot":{},"tables":[]}"#.as_slice()]).unwrap();
            transaction
                .execute(
                    "INSERT INTO device_sync_apply_journal VALUES(?1,1,?2,'finalized',?3,?4,?5)",
                    params![
                        operation,
                        library,
                        backup,
                        "0".repeat(64),
                        (index % 2 == 0).then(|| uuid::Uuid::new_v4().to_string())
                    ],
                )
                .unwrap();
        }
        transaction.commit().unwrap();
    }
    let opened = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    let mut after = None;
    let mut ids = std::collections::BTreeSet::new();
    let mut accounts = 0;
    loop {
        let read = headless::read_backups(&opened.handle, after.as_deref(), 128);
        assert!(read.error.is_none(), "{:?}", read.error);
        assert!(serde_json::to_vec(&read).unwrap().len() <= 65_536);
        let page = read.value.unwrap();
        assert!(
            page.items.len() < 128,
            "byte limit must also constrain this full-name fixture"
        );
        for item in page.items {
            assert!(item.created_at.is_none());
            accounts += usize::from(item.includes_accounts == Some(true));
            assert!(item.unavailable_reason.is_none());
            assert!(ids.insert(item.backup.unwrap()));
        }
        after = page.next;
        if after.is_none() {
            break;
        }
    }
    assert_eq!(ids.len(), 260);
    assert_eq!(accounts, 130);
    let first = headless::read_backups(&opened.handle, None, 1)
        .value
        .unwrap();
    assert_eq!(
        headless::read_backups(&opened.handle, first.next.as_deref(), 0).error,
        Some(ReadError::InvalidInput)
    );
    let other_root = tempfile::tempdir().unwrap();
    let other = headless::open(other_root.path().to_string_lossy().into_owned()).unwrap();
    assert_eq!(
        headless::read_backups(&other.handle, first.next.as_deref(), 1).error,
        Some(ReadError::PreviewChanged)
    );
    let visible_backup = headless::read_backups(&opened.handle, None, 1)
        .value
        .unwrap()
        .items
        .into_iter()
        .next()
        .and_then(|item| item.backup)
        .unwrap();
    database
        .connection
        .lock()
        .unwrap()
        .execute(
            "DELETE FROM device_sync_apply_journal WHERE backup_uuid=?1",
            [visible_backup],
        )
        .unwrap();
    let local_failure = headless::read_backups(&opened.handle, None, 128);
    assert!(local_failure.error.is_none());
    let items = local_failure.value.unwrap().items;
    assert!(items.iter().any(|item| item.unavailable_reason
        == Some(crate::device_sync::read_model::BackupUnavailableReason::OwnershipUnknown)));
    assert!(items.iter().any(|item| item.unavailable_reason.is_none()));
    headless::close_library(&other.handle).unwrap();
    headless::close_library(&opened.handle).unwrap();
}

#[tokio::test]
async fn backup_created_at_legacy_pending_preview_is_readonly_and_save_ddl_is_transactional() {
    let source_root = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let target = CoreApi::open(root.path()).unwrap();
    source.create_tag("incoming".into()).unwrap();
    target.create_tag("old".into()).unwrap();
    let input = tempfile::tempdir().unwrap();
    let file = input.path().join("old.jpg");
    std::fs::write(&file, b"old retained original").unwrap();
    target
        .import_local_files(vec![file.to_string_lossy().into_owned()])
        .await
        .unwrap();
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
            Some(uuid::Uuid::new_v4()),
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    let backup = receipt.backup_uuid;
    let old_bytes: (Vec<u8>, String) = {
        let database = target.database();
        let connection = database.connection.lock().unwrap();
        connection
            .execute_batch("ALTER TABLE device_sync_backup DROP COLUMN created_at")
            .unwrap();
        connection
            .execute_batch("DROP TABLE device_sync_backup_ownership")
            .unwrap();
        connection
            .query_row(
                "SELECT payload,digest FROM device_sync_backup WHERE backup_uuid=?1",
                [backup.to_string()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap()
    };
    drop(receive);
    drop(target);
    let target = CoreApi::open(root.path()).unwrap();
    let database = target.database();
    assert!(!backup_has_created_at(&database.connection.lock().unwrap()).unwrap());
    assert!(!backup_has_ownership(&database.connection.lock().unwrap()).unwrap());
    let refs_before: Vec<(String, String)> = {
        let connection = database.connection.lock().unwrap();
        let values = connection
            .prepare("SELECT file_path,sha256 FROM device_sync_original_ref WHERE owner_uuid=?1")
            .unwrap()
            .query_map([backup.to_string()], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        values
    };
    assert!(!refs_before.is_empty());
    let metadata = database.device_sync_backup_metadata(backup).unwrap();
    assert!(metadata.created_at.is_none());
    assert_eq!(metadata.includes_accounts, Some(true));
    let mut preview =
        RecoveryOperation::preview_pending(database.clone(), receipt.operation_uuid, "Target")
            .unwrap();
    assert!(!backup_has_created_at(&database.connection.lock().unwrap()).unwrap());
    assert!(!backup_has_ownership(&database.connection.lock().unwrap()).unwrap());
    assert!(matches!(
        target.create_tag("blocked".into()),
        Err(CoreError::LibraryBusy)
    ));
    let mut authorization = preview.authorize().unwrap();
    let cancelled = CancellationToken::default();
    cancelled.cancel();
    assert!(preview
        .restore(Some(&mut authorization), &cancelled)
        .is_err());
    assert!(!backup_has_created_at(&database.connection.lock().unwrap()).unwrap());
    assert!(!backup_has_ownership(&database.connection.lock().unwrap()).unwrap());
    database.connection.lock().unwrap().execute_batch(
        "CREATE TEMP TRIGGER reject_new_backup BEFORE INSERT ON device_sync_backup BEGIN SELECT RAISE(ABORT,'synthetic save failure'); END",
    ).unwrap();
    let mut preview =
        RecoveryOperation::preview_pending(database.clone(), receipt.operation_uuid, "Target")
            .unwrap();
    let mut authorization = preview.authorize().unwrap();
    assert!(preview
        .restore(Some(&mut authorization), &CancellationToken::default())
        .is_err());
    assert!(
        !backup_has_created_at(&database.connection.lock().unwrap()).unwrap(),
        "failed save must roll back DDL"
    );
    assert!(
        !backup_has_ownership(&database.connection.lock().unwrap()).unwrap(),
        "failed save must also roll back narrow ownership DDL"
    );
    assert!(database.device_sync_pending_journal().unwrap().is_some());
    database
        .connection
        .lock()
        .unwrap()
        .execute_batch("DROP TRIGGER reject_new_backup")
        .unwrap();
    let mut preview =
        RecoveryOperation::preview_pending(database.clone(), receipt.operation_uuid, "Target")
            .unwrap();
    let mut authorization = preview.authorize().unwrap();
    let started = Utc::now();
    let restored = preview
        .restore(Some(&mut authorization), &CancellationToken::default())
        .unwrap();
    let ended = Utc::now();
    assert!(backup_has_created_at(&database.connection.lock().unwrap()).unwrap());
    assert!(backup_has_ownership(&database.connection.lock().unwrap()).unwrap());
    let safety = database
        .device_sync_backup_metadata(restored.backup_uuid)
        .unwrap();
    assert_eq!(safety.includes_accounts, None);
    assert_eq!(
        safety.unavailable_reason,
        Some(crate::device_sync::read_model::BackupUnavailableReason::InternalCompensation)
    );
    let saved: String = database
        .connection
        .lock()
        .unwrap()
        .query_row(
            "SELECT created_at FROM device_sync_backup WHERE backup_uuid=?1",
            [restored.backup_uuid.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    let saved = DateTime::parse_from_rfc3339(&saved)
        .unwrap()
        .with_timezone(&Utc);
    assert!(saved >= started - chrono::Duration::milliseconds(1) && saved <= ended);
    assert!(database
        .device_sync_backup_metadata(backup)
        .unwrap()
        .created_at
        .is_none());
    let connection = database.connection.lock().unwrap();
    let old_after: (Vec<u8>, String) = connection
        .query_row(
            "SELECT payload,digest FROM device_sync_backup WHERE backup_uuid=?1",
            [backup.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(old_after, old_bytes);
    let refs_after: Vec<(String, String)> = connection
        .prepare("SELECT file_path,sha256 FROM device_sync_original_ref WHERE owner_uuid=?1")
        .unwrap()
        .query_map([backup.to_string()], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(refs_after, refs_before);
    drop(connection);
    assert_eq!(target.list_tags().unwrap(), ["old"]);
    assert_eq!(target.list_media(GalleryQuery::default()).unwrap().len(), 1);
    target.create_tag("after-compensation".into()).unwrap();
    drop(preview);
    drop(database);
    drop(target);
    let target = CoreApi::open(root.path()).unwrap();
    target.database().migrate().unwrap();
    assert!(target
        .database()
        .device_sync_backup_metadata(backup)
        .unwrap()
        .created_at
        .is_none());
}
