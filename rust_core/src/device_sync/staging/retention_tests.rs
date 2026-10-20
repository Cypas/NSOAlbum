use super::tests::{fixture, receive, ABC_SHA};
use super::*;
use crate::device_sync::manifest::ManifestRecord;
use crate::device_sync::planner::{build_plan, SyncMode};
use crate::models::MediaKind;

fn cache_path(root: &Path) -> PathBuf {
    root.join("temporary/device-sync/verified-v1")
        .join(format!("{ABC_SHA}-3-image.jpg"))
}

fn prepare(db: &Arc<Database>, source: &Manifest, target: &Manifest) -> StagingOperation {
    StagingOperation::prepare(
        db.clone(),
        source,
        target,
        &build_plan(source, target, SyncMode::Merge).unwrap(),
    )
    .unwrap()
}

#[test]
fn retained_verified_object_survives_cancel_and_new_operation_publishes_without_transfer() {
    let (_root, db, source, target, plan) = fixture();
    let mut first = StagingOperation::prepare(db.clone(), &source, &target, &plan).unwrap();
    receive(&mut first);
    first.cancel().unwrap();
    drop(first);
    let mut retry = StagingOperation::prepare(db.clone(), &source, &target, &plan).unwrap();
    let lease = db.device_sync_exclusive().unwrap();
    let publication = retry
        .publish(
            &lease,
            retry.operation_id(),
            ABC_SHA,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(
        std::fs::read(publication.identity().path()).unwrap(),
        b"abc"
    );
}

#[test]
fn retained_verified_object_survives_drop_and_another_file_failure_but_partial_never_hits() {
    for failure in [false, true] {
        let (root, db, mut source, target, _) = fixture();
        let mut second = match &source.records[0] {
            ManifestRecord::Media(record) => record.clone(),
            _ => unreachable!(),
        };
        second.sha256 = "cb8379ac2098aa165029e3938a51da0bcecfc008fd6795f401178647f96c5b34".into();
        source.records.push(ManifestRecord::Media(second.clone()));
        let mut first = prepare(&db, &source, &target);
        receive(&mut first);
        first.begin_file(first.id, &second.sha256).unwrap();
        first
            .write_chunk(first.id, &second.sha256, 0, b"bad")
            .unwrap();
        if failure {
            assert_eq!(
                first.finish_file(
                    first.id,
                    &second.sha256,
                    &CancellationToken::default(),
                    &mut |_| {}
                ),
                Err(StagingError::ChecksumMismatch)
            );
        }
        let directory = first.directory.clone();
        drop(first);
        assert!(!directory.exists());
        assert_eq!(std::fs::read(cache_path(root.path())).unwrap(), b"abc");
        let retry = prepare(&db, &source, &target);
        assert!(!retry.requires_transfer(ABC_SHA).unwrap());
        assert!(retry.requires_transfer(&second.sha256).unwrap());
        assert!(!root.path().join("originals").exists());
    }
}

#[test]
fn unfinished_part_in_old_operation_is_not_a_verified_cache() {
    let (_root, db, source, target, _) = fixture();
    let mut first = prepare(&db, &source, &target);
    first.begin_file(first.id, ABC_SHA).unwrap();
    first.write_chunk(first.id, ABC_SHA, 0, b"abc").unwrap();
    let retry = prepare(&db, &source, &target);
    assert!(retry.requires_transfer(ABC_SHA).unwrap());
    assert_eq!(retry.space.requirements.staging_bytes, 3);
    first.cancel().unwrap();
    assert_eq!(
        first.requires_transfer(ABC_SHA),
        Err(StagingError::Cancelled)
    );
    assert_eq!(
        retry.requires_transfer(&"0".repeat(64)),
        Err(StagingError::UnknownMedia)
    );
}

#[test]
fn cache_key_binds_length_sha_kind_and_extension_without_borrowing_other_keys() {
    let (root, db, source, target, _) = fixture();
    let mut first = prepare(&db, &source, &target);
    receive(&mut first);
    drop(first);
    for alteration in 0..4 {
        let mut changed = source.clone();
        let ManifestRecord::Media(record) = &mut changed.records[0] else {
            unreachable!()
        };
        match alteration {
            0 => record.length = 4,
            1 => record.sha256 = "0".repeat(64),
            2 => {
                record.kind = MediaKind::Video;
                record.extension = "mp4".into();
            }
            3 => record.extension = "jpeg".into(),
            _ => unreachable!(),
        }
        let sha = record.sha256.clone();
        let retry = prepare(&db, &changed, &target);
        assert!(
            retry.requires_transfer(&sha).unwrap(),
            "alteration {alteration}"
        );
    }
    assert_eq!(std::fs::read(cache_path(root.path())).unwrap(), b"abc");
    // A wrong-kind key with identical bytes does not satisfy the requested key.
    let wrong_kind = root
        .path()
        .join("temporary/device-sync/verified-v1")
        .join(format!("{ABC_SHA}-3-video.jpg"));
    std::fs::rename(cache_path(root.path()), &wrong_kind).unwrap();
    let retry = prepare(&db, &source, &target);
    assert!(retry.requires_transfer(ABC_SHA).unwrap());
    assert_eq!(std::fs::read(wrong_kind).unwrap(), b"abc");
}

#[test]
fn corrupted_cache_is_rehashed_rejected_and_never_deleted_or_overwritten() {
    for bytes in [b"abd".as_slice(), b"ab".as_slice()] {
        let (root, db, source, target, plan) = fixture();
        let mut first = prepare(&db, &source, &target);
        receive(&mut first);
        drop(first);
        let path = cache_path(root.path());
        std::fs::write(&path, bytes).unwrap();
        let result = StagingOperation::prepare(db, &source, &target, &plan);
        assert!(matches!(
            result,
            Err(StagingError::ChecksumMismatch | StagingError::LengthMismatch)
        ));
        assert_eq!(std::fs::read(path).unwrap(), bytes);
    }
}

#[test]
fn same_key_concurrent_finish_is_no_clobber_and_both_operations_can_copy() {
    let (root, db, source, target, _) = fixture();
    let first = prepare(&db, &source, &target);
    let second = prepare(&db, &source, &target);
    let barrier = Arc::new(std::sync::Barrier::new(2));
    let operations = std::thread::scope(|scope| {
        let handles = [first, second].map(|mut operation| {
            let barrier = barrier.clone();
            scope.spawn(move || {
                operation.begin_file(operation.id, ABC_SHA).unwrap();
                operation
                    .write_chunk(operation.id, ABC_SHA, 0, b"abc")
                    .unwrap();
                barrier.wait();
                operation
                    .finish_file(
                        operation.id,
                        ABC_SHA,
                        &CancellationToken::default(),
                        &mut |_| {},
                    )
                    .unwrap();
                operation
            })
        });
        handles.map(|handle| handle.join().unwrap())
    });
    assert_eq!(
        std::fs::read_dir(root.path().join("temporary/device-sync/verified-v1"))
            .unwrap()
            .count(),
        1
    );
    let lease = db.device_sync_exclusive().unwrap();
    for mut operation in operations {
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
        assert!(publication.rollback().unwrap());
    }
    assert_eq!(std::fs::read(cache_path(root.path())).unwrap(), b"abc");
}

#[test]
fn corrupt_racing_incumbent_is_not_clobbered_by_a_fresh_verified_part() {
    let (root, db, source, target, _) = fixture();
    let mut first = prepare(&db, &source, &target);
    let mut second = prepare(&db, &source, &target);
    receive(&mut first);
    std::fs::write(cache_path(root.path()), b"bad").unwrap();
    second.begin_file(second.id, ABC_SHA).unwrap();
    second.write_chunk(second.id, ABC_SHA, 0, b"abc").unwrap();
    assert_eq!(
        second.finish_file(
            second.id,
            ABC_SHA,
            &CancellationToken::default(),
            &mut |_| {}
        ),
        Err(StagingError::ChecksumMismatch)
    );
    assert_eq!(
        second.requires_transfer(ABC_SHA),
        Err(StagingError::InvalidState)
    );
    assert_eq!(std::fs::read(cache_path(root.path())).unwrap(), b"bad");
}

#[test]
fn rollback_preserves_reusable_cache_and_space_only_discounts_staging() {
    let (root, db, source, target, _) = fixture();
    let mut first = prepare(&db, &source, &target);
    receive(&mut first);
    let first_id = first.id;
    let lease = db.device_sync_exclusive().unwrap();
    let published = first
        .publish(
            &lease,
            first.id,
            ABC_SHA,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    assert!(published.rollback().unwrap());
    drop(lease);
    drop(first);
    let retry = prepare(&db, &source, &target);
    assert_ne!(retry.id, first_id);
    assert_eq!(retry.space.requirements.staging_bytes, 0);
    assert_eq!(retry.space.requirements.publication_bytes, 3);
    assert_eq!(
        retry.space.requirements.stage_peak_bytes,
        if retry.space.requirements.same_volume {
            3
        } else {
            0
        }
    );
    assert_eq!(retry.space.requirements.media_peak_bytes, 3);
    assert!(retry.space.excludes_metadata_and_filesystem_overhead);
    assert_eq!(
        SpaceRequirements::checked(0, u64::MAX, true)
            .unwrap()
            .stage_peak_bytes,
        u64::MAX
    );
    assert_eq!(
        SpaceRequirements::checked(1, u64::MAX, true),
        Err(StagingError::Overflow)
    );
    assert_eq!(
        SpaceRequirements::checked(0, 3, false)
            .unwrap()
            .stage_peak_bytes,
        0
    );
    assert_eq!(std::fs::read(cache_path(root.path())).unwrap(), b"abc");
}

#[cfg(any(windows, unix))]
#[test]
fn cache_object_and_ancestor_links_are_rejected_without_touching_external_bytes() {
    for link_at in 0..3 {
        let (root, db, source, target, plan) = fixture();
        let mut first = prepare(&db, &source, &target);
        receive(&mut first);
        drop(first);
        let outside = tempfile::tempdir().unwrap();
        let external = outside.path().join("sentinel");
        std::fs::write(&external, b"external").unwrap();
        if link_at == 0 {
            let path = cache_path(root.path());
            std::fs::remove_file(&path).unwrap();
            #[cfg(windows)]
            std::os::windows::fs::symlink_file(&external, &path).unwrap();
            #[cfg(unix)]
            std::os::unix::fs::symlink(&external, &path).unwrap();
        } else {
            let directory = if link_at == 1 {
                root.path().join("temporary/device-sync/verified-v1")
            } else {
                root.path().join("temporary/device-sync")
            };
            std::fs::rename(&directory, directory.with_extension("retained")).unwrap();
            #[cfg(windows)]
            std::os::windows::fs::symlink_dir(outside.path(), &directory).unwrap();
            #[cfg(unix)]
            std::os::unix::fs::symlink(outside.path(), &directory).unwrap();
        }
        assert!(matches!(
            StagingOperation::prepare(db, &source, &target, &plan),
            Err(StagingError::UnsafePath)
        ));
        assert_eq!(std::fs::read(external).unwrap(), b"external");
        assert_eq!(std::fs::read_dir(outside.path()).unwrap().count(), 1);
    }
}

#[test]
fn replaced_cache_or_ancestor_directory_after_prepare_cannot_publish() {
    for ancestor in [false, true] {
        let (root, db, source, target, _) = fixture();
        let mut first = prepare(&db, &source, &target);
        receive(&mut first);
        drop(first);
        let mut retry = prepare(&db, &source, &target);
        let directory = if ancestor {
            root.path().join("temporary")
        } else {
            root.path().join("temporary/device-sync/verified-v1")
        };
        let parked = directory.with_extension("retained");
        match std::fs::rename(&directory, &parked) {
            Ok(()) => {}
            Err(error) => {
                // Windows can refuse directory replacement while its live
                // identity handle is held. This is an exercised OS boundary.
                assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
                assert!(!parked.exists());
                let lease = db.device_sync_exclusive().unwrap();
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
                assert!(publication.rollback().unwrap());
                continue;
            }
        }
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::create_dir_all(cache_path(root.path()).parent().unwrap()).unwrap();
        std::fs::write(cache_path(root.path()), b"abc").unwrap();
        let lease = db.device_sync_exclusive().unwrap();
        assert!(matches!(
            retry.publish(
                &lease,
                retry.id,
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {}
            ),
            Err(StagingError::UnsafePath)
        ));
        assert!(db.device_sync_original_path(ABC_SHA).unwrap().is_none());
        assert_eq!(std::fs::read(cache_path(root.path())).unwrap(), b"abc");
        assert!(parked.is_dir());
    }
}

#[test]
fn bounded_cache_lookup_does_not_scan_old_operations_or_unrequested_corruption() {
    let (root, db, source, target, _) = fixture();
    let mut first = prepare(&db, &source, &target);
    receive(&mut first);
    drop(first);
    let runtime = root.path().join("temporary/device-sync");
    std::fs::create_dir(runtime.join("old-operation")).unwrap();
    std::fs::write(
        runtime.join("old-operation/unverified.part"),
        b"do not inspect",
    )
    .unwrap();
    std::fs::write(
        runtime.join("verified-v1/unrequested-object"),
        b"corrupt unrelated bytes",
    )
    .unwrap();
    let retry = prepare(&db, &source, &target);
    assert!(!retry.requires_transfer(ABC_SHA).unwrap());
    assert_eq!(
        std::fs::read(runtime.join("old-operation/unverified.part")).unwrap(),
        b"do not inspect"
    );
    assert_eq!(
        std::fs::read(runtime.join("verified-v1/unrequested-object")).unwrap(),
        b"corrupt unrelated bytes"
    );
}

#[test]
fn cache_reverification_obeys_cancellation_during_streaming_and_preserves_the_object() {
    use crate::device_sync::work::WorkControl;
    let (root, db, mut source, target, _) = fixture();
    let bytes = vec![0x5a; 64 * 1024 * 1024];
    let ManifestRecord::Media(record) = &mut source.records[0] else {
        unreachable!()
    };
    record.sha256 = hex::encode(Sha256::digest(&bytes));
    record.length = bytes.len() as u64;
    let record = record.clone();
    let runtime = root.path().join("temporary/device-sync");
    paths::ensure_directory(&runtime).unwrap();
    let cache = CacheRoot::open(&runtime, Default::default()).unwrap();
    let path = runtime
        .join("verified-v1")
        .join(format!("{}-67108864-image.jpg", record.sha256));
    std::fs::write(&path, &bytes).unwrap();
    let work = WorkControl::default();
    std::thread::scope(|scope| {
        let task = scope.spawn(|| cache.lookup(&record, &work));
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while work.observe().work_items < 2 {
            assert!(
                std::time::Instant::now() < deadline,
                "no streamed validation observed"
            );
            std::thread::yield_now();
        }
        work.cancellation().cancel();
        assert!(matches!(task.join().unwrap(), Err(StagingError::Cancelled)));
    });
    assert_eq!(std::fs::metadata(&path).unwrap().len(), 67108864);
    let retry = prepare(&db, &source, &target);
    assert!(!retry.requires_transfer(&record.sha256).unwrap());
}

#[cfg(windows)]
#[test]
fn windows_junction_cache_root_is_rejected_as_reparse_not_followed() {
    use std::os::windows::process::CommandExt;
    let (root, db, source, target, plan) = fixture();
    let mut first = prepare(&db, &source, &target);
    receive(&mut first);
    drop(first);
    let directory = root.path().join("temporary/device-sync/verified-v1");
    std::fs::rename(&directory, directory.with_extension("retained")).unwrap();
    let outside = tempfile::tempdir().unwrap();
    let sentinel = outside.path().join("sentinel");
    std::fs::write(&sentinel, b"outside").unwrap();
    let output = std::process::Command::new("cmd.exe")
        .creation_flags(0x0800_0000)
        .args(["/C", "mklink", "/J"])
        .arg(directory.to_string_lossy().replace('/', "\\"))
        .arg(outside.path().to_string_lossy().replace('/', "\\"))
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(matches!(
        StagingOperation::prepare(db, &source, &target, &plan),
        Err(StagingError::UnsafePath)
    ));
    assert_eq!(std::fs::read(sentinel).unwrap(), b"outside");
    assert_eq!(std::fs::read_dir(outside.path()).unwrap().count(), 1);
}

#[test]
fn hardlinked_cache_object_is_rejected_without_changing_either_name() {
    let (root, db, source, target, plan) = fixture();
    let mut first = prepare(&db, &source, &target);
    receive(&mut first);
    drop(first);
    let external = root.path().join("external-hardlink");
    std::fs::hard_link(cache_path(root.path()), &external).unwrap();
    assert!(matches!(
        StagingOperation::prepare(db, &source, &target, &plan),
        Err(StagingError::UnsafePath)
    ));
    assert_eq!(std::fs::read(external).unwrap(), b"abc");
    assert_eq!(std::fs::read(cache_path(root.path())).unwrap(), b"abc");
}

#[test]
fn cancelling_a_replaced_part_name_does_not_delete_the_replacement() {
    let (_root, db, source, target, _) = fixture();
    let mut operation = prepare(&db, &source, &target);
    operation.begin_file(operation.id, ABC_SHA).unwrap();
    operation
        .write_chunk(operation.id, ABC_SHA, 0, b"a")
        .unwrap();
    let path = operation.entries[ABC_SHA]
        .part
        .as_ref()
        .unwrap()
        .path()
        .to_path_buf();
    std::fs::remove_file(&path).unwrap();
    std::fs::write(&path, b"not owned by the operation").unwrap();
    assert_eq!(operation.cancel(), Err(StagingError::Cleanup));
    drop(operation);
    assert_eq!(std::fs::read(path).unwrap(), b"not owned by the operation");
}
