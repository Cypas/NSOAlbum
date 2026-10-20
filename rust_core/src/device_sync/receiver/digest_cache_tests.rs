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
