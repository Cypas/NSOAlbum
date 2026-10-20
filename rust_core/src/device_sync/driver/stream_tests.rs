use super::*;

#[tokio::test]
async fn stream_receiver_retains_work_when_native_output_is_temporarily_blocked() {
    let mut pair = Pair::new();
    let fixture = tempfile::tempdir().unwrap();
    let mut paths = vec![];
    for index in 0..8 {
        let path = fixture.path().join(format!("slow-output-{index}.jpg"));
        std::fs::write(&path, vec![index as u8; 1024 * 1024]).unwrap();
        paths.push(path.to_string_lossy().into_owned());
    }
    pair.a.import_local_files(paths).await.unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(120);
    while pair.host.pending_files.is_empty() {
        assert!(std::time::Instant::now() < deadline);
        cycle(&mut pair.host, &mut pair.phone);
    }
    // A published USB write can remain in flight while the owner polls its
    // driver and accepts already-buffered media. Do not consume receiver output
    // until its real bounded response queue experiences backpressure.
    let mut peak = 0;
    for _ in 0..2_000 {
        let previous_bytes = pair.phone.progress.transferred_bytes;
        pair.host.poll().unwrap();
        if pair.phone.ready_for_input() {
            let bytes = pair.host.drain_ciphertext().unwrap();
            if !bytes.is_empty() {
                pair.phone.ingest_ciphertext(&bytes).unwrap();
                pair.host.ciphertext_written(bytes.len()).unwrap();
            }
        }
        pair.phone
            .poll()
            .expect("native output pressure must defer work, not fail the session");
        if pair.phone.progress.transferred_bytes > previous_bytes {
            pair.hc.advance(250);
            pair.pc.advance(250);
        }
        peak = peak.max(pair.phone.outbox.len());
        assert!(pair.phone.outbox.len() <= MAX_OUTBOX);
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    assert!(
        peak >= MAX_OUTBOX - 2,
        "fixture did not exercise output pressure"
    );
    assert!(!pair.phone.state().terminal());
    while pair.host.state() != State::Completed || pair.phone.state() != State::Completed {
        assert!(
            std::time::Instant::now() < deadline,
            "output release did not resume transfer"
        );
        cycle(&mut pair.host, &mut pair.phone);
    }
    let source: BTreeSet<_> = pair
        .a
        .list_media(GalleryQuery::default())
        .unwrap()
        .into_iter()
        .map(|media| media.sha256)
        .collect();
    let target: BTreeSet<_> = pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .into_iter()
        .map(|media| media.sha256)
        .collect();
    assert_eq!(source.len(), 8);
    assert_eq!(source, target);
    assert_eq!(pair.phone.progress.transferred_bytes, 8 * 1024 * 1024);
}

pub(super) async fn window_pair() -> Pair {
    let mut pair = Pair::new();
    let inputs = tempfile::tempdir().unwrap();
    let path = inputs.path().join("bounded.jpg");
    std::fs::write(&path, vec![19; 20 * 1024 * 1024]).unwrap();
    pair.a
        .import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    for _ in 0..1000 {
        cycle(&mut pair.host, &mut pair.phone);
        if pair.host.file.as_ref().is_some_and(|file| file.awaiting) {
            return pair;
        }
    }
    panic!("media transfer did not start");
}

#[tokio::test]
async fn stream_window_fills_sixteen_mib_without_peer_roundtrips_then_stops() {
    let mut pair = window_pair().await;
    let credited = pair.host.progress.transferred_bytes;
    for _ in 0..512 {
        pair.host.poll().unwrap();
        let bytes = pair.host.drain_ciphertext().unwrap();
        pair.host.ciphertext_written(bytes.len()).unwrap();
    }
    let sent = pair.host.file.as_ref().unwrap().offset;
    assert_eq!(sent - credited, 16 * 1024 * 1024);
    assert_eq!(pair.host.progress.transferred_bytes, credited);
    assert!(pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn stream_cumulative_ack_releases_multiple_chunks_and_duplicate_has_no_effect() {
    let mut pair = window_pair().await;
    for _ in 0..12 {
        pair.host.poll().unwrap();
        let bytes = pair.host.drain_ciphertext().unwrap();
        pair.host.ciphertext_written(bytes.len()).unwrap();
    }
    let file = pair.host.file.as_ref().unwrap();
    let sha = file.sha.clone();
    let end = file.offset;
    assert!(end >= 8 * 32_768);
    pair.host
        .handle(Message::ChunkAccepted {
            sha256: sha.clone(),
            offset: end,
        })
        .unwrap();
    assert_eq!(pair.host.progress.transferred_bytes, end);
    let until = pair.host.deadline;
    pair.hc.advance(10);
    pair.host
        .handle(Message::ChunkAccepted {
            sha256: sha.clone(),
            offset: end,
        })
        .unwrap();
    assert_eq!(pair.host.progress.transferred_bytes, end);
    assert_eq!(pair.host.deadline, until);
    assert!(pair
        .host
        .handle(Message::ChunkAccepted {
            sha256: sha.clone(),
            offset: end + 1
        })
        .is_err());
    assert!(pair
        .host
        .handle(Message::ChunkAccepted {
            sha256: sha,
            offset: end - 1
        })
        .is_err());
}

#[tokio::test]
async fn stream_receiver_batches_ack_but_flushes_a_short_tail_after_250ms() {
    let mut pair = window_pair().await;
    let before = pair.phone.sent_sequence;
    let received = pair.phone.progress.transferred_bytes;
    while pair.phone.progress.transferred_bytes == received {
        pair.host.poll().unwrap();
        let bytes = pair.host.drain_ciphertext().unwrap();
        assert!(!bytes.is_empty());
        pair.phone.ingest_ciphertext(&bytes).unwrap();
        pair.host.ciphertext_written(bytes.len()).unwrap();
        pair.phone.poll().unwrap();
    }
    assert_eq!(
        pair.phone.sent_sequence, before,
        "one small write emitted an immediate ACK"
    );
    pair.pc.advance(249);
    pair.phone.poll().unwrap();
    assert_eq!(pair.phone.sent_sequence, before);
    pair.pc.advance(1);
    pair.phone.poll().unwrap();
    assert_eq!(pair.phone.sent_sequence, before + 1);
}

#[tokio::test]
async fn stream_normal_screenshot_batch_is_bounded_by_sixteen_mib_not_eight_tiny_files() {
    let mut pair = Pair::new();
    let inputs = tempfile::tempdir().unwrap();
    let mut paths = vec![];
    for index in 0..9 {
        let path = inputs.path().join(format!("normal-{index}.jpg"));
        std::fs::write(&path, vec![index as u8; 2 * 1024 * 1024]).unwrap();
        paths.push(path.to_string_lossy().into_owned());
    }
    pair.a.import_local_files(paths).await.unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    let batch = pair
        .phone
        .outbox
        .iter()
        .find_map(|message| match message {
            Message::FileRequestBatch { sha256 } => Some(sha256),
            _ => None,
        })
        .expect("normal screenshots must share one request");
    assert_eq!(batch.len(), 8);
    assert_eq!(pair.phone.needed.len(), 1);
}

#[test]
fn ready_receipts_for_multiple_files_share_one_control_frame() {
    let mut pair = Pair::new();
    for sha in ["a".repeat(64), "b".repeat(64)] {
        pair.phone
            .enqueue(Message::ChunkAccepted {
                sha256: sha,
                offset: 2048,
            })
            .unwrap();
    }
    assert_eq!(
        pair.phone.outbox.len(),
        1,
        "ready cross-file receipts must be carried together"
    );
}

#[tokio::test]
async fn stream_multi_file_receipt_validates_every_offset_before_releasing_credit() {
    let mut pair = Pair::new();
    let inputs = tempfile::tempdir().unwrap();
    let mut paths = vec![];
    for index in 0..2 {
        let path = inputs.path().join(format!("receipt-{index}.jpg"));
        std::fs::write(&path, vec![index as u8; 2 * 1024 * 1024]).unwrap();
        paths.push(path.to_string_lossy().into_owned());
    }
    pair.a.import_local_files(paths).await.unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    while pair.host.file.is_none() {
        cycle(&mut pair.host, &mut pair.phone);
    }
    // Publish real encrypted media, but hold the peer's receipts.
    for _ in 0..128 {
        pair.host.poll().unwrap();
        let bytes = pair.host.drain_ciphertext().unwrap();
        pair.host.ciphertext_written(bytes.len()).unwrap();
    }
    let files: Vec<_> = pair
        .host
        .awaiting_files
        .iter()
        .chain(pair.host.file.iter())
        .map(|file| wire::FileReceipt {
            sha256: file.sha.clone(),
            offset: file.offset,
        })
        .collect();
    assert_eq!(files.len(), 2);
    assert!(files.iter().all(|file| file.offset == 2 * 1024 * 1024));
    let before = pair.host.progress.transferred_bytes;
    let mut invalid = files.clone();
    invalid[1].offset += 1;
    assert!(pair.host.accept_stream_receipts(invalid).is_err());
    assert_eq!(pair.host.progress.transferred_bytes, before);
    assert!(pair
        .host
        .accept_stream_receipts(vec![files[0].clone(); 2])
        .is_err());
    assert_eq!(pair.host.progress.transferred_bytes, before);
    pair.host.accept_stream_receipts(files.clone()).unwrap();
    assert_eq!(pair.host.progress.transferred_bytes, 4 * 1024 * 1024);
    pair.host.accept_stream_receipts(files).unwrap();
    assert_eq!(pair.host.progress.transferred_bytes, 4 * 1024 * 1024);
    assert!(pair.host.file.is_none() && pair.host.awaiting_files.is_empty());
}

#[tokio::test]
async fn stream_small_files_use_one_bounded_request_and_apply_every_file_once() {
    let mut pair = Pair::new();
    let inputs = tempfile::tempdir().unwrap();
    let mut paths = vec![];
    for index in 0..17 {
        let path = inputs.path().join(format!("batch-{index}.jpg"));
        std::fs::write(&path, vec![index as u8; 64 * 1024]).unwrap();
        paths.push(path.to_string_lossy().into_owned());
    }
    pair.a.import_local_files(paths).await.unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    let request = pair
        .phone
        .outbox
        .iter()
        .find_map(|message| match message {
            Message::FileRequestBatch { sha256 } => Some(sha256),
            _ => None,
        })
        .expect("small files still require a request per file");
    assert_eq!(request.len(), 8);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(120);
    let mut idle_until = std::time::Instant::now() + std::time::Duration::from_secs(30);
    let mut previous = None;
    while pair.host.state() != State::Completed || pair.phone.state() != State::Completed {
        let progress = [&pair.host, &pair.phone].map(|driver| {
            (
                driver.state(),
                driver.progress.transferred_bytes,
                driver.read_view().progress.scanned_items,
            )
        });
        if previous != Some(progress) {
            previous = Some(progress);
            idle_until = std::time::Instant::now() + std::time::Duration::from_secs(30);
        }
        assert!(
            std::time::Instant::now() < deadline && std::time::Instant::now() < idle_until,
            "batch transfer did not finish: states={:?}/{:?}, steps={}/{}, ready={}/{}, verification={:?}, outbox={}/{}, flushing={}/{}, source file={:?}, counts={}/{}",
            pair.host.state(), pair.phone.state(), pair.host.step as u8, pair.phone.step as u8,
            pair.host.ready_for_input(), pair.phone.ready_for_input(),
            pair.phone.verification.as_ref().map(|worker| worker.is_finished()),
            pair.host.outbox.len(), pair.phone.outbox.len(), pair.host.flush_required, pair.phone.flush_required,
            pair.host.file.as_ref().map(|file| (file.offset, file.length, file.acknowledged, file.pending_chunks.len())),
            pair.host.progress.transferred_bytes, pair.phone.progress.transferred_bytes,
        );
        // Respect backpressure and let real asynchronous filesystem workers
        // run, just like the managed owner; do not busy-spin through applying.
        cycle(&mut pair.host, &mut pair.phone);
    }
    assert_eq!(
        pair.b.list_media(GalleryQuery::default()).unwrap().len(),
        17
    );
    assert_eq!(pair.host.progress.transferred_bytes, 17 * 64 * 1024);
    assert_eq!(pair.phone.progress.transferred_bytes, 17 * 64 * 1024);
    assert_eq!(pair.phone.progress.peak_receiving_files, 1);
    let source: BTreeSet<_> = pair
        .a
        .list_media(GalleryQuery::default())
        .unwrap()
        .into_iter()
        .map(|media| media.sha256)
        .collect();
    let target: BTreeSet<_> = pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .into_iter()
        .map(|media| media.sha256)
        .collect();
    assert_eq!(source, target);
}

#[tokio::test]
async fn stream_mixed_file_sizes_complete_in_both_directions_without_missing_or_duplicate_bytes() {
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        let mut pair = Pair::new();
        let inputs = tempfile::tempdir().unwrap();
        let mut paths = vec![];
        for (index, length) in [8193, 262144, 327681, 16385, 2_359_297]
            .into_iter()
            .enumerate()
        {
            let path = inputs.path().join(format!("mixed-{index}.jpg"));
            std::fs::write(&path, vec![index as u8; length]).unwrap();
            paths.push(path.to_string_lossy().into_owned());
        }
        let (source, target) = match direction {
            Direction::DesktopToPhone => (&pair.a, &pair.b),
            Direction::PhoneToDesktop => (&pair.b, &pair.a),
        };
        source.import_local_files(paths).await.unwrap();
        let expected: BTreeSet<_> = source
            .list_media(GalleryQuery::default())
            .unwrap()
            .into_iter()
            .map(|media| media.sha256)
            .collect();
        let target_db = target.database();
        pair.preview(direction, SyncMode::Merge);
        pair.complete(direction);
        let actual: BTreeSet<_> = target_db
            .list_media(&GalleryQuery::default())
            .unwrap()
            .into_iter()
            .map(|media| media.sha256)
            .collect();
        assert_eq!(actual, expected);
        assert_eq!(pair.host.progress.transferred_bytes, 2_973_700);
        assert_eq!(pair.phone.progress.transferred_bytes, 2_973_700);
        let receiver = match direction {
            Direction::DesktopToPhone => &pair.phone,
            Direction::PhoneToDesktop => &pair.host,
        };
        assert_eq!(receiver.progress.peak_receiving_files, 1);
        assert_eq!(
            receiver.work.validation_metrics().checksum_read_bytes,
            2_973_700
        );
    }
}

#[tokio::test]
async fn stream_invalid_batch_cannot_open_or_mark_any_source_file_as_served() {
    let mut pair = Pair::new();
    let inputs = tempfile::tempdir().unwrap();
    let mut paths = vec![];
    for (index, length) in [10, 20, 4 * 1024 * 1024 + 1].into_iter().enumerate() {
        let path = inputs.path().join(format!("authorization-{index}.jpg"));
        std::fs::write(&path, vec![index as u8; length]).unwrap();
        paths.push(path.to_string_lossy().into_owned());
    }
    pair.a.import_local_files(paths).await.unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    let media = pair.a.list_media(GalleryQuery::default()).unwrap();
    let small: Vec<_> = media
        .iter()
        .filter(|m| std::fs::metadata(&m.storage_path).unwrap().len() < 100)
        .map(|m| m.sha256.clone())
        .collect();
    let large = media
        .iter()
        .find(|m| std::fs::metadata(&m.storage_path).unwrap().len() > 4 * 1024 * 1024)
        .unwrap()
        .sha256
        .clone();
    for invalid in [
        vec![small[0].clone(), small[0].clone()],
        vec![small[0].clone(), "0".repeat(64)],
        vec![small[0].clone(), large],
        vec![small[0].clone(); 9],
    ] {
        assert!(pair.host.start_stream_batch(invalid).is_err());
        assert!(pair.host.file.is_none());
        assert!(pair.host.pending_files.is_empty());
        assert!(pair.host.served.is_empty());
    }
    pair.host.start_stream_batch(small).unwrap();
    assert_eq!(pair.host.served.len(), 2);
    assert_eq!(pair.host.pending_files.len(), 1);
}
