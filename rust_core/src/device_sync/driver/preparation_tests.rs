use super::*;
use crate::device_sync::manifest::ManifestRecord;
use crate::device_sync::work::test_observer::pause_cache_reads;
use std::sync::mpsc;
use std::time::{Duration, Instant};

enum Command {
    Poll(Vec<u8>),
    Approve,
    Stop,
}

struct Reply {
    result: Result<Vec<u8>>,
    state: State,
    needed: usize,
    transferred: u64,
}

fn target_loop(
    target: &mut Driver,
    commands: mpsc::Receiver<Command>,
    replies: mpsc::Sender<Reply>,
) {
    while let Ok(command) = commands.recv() {
        let result = match command {
            Command::Poll(bytes) => (|| {
                if !bytes.is_empty() {
                    target.ingest_ciphertext(&bytes)?;
                }
                target.poll()?;
                let output = target.drain_ciphertext()?;
                if !output.is_empty() {
                    target.ciphertext_written(output.len())?;
                }
                Ok(output)
            })(),
            Command::Approve => target.approve_preview().map(|_| vec![]),
            Command::Stop => break,
        };
        if replies
            .send(Reply {
                result,
                state: target.state(),
                needed: target.needed.len(),
                transferred: target.progress.transferred_bytes,
            })
            .is_err()
        {
            break;
        }
    }
    target.cancel();
    target.finish_shutdown();
}

struct Remote {
    commands: mpsc::Sender<Command>,
    replies: mpsc::Receiver<Reply>,
    pending: bool,
    last_state: State,
    last_needed: usize,
    last_transferred: u64,
}

struct StopRemote<'a> {
    pause: &'a crate::device_sync::work::test_observer::CacheReadPause,
    commands: mpsc::Sender<Command>,
}

impl Drop for StopRemote<'_> {
    fn drop(&mut self) {
        self.pause.release_all();
        let _ = self.commands.send(Command::Stop);
    }
}

impl Remote {
    fn cycle(&mut self, source: &mut Driver) -> Result<()> {
        source.poll()?;
        if !self.pending {
            let bytes = source.drain_ciphertext()?;
            if !bytes.is_empty() {
                source.ciphertext_written(bytes.len())?;
            }
            self.commands.send(Command::Poll(bytes)).unwrap();
            self.pending = true;
        }
        if let Ok(reply) = self.replies.recv_timeout(Duration::from_millis(5)) {
            self.pending = false;
            self.last_state = reply.state;
            self.last_needed = reply.needed;
            self.last_transferred = reply.transferred;
            let bytes = reply.result?;
            if !bytes.is_empty() {
                source.ingest_ciphertext(&bytes)?;
            }
        }
        Ok(())
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
async fn preparation_real_tls_continues_actual_cache_reads_past_sixty_seconds_then_reconfirms() {
    let mut pair = cached_pair().await;
    let pause = pause_cache_reads(&pair.phone.work_control());
    let (commands, receive_commands) = mpsc::channel();
    let (send_replies, replies) = mpsc::channel();
    let mut remote = Remote {
        commands,
        replies,
        pending: false,
        last_state: State::Pairing,
        last_needed: 0,
        last_transferred: 0,
    };
    pair.host
        .configure(Direction::DesktopToPhone, SyncMode::Merge, false)
        .unwrap();
    let outcome = std::thread::scope(|scope| -> Result<()> {
        let target = &mut pair.phone;
        scope.spawn(move || target_loop(target, receive_commands, send_replies));
        let _cleanup = StopRemote {
            pause: &pause,
            commands: remote.commands.clone(),
        };
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut first_read = None;
        while first_read.is_none() && Instant::now() < deadline {
            remote.cycle(&mut pair.host)?;
            first_read = pause.try_wait().ok();
        }
        assert_eq!(first_read, Some(65536), "no actual cache SHA read");
        for index in 0..6 {
            if index > 0 {
                assert_eq!(pause.wait().unwrap(), ((index % 3) + 1) * 65536);
            }
            pair.hc.advance(20000);
            pair.pc.advance(20000);
            for _ in 0..8 {
                remote.cycle(&mut pair.host)?;
            }
            assert_eq!(
                pair.host.preparation_allowance.as_ref().unwrap().completed,
                (index + 1) * 65536
            );
            assert!(pair
                .b
                .list_media(GalleryQuery::default())
                .unwrap()
                .is_empty());
            pause.release_one();
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        while (pair.host.state() != State::AwaitingApproval
            || remote.last_state != State::AwaitingApproval)
            && Instant::now() < deadline
        {
            remote.cycle(&mut pair.host)?;
        }
        assert_eq!(pair.host.state(), State::AwaitingApproval);
        assert_eq!(remote.last_state, State::AwaitingApproval);
        assert_eq!(remote.last_needed, 1);
        assert_eq!(pair.hc.monotonic_ms(), 120000);
        assert_eq!(remote.last_transferred, 0);
        assert!(pair
            .b
            .list_media(GalleryQuery::default())
            .unwrap()
            .is_empty());
        while remote.pending {
            remote.cycle(&mut pair.host)?;
        }
        remote.commands.send(Command::Approve).unwrap();
        remote
            .replies
            .recv_timeout(Duration::from_secs(5))
            .unwrap()
            .result?;
        let deadline = Instant::now() + Duration::from_secs(15);
        while (pair.host.state() != State::Completed || remote.last_state != State::Completed)
            && Instant::now() < deadline
        {
            remote.cycle(&mut pair.host)?;
        }
        assert_eq!(pair.host.state(), State::Completed);
        assert_eq!(remote.last_state, State::Completed);
        assert_eq!(pair.host.progress.transferred_bytes, 131072);
        assert_eq!(remote.last_transferred, 131072);
        assert_eq!(pair.b.list_media(GalleryQuery::default()).unwrap().len(), 3);
        Ok(())
    });
    assert!(
        outcome.is_ok(),
        "real cache reads lost their live TLS session: {outcome:?}"
    );
}

async fn paused_pair() -> (
    Pair,
    crate::device_sync::work::test_observer::CacheReadPause,
) {
    let (pair, pause, _) = paused_pair_snapshot().await;
    (pair, pause)
}

async fn paused_pair_snapshot() -> (
    Pair,
    crate::device_sync::work::test_observer::CacheReadPause,
    Snapshot,
) {
    let mut pair = cached_pair().await;
    let target_snapshot = Snapshot::read(&pair.b.database(), "Phone").unwrap();
    let pause = pause_cache_reads(&pair.phone.work_control());
    pair.host
        .configure(Direction::DesktopToPhone, SyncMode::Merge, false)
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        cycle(&mut pair.host, &mut pair.phone);
        if pause.try_wait().is_ok() {
            break;
        }
        assert!(Instant::now() < deadline);
    }
    for _ in 0..10 {
        cycle(&mut pair.host, &mut pair.phone);
    }
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
async fn preparation_paused_read_does_not_renew_either_endpoint_deadline() {
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
async fn preparation_real_multi_file_progress_respects_fifo_backpressure_without_renewing_old_bytes(
) {
    let (mut pair, pause) = paused_pair().await;
    pair.phone.flush_required = true;
    for index in 1..6 {
        pause.release_one();
        assert_eq!(pause.wait().unwrap(), ((index % 3) + 1) * 65536);
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
        let deadline = Instant::now() + Duration::from_secs(5);
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
