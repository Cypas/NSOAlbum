use super::*;
use crate::api::CoreApi;
use crate::models::GalleryQuery;

fn empty_pair() -> (tempfile::TempDir, tempfile::TempDir, CoreApi, CoreApi) {
    let source = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    let a = CoreApi::open(source.path()).unwrap();
    let b = CoreApi::open(target.path()).unwrap();
    (source, target, a, b)
}

#[test]
fn receiver_prepare_deterministically_rejects_metadata_peak_without_writing_library() {
    use super::super::space_budget::tests_support::Override;
    let (_source, _target, a, b) = empty_pair();
    a.database().create_tag("incoming").unwrap();
    let before = Snapshot::read(&b.database(), "Target").unwrap();
    let _free = Override::free(0);
    assert!(matches!(
        ReceiveOperation::prepare(
            b.database(),
            Snapshot::read(&a.database(), "Source").unwrap(),
            "Target",
            SyncMode::Merge,
        ),
        Err(ReceiverError::Staging(StagingError::InsufficientSpace))
    ));
    assert_eq!(
        Snapshot::read_with_header(
            &b.database(),
            before.manifest.header.clone(),
            Some("Target")
        )
        .unwrap()
        .digest()
        .unwrap(),
        before.digest().unwrap()
    );
    assert!(b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
}

// Free-space loss after reception must not even create a prepare journal.
#[tokio::test]
async fn receiver_apply_rechecks_free_before_journal_and_retains_verified_cache() {
    use super::super::space_budget::tests_support::Override;
    let (_source, _target, a, b) = empty_pair();
    import(&a, b"cached bytes", "incoming.jpg").await;
    a.database().create_tag("incoming tag").unwrap();
    let snapshot = Snapshot::read(&a.database(), "Source").unwrap();
    let mut receive = {
        let _free = Override::free(u64::MAX);
        ReceiveOperation::prepare(b.database(), snapshot.clone(), "Target", SyncMode::Merge)
            .unwrap()
    };
    let initial_additional = receive
        .receiver_budget()
        .volumes
        .iter()
        .map(|v| v.additional_bytes)
        .sum::<u64>();
    // Fresh snapshot times can have different JSON fraction widths; isolate M.
    let initial_metadata = b
        .database()
        .device_sync_metadata_cost(
            receive.target(),
            receive.plan(),
            &super::super::work::WorkControl::default(),
        )
        .unwrap();
    let initial_metadata_bytes = 4
        * (initial_metadata.database_bytes
            + initial_metadata.backup_bytes
            + initial_metadata.plan_bytes)
        + 16 * 1024 * 1024;
    let initial_media_bytes = initial_additional - initial_metadata_bytes;
    assert_eq!(initial_media_bytes, 163_840);
    stage(&mut receive, b"cached bytes");
    let before = Snapshot::read(&b.database(), "Target").unwrap();
    let mut authorization = receive.authorize().unwrap();
    {
        let _free = Override::free(0);
        assert!(matches!(
            receive.apply(
                Some(&mut authorization),
                None,
                &CancellationToken::default(),
                &mut |_| {}
            ),
            Err(ReceiverError::Staging(StagingError::InsufficientSpace))
        ));
    }
    assert_eq!(
        Snapshot::read_with_header(
            &b.database(),
            before.manifest.header.clone(),
            Some("Target")
        )
        .unwrap()
        .digest()
        .unwrap(),
        before.digest().unwrap()
    );
    assert!(b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
    assert!(b
        .database()
        .device_sync_backup_reference_owners()
        .unwrap()
        .is_empty());
    assert!(b.list_media(GalleryQuery::default()).unwrap().is_empty());
    drop(receive);
    let _free = Override::free(u64::MAX);
    let mut retry =
        ReceiveOperation::prepare(b.database(), snapshot, "Target", SyncMode::Merge).unwrap();
    let retry_metadata = b
        .database()
        .device_sync_metadata_cost(
            retry.target(),
            retry.plan(),
            &super::super::work::WorkControl::default(),
        )
        .unwrap();
    let retry_metadata_bytes = 4
        * (retry_metadata.database_bytes + retry_metadata.backup_bytes + retry_metadata.plan_bytes)
        + 16 * 1024 * 1024;
    let retry_media_bytes = retry
        .receiver_budget()
        .volumes
        .iter()
        .map(|v| v.additional_bytes)
        .sum::<u64>()
        - retry_metadata_bytes;
    assert_eq!(
        retry_media_bytes, 81_920,
        "publication allocation must remain"
    );
    assert_eq!(
        initial_media_bytes - retry_media_bytes,
        81_920,
        "cache removes only staging allocation, never publication"
    );
    let sha = hex::encode(sha2::Sha256::digest(b"cached bytes"));
    assert!(!retry.staging_mut().requires_transfer(&sha).unwrap());
    let mut approved = retry.authorize().unwrap();
    retry
        .apply(
            Some(&mut approved),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(b.list_media(GalleryQuery::default()).unwrap().len(), 1);
}

// Actual backup JSON length depends on the snapshot time's serialized precision.
#[test]
fn receiver_budget_measures_serialized_header_precision_in_metadata() {
    use super::super::space_budget::tests_support::Override;
    use chrono::TimeZone;
    let (_source, _target, a, b) = empty_pair();
    let source = Snapshot::read(&a.database(), "Source").unwrap();
    let mut target = Snapshot::read(&b.database(), "Target").unwrap();
    let work = super::super::work::WorkControl::default();
    let _free = Override::free(u64::MAX);
    let mut observed = Vec::new();
    for nanos in [123_456_000, 123_456_001] {
        target.manifest.header.observed_at = chrono::Utc
            .timestamp_opt(1_700_000_000, nanos)
            .single()
            .unwrap();
        let plan =
            super::super::planner::build_plan(&source.manifest, &target.manifest, SyncMode::Merge)
                .unwrap();
        let staging =
            StagingOperation::prepare(b.database(), &source.manifest, &target.manifest, &plan)
                .unwrap();
        let metadata = b
            .database()
            .device_sync_metadata_cost(&target, &plan, &work)
            .unwrap();
        let measured = (
            metadata.database_bytes,
            metadata.backup_bytes,
            metadata.plan_bytes,
        );
        let budget = super::super::space_budget::measure(&staging, metadata, &work).unwrap();
        observed.push((
            measured.0,
            measured.1,
            measured.2,
            budget
                .volumes
                .iter()
                .map(|v| v.additional_bytes)
                .sum::<u64>(),
        ));
    }
    let (six_d, six_b, six_p, six_peak) = observed[0];
    let (nine_d, nine_b, nine_p, nine_peak) = observed[1];
    assert_eq!(nine_d, six_d);
    assert_eq!(nine_p, six_p);
    assert_eq!(
        nine_b - six_b,
        3,
        "actual backup JSON gains three fractional digits"
    );
    assert_eq!(
        nine_peak - six_peak,
        12,
        "metadata peak must include four times the actual byte delta"
    );
}

// Dropping the authorization check must make the actual receiver mutate the DB.
#[test]
fn receiver_requires_local_confirmation_and_rejects_changed_target() {
    let (_source, _target, a, b) = empty_pair();
    a.database().create_tag("incoming").unwrap();
    let source = Snapshot::read(&a.database(), "Source").unwrap();
    let mut receive =
        ReceiveOperation::prepare(b.database(), source, "Target", SyncMode::Merge).unwrap();
    let generation = b.database().device_sync_header().unwrap().generation;
    assert!(matches!(
        receive.apply(None, None, &CancellationToken::default(), &mut |_| {}),
        Err(ReceiverError::AuthorizationRequired)
    ));
    assert_eq!(
        b.database().device_sync_header().unwrap().generation,
        generation
    );
    assert!(!b
        .database()
        .list_tags()
        .unwrap()
        .contains(&"incoming".into()));
    let mut confirmed = receive.authorize().unwrap();
    b.database().create_tag("changed locally").unwrap();
    assert!(matches!(
        receive.apply(
            Some(&mut confirmed),
            None,
            &CancellationToken::default(),
            &mut |_| {}
        ),
        Err(ReceiverError::PlanChanged)
    ));
    assert!(!b
        .database()
        .list_tags()
        .unwrap()
        .contains(&"incoming".into()));
    assert!(matches!(
        receive.apply(
            Some(&mut confirmed),
            None,
            &CancellationToken::default(),
            &mut |_| {}
        ),
        Err(ReceiverError::AuthorizationMismatch)
    ));
}

// A new wall-clock sample is not a change to an otherwise unchanged target.
#[test]
fn receiver_unchanged_target_applies_real_catalog_and_survives_reopen() {
    let (_source, target, a, b) = empty_pair();
    a.database().create_tag("incoming standalone").unwrap();
    let source = Snapshot::read(&a.database(), "Source").unwrap();
    let mut receive =
        ReceiveOperation::prepare(b.database(), source, "Target", SyncMode::Merge).unwrap();
    let mut confirmed = receive.authorize().unwrap();
    let receipt = receive
        .apply(
            Some(&mut confirmed),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    let backup_journal = b
        .database()
        .device_sync_backup_journal(receipt.backup_uuid)
        .unwrap();
    assert_eq!(backup_journal.operation_uuid, receipt.operation_uuid);
    assert_eq!(backup_journal.external_reference, None);
    assert!(b
        .database()
        .device_sync_backup_journal(uuid::Uuid::new_v4())
        .is_err());
    assert_eq!(receipt.state, ApplyState::Finalized);
    assert!(b
        .database()
        .list_tags()
        .unwrap()
        .contains(&"incoming standalone".into()));
    assert!(b.list_media(GalleryQuery::default()).unwrap().is_empty());
    assert!(!b.database().device_sync_recovery_pending());
    assert_eq!(
        b.database().device_sync_backup_reference_owners().unwrap(),
        vec![receipt.backup_uuid]
    );
    drop(receive);
    drop(b);
    let reopened = CoreApi::open(target.path()).unwrap();
    assert!(reopened
        .database()
        .list_tags()
        .unwrap()
        .contains(&"incoming standalone".into()));
    assert!(!reopened.database().device_sync_recovery_pending());
}

#[test]
fn receiver_account_backup_restore_stays_pending_and_compensates_restore_before_restore() {
    use crate::device_sync::recovery::RecoveryOperation;
    let (_source, _target, a, b) = empty_pair();
    b.database().create_tag("original target").unwrap();
    a.database().create_tag("incoming").unwrap();
    let mut receive = ReceiveOperation::prepare(
        b.database(),
        Snapshot::read(&a.database(), "Source").unwrap(),
        "Target",
        SyncMode::Overwrite,
    )
    .unwrap();
    let mut approved = receive.authorize().unwrap();
    let original_external = uuid::Uuid::new_v4();
    let receipt = receive
        .apply(
            Some(&mut approved),
            Some(original_external),
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    drop(receive);
    let mut finalized =
        RecoveryOperation::preview_pending(b.database(), receipt.operation_uuid, "Target").unwrap();
    let mut approved = finalized.authorize().unwrap();
    finalized
        .finalize(Some(&mut approved), Some(original_external))
        .unwrap();
    drop(finalized);
    b.database().create_tag("before explicit restore").unwrap();
    let before = b.list_tags().unwrap();
    let mut restore =
        RecoveryOperation::preview_backup(b.database(), receipt.backup_uuid, "Target").unwrap();
    let mut approved = restore.authorize().unwrap();
    let external = uuid::Uuid::new_v4();
    let restored = restore
        .restore_with_external(
            Some(&mut approved),
            Some(external),
            &CancellationToken::default(),
        )
        .unwrap();
    assert_eq!(b.list_tags().unwrap(), ["original target"]);
    let pending = b.database().device_sync_pending_journal().unwrap().unwrap();
    assert_eq!(pending.operation_uuid, restored.operation_uuid);
    assert_eq!(pending.external_reference, Some(external));
    assert_eq!(
        b.database()
            .device_sync_backup_journal(restored.backup_uuid)
            .unwrap()
            .external_reference,
        Some(external),
    );
    assert!(b.database().create_tag("blocked").is_err());
    let mut compensate =
        RecoveryOperation::preview_pending(b.database(), restored.operation_uuid, "Target")
            .unwrap();
    let mut approved = compensate.authorize().unwrap();
    compensate
        .restore(Some(&mut approved), &CancellationToken::default())
        .unwrap();
    assert_eq!(b.list_tags().unwrap(), before);
    assert!(!b.database().device_sync_recovery_pending());
}

async fn import(api: &CoreApi, bytes: &[u8], name: &str) -> crate::models::MediaAsset {
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    api.import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    let sha = hex::encode(sha2::Sha256::digest(bytes));
    api.list_media(GalleryQuery::default())
        .unwrap()
        .into_iter()
        .find(|m| m.sha256 == sha)
        .unwrap()
}

fn stage(receive: &mut ReceiveOperation, bytes: &[u8]) {
    let sha = hex::encode(sha2::Sha256::digest(bytes));
    let id = receive.operation_id();
    receive.staging_mut().begin_file(id, &sha).unwrap();
    receive
        .staging_mut()
        .write_chunk(id, &sha, 0, bytes)
        .unwrap();
    receive
        .staging_mut()
        .finish_file(id, &sha, &CancellationToken::default(), &mut |_| {})
        .unwrap();
}

// Full-version replacement must clear fields, preserve real local paths/IDs,
// and publish new data through the actual staging resource.
#[tokio::test]
async fn receiver_full_versions_reuse_jpg_and_publish_unknown_history() {
    let (_source, _target, a, b) = empty_pair();
    let source = import(&a, b"shared", "source.jpeg").await;
    let target = import(&b, b"shared", "target.jpg").await;
    b.set_note(target.id, "must be cleared".into()).unwrap();
    b.add_tag(target.id, "remove this".into()).unwrap();
    b.set_favorite(target.id, true).unwrap();
    import(&a, b"new published original", "new.jpg").await;
    let mut snapshot = Snapshot::read(&a.database(), "A").unwrap();
    for record in &mut snapshot.manifest.records {
        if let crate::device_sync::manifest::ManifestRecord::Media(record) = record {
            record.imported_at = None;
            record.revision = None;
        }
    }
    snapshot.sources =
        SourceDescriptions::new(&snapshot.manifest, snapshot.sources.entries).unwrap();
    let source_before = Snapshot::read(&a.database(), "A").unwrap();
    let mut receive =
        ReceiveOperation::prepare(b.database(), snapshot, "B", SyncMode::Overwrite).unwrap();
    stage(&mut receive, b"new published original");
    let mut auth = receive.authorize().unwrap();
    receive
        .apply(
            Some(&mut auth),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    let result = b.database().media_asset(target.id).unwrap();
    assert_eq!(result.sha256, source.sha256);
    assert_eq!(result.storage_path, target.storage_path);
    assert!(result.note.as_deref().is_none_or(str::is_empty));
    assert!(result.tags.is_empty());
    assert!(!result.favorite);
    assert_eq!(result.imported_at, None);
    assert_eq!(std::fs::read(&result.storage_path).unwrap(), b"shared");
    assert_eq!(b.list_media(GalleryQuery::default()).unwrap().len(), 2);
    assert_eq!(
        Snapshot::read_with_header(
            &a.database(),
            source_before.manifest.header.clone(),
            Some("A")
        )
        .unwrap(),
        source_before
    );
}

// A third sender cannot relabel the original author of a forwarded album.
#[test]
fn receiver_provenance_survives_a_b_c_forwarding_and_conflicts() {
    let (_source, _target, a, b) = empty_pair();
    a.database().create_album("Same name", "", false).unwrap();
    b.database().create_album("Same name", "", false).unwrap();
    let a_uuid = a.database().device_sync_header().unwrap().library_uuid;
    let mut ab = ReceiveOperation::prepare(
        b.database(),
        Snapshot::read(&a.database(), "A origin").unwrap(),
        "B relay",
        SyncMode::Merge,
    )
    .unwrap();
    let mut auth = ab.authorize().unwrap();
    ab.apply(
        Some(&mut auth),
        None,
        &CancellationToken::default(),
        &mut |_| {},
    )
    .unwrap();
    let c_root = tempfile::tempdir().unwrap();
    let c = CoreApi::open(c_root.path()).unwrap();
    let mut bc = ReceiveOperation::prepare(
        c.database(),
        Snapshot::read(&b.database(), "B relay").unwrap(),
        "C",
        SyncMode::Merge,
    )
    .unwrap();
    let mut auth = bc.authorize().unwrap();
    bc.apply(
        Some(&mut auth),
        None,
        &CancellationToken::default(),
        &mut |_| {},
    )
    .unwrap();
    let names = c.database().device_sync_source_names().unwrap();
    assert_eq!(
        names
            .iter()
            .find(|n| n.library_uuid == a_uuid)
            .unwrap()
            .display_name,
        "A origin"
    );
    assert_eq!(
        c.database()
            .list_albums()
            .unwrap()
            .iter()
            .filter(|a| a.name == "Same name")
            .count(),
        2
    );
    let mut forwarded = Snapshot::read(&b.database(), "B relay").unwrap();
    forwarded
        .sources
        .entries
        .iter_mut()
        .find(|n| n.library_uuid == a_uuid)
        .unwrap()
        .display_name = "false third-party replacement".into();
    let mut repeated =
        ReceiveOperation::prepare(c.database(), forwarded, "C", SyncMode::Merge).unwrap();
    let mut auth = repeated.authorize().unwrap();
    repeated
        .apply(
            Some(&mut auth),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(
        c.database()
            .device_sync_source_names()
            .unwrap()
            .iter()
            .find(|n| n.library_uuid == a_uuid)
            .unwrap()
            .display_name,
        "A origin"
    );
}

#[test]
fn receiver_strict_noop_reapplies_changed_source_name() {
    let source_root = tempfile::tempdir().unwrap();
    let target_root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let target = CoreApi::open(target_root.path()).unwrap();
    source
        .create_album("Forwarded".into(), String::new(), false)
        .unwrap();
    let source_uuid = source.database().device_sync_header().unwrap().library_uuid;

    let mut first = ReceiveOperation::prepare(
        target.database(),
        Snapshot::read(&source.database(), "Source old").unwrap(),
        "Target",
        SyncMode::Merge,
    )
    .unwrap();
    let mut authorization = first.authorize().unwrap();
    first
        .apply(
            Some(&mut authorization),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(
        target
            .database()
            .device_sync_source_name(&source_uuid)
            .unwrap()
            .unwrap()
            .display_name,
        "Source old"
    );

    let renamed = Snapshot::read(&source.database(), "Source renamed").unwrap();
    let mut repeat = ReceiveOperation::prepare(
        target.database(),
        renamed.clone(),
        "Target",
        SyncMode::Merge,
    )
    .unwrap();
    assert!(!repeat.plan().is_strict_noop(
        &renamed.manifest,
        &repeat.target().manifest,
        &renamed.sources,
        &repeat.target().sources
    ));
    let mut authorization = repeat.authorize().unwrap();
    repeat
        .apply(
            Some(&mut authorization),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(
        target
            .database()
            .device_sync_source_name(&source_uuid)
            .unwrap()
            .unwrap()
            .display_name,
        "Source renamed"
    );
}

// Publishing the pending state only in memory would admit writes on reopen.
#[test]
fn receiver_external_pending_reopens_readonly_and_cancel_after_apply_stays_pending() {
    let (_source, target, a, b) = empty_pair();
    a.database().create_tag("new pending catalog").unwrap();
    let mut receive = ReceiveOperation::prepare(
        b.database(),
        Snapshot::read(&a.database(), "A").unwrap(),
        "B",
        SyncMode::Merge,
    )
    .unwrap();
    let mut auth = receive.authorize().unwrap();
    let receipt = receive
        .apply(
            Some(&mut auth),
            Some(uuid::Uuid::new_v4()),
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(receipt.state, ApplyState::LibraryAppliedPending);
    assert!(b.database().device_sync_recovery_pending());
    assert!(matches!(
        b.create_tag("blocked".into()),
        Err(CoreError::LibraryBusy)
    ));
    assert!(b
        .database()
        .list_tags()
        .unwrap()
        .contains(&"new pending catalog".into()));
    drop(receive);
    drop(b);
    let reopened = CoreApi::open(target.path()).unwrap();
    assert!(reopened.database().device_sync_recovery_pending());
    assert!(matches!(
        reopened.database().write_lease(),
        Err(CoreError::LibraryBusy)
    ));
}

// A backup restore is a new, confirmed operation with its own safety backup.
#[test]
fn receiver_backup_restore_is_confirmed_and_can_be_restored_again() {
    use crate::device_sync::recovery::RecoveryOperation;
    let (_source, _target, a, b) = empty_pair();
    b.database().create_tag("original target").unwrap();
    a.database().create_tag("replacement").unwrap();
    let mut receive = ReceiveOperation::prepare(
        b.database(),
        Snapshot::read(&a.database(), "A").unwrap(),
        "B",
        SyncMode::Overwrite,
    )
    .unwrap();
    let mut auth = receive.authorize().unwrap();
    let first = receive
        .apply(
            Some(&mut auth),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    let mut restore =
        RecoveryOperation::preview_backup(b.database(), first.backup_uuid, "B").unwrap();
    assert!(matches!(
        restore.restore(None, &CancellationToken::default()),
        Err(ReceiverError::AuthorizationRequired)
    ));
    assert!(b
        .database()
        .list_tags()
        .unwrap()
        .contains(&"replacement".into()));
    let mut auth = restore.authorize().unwrap();
    let restored = restore
        .restore(Some(&mut auth), &CancellationToken::default())
        .unwrap();
    assert!(b
        .database()
        .list_tags()
        .unwrap()
        .contains(&"original target".into()));
    assert!(!b
        .database()
        .list_tags()
        .unwrap()
        .contains(&"replacement".into()));
    let mut again =
        RecoveryOperation::preview_backup(b.database(), restored.backup_uuid, "B").unwrap();
    let mut auth = again.authorize().unwrap();
    again
        .restore(Some(&mut auth), &CancellationToken::default())
        .unwrap();
    assert!(b
        .database()
        .list_tags()
        .unwrap()
        .contains(&"replacement".into()));
}

// The recovery capability must be tied to a real pending operation, not a
// boolean bypass or an arbitrary UUID supplied by the caller.
#[test]
fn receiver_pending_compensation_and_external_finalize_are_distinct() {
    use crate::device_sync::recovery::RecoveryOperation;
    let (_source, _target, a, b) = empty_pair();
    b.database().create_tag("before external").unwrap();
    a.database().create_tag("incoming external").unwrap();
    let mut receive = ReceiveOperation::prepare(
        b.database(),
        Snapshot::read(&a.database(), "A").unwrap(),
        "B",
        SyncMode::Overwrite,
    )
    .unwrap();
    let mut auth = receive.authorize().unwrap();
    let reference = uuid::Uuid::new_v4();
    let receipt = receive
        .apply(
            Some(&mut auth),
            Some(reference),
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert!(RecoveryOperation::preview_pending(b.database(), uuid::Uuid::new_v4(), "B").is_err());
    let mut recover =
        RecoveryOperation::preview_pending(b.database(), receipt.operation_uuid, "B").unwrap();
    let mut auth = recover.authorize().unwrap();
    assert!(recover.finalize(Some(&mut auth), None).is_err());
    assert!(b.database().device_sync_recovery_pending());
    let mut recover =
        RecoveryOperation::preview_pending(b.database(), receipt.operation_uuid, "B").unwrap();
    let mut auth = recover.authorize().unwrap();
    recover
        .restore(Some(&mut auth), &CancellationToken::default())
        .unwrap();
    assert!(!b.database().device_sync_recovery_pending());
    assert!(b
        .database()
        .list_tags()
        .unwrap()
        .contains(&"before external".into()));
    assert!(!b
        .database()
        .list_tags()
        .unwrap()
        .contains(&"incoming external".into()));
}

// Snapshot names and media must come from one stable library generation, even
// when the library is currently empty enough to fit in a single manifest page.
#[test]
fn receiver_snapshot_refuses_an_inflight_ordinary_writer() {
    let root = tempfile::tempdir().unwrap();
    let api = CoreApi::open(root.path()).unwrap();
    let lease = api.database().write_lease().unwrap();
    assert!(matches!(
        Snapshot::read(&api.database(), "Local"),
        Err(CoreError::LibraryBusy)
    ));
    drop(lease);
    assert!(Snapshot::read(&api.database(), "Local").is_ok());
}

#[test]
fn receiver_nil_external_reference_is_rejected_before_any_backup_or_journal() {
    let (_source, _target, a, b) = empty_pair();
    a.database().create_tag("incoming").unwrap();
    let mut receive = ReceiveOperation::prepare(
        b.database(),
        Snapshot::read(&a.database(), "A").unwrap(),
        "B",
        SyncMode::Merge,
    )
    .unwrap();
    let mut auth = receive.authorize().unwrap();
    assert!(receive
        .apply(
            Some(&mut auth),
            Some(uuid::Uuid::nil()),
            &CancellationToken::default(),
            &mut |_| {}
        )
        .is_err());
    assert!(!b.database().device_sync_recovery_pending());
    assert!(b
        .database()
        .device_sync_backup_reference_owners()
        .unwrap()
        .is_empty());
    assert!(!b
        .database()
        .list_tags()
        .unwrap()
        .contains(&"incoming".into()));
}

#[tokio::test]
async fn receiver_shared_tag_catalog_owns_display_spelling_not_per_media_casing() {
    let (_source, _target, a, b) = empty_pair();
    let source = import(&a, b"case-shared", "a.jpg").await;
    let target = import(&b, b"case-shared", "b.jpg").await;
    a.add_tag(source.id, "Beta".into()).unwrap();
    a.set_note(source.id, "older source".into()).unwrap();
    b.add_tag(target.id, "beta".into()).unwrap();
    b.set_note(target.id, "newer target".into()).unwrap();
    let mut incoming = Snapshot::read(&a.database(), "A").unwrap();
    for record in &mut incoming.manifest.records {
        match record {
            crate::device_sync::manifest::ManifestRecord::Media(media) => {
                media.revision = Some(
                    chrono::DateTime::parse_from_rfc3339("2000-01-01T00:00:00Z")
                        .unwrap()
                        .into(),
                );
            }
            crate::device_sync::manifest::ManifestRecord::Tag(tag) => tag.revision = None,
            _ => {}
        }
    }
    incoming.sources =
        SourceDescriptions::new(&incoming.manifest, incoming.sources.entries).unwrap();
    let mut operation =
        ReceiveOperation::prepare(b.database(), incoming, "B", SyncMode::Merge).unwrap();
    assert_eq!(
        operation.plan().media[0]
            .final_record
            .as_ref()
            .unwrap()
            .tags,
        ["Beta"]
    );
    assert_eq!(
        operation
            .plan()
            .tags
            .iter()
            .find(|t| !t.deleted)
            .unwrap()
            .name,
        "Beta"
    );
    let mut auth = operation.authorize().unwrap();
    operation
        .apply(
            Some(&mut auth),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    let media = b.database().media_asset(target.id).unwrap();
    assert_eq!(media.tags, ["Beta"]);
    assert_eq!(media.note.as_deref(), Some("newer target"));
}

#[test]
fn receiver_cancellation_at_durable_boundaries_is_not_false_success() {
    use crate::device_sync::recovery::RecoveryOperation;
    for boundary in [ApplyBoundary::Prepared, ApplyBoundary::LibraryApplied] {
        let (_source, _target, a, b) = empty_pair();
        a.database().create_tag("incoming").unwrap();
        b.database().create_tag("original").unwrap();
        let mut operation = ReceiveOperation::prepare(
            b.database(),
            Snapshot::read(&a.database(), "A").unwrap(),
            "B",
            SyncMode::Overwrite,
        )
        .unwrap();
        let mut auth = operation.authorize().unwrap();
        let cancel = CancellationToken::default();
        assert!(operation
            .apply(Some(&mut auth), None, &cancel, &mut |stage| {
                if stage == boundary {
                    cancel.cancel();
                }
            })
            .is_err());
        if boundary == ApplyBoundary::Prepared {
            assert!(!b.database().device_sync_recovery_pending());
            assert!(b
                .database()
                .list_tags()
                .unwrap()
                .contains(&"original".into()));
        } else {
            assert!(b.database().device_sync_recovery_pending());
            let journal = b.database().device_sync_pending_journal().unwrap().unwrap();
            let mut recover =
                RecoveryOperation::preview_pending(b.database(), journal.operation_uuid, "B")
                    .unwrap();
            let mut auth = recover.authorize().unwrap();
            recover
                .restore(Some(&mut auth), &CancellationToken::default())
                .unwrap();
            assert!(b
                .database()
                .list_tags()
                .unwrap()
                .contains(&"original".into()));
        }
    }
}

// A catalog-selected spelling must not manufacture a complete media-version
// conflict on every later sync of the same source and same normalized tags.
#[tokio::test]
async fn receiver_repeated_tag_case_sync_is_idempotent_without_media_revision_change() {
    use crate::device_sync::manifest::ManifestRecord;
    use crate::device_sync::planner::Action;
    let (_source, _target, a, b) = empty_pair();
    let source = import(&a, b"repeat casing", "a.jpg").await;
    let target = import(&b, b"repeat casing", "b.jpg").await;
    a.add_tag(source.id, "beta".into()).unwrap();
    a.set_note(source.id, "source metadata".into()).unwrap();
    b.add_tag(target.id, "Beta".into()).unwrap();
    b.set_note(target.id, "target old metadata".into()).unwrap();
    let mut incoming = Snapshot::read(&a.database(), "A").unwrap();
    for record in &mut incoming.manifest.records {
        match record {
            ManifestRecord::Media(media) => media.revision = None,
            ManifestRecord::Tag(tag) => {
                tag.revision = Some(
                    chrono::DateTime::parse_from_rfc3339("2000-01-01T00:00:00Z")
                        .unwrap()
                        .into(),
                )
            }
            _ => {}
        }
    }
    incoming.sources =
        SourceDescriptions::new(&incoming.manifest, incoming.sources.entries).unwrap();
    let mut first =
        ReceiveOperation::prepare(b.database(), incoming.clone(), "B", SyncMode::Merge).unwrap();
    let mut auth = first.authorize().unwrap();
    first
        .apply(
            Some(&mut auth),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(b.database().media_asset(target.id).unwrap().tags, ["Beta"]);
    let generation = b.database().device_sync_header().unwrap().generation;
    let mut repeated =
        ReceiveOperation::prepare(b.database(), incoming, "B", SyncMode::Merge).unwrap();
    assert_eq!(
        repeated.plan().media[0].action,
        Action::Keep,
        "case-only catalog spelling must not repeat Replace"
    );
    assert!(!repeated.plan().media[0].revision_only);
    assert!(repeated
        .plan()
        .conflicts
        .iter()
        .all(|c| c.object_kind != "media"));
    let mut auth = repeated.authorize().unwrap();
    repeated
        .apply(
            Some(&mut auth),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(
        b.database().device_sync_header().unwrap().generation,
        generation
    );
    let snapshot = Snapshot::read(&b.database(), "B").unwrap();
    let media = snapshot.manifest.validate().unwrap().media;
    assert_eq!(media[&source.sha256].revision, None);
}

#[test]
fn receiver_authorization_rejects_other_operations_plan_and_source_tampering() {
    let (_source, _target, a, b) = empty_pair();
    a.database().create_tag("incoming").unwrap();
    let original = Snapshot::read(&a.database(), "A").unwrap();
    let generation = b.database().device_sync_header().unwrap().generation;
    let mut first =
        ReceiveOperation::prepare(b.database(), original.clone(), "B", SyncMode::Merge).unwrap();
    let mut auth = first.authorize().unwrap();
    let mut other =
        ReceiveOperation::prepare(b.database(), original.clone(), "B", SyncMode::Merge).unwrap();
    assert!(matches!(
        other.apply(
            Some(&mut auth),
            None,
            &CancellationToken::default(),
            &mut |_| {}
        ),
        Err(ReceiverError::AuthorizationMismatch)
    ));
    for mutation in 0..7 {
        let mut operation =
            ReceiveOperation::prepare(b.database(), original.clone(), "B", SyncMode::Merge)
                .unwrap();
        let mut auth = operation.authorize().unwrap();
        match mutation {
            0 => operation.plan.source_digest = "a".repeat(64),
            1 => operation.plan.target_digest = "b".repeat(64),
            2 => operation.plan.source_library_uuid = uuid::Uuid::new_v4().to_string(),
            3 => operation.plan.target_library_uuid = uuid::Uuid::new_v4().to_string(),
            4 => operation.plan.mode = SyncMode::Overwrite,
            5 => operation.source.sources.entries[0].display_name = "Tampered source".into(),
            _ => operation.plan.version = 999,
        }
        assert!(operation
            .apply(
                Some(&mut auth),
                None,
                &CancellationToken::default(),
                &mut |_| {}
            )
            .is_err());
        assert_eq!(
            b.database().device_sync_header().unwrap().generation,
            generation
        );
        assert!(b
            .database()
            .device_sync_backup_reference_owners()
            .unwrap()
            .is_empty());
    }
    first
        .apply(
            Some(&mut auth),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert!(matches!(
        first.apply(
            Some(&mut auth),
            None,
            &CancellationToken::default(),
            &mut |_| {}
        ),
        Err(ReceiverError::AuthorizationMismatch)
    ));
}

#[tokio::test]
async fn receiver_retained_source_and_durable_backup_protect_real_originals() {
    let (_source, _target, a, b) = empty_pair();
    let original = import(&a, b"retained source", "a.jpg").await;
    let retained = Snapshot::retain(&a.database(), "A").unwrap();
    a.delete_media(original.id).unwrap();
    assert_eq!(
        std::fs::read(retained.originals()[0].path()).unwrap(),
        b"retained source"
    );
    let video = import(&b, b"old retained video", "video.mp4").await;
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
    let input = tempfile::tempdir().unwrap();
    let edited = input.path().join("edited.mp4");
    std::fs::write(&edited, b"new edited video").unwrap();
    let new = b
        .commit_video_edit(video.id, edited.to_string_lossy().into_owned(), true)
        .await
        .unwrap();
    assert_eq!(
        std::fs::read(&video.storage_path).unwrap(),
        b"old retained video"
    );
    b.delete_media(new.id).unwrap();
    assert_eq!(
        std::fs::read(&video.storage_path).unwrap(),
        b"old retained video"
    );
    let mut restore = crate::device_sync::recovery::RecoveryOperation::preview_backup(
        b.database(),
        receipt.backup_uuid,
        "B",
    )
    .unwrap();
    let mut auth = restore.authorize().unwrap();
    restore
        .restore(Some(&mut auth), &CancellationToken::default())
        .unwrap();
    assert_eq!(
        b.database().media_asset(video.id).unwrap().sha256,
        video.sha256
    );
    assert_eq!(
        retained.snapshot().manifest.validate().unwrap().media.len(),
        1
    );
}

#[tokio::test]
async fn receiver_two_way_merge_keeps_rules_mappings_tombstones_and_album_identity() {
    use crate::device_sync::manifest::{ManifestRecord, MappingKind};
    let (_source, _target, a, b) = empty_pair();
    let media = import(&a, b"A media", "a.jpg").await;
    let local = import(&b, b"B media", "b.jpg").await;
    let tag = a.add_tag(media.id, "before".into()).unwrap();
    a.database().rename_tag(tag, "selected").unwrap();
    let tombstone = a.database().create_tag("deleted standalone").unwrap();
    a.database().delete_tag(tombstone).unwrap();
    a.set_favorite(media.id, true).unwrap();
    let manual = a
        .database()
        .create_album("Same title", "A album", false)
        .unwrap();
    a.database().add_media_to_album(manual, media.id).unwrap();
    b.database()
        .create_album("Same title", "B album", false)
        .unwrap();
    let smart = a
        .database()
        .create_album("Selected smart", "", true)
        .unwrap();
    a.database()
        .replace_album_rules(
            smart,
            &[crate::models::AlbumRule {
                rule_group: 0,
                field: "tag".into(),
                operator: "contains".into(),
                value: "selected".into(),
            }],
        )
        .unwrap();
    a.database()
        .rename_game_tag(&media.game_name, "Source display")
        .unwrap();
    let source = Snapshot::read(&a.database(), "A").unwrap();
    let origin = source.manifest.validate().unwrap();
    let mut ab =
        ReceiveOperation::prepare(b.database(), source.clone(), "B", SyncMode::Merge).unwrap();
    stage(&mut ab, b"A media");
    let mut auth = ab.authorize().unwrap();
    ab.apply(
        Some(&mut auth),
        None,
        &CancellationToken::default(),
        &mut |_| {},
    )
    .unwrap();
    assert_eq!(
        Snapshot::read_with_header(&a.database(), source.manifest.header.clone(), Some("A"))
            .unwrap(),
        source
    );
    let result = Snapshot::read(&b.database(), "B").unwrap();
    let validated = result.manifest.validate().unwrap();
    assert_eq!(validated.media.len(), 2);
    assert!(validated.tags["deleted standalone"].deleted);
    assert_eq!(
        validated.mappings[&(MappingKind::Tag, "before".into())]
            .target_name
            .as_deref(),
        Some("selected")
    );
    assert!(
        validated
            .mappings
            .values()
            .any(|m| m.kind == MappingKind::Game
                && m.target_name.as_deref() == Some("Source display"))
    );
    for (id, album) in &origin.albums {
        if id != crate::device_sync::manifest::FAVORITES_UUID {
            assert_eq!(validated.albums[id], *album);
        }
    }
    let albums = b.database().list_albums().unwrap();
    assert_eq!(
        albums
            .iter()
            .filter(|a| a.system_key.as_deref() == Some("favorites"))
            .count(),
        1
    );
    assert_eq!(albums.iter().filter(|a| a.name == "Same title").count(), 2);
    let smart_id = albums
        .iter()
        .find(|a| a.name == "Selected smart")
        .unwrap()
        .id;
    let query = GalleryQuery {
        album_id: Some(smart_id),
        ..GalleryQuery::default()
    };
    assert_eq!(b.list_media(query).unwrap().len(), 1);
    assert!(!result.manifest.records.iter().any(|r|matches!(r,ManifestRecord::Member(m) if m.album_uuid==origin.albums.values().find(|a|a.definition.name=="Selected smart").unwrap().definition.uuid)));
    let mut ba = ReceiveOperation::prepare(a.database(), result, "A", SyncMode::Merge).unwrap();
    stage(&mut ba, b"B media");
    let mut auth = ba.authorize().unwrap();
    ba.apply(
        Some(&mut auth),
        None,
        &CancellationToken::default(),
        &mut |_| {},
    )
    .unwrap();
    assert_eq!(a.list_media(GalleryQuery::default()).unwrap().len(), 2);
    assert_eq!(
        a.list_media(GalleryQuery::default())
            .unwrap()
            .iter()
            .find(|m| m.sha256 == media.sha256)
            .unwrap()
            .id,
        media.id
    );
    assert!(a
        .list_media(GalleryQuery::default())
        .unwrap()
        .iter()
        .any(|m| m.sha256 == local.sha256));
}
