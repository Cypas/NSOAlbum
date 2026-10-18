use super::*;

fn pair() -> Pair {
    let mut pair = Pair::new();
    reconnect(&mut pair);
    pair
}

fn reconnect(pair: &mut Pair) {
    let now = pair.hc.unix_ms() / 1000;
    let mut invitation =
        crate::device_sync::Invitation::create(crate::device_sync::Transport::Usb, now).unwrap();
    invitation.delegate_to_phone().unwrap();
    invitation
        .set_app_build(Some(crate::device_sync::connection::ApplicationBuild {
            version: "0.2.14".into(),
            build_number: "47".into(),
        }))
        .unwrap();
    let encoded = invitation.qr().unwrap().encode().unwrap();
    let host = invitation.accept(Role::Receiver, "Desktop", now).unwrap();
    let phone = crate::device_sync::Session::client(
        crate::device_sync::Qr::parse(&encoded, now).unwrap(),
        Role::Sender,
        "Phone",
        now,
    )
    .unwrap();
    pair.host = Driver::new(host, pair.a.database(), "Desktop", pair.hc.clone()).unwrap();
    pair.phone = Driver::new(phone, pair.b.database(), "Phone", pair.pc.clone()).unwrap();
    for _ in 0..100 {
        cycle(&mut pair.host, &mut pair.phone);
        if pair.phone.session.state() == SessionState::AwaitingConfirmation {
            break;
        }
    }
    pair.phone.confirm_pairing().unwrap();
    for _ in 0..100 {
        cycle(&mut pair.host, &mut pair.phone);
        if pair.host.session.state() == SessionState::Confirmed {
            return;
        }
    }
    panic!("real delegated TLS confirmation did not finish")
}

fn preview(pair: &mut Pair, direction: Direction) {
    pair.phone
        .configure(direction, SyncMode::Merge, false)
        .unwrap();
    for _ in 0..10_000 {
        cycle(&mut pair.host, &mut pair.phone);
        if pair.host.state() == State::AwaitingApproval
            && pair.phone.state() == State::AwaitingApproval
        {
            return;
        }
    }
    panic!("real preview not reached")
}

fn ends(pair: &mut Pair, direction: Direction) -> (&mut Driver, &mut Driver) {
    if direction == Direction::DesktopToPhone {
        (&mut pair.host, &mut pair.phone)
    } else {
        (&mut pair.phone, &mut pair.host)
    }
}

fn transmit(source: &mut Driver, target: &mut Driver) {
    let bytes = source.drain_ciphertext().unwrap();
    if !bytes.is_empty() {
        target.ingest_ciphertext(&bytes).unwrap();
        source.ciphertext_written(bytes.len()).unwrap();
    }
}

fn issued(pair: &mut Pair, direction: Direction) {
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    pair.phone.approve_controlled_preview(&binding).unwrap();
    for _ in 0..10_000 {
        let (source, target) = ends(pair, direction);
        target.poll().unwrap();
        transmit(target, source);
        source.poll().unwrap();
        if source.source_grant_issued() {
            return;
        }
        transmit(source, target);
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    panic!("one-use grant not issued")
}

fn settle_local(target: &mut Driver) {
    let until = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while target.worker.is_some() {
        target.poll_local().unwrap();
        assert!(std::time::Instant::now() < until);
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
}

#[test]
fn local_handoff_actual_approved_worker_survives_disconnect_after_prepared() {
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        let mut pair = pair();
        let (entered_tx, entered_rx) = std::sync::mpsc::sync_channel(1);
        let (resume_tx, resume_rx) = std::sync::mpsc::sync_channel(1);
        let resume = std::sync::Mutex::new(resume_rx);
        let target = if direction == Direction::DesktopToPhone {
            &mut pair.phone
        } else {
            &mut pair.host
        };
        target
            .set_apply_observer(Arc::new(move |boundary| {
                if boundary == ApplyBoundary::Prepared {
                    entered_tx.send(()).unwrap();
                    resume.lock().unwrap().recv().unwrap();
                }
            }))
            .unwrap();
        pair.a.create_tag("desktop synthetic".into()).unwrap();
        pair.b.create_tag("phone synthetic".into()).unwrap();
        preview(&mut pair, direction);
        let binding = pair.phone.preview_binding().unwrap().to_owned();
        pair.phone.approve_controlled_preview(&binding).unwrap();
        for _ in 0..10_000 {
            cycle(&mut pair.host, &mut pair.phone);
            if entered_rx.try_recv().is_ok() {
                break;
            }
        }
        pair.hc.advance(LEASE_MS + 1);
        pair.pc.advance(LEASE_MS + 1);
        let target = if direction == Direction::DesktopToPhone {
            &mut pair.phone
        } else {
            &mut pair.host
        };
        let worker = target.worker.as_ref().expect("approved worker started");
        assert!(!worker.is_finished());
        target.disconnect();
        resume_tx.send(()).unwrap();
        target.finish_shutdown();
        assert_eq!(target.state(), State::Completed);
        let database = if direction == Direction::DesktopToPhone {
            pair.b.database()
        } else {
            pair.a.database()
        };
        assert!(!database.device_sync_recovery_pending());
        let receipt = target.receipt().expect("real finalized receipt");
        assert_eq!(
            database
                .device_sync_journal(receipt.operation_uuid)
                .unwrap()
                .unwrap()
                .stage,
            crate::device_sync::recovery::JournalStage::Finalized
        );
    }
}

#[tokio::test]
async fn local_handoff_real_file_ack_source_release_and_lost_receipt_are_independent() {
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        let mut pair = pair();
        let input = tempfile::tempdir().unwrap();
        let path = input.path().join("synthetic.mp4");
        std::fs::write(&path, vec![43; 96 * 1024]).unwrap();
        let second = input.path().join("second.mp4");
        std::fs::write(&second, vec![18; 32 * 1024]).unwrap();
        let source_api = if direction == Direction::DesktopToPhone {
            &pair.a
        } else {
            &pair.b
        };
        source_api
            .import_local_files(vec![
                path.to_string_lossy().into_owned(),
                second.to_string_lossy().into_owned(),
            ])
            .await
            .unwrap();
        preview(&mut pair, direction);
        issued(&mut pair, direction);
        let source_api = if direction == Direction::DesktopToPhone {
            &pair.a
        } else {
            &pair.b
        };
        source_api
            .create_tag("after granted snapshot".into())
            .unwrap();
        let (source, target) = ends(&mut pair, direction);
        assert!(source.retained.is_none());
        assert!(source.source_lease.is_none());
        assert_eq!(source.progress.transferred_bytes, 128 * 1024);
        assert!(!target.local_apply_installed());
        transmit(source, target);
        target.poll().unwrap();
        assert!(target.local_apply_installed());
        target.disconnect();
        settle_local(target);
        assert_eq!(target.state(), State::Completed);
        source.disconnect();
        assert_eq!(source.state(), State::CompletedUnconfirmed);
        let target_api = if direction == Direction::DesktopToPhone {
            &pair.b
        } else {
            &pair.a
        };
        assert_eq!(
            target_api
                .list_media(GalleryQuery::default())
                .unwrap()
                .len(),
            2
        );
        assert!(!target_api
            .list_tags()
            .unwrap()
            .iter()
            .any(|tag| tag == "after granted snapshot"));
    }
}

#[test]
fn local_handoff_rejects_early_wrong_or_repeated_grants_and_old_lease_messages() {
    let mut pair = pair();
    preview(&mut pair, Direction::DesktopToPhone);
    let operation = pair.phone.receive_operation_id().unwrap();
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    assert!(pair
        .phone
        .handle(Message::ApplyGrant {
            binding: binding.clone(),
            receiver_operation: operation,
            external_reference: None
        })
        .is_err());
    assert!(!pair.phone.local_apply_installed());
    issued(&mut pair, Direction::DesktopToPhone);
    for (wrong_binding, wrong_operation, wrong_external) in [
        ("0".repeat(64), operation, None),
        (binding.clone(), Uuid::new_v4(), None),
        (binding.clone(), operation, Some(Uuid::new_v4())),
    ] {
        assert!(pair
            .phone
            .handle(Message::ApplyGrant {
                binding: wrong_binding,
                receiver_operation: wrong_operation,
                external_reference: wrong_external
            })
            .is_err());
        assert!(!pair.phone.local_apply_installed());
    }
    assert!(pair
        .phone
        .handle(Message::LeaseGranted {
            binding: binding.clone(),
            id: 0,
            work: ApplyWork::default()
        })
        .is_err());
    transmit(&mut pair.host, &mut pair.phone);
    pair.phone.poll().unwrap();
    assert!(pair.phone.local_apply_installed());
    assert!(pair
        .phone
        .handle(Message::ApplyGrant {
            binding,
            receiver_operation: operation,
            external_reference: None
        })
        .is_err());
    pair.phone.disconnect();
    settle_local(&mut pair.phone);
    assert_eq!(pair.phone.state(), State::Completed);
}

#[test]
fn local_handoff_source_wait_has_fixed_deadline_and_no_authority_revocation() {
    let mut pair = pair();
    preview(&mut pair, Direction::DesktopToPhone);
    issued(&mut pair, Direction::DesktopToPhone);
    pair.hc.advance(USER_MS - 1);
    pair.host.poll().unwrap();
    assert_eq!(pair.host.state(), State::Verifying);
    pair.hc.advance(1);
    pair.host.poll().unwrap();
    assert_eq!(pair.host.state(), State::CompletedUnconfirmed);
    assert!(pair.host.source_grant_issued());
    assert!(!pair.phone.local_apply_installed());
}

#[test]
fn local_handoff_cancel_before_install_and_spawn_failure_never_reactivate() {
    for spawn_failure in [false, true] {
        let mut pair = pair();
        preview(&mut pair, Direction::DesktopToPhone);
        issued(&mut pair, Direction::DesktopToPhone);
        if spawn_failure {
            pair.phone.fail_local_spawn = true;
            transmit(&mut pair.host, &mut pair.phone);
            assert!(pair.phone.poll().is_err());
            assert_eq!(pair.phone.state(), State::Failed);
            assert!(pair.phone.worker.is_none());
            assert!(pair.phone.receive.is_none());
        } else {
            pair.phone.lifecycle.cancel();
            transmit(&mut pair.host, &mut pair.phone);
            assert!(pair.phone.poll().is_err());
            assert!(!pair.phone.local_apply_installed());
        }
        assert!(pair
            .b
            .database()
            .device_sync_pending_journal()
            .unwrap()
            .is_none());
        assert!(!pair.b.database().device_sync_recovery_pending());
    }
}

#[tokio::test]
async fn local_handoff_missing_bytes_cannot_request_ready_and_fresh_cache_still_publishes() {
    let mut pair = pair();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("synthetic.mp4");
    std::fs::write(&path, vec![52; 64 * 1024]).unwrap();
    pair.a
        .import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    preview(&mut pair, Direction::DesktopToPhone);
    assert!(pair.phone.request_apply().is_err(), "no phone approval");
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    pair.phone.approve_controlled_preview(&binding).unwrap();
    assert!(pair.phone.receiving.is_some());
    assert!(
        pair.phone.request_apply().is_err(),
        "no SHA-complete local bytes"
    );
    for _ in 0..10_000 {
        let (source, target) = ends(&mut pair, Direction::DesktopToPhone);
        target.poll().unwrap();
        transmit(target, source);
        source.poll().unwrap();
        if source.source_grant_issued() {
            break;
        }
        transmit(source, target);
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    assert!(pair.host.source_grant_issued());
    pair.phone.cancel();
    pair.host.cancel();
    pair.phone.finish_shutdown();
    pair.host.finish_shutdown();
    assert!(pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .is_empty());
    reconnect(&mut pair);
    preview(&mut pair, Direction::DesktopToPhone);
    assert_eq!(pair.phone.progress.transfer_total_bytes, 0);
    issued(&mut pair, Direction::DesktopToPhone);
    assert_eq!(pair.host.progress.transferred_bytes, 0);
    transmit(&mut pair.host, &mut pair.phone);
    pair.phone.poll().unwrap();
    pair.phone.disconnect();
    settle_local(&mut pair.phone);
    assert_eq!(pair.phone.state(), State::Completed);
    assert_eq!(pair.b.list_media(GalleryQuery::default()).unwrap().len(), 1);
}

#[test]
fn local_handoff_source_change_fails_before_grant() {
    let mut pair = pair();
    preview(&mut pair, Direction::DesktopToPhone);
    pair.a
        .create_tag("changed after approved source snapshot".into())
        .unwrap();
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    pair.phone.approve_controlled_preview(&binding).unwrap();
    let mut rejected = false;
    for _ in 0..100 {
        pair.phone.poll().unwrap();
        transmit(&mut pair.phone, &mut pair.host);
        if pair.host.poll().is_err() {
            rejected = true;
            break;
        }
        transmit(&mut pair.host, &mut pair.phone);
    }
    assert!(rejected);
    assert!(!pair.host.source_grant_issued());
    assert!(!pair.phone.local_apply_installed());
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
}

fn both_state(pair: &mut Pair, state: State) {
    for _ in 0..10_000 {
        cycle(&mut pair.host, &mut pair.phone);
        if pair.host.state() == state && pair.phone.state() == state {
            return;
        }
    }
    panic!(
        "state not reached: {:?}/{:?}",
        pair.host.state(),
        pair.phone.state()
    );
}

#[test]
fn local_handoff_zero_media_account_authorizations_and_external_finalize_survive_detach() {
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        let mut pair = pair();
        pair.phone
            .configure(direction, SyncMode::Merge, true)
            .unwrap();
        both_state(&mut pair, State::AwaitingAccountConsent);
        pair.phone.consent_controlled(true).unwrap();
        for _ in 0..100 {
            cycle(&mut pair.host, &mut pair.phone);
            if pair.host.read_view().accounts_consent_authorized {
                break;
            }
        }
        let (source, target) = ends(&mut pair, direction);
        source.authorize_accounts_export(
            br#"{"version":1,"accounts":[{"account_id":"synthetic","nickname":"Test","session_token":"synthetic-token"}]}"#,
            &"a".repeat(64)
        ).unwrap();
        target.authorize_accounts_receive(&"b".repeat(64)).unwrap();
        both_state(&mut pair, State::AwaitingApproval);
        let binding = pair.phone.preview_binding().unwrap().to_owned();
        let (_, target) = ends(&mut pair, direction);
        target
            .publish_account_preview(
                &binding,
                crate::device_sync::read_model::ChangeCounts {
                    added: 1,
                    ..Default::default()
                },
            )
            .unwrap();
        for _ in 0..100 {
            cycle(&mut pair.host, &mut pair.phone);
            if pair.phone.preview_summary().unwrap().accounts.is_some() {
                break;
            }
        }
        pair.phone.approve_controlled_preview(&binding).unwrap();
        for _ in 0..100 {
            cycle(&mut pair.host, &mut pair.phone);
            if ends(&mut pair, direction).1.preview_approved {
                break;
            }
        }
        let external = Uuid::new_v4();
        ends(&mut pair, direction)
            .1
            .approve_accounts_preview(&binding, &"b".repeat(64), external)
            .unwrap();
        let mut checked_target = false;
        let mut checked_source = false;
        for _ in 0..10_000 {
            cycle(&mut pair.host, &mut pair.phone);
            let (source, target) = ends(&mut pair, direction);
            if target.state() == State::AwaitingTargetAccountFinal {
                assert!(!source.source_grant_issued());
                assert!(!target.local_apply_installed());
                target
                    .approve_accounts_target_final(&"b".repeat(64))
                    .unwrap();
                checked_target = true;
            }
            if source.state() == State::AwaitingAccountFinal {
                assert!(!source.source_grant_issued());
                source.approve_accounts_final(&"a".repeat(64)).unwrap();
                checked_source = true;
            }
            if target.local_apply_installed() {
                break;
            }
        }
        assert!(checked_target && checked_source);
        let (source, target) = ends(&mut pair, direction);
        assert!(source.source_grant_issued());
        target.disconnect();
        settle_local(target);
        assert_eq!(target.state(), State::AwaitingExternal);
        target.check_external_commit().unwrap();
        assert!(target.finalize_accounts(Uuid::new_v4()).is_err());
        target.external_step().unwrap();
        target.finalize_accounts(external).unwrap();
        assert_eq!(target.state(), State::Completed);
        source.disconnect();
        assert_eq!(source.state(), State::CompletedUnconfirmed);
    }
}

#[test]
fn local_handoff_finalized_survives_ack_enqueue_failure() {
    let mut pair = pair();
    let (entered, observed) = std::sync::mpsc::sync_channel(1);
    let (resume, paused) = std::sync::mpsc::sync_channel(1);
    let paused = std::sync::Mutex::new(paused);
    pair.phone
        .set_apply_observer(Arc::new(move |boundary| {
            if boundary == ApplyBoundary::Finalized {
                entered.send(()).unwrap();
                paused.lock().unwrap().recv().unwrap();
            }
        }))
        .unwrap();
    preview(&mut pair, Direction::DesktopToPhone);
    issued(&mut pair, Direction::DesktopToPhone);
    transmit(&mut pair.host, &mut pair.phone);
    pair.phone.poll().unwrap();
    observed
        .recv_timeout(std::time::Duration::from_secs(10))
        .unwrap();
    for _ in 0..MAX_OUTBOX {
        pair.phone.enqueue(Message::Abort {}).unwrap();
    }
    resume.send(()).unwrap();
    settle_local(&mut pair.phone);
    assert_eq!(pair.phone.state(), State::Completed);
    assert!(!pair.b.database().device_sync_recovery_pending());
    pair.phone.disconnect();
    assert_eq!(pair.phone.state(), State::Completed);
}

#[test]
fn local_handoff_local_cancel_after_install_compensates_prepared_library() {
    let mut pair = pair();
    pair.a.create_tag("incoming".into()).unwrap();
    pair.b.create_tag("original".into()).unwrap();
    let before = Snapshot::read(&pair.b.database(), "Phone").unwrap();
    let (entered, observed) = std::sync::mpsc::sync_channel(1);
    let (resume, paused) = std::sync::mpsc::sync_channel(1);
    let paused = std::sync::Mutex::new(paused);
    pair.phone
        .set_apply_observer(Arc::new(move |boundary| {
            if boundary == ApplyBoundary::Prepared {
                entered.send(()).unwrap();
                paused.lock().unwrap().recv().unwrap();
            }
        }))
        .unwrap();
    preview(&mut pair, Direction::DesktopToPhone);
    issued(&mut pair, Direction::DesktopToPhone);
    transmit(&mut pair.host, &mut pair.phone);
    pair.phone.poll().unwrap();
    observed
        .recv_timeout(std::time::Duration::from_secs(10))
        .unwrap();
    pair.phone.disconnect();
    pair.phone.lifecycle.cancel();
    let cancelled = pair.phone.poll();
    resume.send(()).unwrap();
    pair.phone.finish_shutdown();
    assert!(cancelled.is_err());
    assert_eq!(pair.phone.state(), State::Cancelled);
    assert!(!pair.b.database().device_sync_recovery_pending());
    assert_eq!(
        Snapshot::read(&pair.b.database(), "Phone")
            .unwrap()
            .manifest
            .records,
        before.manifest.records
    );
}

#[tokio::test]
async fn local_handoff_corrupt_controlled_reuse_fails_locally_before_formal_mutation() {
    corrupt_controlled_reuse(true).await;
}

#[tokio::test]
async fn local_handoff_attached_corrupt_reuse_reconciles_worker_failure() {
    corrupt_controlled_reuse(false).await;
}

async fn corrupt_controlled_reuse(detached: bool) {
    let mut pair = pair();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("synthetic.mp4");
    std::fs::write(&path, b"synthetic-original").unwrap();
    for api in [&pair.a, &pair.b] {
        api.import_local_files(vec![path.to_string_lossy().into_owned()])
            .await
            .unwrap();
    }
    pair.a.create_tag("incoming metadata".into()).unwrap();
    let before = Snapshot::read(&pair.b.database(), "Phone").unwrap();
    preview(&mut pair, Direction::DesktopToPhone);
    let original = pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .remove(0);
    // Same length, same DB-approved CAS identity: only full local SHA can reject.
    std::fs::write(&original.storage_path, b"synthetic-corrupt!").unwrap();
    issued(&mut pair, Direction::DesktopToPhone);
    transmit(&mut pair.host, &mut pair.phone);
    pair.phone.poll().unwrap();
    assert!(pair.phone.local_apply_installed());
    if detached {
        pair.phone.disconnect();
    }
    let until = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let mut failed = false;
    while pair.phone.worker.is_some() {
        failed |= pair.phone.poll().is_err();
        assert!(std::time::Instant::now() < until);
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    assert!(failed);
    assert_eq!(pair.phone.state(), State::Failed);
    assert!(pair.phone.receipt().is_none());
    assert!(!pair.b.database().device_sync_recovery_pending());
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
    assert_eq!(
        Snapshot::read(&pair.b.database(), "Phone")
            .unwrap()
            .manifest
            .records,
        before.manifest.records
    );
    assert_eq!(
        std::fs::read(&original.storage_path).unwrap(),
        b"synthetic-corrupt!"
    );
    for _ in 0..3 {
        let _ = pair.phone.poll();
        assert_eq!(pair.phone.state(), State::Failed);
        assert!(pair.phone.worker.is_none());
        assert!(pair.phone.receipt().is_none());
    }
}

#[test]
fn local_handoff_attached_pending_worker_error_preserves_recovery() {
    reconcile_boundary_failure(false, ApplyBoundary::LibraryApplied, false);
}

#[test]
fn local_handoff_detached_pending_worker_error_preserves_recovery() {
    reconcile_boundary_failure(true, ApplyBoundary::LibraryApplied, false);
}

#[test]
fn local_handoff_attached_join_failure_preserves_pending_journal() {
    reconcile_boundary_failure(false, ApplyBoundary::Prepared, true);
}

#[test]
fn local_handoff_detached_join_failure_preserves_pending_journal() {
    reconcile_boundary_failure(true, ApplyBoundary::Prepared, true);
}

#[test]
fn local_handoff_attached_join_failure_preserves_finalized_success() {
    reconcile_boundary_failure(false, ApplyBoundary::Finalized, true);
}

#[test]
fn local_handoff_detached_join_failure_preserves_finalized_success() {
    reconcile_boundary_failure(true, ApplyBoundary::Finalized, true);
}

fn reconcile_boundary_failure(detached: bool, failure: ApplyBoundary, panic_worker: bool) {
    use crate::device_sync::recovery::JournalStage;

    let mut pair = pair();
    pair.a.create_tag("incoming metadata".into()).unwrap();
    let control = pair.phone.lifecycle_control();
    let (entered, observed) = std::sync::mpsc::sync_channel(1);
    let (resume, paused) = std::sync::mpsc::sync_channel(1);
    let paused = std::sync::Mutex::new(paused);
    pair.phone
        .set_apply_observer(Arc::new(move |boundary| {
            if boundary == ApplyBoundary::Prepared {
                entered.send(()).unwrap();
                paused.lock().unwrap().recv().unwrap();
            }
            if boundary == failure {
                if panic_worker {
                    panic!("synthetic worker failure at real apply boundary");
                } else {
                    // receiver::apply returns a real cancellation after durable SQL.
                    control.cancel();
                }
            }
        }))
        .unwrap();
    preview(&mut pair, Direction::DesktopToPhone);
    issued(&mut pair, Direction::DesktopToPhone);
    transmit(&mut pair.host, &mut pair.phone);
    pair.phone.poll().unwrap();
    observed
        .recv_timeout(std::time::Duration::from_secs(10))
        .unwrap();
    if detached {
        pair.phone.disconnect();
    }
    resume.send(()).unwrap();
    let until = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !pair.phone.worker.as_ref().unwrap().is_finished() {
        assert!(std::time::Instant::now() < until);
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    let identity = pair.phone.local_identity.clone().unwrap();
    let journal = pair
        .b
        .database()
        .device_sync_journal(identity.operation)
        .unwrap()
        .unwrap();
    let finalized = failure == ApplyBoundary::Finalized;
    let expected_stage = match failure {
        ApplyBoundary::Prepared => JournalStage::Prepared,
        ApplyBoundary::LibraryApplied => JournalStage::LibraryApplied,
        ApplyBoundary::Finalized => JournalStage::Finalized,
    };
    assert_eq!(journal.stage, expected_stage);
    assert_eq!(journal.external_reference, identity.external);
    let result = pair.phone.poll();
    assert_eq!(result.is_ok(), finalized, "{result:?}");
    assert!(
        pair.phone.worker.is_none(),
        "finished worker was not reconciled"
    );
    let expected_state = if finalized {
        State::Completed
    } else {
        State::RecoveryPending
    };
    assert_eq!(pair.phone.state(), expected_state);
    assert_eq!(pair.b.database().device_sync_recovery_pending(), !finalized);
    if finalized {
        let receipt = pair.phone.receipt().unwrap();
        assert_eq!(receipt.operation_uuid, journal.operation_uuid);
        assert_eq!(receipt.backup_uuid, journal.backup_uuid);
        assert_eq!(receipt.state, ApplyState::Finalized);
    } else {
        assert!(pair.phone.receipt().is_none());
    }
    for _ in 0..3 {
        let _ = pair.phone.poll();
        assert_eq!(pair.phone.state(), expected_state);
        assert!(pair.phone.worker.is_none());
    }
    assert_eq!(
        pair.b
            .database()
            .device_sync_journal(identity.operation)
            .unwrap()
            .unwrap()
            .stage,
        expected_stage
    );
}

#[tokio::test]
async fn local_handoff_missing_controlled_reuse_cannot_send_ready() {
    let mut pair = pair();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("synthetic.mp4");
    std::fs::write(&path, b"synthetic-original").unwrap();
    for api in [&pair.a, &pair.b] {
        api.import_local_files(vec![path.to_string_lossy().into_owned()])
            .await
            .unwrap();
    }
    preview(&mut pair, Direction::DesktopToPhone);
    let original = pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .remove(0);
    std::fs::remove_file(original.storage_path).unwrap();
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    assert!(pair.phone.approve_controlled_preview(&binding).is_err());
    assert!(!pair.phone.local_apply_installed());
    assert!(!pair.host.source_grant_issued());
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
}

#[test]
fn local_handoff_full_grant_queue_never_issues_or_releases_source() {
    let mut pair = pair();
    preview(&mut pair, Direction::DesktopToPhone);
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    pair.phone.approve_controlled_preview(&binding).unwrap();
    for _ in 0..100 {
        pair.phone.poll().unwrap();
        transmit(&mut pair.phone, &mut pair.host);
        pair.host.poll().unwrap();
        if pair.host.step == Step::SourceReady {
            break;
        }
        transmit(&mut pair.host, &mut pair.phone);
    }
    assert_eq!(pair.host.state(), State::Verifying);
    assert!(!pair.host.source_grant_issued());
    let identity = pair.phone.local_identity.clone().unwrap();
    for _ in 0..MAX_OUTBOX {
        pair.host.enqueue(Message::Abort {}).unwrap();
    }
    assert!(pair
        .host
        .handle(Message::ApplyReady {
            binding: identity.binding,
            receiver_operation: identity.operation,
            external_reference: identity.external
        })
        .is_err());
    assert!(!pair.host.source_grant_issued());
    assert!(pair.host.retained.is_some());
    assert!(!pair.phone.local_apply_installed());
}

#[test]
fn local_handoff_eof_before_install_rejects_grant_but_abort_after_install_detaches_only() {
    let mut before = pair();
    preview(&mut before, Direction::DesktopToPhone);
    issued(&mut before, Direction::DesktopToPhone);
    before.phone.disconnect();
    let bytes = before.host.drain_ciphertext().unwrap();
    assert!(before.phone.ingest_ciphertext(&bytes).is_err());
    assert!(!before.phone.local_apply_installed());
    assert!(before
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());

    let mut pair = pair();
    let (entered, observed) = std::sync::mpsc::sync_channel(1);
    let (resume, paused) = std::sync::mpsc::sync_channel(1);
    let paused = std::sync::Mutex::new(paused);
    pair.phone
        .set_apply_observer(Arc::new(move |boundary| {
            if boundary == ApplyBoundary::Prepared {
                entered.send(()).unwrap();
                paused.lock().unwrap().recv().unwrap();
            }
        }))
        .unwrap();
    preview(&mut pair, Direction::DesktopToPhone);
    issued(&mut pair, Direction::DesktopToPhone);
    transmit(&mut pair.host, &mut pair.phone);
    pair.phone.poll().unwrap();
    observed
        .recv_timeout(std::time::Duration::from_secs(10))
        .unwrap();
    pair.host.enqueue(Message::Abort {}).unwrap();
    pair.host.poll().unwrap();
    transmit(&mut pair.host, &mut pair.phone);
    pair.phone.poll().unwrap();
    assert!(pair.phone.transport_detached());
    assert!(pair.phone.cancel.check().is_ok());
    resume.send(()).unwrap();
    settle_local(&mut pair.phone);
    assert_eq!(pair.phone.state(), State::Completed);
}
