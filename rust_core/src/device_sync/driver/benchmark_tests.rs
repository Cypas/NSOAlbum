use super::*;

fn synchronized_pair() -> Pair {
    let mut pair = Pair::new();
    pair.a
        .create_album("Shared album".into(), "Synthetic only".into(), false)
        .unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.complete(Direction::DesktopToPhone);
    let (host, phone, _) = confirmed(Role::Receiver);
    pair.host = Driver::new(host, pair.a.database(), "Desktop", pair.hc.clone()).unwrap();
    pair.phone = Driver::new(phone, pair.b.database(), "Phone", pair.pc.clone()).unwrap();
    pair
}

fn settle_completed(pair: &mut Pair) {
    for _ in 0..100 {
        cycle(&mut pair.host, &mut pair.phone);
        pair.host.finish_success();
        pair.phone.finish_success();
        if pair.host.session.state() == SessionState::Terminal
            && pair.phone.session.state() == SessionState::Terminal
        {
            return;
        }
    }
    panic!("final receipt was not flushed");
}

#[test]
fn benchmark_final_metrics_wait_for_managed_transport_cleanup_and_remain_stable() {
    let mut pair = synchronized_pair();
    pair.host.require_transport_cleanup();
    pair.phone.require_transport_cleanup();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    for driver in [&mut pair.host, &mut pair.phone] {
        let binding = driver.preview_binding().unwrap().to_owned();
        assert!(driver.benchmark_require_noop(&binding).unwrap());
    }
    pair.complete(Direction::DesktopToPhone);
    settle_completed(&mut pair);
    assert!(pair.host.benchmark_metrics().is_none());
    assert!(pair.phone.benchmark_metrics().is_none());
    pair.hc.advance(250);
    pair.pc.advance(250);
    pair.host.benchmark_transport_finished(true);
    pair.phone.benchmark_transport_finished(true);
    let first = pair.phone.benchmark_metrics().unwrap();
    assert!(first
        .split_whitespace()
        .any(|field| field == "session_ms=250"));
    pair.pc.advance(9000);
    pair.phone.work.validation.snapshot_digest();
    assert_eq!(pair.phone.benchmark_metrics().unwrap(), first);
}

#[test]
fn benchmark_late_source_catalog_change_is_rejected_before_transfer() {
    let mut pair = synchronized_pair();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    for driver in [&mut pair.host, &mut pair.phone] {
        let binding = driver.preview_binding().unwrap().to_owned();
        assert!(driver.benchmark_require_noop(&binding).unwrap());
    }
    pair.a.create_tag("late-source-edit".into()).unwrap();
    pair.phone.approve_preview().unwrap();
    let mut rejected = false;
    for _ in 0..100 {
        let _ = pair.phone.poll();
        let bytes = pair.phone.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.host.ingest_ciphertext(&bytes).unwrap();
            pair.phone.ciphertext_written(bytes.len()).unwrap();
        }
        if pair.host.poll().is_err() {
            rejected = true;
            break;
        }
    }
    assert!(rejected);
    assert!(pair.b.list_tags().unwrap().is_empty());
    assert_eq!(pair.host.progress().transferred_bytes, 0);
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
}

#[test]
fn benchmark_guard_rejects_stale_binding_and_does_not_approve() {
    let mut pair = synchronized_pair();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    assert!(pair.host.benchmark_require_noop("stale-binding").is_err());
    let binding = pair.host.preview_binding().unwrap().to_owned();
    assert!(pair.host.benchmark_require_noop(&binding).unwrap());
    assert_eq!(pair.host.state(), State::AwaitingApproval);
    assert_eq!(pair.phone.state(), State::AwaitingApproval);
    assert!(pair.host.benchmark_metrics().is_none());
    assert!(!pair.host.preview_approved);
}

#[test]
fn benchmark_guard_does_not_repeat_full_snapshot_work() {
    let mut pair = synchronized_pair();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    let before = pair.host.work.validation_metrics().snapshot_digests;
    let scanned = pair.host.work.observe().work_items;
    let binding = pair.host.preview_binding().unwrap().to_owned();
    assert!(pair.host.benchmark_require_noop(&binding).unwrap());
    pair.host.check_benchmark_guard().unwrap();
    assert_eq!(pair.host.work.validation_metrics().snapshot_digests, before);
    assert_eq!(pair.host.work.observe().work_items, scanned);
}

#[test]
fn benchmark_zero_media_bytes_does_not_accept_catalog_changes() {
    let mut pair = synchronized_pair();
    pair.a.create_tag("not-on-target".into()).unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    assert_eq!(pair.phone.progress().transfer_total_bytes, 0);
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    assert!(!pair.phone.benchmark_require_noop(&binding).unwrap());
    assert!(pair.b.list_tags().unwrap().is_empty());
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
}

#[test]
fn benchmark_guard_refuses_overwrite_even_when_contents_match() {
    let mut pair = synchronized_pair();
    pair.preview(Direction::DesktopToPhone, SyncMode::Overwrite);
    let binding = pair.host.preview_binding().unwrap().to_owned();
    assert!(!pair.host.benchmark_require_noop(&binding).unwrap());
}

fn assert_ordinary_noop_but_benchmark_refused(pair: &mut Pair) {
    for driver in [&mut pair.host, &mut pair.phone] {
        let source = driver.source.as_ref().unwrap();
        let target = driver.target.as_ref().unwrap();
        assert!(driver.plan().unwrap().is_strict_noop(
            &source.manifest,
            &target.manifest,
            &source.sources,
            &target.sources
        ));
        let binding = driver.preview_binding().unwrap().to_owned();
        assert!(!driver.benchmark_require_noop(&binding).unwrap());
        assert_eq!(driver.state(), State::AwaitingApproval);
    }
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
}

#[tokio::test]
async fn benchmark_review_rejects_target_only_media_that_merge_would_keep() {
    let mut pair = synchronized_pair();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("target-only.jpg");
    std::fs::write(&path, b"synthetic target-only original").unwrap();
    pair.b
        .import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    assert_ordinary_noop_but_benchmark_refused(&mut pair);
}

#[tokio::test]
async fn benchmark_review_rejects_older_source_note_that_merge_would_keep() {
    let mut pair = Pair::new();
    pair.a
        .create_album("Shared provenance".into(), String::new(), false)
        .unwrap();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("shared.jpg");
    std::fs::write(&path, b"synthetic shared original").unwrap();
    pair.a
        .import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.complete(Direction::DesktopToPhone);
    let (host, phone, _) = confirmed(Role::Receiver);
    pair.host = Driver::new(host, pair.a.database(), "Desktop", pair.hc.clone()).unwrap();
    pair.phone = Driver::new(phone, pair.b.database(), "Phone", pair.pc.clone()).unwrap();
    let media = pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .remove(0);
    pair.b
        .set_note(media.id, "newer local note".into())
        .unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    assert_ordinary_noop_but_benchmark_refused(&mut pair);
}

#[test]
fn benchmark_review_rejects_older_source_album_that_merge_would_keep() {
    let mut pair = synchronized_pair();
    let album = pair
        .b
        .list_albums()
        .unwrap()
        .into_iter()
        .find(|album| album.system_key.is_none())
        .unwrap();
    pair.b
        .update_album(
            album.id,
            "Changed on target".into(),
            "newer description".into(),
            false,
        )
        .unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    assert_ordinary_noop_but_benchmark_refused(&mut pair);
}

#[tokio::test]
async fn benchmark_review_equivalent_media_and_metadata_are_accepted_in_both_directions() {
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        let mut pair = Pair::new();
        let input = tempfile::tempdir().unwrap();
        let path = input.path().join("equivalent.jpg");
        std::fs::write(&path, b"synthetic equal original").unwrap();
        let source = if direction == Direction::DesktopToPhone {
            &pair.a
        } else {
            &pair.b
        };
        source
            .import_local_files(vec![path.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let media = source
            .list_media(GalleryQuery::default())
            .unwrap()
            .remove(0);
        source.set_note(media.id, "shared note".into()).unwrap();
        source.set_favorite(media.id, true).unwrap();
        source.add_tag(media.id, "shared tag".into()).unwrap();
        let album = source
            .create_album("Shared metadata".into(), "description".into(), false)
            .unwrap();
        source.add_media_to_album(album, media.id).unwrap();
        pair.preview(direction, SyncMode::Merge);
        pair.complete(direction);
        settle_completed(&mut pair);
        let (host, phone, _) = confirmed(Role::Receiver);
        pair.host = Driver::new(host, pair.a.database(), "Desktop", pair.hc.clone()).unwrap();
        pair.phone = Driver::new(phone, pair.b.database(), "Phone", pair.pc.clone()).unwrap();
        pair.preview(direction, SyncMode::Merge);
        let generations = [
            pair.a.database().device_sync_header().unwrap().generation,
            pair.b.database().device_sync_header().unwrap().generation,
        ];
        for driver in [&mut pair.host, &mut pair.phone] {
            let binding = driver.preview_binding().unwrap().to_owned();
            assert!(driver.benchmark_require_noop(&binding).unwrap());
        }
        pair.complete(direction);
        settle_completed(&mut pair);
        assert_eq!(
            pair.a.database().device_sync_header().unwrap().generation,
            generations[0]
        );
        assert_eq!(
            pair.b.database().device_sync_header().unwrap().generation,
            generations[1]
        );
    }
}

#[test]
fn benchmark_review_sql_entry_plan_checks_are_included_in_native_timing() {
    let mut pair = synchronized_pair();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    for driver in [&mut pair.host, &mut pair.phone] {
        let binding = driver.preview_binding().unwrap().to_owned();
        assert!(driver.benchmark_require_noop(&binding).unwrap());
    }
    pair.complete(Direction::DesktopToPhone);
    settle_completed(&mut pair);
    let metrics = pair.phone.benchmark_metrics().unwrap();
    assert!(metrics
        .split_whitespace()
        .any(|field| field == "apply_plan_count=3"));
}

#[test]
fn benchmark_true_noop_finishes_without_business_generation_change() {
    let mut pair = synchronized_pair();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    for driver in [&mut pair.host, &mut pair.phone] {
        let binding = driver.preview_binding().unwrap().to_owned();
        assert!(driver.benchmark_require_noop(&binding).unwrap());
    }
    let generation = pair.b.database().device_sync_header().unwrap().generation;
    pair.complete(Direction::DesktopToPhone);
    for _ in 0..100 {
        cycle(&mut pair.host, &mut pair.phone);
        pair.host.finish_success();
        pair.phone.finish_success();
        if pair.host.benchmark_metrics().is_some() && pair.phone.benchmark_metrics().is_some() {
            break;
        }
    }
    assert_eq!(
        pair.b.database().device_sync_header().unwrap().generation,
        generation
    );
    let source = pair.host.benchmark_metrics().expect("final source metrics");
    let target = pair
        .phone
        .benchmark_metrics()
        .expect("final receiver metrics");
    assert!(source.contains("benchmark_noop_armed=1"));
    assert!(target.contains("benchmark_noop_armed=1"));
    assert!(target.contains("strict_noop_applied=1"));
    assert!(target.contains("media_bytes=0"));
    assert!(target.contains("apply_sql_count=1"));
    assert!(target.contains("apply_journal_count=1"));
    assert!(target.contains("apply_originals_count=1"));
    for private in [
        pair.host.session_id(),
        pair.phone.session_id(),
        "Shared album",
        "Desktop",
        "Phone",
    ] {
        assert!(!source.contains(private));
        assert!(!target.contains(private));
    }
}

#[test]
fn benchmark_guard_rejects_a_late_library_edit_before_approval() {
    let mut pair = synchronized_pair();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    assert!(pair.phone.benchmark_require_noop(&binding).unwrap());
    pair.b.create_tag("late-edit".into()).unwrap();
    assert!(pair.phone.approve_preview().is_err());
    assert_eq!(pair.phone.state(), State::AwaitingApproval);
    assert_eq!(pair.b.list_tags().unwrap(), ["late-edit"]);
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
}

#[test]
fn benchmark_final_guard_rejects_external_account_coordination_before_journal() {
    let mut pair = synchronized_pair();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    assert!(pair.phone.benchmark_require_noop(&binding).unwrap());
    let mut receive = pair.phone.receive.take().unwrap();
    let mut authorization = receive.authorize().unwrap();
    assert!(receive
        .apply(
            Some(&mut authorization),
            Some(Uuid::new_v4()),
            &CancellationToken::default(),
            &mut |_| {}
        )
        .is_err());
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
}
