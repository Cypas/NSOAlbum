use super::*;
use crate::api::CoreApi;

#[test]
fn immutable_receiver_binding_reuses_validation_and_remains_cancellable() {
    let source_root = tempfile::tempdir().unwrap();
    let target_root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let target = CoreApi::open(target_root.path()).unwrap();
    source.create_tag("synthetic".into()).unwrap();
    let cancel = CancellationToken::default();
    let work = super::super::work::WorkControl::new(cancel.clone());
    let mut operation = ReceiveOperation::prepare_controlled(
        target.database(),
        Snapshot::read(&source.database(), "Source").unwrap(),
        "Target",
        SyncMode::Merge,
        None,
        &work,
    )
    .unwrap();
    let binding = operation.binding().unwrap();
    assert_eq!(work.validation_metrics().snapshot_digests, 2);
    assert_eq!(work.validation_metrics().binding_digests, 1);
    let before = work.observe().work_items;
    for _ in 0..100 {
        assert_eq!(operation.binding().unwrap(), binding);
    }
    assert_eq!(
        work.observe().work_items,
        before,
        "immutable binding must not revalidate records"
    );
    assert_eq!(work.validation_metrics().snapshot_digests, 2);
    assert_eq!(work.validation_metrics().binding_digests, 1);
    let authorization = operation.authorize().unwrap();
    assert_eq!(operation.handoff_binding(&authorization).unwrap(), binding);
    cancel.cancel();
    assert!(matches!(operation.binding(), Err(CoreError::Cancelled)));
}

#[test]
fn cached_preview_binding_does_not_skip_the_final_library_change_check() {
    let source_root = tempfile::tempdir().unwrap();
    let target_root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(source_root.path()).unwrap();
    let target = CoreApi::open(target_root.path()).unwrap();
    source.create_tag("incoming".into()).unwrap();
    let mut operation = ReceiveOperation::prepare(
        target.database(),
        Snapshot::read(&source.database(), "Source").unwrap(),
        "Target",
        SyncMode::Merge,
    )
    .unwrap();
    let mut authorization = operation.authorize().unwrap();
    target.create_tag("late-local-edit".into()).unwrap();
    assert!(matches!(
        operation.apply(
            Some(&mut authorization),
            None,
            &CancellationToken::default(),
            &mut |_| {}
        ),
        Err(ReceiverError::PlanChanged)
    ));
    assert_eq!(target.list_tags().unwrap(), ["late-local-edit"]);
}

#[test]
fn benchmark_review_receiver_prepare_failed_snapshot_validation_is_timed_before_backup() {
    let root = tempfile::tempdir().unwrap();
    let target = CoreApi::open(root.path()).unwrap();
    let database = target.database();
    let mut snapshot = Snapshot::read(&database, "Target").unwrap();
    snapshot.sources.manifest_digest.clear();
    let cancel = CancellationToken::default();
    let work = super::super::work::WorkControl::new(cancel.clone());
    let lease = database.device_sync_exclusive().unwrap();

    let result = database.receiver_prepare(
        &lease,
        Uuid::new_v4(),
        &"a".repeat(64),
        &snapshot,
        true,
        None,
        &cancel,
        &work,
    );

    assert!(matches!(result, Err(CoreError::InvalidConfig(_))));
    let metrics = work.validation_metrics().to_string();
    assert!(metrics
        .split_whitespace()
        .any(|field| field == "apply_plan_count=1"));
    assert!(metrics
        .split_whitespace()
        .any(|field| field == "apply_originals_count=0"));
    assert!(metrics
        .split_whitespace()
        .any(|field| field == "apply_backup_count=0"));
    drop(lease);
    assert!(database.device_sync_pending_journal().unwrap().is_none());
}
