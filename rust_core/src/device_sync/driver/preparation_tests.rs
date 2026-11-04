use super::*;
use crate::device_sync::manifest::ManifestRecord;
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Hold a real preparation result until the protocol fixture releases it.
/// Byte advances are explicit protocol-test inputs, never product cache reads.
struct PausedPreparation {
    release: mpsc::SyncSender<()>,
    work: crate::device_sync::work::WorkControl,
}

impl PausedPreparation {
    fn advance(&self, bytes: u64) {
        self.work.preparation_read(bytes).unwrap();
    }

    fn release_all(&self) {
        let _ = self.release.try_send(());
    }
}

impl Drop for PausedPreparation {
    fn drop(&mut self) {
        self.release_all();
    }
}

async fn cached_pair() -> Pair {
    let pair = Pair::new();
    let input = tempfile::tempdir().unwrap();
    for (name, value, length) in [
        ("cached-one.jpg", 41, 196608),
        ("cached-two.jpg", 42, 196608),
        ("missing.jpg", 43, 131072),
    ] {
        let path = input.path().join(name);
        std::fs::write(&path, vec![value; length]).unwrap();
        pair.a
            .import_local_files(vec![path.to_string_lossy().into_owned()])
            .await
            .unwrap();
    }
    let snapshot = Snapshot::read(&pair.a.database(), "Desktop").unwrap();
    let mut seed = ReceiveOperation::prepare(
        pair.b.database(),
        snapshot.clone(),
        "Phone",
        SyncMode::Merge,
    )
    .unwrap();
    let media = pair.a.list_media(GalleryQuery::default()).unwrap();
    for record in &snapshot.manifest.records {
        if let ManifestRecord::Media(record) = record {
            if record.length == 196608 {
                let item = media
                    .iter()
                    .find(|item| item.sha256 == record.sha256)
                    .unwrap();
                let bytes = std::fs::read(&item.storage_path).unwrap();
                let operation = seed.operation_id();
                let stage = seed.staging_mut();
                stage.begin_file(operation, &record.sha256).unwrap();
                for (index, chunk) in bytes.chunks(65536).enumerate() {
                    stage
                        .write_chunk(operation, &record.sha256, index as u64 * 65536, chunk)
                        .unwrap();
                }
                stage
                    .finish_file(
                        operation,
                        &record.sha256,
                        &CancellationToken::default(),
                        &mut |_| {},
                    )
                    .unwrap();
            }
        }
    }
    drop(seed);
    assert!(pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .is_empty());
    pair
}

#[tokio::test]
async fn preparation_reuses_verified_cache_without_hash_reads_and_transfers_only_missing_media() {
    let mut pair = cached_pair().await;
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    assert_eq!(pair.phone.needed.len(), 1);
    assert_eq!(pair.phone.work.validation_metrics().checksum_read_bytes, 0);
    assert_eq!(pair.phone.progress.transferred_bytes, 0);
    pair.complete(Direction::DesktopToPhone);
    assert_eq!(pair.host.progress.transferred_bytes, 131072);
    assert_eq!(pair.phone.progress.transferred_bytes, 131072);
    assert_eq!(
        pair.phone.work.validation_metrics().checksum_read_bytes,
        131072
    );
    assert_eq!(pair.b.list_media(GalleryQuery::default()).unwrap().len(), 3);
    assert_eq!(
        pair.phone.permit.published_bytes.load(Ordering::SeqCst),
        524288,
        "copying and publishing must not count the same media bytes twice"
    );
}

#[tokio::test]
async fn media_transfer_with_progress_over_five_minutes_still_reaches_apply() {
    let mut pair = Pair::new();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("long-transfer.jpg");
    let media = vec![73; 34 * 1024 * 1024];
    std::fs::write(&path, &media).unwrap();
    pair.a
        .import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();

    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();

    let start = pair.hc.monotonic_ms();
    let mut received = pair.phone.progress.transferred_bytes;
    let mut saw_apply = false;
    // The synthetic clock advances through a >5 minute transfer; keep enough
    // wall-clock budget for real chunk I/O and filesystem work on CI workers.
    let deadline = Instant::now() + Duration::from_secs(120);
    while Instant::now() < deadline {
        cycle(&mut pair.host, &mut pair.phone);
        saw_apply |= matches!(
            pair.phone.state(),
            State::Applying | State::AwaitingExternal | State::Completed
        );
        let current = pair.phone.progress.transferred_bytes;
        if current > received {
            let transferred = current - received;
            let chunks = transferred.div_ceil(crate::device_sync::wire::MEDIA_CHUNK as u64);
            // Simulate three seconds per real received chunk. A 4 MiB ACK
            // cadence then stays below the 60-second no-progress deadline,
            // while the full transfer takes more than five minutes.
            let elapsed = chunks * 3_000;
            pair.hc.advance(elapsed);
            pair.pc.advance(elapsed);
            received = current;
        }
        if pair.host.state() == State::Completed && pair.phone.state() == State::Completed {
            break;
        }
    }

    let elapsed = pair.hc.monotonic_ms().saturating_sub(start);
    assert!(
        elapsed > 300_000,
        "the synthetic transfer must model more than five minutes, got {elapsed}ms"
    );
    assert_eq!(pair.host.progress.transferred_bytes, media.len() as u64);
    assert_eq!(pair.phone.progress.transferred_bytes, media.len() as u64);
    assert!(saw_apply, "the receiver never entered its apply phase");
    assert_eq!(pair.host.state(), State::Completed);
    assert_eq!(pair.phone.state(), State::Completed);
    let imported = pair.b.list_media(GalleryQuery::default()).unwrap();
    assert_eq!(imported.len(), 1);
    assert_eq!(std::fs::read(&imported[0].storage_path).unwrap(), media);
}

async fn paused_pair() -> (Pair, PausedPreparation) {
    let (pair, pause, _) = paused_pair_snapshot().await;
    (pair, pause)
}

async fn paused_pair_snapshot() -> (Pair, PausedPreparation, Snapshot) {
    let mut pair = cached_pair().await;
    let target_snapshot = Snapshot::read(&pair.b.database(), "Phone").unwrap();
    let source = Snapshot::read(&pair.a.database(), "Desktop").unwrap();
    let source_digest = source.digest_controlled(&pair.phone.work).unwrap();
    let limit = preparation_limit(&source).unwrap();
    let bytes = crate::device_sync::work::PreparationBytes::new(limit);
    let work = pair.phone.work.with_preparation(bytes.clone());
    // Exercise protocol bounds without making metadata-only cache lookup
    // manufacture progress bytes in product code.
    work.preparation_read(65536).unwrap();
    let (release, released) = mpsc::sync_channel(1);
    let worker_work = work.clone();
    let database = pair.b.database();
    let worker_source = source.clone();
    let worker = std::thread::spawn(move || {
        let _ = released.recv_timeout(Duration::from_secs(30));
        ReceiveOperation::prepare_controlled(
            database,
            worker_source,
            "Phone",
            SyncMode::Merge,
            None,
            &worker_work,
        )
    });
    for endpoint in [&mut pair.host, &mut pair.phone] {
        endpoint.config = Some(Config {
            direction: Direction::DesktopToPhone,
            mode: SyncMode::Merge,
            accounts: false,
        });
        endpoint.state = State::Comparing;
        endpoint.deadline = DATA_MS;
        endpoint.source = Some(source.clone());
        endpoint.source_digest = Some(source_digest.clone());
    }
    pair.host.step = Step::ReceiveTarget;
    pair.host.preparation_allowance = Some(PreparationAllowance {
        source_digest: source_digest.clone(),
        limit,
        completed: 65536,
        open: true,
    });
    pair.phone.step = Step::PreparingTarget;
    pair.phone.preparation = Some(Preparation {
        session: pair.phone.session.session_id().into(),
        operation: pair.phone.session.operation_id().into(),
        source_digest,
        bytes,
        last_observed: 65536,
        last_enqueued: 65536,
        active: true,
        worker,
    });
    let pause = PausedPreparation { release, work };
    assert_eq!(
        pair.host.preparation_allowance.as_ref().unwrap().completed,
        65536
    );
    assert_eq!(
        pair.phone.preparation.as_ref().unwrap().bytes.completed(),
        65536
    );
    assert!(pair.phone.outbox.is_empty());
    (pair, pause, target_snapshot)
}

fn send_frame(from: &mut Driver, to: &mut Driver, message: Message) -> Result<()> {
    let envelope = Envelope {
        version: 1,
        session: from.session.session_id().into(),
        operation: from.session.operation_id().into(),
        generation: 1,
        sequence: from.sent_sequence,
        message,
    };
    from.session
        .send_payload(&envelope.encode()?, from.clock.unix_ms() / 1000)?;
    from.sent_sequence += 1;
    let bytes = from.drain_ciphertext()?;
    to.ingest_ciphertext(&bytes)?;
    from.ciphertext_written(bytes.len())?;
    to.poll()
}

#[tokio::test]
async fn preparation_tls_rejects_zero_duplicate_regression_over_budget_and_wrong_digest() {
    for (completed, wrong_digest) in [
        (0, false),
        (65536, false),
        (65535, false),
        (524289, false),
        (65537, true),
    ] {
        let (mut pair, pause) = paused_pair().await;
        let allowance = pair.host.preparation_allowance.as_ref().unwrap();
        assert_eq!(allowance.limit, 524288);
        let digest = if wrong_digest {
            "f".repeat(64)
        } else {
            allowance.source_digest.clone()
        };
        let result = send_frame(
            &mut pair.phone,
            &mut pair.host,
            Message::PreparationProgress {
                source_digest: digest,
                completed_bytes: completed,
            },
        );
        pause.release_all();
        assert!(matches!(result, Err(DriverError::Protocol)));
        assert_eq!(pair.host.state(), State::Failed);
        assert!(pair
            .b
            .list_media(GalleryQuery::default())
            .unwrap()
            .is_empty());
    }
}

#[tokio::test]
async fn preparation_progress_window_closes_at_snapshot_start_with_zero_or_existing_pages() {
    for page in [false, true] {
        let (mut pair, pause, target) = paused_pair_snapshot().await;
        let digest = pair
            .host
            .preparation_allowance
            .as_ref()
            .unwrap()
            .source_digest
            .clone();
        send_frame(
            &mut pair.phone,
            &mut pair.host,
            Message::SnapshotStart {
                header: target.manifest.header.clone(),
            },
        )
        .unwrap();
        assert!(pair.host.collector.is_some());
        assert!(!pair.host.preparation_allowance.as_ref().unwrap().open);
        if page {
            let mut sender = MetadataSender::with_control(target, &pair.phone.work).unwrap();
            let message = sender.next().unwrap().unwrap();
            assert!(matches!(message, Message::PagePart { .. }));
            send_frame(&mut pair.phone, &mut pair.host, message).unwrap();
            assert_eq!(pair.host.progress.metadata_parts, 1);
        }
        let result = send_frame(
            &mut pair.phone,
            &mut pair.host,
            Message::PreparationProgress {
                source_digest: digest,
                completed_bytes: 65537,
            },
        );
        pause.release_all();
        assert!(matches!(result, Err(DriverError::Protocol)));
        assert!(pair
            .b
            .list_media(GalleryQuery::default())
            .unwrap()
            .is_empty());
    }
}

#[tokio::test]
async fn preparation_progress_is_rejected_on_target_side_despite_a_correct_source_digest() {
    let (mut pair, pause) = paused_pair().await;
    let digest = pair
        .host
        .preparation_allowance
        .as_ref()
        .unwrap()
        .source_digest
        .clone();
    let result = send_frame(
        &mut pair.host,
        &mut pair.phone,
        Message::PreparationProgress {
            source_digest: digest,
            completed_bytes: 65537,
        },
    );
    pause.release_all();
    assert!(matches!(result, Err(DriverError::Protocol)));
    assert_eq!(pair.phone.state(), State::Failed);
    pair.phone.finish_shutdown();
    assert!(pair.phone.authorization.is_none());
    assert!(pair.phone.receive.is_none());
}

#[tokio::test]
async fn preparation_progress_after_real_preview_cannot_reopen_the_preparation_window() {
    let mut pair = cached_pair().await;
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    let allowance = pair.host.preparation_allowance.as_ref().unwrap();
    assert!(!allowance.open);
    let digest = allowance.source_digest.clone();
    let completed = allowance.completed + 1;
    assert!(completed <= allowance.limit);
    let result = send_frame(
        &mut pair.phone,
        &mut pair.host,
        Message::PreparationProgress {
            source_digest: digest,
            completed_bytes: completed,
        },
    );
    assert!(matches!(result, Err(DriverError::Protocol)));
    assert!(pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn preparation_without_new_work_does_not_renew_either_endpoint_deadline() {
    for source in [true, false] {
        let (mut pair, pause) = paused_pair().await;
        let result = if source {
            pair.hc.advance(60000);
            pair.host.poll()
        } else {
            pair.pc.advance(60000);
            pair.phone.poll()
        };
        pause.release_all();
        assert!(matches!(result, Err(DriverError::Timeout)));
        assert!(pair
            .b
            .list_media(GalleryQuery::default())
            .unwrap()
            .is_empty());
        assert!(pair.phone.authorization.is_none());
    }
}

#[tokio::test]
async fn preparation_accounted_work_respects_fifo_backpressure_without_renewing_old_bytes() {
    let (mut pair, pause) = paused_pair().await;
    pair.phone.flush_required = true;
    for _ in 1..6 {
        pause.advance(65536);
        pair.pc.advance(1000);
        pair.phone.poll().unwrap();
        assert!(pair.phone.outbox.len() <= 4);
    }
    let owner = pair.phone.preparation.as_ref().unwrap();
    assert_eq!(owner.last_observed, 393216);
    assert_eq!(owner.last_enqueued, 327680);
    assert_eq!(pair.phone.outbox.len(), 4);
    let deadline = pair.phone.deadline;
    pair.pc.advance(10000);
    pair.phone.flush_required = false;
    pair.phone.poll().unwrap();
    let bytes = pair.phone.drain_ciphertext().unwrap();
    pair.phone.ciphertext_written(bytes.len()).unwrap();
    pair.host.ingest_ciphertext(&bytes).unwrap();
    pair.host.poll().unwrap();
    assert_eq!(
        pair.host.preparation_allowance.as_ref().unwrap().completed,
        131072
    );
    pair.phone.poll().unwrap();
    assert_eq!(pair.phone.deadline, deadline);
    assert_eq!(
        pair.phone.preparation.as_ref().unwrap().last_enqueued,
        393216
    );
    assert_eq!(pair.phone.progress.transferred_bytes, 0);
    assert!(pair.phone.progress.peak_outbox_messages <= 4);
    pause.release_all();
}

#[tokio::test]
async fn preparation_cancel_retains_owned_worker_until_reaped_and_preserves_cache_without_preview()
{
    let (mut pair, pause) = paused_pair().await;
    pair.phone.cancel();
    assert!(pair.phone.preparation.is_some());
    assert!(!pair.phone.preparation.as_ref().unwrap().active);
    pair.phone.poll().unwrap();
    assert!(pair.phone.preparation.is_some());
    assert!(pair.phone.authorization.is_none());
    assert!(pair.phone.receive.is_none());
    assert!(pair.phone.binding.is_none());
    assert!(pair.phone.outbox.is_empty());
    pause.release_all();
    pair.phone.finish_shutdown();
    assert!(pair.phone.preparation.is_none());
    assert_eq!(pair.phone.state(), State::Cancelled);
    assert!(pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .is_empty());
    let mut retry = ReceiveOperation::prepare(
        pair.b.database(),
        Snapshot::read(&pair.a.database(), "Desktop").unwrap(),
        "Phone",
        SyncMode::Merge,
    )
    .unwrap();
    let hashes = retry
        .plan()
        .media
        .iter()
        .filter_map(|record| record.final_record.as_ref())
        .filter(|record| record.length == 196608)
        .map(|record| record.sha256.clone())
        .collect::<Vec<_>>();
    for sha in hashes {
        assert!(!retry.staging_mut().requires_transfer(&sha).unwrap());
    }
}

#[tokio::test]
async fn preparation_completed_worker_loses_to_cancel_or_stale_owner_and_shutdown_never_publishes()
{
    for action in 0..3 {
        let (mut pair, pause) = paused_pair().await;
        pause.release_all();
        // This waits only for the preparation test worker to finish; it is not
        // a virtual-clock or product timeout and may need slack under load.
        let deadline = Instant::now() + Duration::from_secs(30);
        while !pair
            .phone
            .preparation
            .as_ref()
            .unwrap()
            .worker
            .is_finished()
        {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        match action {
            0 => {
                pair.phone.cancel();
                pair.phone.poll().unwrap();
            }
            1 => {
                pair.phone.preparation.as_mut().unwrap().operation = "stale operation".into();
                assert!(matches!(pair.phone.poll(), Err(DriverError::Protocol)));
            }
            2 => pair.phone.finish_shutdown(),
            _ => unreachable!(),
        }
        assert!(pair.phone.preparation.is_none());
        assert!(pair.phone.receive.is_none());
        assert!(pair.phone.authorization.is_none());
        assert!(pair.phone.binding.is_none());
        assert!(pair.phone.outbox.is_empty());
        assert!(pair
            .b
            .list_media(GalleryQuery::default())
            .unwrap()
            .is_empty());
    }
}

#[test]
fn preparation_operation_counter_checks_overflow_and_budget_without_partial_increments() {
    use crate::device_sync::work::{PreparationBytes, WorkControl};
    for limit in [3, u64::MAX] {
        let bytes = PreparationBytes::new(limit);
        let work = WorkControl::default().with_preparation(bytes.clone());
        work.preparation_read(limit).unwrap();
        assert_eq!(bytes.completed(), limit);
        assert!(work.preparation_read(1).is_err());
        assert_eq!(bytes.completed(), limit);
    }
    let old = PreparationBytes::new(3);
    WorkControl::default()
        .with_preparation(old.clone())
        .preparation_read(3)
        .unwrap();
    assert_eq!(PreparationBytes::new(3).completed(), 0);
}
