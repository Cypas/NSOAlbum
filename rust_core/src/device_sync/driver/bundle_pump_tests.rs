use super::*;
use crate::device_sync::driver::pump::bundle::BundlePump;
use crate::device_sync::mailbox::bundle::{BundleDecoder, BundleEncoder};

struct AdvancingPreparationClock {
    mono: AtomicU64,
    wall: i64,
}
impl Clock for AdvancingPreparationClock {
    fn monotonic_ms(&self) -> u64 {
        self.mono.fetch_add(2, Ordering::SeqCst)
    }
    fn unix_ms(&self) -> i64 {
        self.wall
    }
}

#[tokio::test]
async fn usb_active_preparation_crossing_flush_deadline_still_fills_target() {
    let mut pair = super::stream_tests::window_pair().await;
    pair.host.clock = Arc::new(AdvancingPreparationClock {
        mono: AtomicU64::new(pair.hc.monotonic_ms()),
        wall: pair.hc.unix_ms(),
    });
    let mut pump = BundlePump::default();
    let first = pump
        .outgoing_without_finish(&mut pair.host)
        .unwrap()
        .map(|(name, bytes)| (name.to_owned(), bytes.to_vec()))
        .unwrap();
    assert!(
        first.1.len() >= 4 * 1024 * 1024,
        "a publication timer must not stop actively available bounded preparation"
    );
    assert!(pair.host.clock.monotonic_ms() >= 50);
    let before = pair.host.file.as_ref().unwrap().offset;
    let pending = pump
        .outgoing_without_finish(&mut pair.host)
        .unwrap()
        .map(|(name, bytes)| (name.to_owned(), bytes.to_vec()))
        .unwrap();
    assert_eq!(pending, first, "native write ownership must stay exact");
    assert!(pair.host.file.as_ref().unwrap().offset >= before + 4 * 1024 * 1024);
    assert!(pump.buffered_bytes() <= 16 * 1024 * 1024);
    pump.written(&mut pair.host).unwrap();
    let next = pump
        .outgoing_without_finish(&mut pair.host)
        .unwrap()
        .unwrap();
    assert!(next.1.len() >= 4 * 1024 * 1024);
    assert_ne!(next.0, first.0);
    pair.host.cancel();
    assert!(pump.outgoing_without_finish(&mut pair.host).is_err());
}

#[tokio::test]
async fn usb_large_media_reaches_four_mib_target_without_waiting_for_a_peer_receipt() {
    let mut pair = super::stream_tests::window_pair().await;
    let mut pump = BundlePump::default();
    let (name, bytes) = pump
        .outgoing_without_finish(&mut pair.host)
        .unwrap()
        .map(|(name, bytes)| (name.to_owned(), bytes.to_vec()))
        .unwrap();
    assert!(bytes.len() >= 4 * 1024 * 1024);
    assert!(bytes.len() < 4 * 1024 * 1024 + 65_536 + 1024);
    assert!(
        BundleDecoder::default()
            .decode(&name, &bytes)
            .unwrap()
            .len()
            > 4
    );
    assert!(pair.host.file.as_ref().unwrap().offset <= 16 * 1024 * 1024);
    assert!(pump.buffered_bytes() <= 16 * 1024 * 1024);
    pump.written(&mut pair.host).unwrap();
    assert_eq!(
        pair.host.progress.transferred_bytes, 0,
        "native publication must not masquerade as peer receipt"
    );
}

#[tokio::test]
async fn usb_prepares_next_carrier_while_the_exact_previous_write_is_in_flight() {
    let mut pair = super::stream_tests::window_pair().await;
    let mut pump = BundlePump::default();
    let first = pump
        .outgoing_without_finish(&mut pair.host)
        .unwrap()
        .map(|(name, bytes)| (name.to_owned(), bytes.to_vec()))
        .unwrap();
    let before = pair.host.file.as_ref().unwrap().offset;
    let retried = pump
        .outgoing_without_finish(&mut pair.host)
        .unwrap()
        .map(|(name, bytes)| (name.to_owned(), bytes.to_vec()))
        .unwrap();
    assert_eq!(
        retried, first,
        "preparation cannot replace an in-flight native capability"
    );
    assert!(
        pair.host.file.as_ref().unwrap().offset > before,
        "native latency must overlap bounded media preparation"
    );
    assert!(pump.buffered_bytes() <= 16 * 1024 * 1024);
    assert_eq!(pair.host.progress.transferred_bytes, 0);
    pump.written(&mut pair.host).unwrap();
    let (next, _) = pump
        .outgoing_without_finish(&mut pair.host)
        .unwrap()
        .unwrap();
    assert_ne!(next, first.0);
    assert!(pair.host.file.as_ref().unwrap().offset <= 16 * 1024 * 1024);
}

#[tokio::test]
async fn usb_consumes_an_already_received_media_batch_before_publishing_its_ready_acks() {
    let mut pair = Pair::new();
    let fixture = tempfile::tempdir().unwrap();
    let file = fixture.path().join("four-chunks.jpg");
    std::fs::write(&file, vec![7; 4 * wire::MEDIA_CHUNK]).unwrap();
    pair.a
        .import_local_files(vec![file.to_string_lossy().into_owned()])
        .await
        .unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while pair.host.file.is_none() && std::time::Instant::now() < deadline {
        pair.phone.poll().unwrap();
        let bytes = pair.phone.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.host.ingest_ciphertext(&bytes).unwrap();
            pair.phone.ciphertext_written(bytes.len()).unwrap();
        }
        pair.host.poll().unwrap();
        if pair.host.file.is_some() {
            break;
        }
        let bytes = pair.host.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.phone.ingest_ciphertext(&bytes).unwrap();
            pair.host.ciphertext_written(bytes.len()).unwrap();
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    assert!(pair.host.file.is_some());
    let mut sender = BundlePump::default();
    let mut receiver = BundlePump::default();
    let (name, bytes) = sender
        .outgoing_without_finish(&mut pair.host)
        .unwrap()
        .map(|(name, bytes)| (name.to_owned(), bytes.to_vec()))
        .unwrap();
    sender.written(&mut pair.host).unwrap();
    let mut accepted = receiver.accept(&mut pair.phone, &name, &bytes).unwrap();
    while accepted.is_none() {
        pair.phone.poll().unwrap();
        accepted = receiver.resume_input(&mut pair.phone).unwrap();
    }
    let count = pair.host.file.as_ref().unwrap().pending_chunks.len();
    assert!((2..=16).contains(&count));
    pair.phone.poll().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while pair.phone.verification.is_some() {
        assert!(std::time::Instant::now() < deadline);
        pair.phone.poll().unwrap();
        std::thread::yield_now();
    }
    assert_eq!(
        pair.phone.progress.transferred_bytes,
        (count * wire::MEDIA_CHUNK) as u64
    );
    // Real verification progress may precede the tail receipt in TLS output.
    // Only the cumulative tail receipt, not that progress, releases the file.
    while pair.host.file.is_some() {
        assert!(std::time::Instant::now() < deadline);
        pair.phone.poll().unwrap();
        let ack = pair.phone.drain_ciphertext().unwrap();
        if !ack.is_empty() {
            pair.host.ingest_ciphertext(&ack).unwrap();
            pair.phone.ciphertext_written(ack.len()).unwrap();
        }
        pair.host.poll().unwrap();
    }
    // File-tail cumulative receipt releases every actually sent byte.
    assert!(pair.host.file.is_none());
    assert_eq!(
        pair.host.progress.transferred_bytes,
        4 * wire::MEDIA_CHUNK as u64
    );
}

#[test]
fn usb_coalesces_ready_chunk_acks_without_waiting_or_changing_tcp_output() {
    for (transport, expected) in [
        (crate::device_sync::Transport::Usb, 3),
        (
            crate::device_sync::Transport::Tcp("127.0.0.1:45123".parse().unwrap()),
            1,
        ),
    ] {
        let mut pair = Pair::new();
        let (_, mut host, mut phone, time) =
            crate::device_sync::tests::pair(transport, Role::Sender);
        crate::device_sync::tests::pump(&mut host, &mut phone, time).unwrap();
        host.confirm(time).unwrap();
        phone.confirm(time).unwrap();
        crate::device_sync::tests::pump(&mut host, &mut phone, time).unwrap();
        pair.host.session = host;
        pair.phone.session = phone;
        for offset in 1..=3 {
            pair.host
                .enqueue(Message::ChunkAccepted {
                    sha256: "a".repeat(64),
                    offset,
                })
                .unwrap();
        }
        pair.host.poll().unwrap();
        let bytes = pair.host.drain_ciphertext().unwrap();
        pair.phone.ingest_ciphertext(&bytes).unwrap();
        let mut offsets = vec![];
        while let Some(payload) = pair.phone.session.receive_payload(time).unwrap() {
            let envelope = Envelope::decode(&payload).unwrap();
            assert_eq!(envelope.sequence, offsets.len() as u64);
            let Message::ChunkAccepted { offset, .. } = envelope.message else {
                panic!("unexpected application payload")
            };
            offsets.push(offset);
        }
        assert_eq!(offsets, (1..=expected).collect::<Vec<u64>>());
        assert_eq!(pair.host.outbox.len(), 3 - expected as usize);
    }
}

#[tokio::test]
async fn bundle_pump_streams_real_library_media_with_multiple_drains_and_bounded_ownership() {
    let mut pair = Pair::new();
    let fixture = tempfile::tempdir().unwrap();
    let input = fixture.path().join("synthetic.jpg");
    std::fs::write(&input, vec![0x53; 1024 * 1024]).unwrap();
    pair.a
        .import_local_files(vec![input.to_string_lossy().into_owned()])
        .await
        .unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    let mut a = BundlePump::default();
    let mut b = BundlePump::default();
    let mut inspect = BundleDecoder::default();
    let mut largest_bundle = 0;
    let mut largest_carrier = 0;
    let mut writes = 0;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    while std::time::Instant::now() < deadline {
        pair.host.poll().unwrap();
        pair.phone.poll().unwrap();
        let prepared_before = pair.host.file.as_ref().map_or(0, |file| file.offset);
        {
            if let Some((name, bytes)) = a.outgoing_without_finish(&mut pair.host).unwrap() {
                let name = name.to_owned();
                let bytes = bytes.to_vec();
                let count = inspect.decode(&name, &bytes).unwrap().len();
                largest_bundle = largest_bundle.max(count);
                largest_carrier = largest_carrier.max(bytes.len());
                // Count carriers that actually prepared media, not required
                // immediate lease/verification/finalization control messages.
                writes += usize::from(
                    pair.host
                        .file
                        .as_ref()
                        .is_some_and(|file| file.offset > prepared_before),
                );
                assert!(bytes.len() <= 8 * 1024 * 1024);
                assert!(pair.host.outstanding_ciphertext > 0);
                a.written(&mut pair.host).unwrap(); // Simulated successful atomic OS publication.
                let mut ack = b.accept(&mut pair.phone, &name, &bytes).unwrap();
                while ack.is_none() {
                    pair.phone.poll().unwrap();
                    ack = b.resume_input(&mut pair.phone).unwrap();
                }
                assert_eq!(ack.as_deref(), Some(name.as_str()));
            }
        }
        if let Some((name, bytes)) = b.outgoing_without_finish(&mut pair.phone).unwrap() {
            let (name, bytes) = (name.to_owned(), bytes.to_vec());
            b.written(&mut pair.phone).unwrap();
            let mut ack = a.accept(&mut pair.host, &name, &bytes).unwrap();
            while ack.is_none() {
                pair.host.poll().unwrap();
                ack = a.resume_input(&mut pair.host).unwrap();
            }
        }
        assert!(a.buffered_bytes() <= 16 * 1024 * 1024);
        assert!(b.buffered_bytes() <= 16 * 1024 * 1024);
        if pair.host.state() == State::Completed && pair.phone.state() == State::Completed {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    assert_eq!(pair.host.state(), State::Completed);
    assert_eq!(pair.phone.state(), State::Completed);
    assert!(
        largest_bundle > 4 && largest_carrier >= 512 * 1024,
        "available byte credits must reach the large-carrier target, not the old four-frame cap"
    );
    assert!(
        writes <= 5,
        "oneMiB must stream in a few large carriers, not one carrier per small window"
    );
    let received = pair.b.list_media(GalleryQuery::default()).unwrap();
    assert_eq!(received.len(), 1);
    assert_eq!(
        std::fs::read(&received[0].storage_path).unwrap(),
        vec![0x53; 1024 * 1024]
    );
    assert!(a.finish_success(&mut pair.host));
    assert!(b.finish_success(&mut pair.phone));
}

#[test]
fn bundle_pump_retains_unaccepted_tail_without_exposing_an_early_directory_ack() {
    let mut pair = Pair::new();
    for index in 0..9u8 {
        pair.host
            .session
            .send_media_payload(&vec![index; 16_384], pair.hc.unix_ms() / 1000)
            .unwrap();
    }
    let mut drains = vec![];
    loop {
        let bytes = pair.host.drain_ciphertext().unwrap();
        if bytes.is_empty() {
            break;
        }
        drains.push(bytes);
    }
    assert_eq!(drains.len(), 3);
    let encoded = BundleEncoder::default().encode(&drains).unwrap();
    let mut receiver = BundlePump::default();
    assert!(receiver
        .accept(&mut pair.phone, &encoded.name, &encoded.bytes)
        .unwrap()
        .is_none());
    assert!(receiver.buffered_bytes() > 0);
    let mut received = Vec::new();
    let mut ack = None;
    for _ in 0..30 {
        while let Some(payload) = pair
            .phone
            .session
            .receive_payload(pair.pc.unix_ms() / 1000)
            .unwrap()
        {
            received.push(payload);
        }
        if ack.is_none() {
            ack = receiver.resume_input(&mut pair.phone).unwrap();
        }
        if received.len() == 9 {
            break;
        }
    }
    assert_eq!(ack.as_deref(), Some(encoded.name.as_str()));
    assert_eq!(
        received,
        (0..9u8)
            .map(|index| vec![index; 16_384])
            .collect::<Vec<_>>()
    );
    assert_eq!(receiver.buffered_bytes(), 0);
}

#[test]
fn bundle_pump_window_full_keeps_the_exact_sequence_and_does_not_fake_a_native_write() {
    let mut pair = Pair::new();
    pair.host
        .session
        .send_payload(b"synthetic control", pair.hc.unix_ms() / 1000)
        .unwrap();
    let mut pump = BundlePump::default();
    let (name, bytes) = pump
        .outgoing_without_finish(&mut pair.host)
        .unwrap()
        .map(|(name, bytes)| (name.to_owned(), bytes.to_vec()))
        .unwrap();
    let outstanding = pair.host.outstanding_ciphertext;
    assert!(outstanding > 0);
    assert_eq!(pump.buffered_bytes(), bytes.len());
    pump.window_full();
    assert!(pump
        .outgoing_without_finish(&mut pair.host)
        .unwrap()
        .is_none());
    assert_eq!(pair.host.outstanding_ciphertext, outstanding);
    pump.capacity_released();
    let retried = pump
        .outgoing_without_finish(&mut pair.host)
        .unwrap()
        .unwrap();
    assert_eq!(retried, (name.as_str(), bytes.as_slice()));
    pump.written(&mut pair.host).unwrap();
    assert_eq!(pair.host.outstanding_ciphertext, 0);
    assert_eq!(pump.buffered_bytes(), 0);
}
