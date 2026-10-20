use super::tests::{fixture, receive, ABC_SHA};
use super::*;
use crate::device_sync::manifest::ManifestRecord;

#[test]
fn transfer_writes_do_not_compute_media_sha_before_final_validation() {
    let (_root, database, source, target, plan) = fixture();
    let work = super::super::work::WorkControl::default();
    let mut operation =
        StagingOperation::prepare_controlled(database, &source, &target, &plan, &work).unwrap();
    operation.begin_file(operation.id, ABC_SHA).unwrap();
    operation
        .write_chunk(operation.id, ABC_SHA, 0, b"abc")
        .unwrap();
    assert_eq!(work.validation_metrics().receive_hashed_bytes, 0);
    assert_eq!(work.validation_metrics().checksum_read_bytes, 0);
    assert!(operation
        .check_handoff_complete(&CancellationToken::default())
        .is_err());
}

#[test]
fn final_validation_reads_once_and_copying_does_not_reread_verified_bytes() {
    let (_root, database, source, target, plan) = fixture();
    let work = super::super::work::WorkControl::default();
    let mut operation =
        StagingOperation::prepare_controlled(database.clone(), &source, &target, &plan, &work)
            .unwrap();
    receive(&mut operation);
    let after_receive = work.validation_metrics();
    assert_eq!(after_receive.receive_hashed_bytes, 0);
    assert_eq!(
        after_receive.checksum_read_bytes, 3,
        "content is read once during final validation"
    );
    let lease = database.device_sync_exclusive().unwrap();
    let publication = operation
        .publish(
            &lease,
            operation.id,
            ABC_SHA,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(
        std::fs::read(publication.identity().path()).unwrap(),
        b"abc"
    );
    let after_copy = work.validation_metrics();
    assert_eq!(after_copy.copy_bytes, 3);
    assert_eq!(
        after_copy.checksum_read_bytes, 3,
        "publication must hash the copy, not reread it"
    );
}

#[test]
fn copy_rejects_same_length_corruption_without_a_second_pass() {
    let (root, _database, source, _target, _plan) = fixture();
    let ManifestRecord::Media(record) = &source.records[0] else {
        panic!()
    };
    let input = root.path().join("synthetic-input");
    std::fs::write(&input, b"abd").unwrap();
    let mut output = OwnedPart::create(root.path()).unwrap();
    assert_eq!(
        copy_file(
            File::open(input).unwrap(),
            &mut output,
            record,
            &CancellationToken::default(),
            &mut |_| {},
            &Default::default()
        ),
        Err(StagingError::ChecksumMismatch),
    );
}

#[test]
fn rejected_duplicate_offset_does_not_enter_the_digest_or_byte_counts() {
    let (_root, database, source, target, plan) = fixture();
    let work = super::super::work::WorkControl::default();
    let mut operation =
        StagingOperation::prepare_controlled(database, &source, &target, &plan, &work).unwrap();
    operation.begin_file(operation.id, ABC_SHA).unwrap();
    operation
        .write_chunk(operation.id, ABC_SHA, 0, b"a")
        .unwrap();
    assert_eq!(
        operation.write_chunk(operation.id, ABC_SHA, 0, b"a"),
        Err(StagingError::Offset)
    );
    operation
        .write_chunk(operation.id, ABC_SHA, 1, b"bc")
        .unwrap();
    operation
        .finish_file(
            operation.id,
            ABC_SHA,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(work.validation_metrics().receive_hashed_bytes, 0);
    assert_eq!(work.validation_metrics().checksum_read_bytes, 3);
}

#[test]
fn short_write_counts_only_the_prefix_that_really_reached_the_writer() {
    struct ShortWriter(bool);
    impl Write for ShortWriter {
        fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
            if self.0 {
                return Ok(0);
            }
            self.0 = true;
            Ok(1)
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut written = 0;
    assert_eq!(
        write_counted(
            &mut ShortWriter(false),
            b"abc",
            &mut written,
            &mut progress(Phase::Receiving, 0, Some(3)),
            3,
        ),
        Err(StagingError::Write)
    );
    assert_eq!(written, 1);
}

#[test]
fn sealed_files_are_untrusted_until_the_final_batch_pass() {
    let (_root, database, source, target, plan) = fixture();
    let work = super::super::work::WorkControl::default();
    let mut operation =
        StagingOperation::prepare_controlled(database.clone(), &source, &target, &plan, &work)
            .unwrap();
    operation.begin_file(operation.id, ABC_SHA).unwrap();
    operation
        .write_chunk(operation.id, ABC_SHA, 0, b"abc")
        .unwrap();
    let cancel = CancellationToken::default();
    assert_eq!(
        operation.verify_received(&cancel, &mut |_| {}),
        Err(StagingError::InvalidState)
    );
    operation.seal_file(operation.id, ABC_SHA, &cancel).unwrap();
    assert_eq!(work.validation_metrics().checksum_read_bytes, 0);
    assert!(operation.check_handoff_complete(&cancel).is_err());
    assert!(
        !operation.requires_transfer(ABC_SHA).unwrap(),
        "Do not request a sealed file again"
    );
    let lease = database.device_sync_exclusive().unwrap();
    assert!(matches!(
        operation.publish(&lease, operation.id, ABC_SHA, &cancel, &mut |_| {}),
        Err(StagingError::InvalidState)
    ));
    drop(lease);
    let mut progress = Vec::new();
    operation
        .verify_received(&cancel, &mut |event| progress.push(event))
        .unwrap();
    assert_eq!(work.validation_metrics().checksum_read_bytes, 3);
    assert_eq!(progress.last().unwrap().completed_bytes, 3);
    operation.check_handoff_complete(&cancel).unwrap();
    operation.verify_received(&cancel, &mut |_| {}).unwrap();
    assert_eq!(
        work.validation_metrics().checksum_read_bytes,
        3,
        "Reuse this operation's validation"
    );
}

#[test]
fn wrong_sha_at_final_batch_never_enters_cache_or_changes_the_library() {
    let (_root, database, source, target, plan) = fixture();
    let mut operation =
        StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
    operation.begin_file(operation.id, ABC_SHA).unwrap();
    operation
        .write_chunk(operation.id, ABC_SHA, 0, b"abd")
        .unwrap();
    operation
        .seal_file(operation.id, ABC_SHA, &CancellationToken::default())
        .unwrap();
    assert_eq!(
        operation.verify_received(&CancellationToken::default(), &mut |_| {}),
        Err(StagingError::ChecksumMismatch)
    );
    assert!(database
        .device_sync_original_path(ABC_SHA)
        .unwrap()
        .is_none());
    let retry = StagingOperation::prepare(database, &source, &target, &plan).unwrap();
    assert!(retry.requires_transfer(ABC_SHA).unwrap());
}

#[test]
fn cancelling_final_batch_keeps_unverified_files_out_of_the_verified_cache() {
    let (_root, database, source, target, plan) = fixture();
    let mut operation =
        StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
    operation.begin_file(operation.id, ABC_SHA).unwrap();
    operation
        .write_chunk(operation.id, ABC_SHA, 0, b"abc")
        .unwrap();
    let cancel = CancellationToken::default();
    operation.seal_file(operation.id, ABC_SHA, &cancel).unwrap();
    assert_eq!(
        operation.verify_received(&cancel, &mut |_| cancel.cancel()),
        Err(StagingError::Cancelled)
    );
    let retry = StagingOperation::prepare(database, &source, &target, &plan).unwrap();
    assert!(retry.requires_transfer(ABC_SHA).unwrap());
}

#[test]
fn final_batch_waits_for_all_files_then_reports_cumulative_real_bytes() {
    let (_root, database, mut source, target, _) = fixture();
    let ManifestRecord::Media(mut second) = source.records[0].clone() else {
        panic!()
    };
    const XYZ_SHA: &str = "3608bca1e44ea6c4d268eb6db02260269892c0b42b86bbf1e77a6fa16c3c9282";
    second.sha256 = XYZ_SHA.into();
    source.records.push(ManifestRecord::Media(second));
    let plan = crate::device_sync::planner::build_plan(
        &source,
        &target,
        crate::device_sync::planner::SyncMode::Merge,
    )
    .unwrap();
    let work = crate::device_sync::work::WorkControl::default();
    let mut operation =
        StagingOperation::prepare_controlled(database, &source, &target, &plan, &work).unwrap();
    let cancel = CancellationToken::default();
    operation.begin_file(operation.id, ABC_SHA).unwrap();
    operation
        .write_chunk(operation.id, ABC_SHA, 0, b"abc")
        .unwrap();
    operation.seal_file(operation.id, ABC_SHA, &cancel).unwrap();
    assert_eq!(
        operation.verify_received(&cancel, &mut |_| {}),
        Err(StagingError::InvalidState)
    );
    assert_eq!(work.validation_metrics().checksum_read_bytes, 0);
    operation.begin_file(operation.id, XYZ_SHA).unwrap();
    operation
        .write_chunk(operation.id, XYZ_SHA, 0, b"xyz")
        .unwrap();
    operation.seal_file(operation.id, XYZ_SHA, &cancel).unwrap();
    let mut events = Vec::new();
    operation
        .verify_received(&cancel, &mut |event| events.push(event))
        .unwrap();
    assert_eq!(work.validation_metrics().receive_hashed_bytes, 0);
    assert_eq!(work.validation_metrics().checksum_read_bytes, 6);
    assert!(events.iter().all(|event| event.total_bytes == Some(6)));
    assert!(events
        .windows(2)
        .all(|pair| pair[0].completed_bytes <= pair[1].completed_bytes));
    assert_eq!(events.last().unwrap().completed_bytes, 6);
}

#[test]
fn new_operation_revalidates_cache_once_then_reuses_its_result() {
    let (_root, database, source, target, plan) = fixture();
    let mut first = StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
    receive(&mut first);
    first.cancel().unwrap();
    let work = super::super::work::WorkControl::default();
    let mut retry =
        StagingOperation::prepare_controlled(database.clone(), &source, &target, &plan, &work)
            .unwrap();
    assert_eq!(work.validation_metrics().checksum_read_bytes, 3);
    for _ in 0..100 {
        assert!(!retry.requires_transfer(ABC_SHA).unwrap());
    }
    let lease = database.device_sync_exclusive().unwrap();
    let publication = retry
        .publish(
            &lease,
            retry.id,
            ABC_SHA,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(
        std::fs::read(publication.identity().path()).unwrap(),
        b"abc"
    );
    assert_eq!(work.validation_metrics().checksum_read_bytes, 3);
    assert_eq!(work.validation_metrics().copy_bytes, 3);
    assert_eq!(work.validation_metrics().receive_hashed_bytes, 0);
}

#[test]
fn changed_receiving_file_cannot_become_a_verified_cache_entry() {
    let (_root, database, source, target, plan) = fixture();
    let mut operation = StagingOperation::prepare(database, &source, &target, &plan).unwrap();
    operation.begin_file(operation.id, ABC_SHA).unwrap();
    operation
        .write_chunk(operation.id, ABC_SHA, 0, b"abc")
        .unwrap();
    let part = operation.entries[ABC_SHA].part.as_ref().unwrap().path();
    std::fs::write(part, b"abd").unwrap();
    File::options()
        .write(true)
        .open(part)
        .unwrap()
        .set_times(
            std::fs::FileTimes::new().set_modified(
                std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(100),
            ),
        )
        .unwrap();
    assert_eq!(
        operation.finish_file(
            operation.id,
            ABC_SHA,
            &CancellationToken::default(),
            &mut |_| {}
        ),
        Err(StagingError::ChecksumMismatch)
    );
    assert_eq!(operation.progress().phase, Phase::Failed);
}
