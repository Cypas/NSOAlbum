use super::*;

fn controlled_pair() -> Pair {
    let mut pair = Pair::new();
    let now = pair.hc.unix_ms() / 1000;
    let mut invitation =
        crate::device_sync::Invitation::create(crate::device_sync::Transport::Usb, now).unwrap();
    let mut value: serde_json::Value =
        serde_json::from_str(&invitation.qr.encode().unwrap()).unwrap();
    value["control"] = "phone".into();
    let encoded = serde_json::to_string(&value).unwrap();
    invitation.qr = crate::device_sync::Qr::parse(&encoded, now).unwrap();
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
    pair
}

fn confirm_phone(pair: &mut Pair) {
    pair.phone.confirm_pairing().unwrap();
    for _ in 0..100 {
        cycle(&mut pair.host, &mut pair.phone);
        if pair.host.session.state() == SessionState::Confirmed {
            return;
        }
    }
    panic!("phone confirmation did not reach desktop");
}

fn configured_preview(pair: &mut Pair, direction: Direction, accounts: bool) {
    confirm_phone(pair);
    pair.phone
        .configure(direction, SyncMode::Merge, accounts)
        .unwrap();
    pump_until(
        pair,
        if accounts {
            State::AwaitingAccountConsent
        } else {
            State::AwaitingApproval
        },
    );
}

fn pump_until(pair: &mut Pair, state: State) {
    for _ in 0..10_000 {
        cycle(&mut pair.host, &mut pair.phone);
        if pair.host.state() == state && pair.phone.state() == state {
            return;
        }
    }
    panic!(
        "state not reached: {:?} {:?}",
        pair.host.state(),
        pair.phone.state()
    );
}

#[test]
fn phone_controller_alone_confirms_and_configures_both_directions() {
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        let mut pair = controlled_pair();
        assert!(!pair.host.read_view().confirmation_available);
        assert!(pair.host.confirm_pairing().is_err());
        pair.phone.confirm_pairing().unwrap();
        for _ in 0..100 {
            cycle(&mut pair.host, &mut pair.phone);
            if pair.host.session.state() == SessionState::Confirmed {
                break;
            }
        }
        assert_eq!(pair.host.session.state(), SessionState::Confirmed);
        assert_eq!(pair.phone.session.state(), SessionState::Confirmed);
        assert!(pair
            .host
            .configure(direction, SyncMode::Merge, false)
            .is_err());
        pair.phone
            .configure(direction, SyncMode::Merge, false)
            .unwrap();
        for _ in 0..10_000 {
            cycle(&mut pair.host, &mut pair.phone);
            if pair.host.state() == State::AwaitingApproval
                && pair.phone.state() == State::AwaitingApproval
            {
                break;
            }
        }
        assert_eq!(pair.host.state(), State::AwaitingApproval);
        assert_eq!(pair.phone.state(), State::AwaitingApproval);
        let phone_view = serde_json::to_value(pair.phone.read_view()).unwrap();
        assert_eq!(phone_view["controller"], true);
        assert_eq!(phone_view["phone_controlled"], true);
        assert_eq!(phone_view["source"], direction == Direction::PhoneToDesktop);
        assert!(pair
            .phone
            .preview_summary()
            .unwrap()
            .receiver_budget
            .is_some());
        assert!(
            !serde_json::to_string(pair.phone.preview_summary().unwrap())
                .unwrap()
                .contains(pair._roots[0].path().to_str().unwrap())
        );
    }
}

#[test]
fn phone_controller_transfer_projection_has_idle_rate_and_both_totals() {
    let mut pair = Pair::new();
    pair.host.state = State::Transferring;
    pair.phone.state = State::Transferring;
    pair.host.config = Some(Config {
        direction: Direction::DesktopToPhone,
        mode: SyncMode::Merge,
        accounts: false,
    });
    pair.host.progress.transfer_total_bytes = 1024;
    pair.phone.progress.transfer_total_bytes = 1024;
    for driver in [&pair.host, &pair.phone] {
        let value = serde_json::to_value(driver.read_view()).unwrap();
        assert_eq!(value["progress"]["transfer_total_bytes"], 1024);
        assert_eq!(value["progress"]["transfer_bytes_per_second"], 0);
    }
}

#[test]
fn phone_controller_scope_is_visible_before_separate_account_consent() {
    let mut pair = controlled_pair();
    configured_preview(&mut pair, Direction::DesktopToPhone, true);
    assert_eq!(pair.phone.read_view().source, Some(false));
    assert!(
        pair.phone
            .read_view()
            .configuration
            .unwrap()
            .include_accounts
    );
    assert!(!pair.host.read_view().accounts_consent_authorized);
    assert!(!pair.phone.read_view().accounts_consent_authorized);
}

#[test]
fn phone_controller_cannot_be_skipped_by_receiver_approved_message() {
    let mut pair = controlled_pair();
    configured_preview(&mut pair, Direction::PhoneToDesktop, false);
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    assert!(pair.phone.handle(Message::Approved { binding }).is_err());
    assert_eq!(pair.phone.state(), State::AwaitingApproval);
}

#[test]
fn phone_controller_rate_is_throttled_monotonic_and_idle_decays() {
    let mut rate = throughput::Throughput::default();
    assert_eq!(rate.rate(0), 0);
    rate.record(0, 3000);
    assert_eq!(rate.rate(499), 0);
    assert_eq!(rate.rate(500), 6000);
    assert_eq!(rate.rate(100), 6000);
    assert_eq!(rate.rate(1000), 3000);
    assert_eq!(rate.rate(2000), 1500);
    assert_eq!(rate.rate(3000), 0);
    rate.record(3000, 6000);
    assert_eq!(rate.rate(3500), 2000);
    assert_eq!(rate.rate(6000), 0);
}

#[test]
fn phone_controller_rate_resets_for_new_session_and_is_absent_outside_transfer() {
    let mut pair = Pair::new();
    pair.host.throughput.record(0, 10_000);
    pair.host.state = State::Transferring;
    pair.hc.advance(500);
    assert_eq!(
        pair.host.read_view().progress.transfer_bytes_per_second,
        Some(20_000)
    );
    pair.host.state = State::Verifying;
    assert_eq!(
        pair.host.read_view().progress.transfer_bytes_per_second,
        None
    );
    let fresh = Pair::new();
    assert_eq!(fresh.host.throughput.rate(500), 0);
}

#[test]
fn phone_controller_exact_binding_is_one_use_and_enters_receiver_safety_chain() {
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        let mut pair = controlled_pair();
        pair.a.create_tag("desktop-owned".into()).unwrap();
        pair.b.create_tag("phone-owned".into()).unwrap();
        configured_preview(&mut pair, direction, false);
        let binding = pair.phone.preview_binding().unwrap().to_owned();
        assert!(pair.host.approve_controlled_preview(&binding).is_err());
        assert!(pair
            .phone
            .approve_controlled_preview(&"0".repeat(64))
            .is_err());
        let target = if direction == Direction::DesktopToPhone {
            &mut pair.phone
        } else {
            &mut pair.host
        };
        assert!(target.approve_preview().is_err());
        assert!(target.authorization.is_none());
        pair.phone.approve_controlled_preview(&binding).unwrap();
        assert!(pair.phone.approve_controlled_preview(&binding).is_err());
        pump_until(&mut pair, State::Completed);
        assert!(pair
            .a
            .list_tags()
            .unwrap()
            .contains(&"desktop-owned".into()));
        assert!(pair.b.list_tags().unwrap().contains(&"phone-owned".into()));
        let target = if direction == Direction::DesktopToPhone {
            &pair.b
        } else {
            &pair.a
        };
        assert!(target
            .list_tags()
            .unwrap()
            .contains(&"desktop-owned".into()));
        assert!(target.list_tags().unwrap().contains(&"phone-owned".into()));
    }
}

#[test]
fn phone_controller_account_scope_requires_extra_intent_and_local_receiver_authorization() {
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        let mut pair = controlled_pair();
        configured_preview(&mut pair, direction, true);
        let payload = br#"{"version":1,"accounts":[{"account_id":"synthetic","nickname":"Test","session_token":"synthetic-token"}]}"#;
        let (source, target) = if direction == Direction::DesktopToPhone {
            (&mut pair.host, &mut pair.phone)
        } else {
            (&mut pair.phone, &mut pair.host)
        };
        assert!(source
            .authorize_accounts_export(payload, &"a".repeat(64))
            .is_err());
        assert!(target.authorize_accounts_receive(&"b".repeat(64)).is_err());
        assert!(pair.host.consent_controlled(true).is_err());
        pair.phone.consent_controlled(true).unwrap();
        assert!(pair.phone.consent_controlled(true).is_err());
        for _ in 0..100 {
            cycle(&mut pair.host, &mut pair.phone);
            if pair.host.read_view().accounts_consent_authorized {
                break;
            }
        }
        assert!(pair.host.read_view().accounts_consent_authorized);
        let (source, target) = if direction == Direction::DesktopToPhone {
            (&mut pair.host, &mut pair.phone)
        } else {
            (&mut pair.phone, &mut pair.host)
        };
        source
            .authorize_accounts_export(payload, &"a".repeat(64))
            .unwrap();
        target.authorize_accounts_receive(&"b".repeat(64)).unwrap();
        pump_until(&mut pair, State::AwaitingApproval);
        let binding = pair.phone.preview_binding().unwrap().to_owned();
        assert!(pair.phone.approve_controlled_preview(&binding).is_err());
        let external = Uuid::new_v4();
        let target = if direction == Direction::DesktopToPhone {
            &mut pair.phone
        } else {
            &mut pair.host
        };
        assert!(target
            .approve_accounts_preview(&binding, &"b".repeat(64), external)
            .is_err());
        let counts = crate::device_sync::read_model::ChangeCounts {
            added: 1,
            ..Default::default()
        };
        target
            .publish_account_preview(&binding, counts.clone())
            .unwrap();
        assert!(target.publish_account_preview(&binding, counts).is_err());
        for _ in 0..100 {
            cycle(&mut pair.host, &mut pair.phone);
            if pair.phone.preview_summary().unwrap().accounts.is_some() {
                break;
            }
        }
        assert_eq!(
            pair.phone
                .preview_summary()
                .unwrap()
                .accounts
                .as_ref()
                .unwrap()
                .added,
            1
        );
        pair.phone.approve_controlled_preview(&binding).unwrap();
        for _ in 0..100 {
            cycle(&mut pair.host, &mut pair.phone);
            if pair.host.read_view().preview_approved {
                break;
            }
            if direction == Direction::DesktopToPhone {
                break;
            }
        }
        let target = if direction == Direction::DesktopToPhone {
            &mut pair.phone
        } else {
            &mut pair.host
        };
        assert_eq!(target.state(), State::AwaitingApproval);
        assert!(target.authorization.is_none());
        target
            .approve_accounts_preview(&binding, &"b".repeat(64), external)
            .unwrap();
        for _ in 0..10_000 {
            cycle(&mut pair.host, &mut pair.phone);
            let (source, target) = if direction == Direction::DesktopToPhone {
                (&mut pair.host, &mut pair.phone)
            } else {
                (&mut pair.phone, &mut pair.host)
            };
            if source.state() == State::AwaitingAccountFinal {
                source.approve_accounts_final(&"a".repeat(64)).unwrap();
            }
            if target.state() == State::AwaitingTargetAccountFinal {
                target
                    .approve_accounts_target_final(&"b".repeat(64))
                    .unwrap();
            }
            if target.state() == State::AwaitingExternal {
                target.external_step().unwrap();
                target.finalize_accounts(external).unwrap();
                break;
            }
        }
        pump_until(&mut pair, State::Completed);
    }
}

#[test]
fn phone_controller_declining_accounts_falls_back_without_secure_store_authorization() {
    let mut pair = controlled_pair();
    configured_preview(&mut pair, Direction::PhoneToDesktop, true);
    pair.phone.consent_controlled(false).unwrap();
    pump_until(&mut pair, State::AwaitingApproval);
    assert!(!pair.host.read_view().accounts_consent_authorized);
    assert!(!pair.phone.read_view().accounts_consent_authorized);
    assert!(!pair.host.accounts_included());
    assert!(!pair.phone.accounts_included());
    assert!(
        !pair
            .phone
            .read_view()
            .configuration
            .unwrap()
            .include_accounts
    );
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    pair.phone.approve_controlled_preview(&binding).unwrap();
    pump_until(&mut pair, State::Completed);
}

#[test]
fn phone_controller_rejects_wrong_direction_consent_and_source_injected_preview() {
    let mut pair = controlled_pair();
    configured_preview(&mut pair, Direction::PhoneToDesktop, true);
    assert!(pair
        .host
        .handle(Message::ControllerAccountConsent {
            direction: Direction::DesktopToPhone,
            mode: SyncMode::Merge,
            accepted: true,
        })
        .is_err());
    assert!(!pair.host.read_view().accounts_consent_authorized);
    assert!(pair
        .phone
        .handle(Message::ControllerAccountConsent {
            direction: Direction::PhoneToDesktop,
            mode: SyncMode::Merge,
            accepted: true,
        })
        .is_err());
    pair.phone.consent_controlled(false).unwrap();
    pump_until(&mut pair, State::AwaitingApproval);
    let summary = pair.phone.preview_summary().unwrap().clone();
    assert!(pair
        .host
        .handle(Message::ControllerPreview {
            summary: Box::new(summary),
            transfer_total_bytes: 0,
        })
        .is_err());
}

#[tokio::test]
async fn phone_controller_progress_counts_staged_and_acknowledged_media_not_metadata_or_reuse() {
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        let mut pair = controlled_pair();
        let input = tempfile::tempdir().unwrap();
        let path = input.path().join("synthetic.mp4");
        std::fs::write(&path, vec![91; 256 * 1024]).unwrap();
        let source = if direction == Direction::DesktopToPhone {
            &pair.a
        } else {
            &pair.b
        };
        source
            .import_local_files(vec![path.to_string_lossy().into_owned()])
            .await
            .unwrap();
        configured_preview(&mut pair, direction, false);
        assert_eq!(pair.host.progress.transferred_bytes, 0);
        assert_eq!(pair.phone.progress.transferred_bytes, 0);
        let binding = pair.phone.preview_binding().unwrap().to_owned();
        pair.phone.approve_controlled_preview(&binding).unwrap();
        for _ in 0..10_000 {
            cycle(&mut pair.host, &mut pair.phone);
            if pair.host.progress.transferred_bytes > 0 && pair.phone.progress.transferred_bytes > 0
            {
                break;
            }
        }
        pair.hc.advance(500);
        pair.pc.advance(500);
        for driver in [&pair.host, &pair.phone] {
            assert_eq!(driver.state(), State::Transferring);
            let progress = driver.read_view().progress;
            assert_eq!(progress.transfer_total_bytes, Some(256 * 1024));
            assert_eq!(
                progress.transfer_bytes_per_second,
                Some(driver.progress.transferred_bytes * 2)
            );
        }
        let (source, target) = if direction == Direction::DesktopToPhone {
            (&mut pair.host, &mut pair.phone)
        } else {
            (&mut pair.phone, &mut pair.host)
        };
        let received = target.progress.transferred_bytes;
        let acknowledged = source.progress.transferred_bytes;
        let sha = target.receiving.as_ref().unwrap().0.clone();
        assert!(target
            .handle(Message::FileChunk {
                sha256: sha.clone(),
                offset: 0,
                data: wire::encode_chunk(&vec![91; wire::RAW_CHUNK]),
            })
            .is_err());
        assert!(source
            .handle(Message::ChunkAccepted {
                sha256: sha,
                offset: acknowledged,
            })
            .is_err());
        assert_eq!(target.progress.transferred_bytes, received);
        assert_eq!(source.progress.transferred_bytes, acknowledged);
        pump_until(&mut pair, State::Completed);
        assert_eq!(pair.host.progress.transferred_bytes, 256 * 1024);
        assert_eq!(pair.phone.progress.transferred_bytes, 256 * 1024);
    }
}

#[tokio::test]
async fn phone_controller_reused_originals_add_no_transfer_bytes_or_rate() {
    let mut pair = controlled_pair();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("shared.jpg");
    std::fs::write(&path, vec![7; 65_536]).unwrap();
    for api in [&pair.a, &pair.b] {
        api.import_local_files(vec![path.to_string_lossy().into_owned()])
            .await
            .unwrap();
    }
    configured_preview(&mut pair, Direction::PhoneToDesktop, false);
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    assert_eq!(pair.host.progress.transfer_total_bytes, 0);
    assert_eq!(pair.phone.progress.transfer_total_bytes, 0);
    pair.phone.approve_controlled_preview(&binding).unwrap();
    pump_until(&mut pair, State::Completed);
    assert_eq!(pair.host.progress.transferred_bytes, 0);
    assert_eq!(pair.phone.progress.transferred_bytes, 0);
    assert_eq!(pair.host.throughput.rate(500), 0);
    assert_eq!(pair.phone.throughput.rate(500), 0);
}

#[test]
fn phone_controller_decline_snapshot_failure_immediately_retires_consumed_intent() {
    let mut pair = controlled_pair();
    configured_preview(&mut pair, Direction::PhoneToDesktop, true);
    let closed = Arc::new(AtomicBool::new(false));
    let observed = closed.clone();
    pair.phone
        .set_transport_close(move || observed.store(true, Ordering::SeqCst))
        .unwrap();
    let database = pair.b.database();
    let lease = database.device_sync_exclusive().unwrap();
    assert!(pair.phone.consent_controlled(false).is_err());
    assert!(pair.phone.state().terminal());
    assert_eq!(pair.phone.session.state(), SessionState::Terminal);
    assert!(pair.phone.outbox.is_empty());
    assert!(closed.load(Ordering::SeqCst));
    assert!(!pair.phone.read_view().accounts_consent_authorized);
    pair.host.poll().unwrap();
    assert!(pair.host.step == Step::AccountConsent);
    assert!(pair.host.controller_account_consent.is_none());
    drop(lease);
    pair.b.create_tag("local access restored".into()).unwrap();
}

#[test]
fn phone_controller_decline_full_queue_does_not_consume_intent() {
    let mut pair = controlled_pair();
    configured_preview(&mut pair, Direction::PhoneToDesktop, true);
    for _ in 0..MAX_OUTBOX {
        pair.phone
            .enqueue(Message::ClockSample {
                sample: ConnectionSample {
                    lower_offset_ms: 0,
                    upper_offset_ms: 0,
                },
            })
            .unwrap();
    }
    assert!(pair.phone.consent_controlled(false).is_err());
    assert_eq!(pair.phone.state(), State::AwaitingAccountConsent);
    assert!(pair.phone.controller_account_consent.is_none());
    assert!(pair.phone.config.unwrap().accounts);
    assert_eq!(pair.phone.outbox.len(), MAX_OUTBOX);
    pair.phone.outbox.clear();
    pair.phone.consent_controlled(false).unwrap();
    pump_until(&mut pair, State::AwaitingApproval);
}

#[test]
fn phone_controller_approval_full_queue_preserves_retryable_authorization() {
    let mut pair = controlled_pair();
    configured_preview(&mut pair, Direction::DesktopToPhone, false);
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    for _ in 0..MAX_OUTBOX {
        pair.phone
            .enqueue(Message::ClockSample {
                sample: ConnectionSample {
                    lower_offset_ms: 0,
                    upper_offset_ms: 0,
                },
            })
            .unwrap();
    }
    assert!(pair.phone.approve_controlled_preview(&binding).is_err());
    assert_eq!(pair.phone.state(), State::AwaitingApproval);
    assert!(!pair.phone.preview_approved);
    assert!(pair.phone.authorization.is_none());
    assert_eq!(pair.phone.outbox.len(), MAX_OUTBOX);
    pair.phone.outbox.clear();
    pair.phone.approve_controlled_preview(&binding).unwrap();
    pump_until(&mut pair, State::Completed);
}

#[tokio::test]
async fn phone_controller_first_part_creation_failure_retires_receiver_approval() {
    let mut pair = controlled_pair();
    let input = tempfile::tempdir().unwrap();
    let source = input.path().join("source.jpg");
    std::fs::write(&source, b"synthetic source remains intact").unwrap();
    pair.a
        .import_local_files(vec![source.to_string_lossy().into_owned()])
        .await
        .unwrap();
    configured_preview(&mut pair, Direction::DesktopToPhone, false);
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    let staging = pair
        .phone
        .receive
        .as_mut()
        .unwrap()
        .staging_mut()
        .budget_inputs(&pair.phone.work)
        .unwrap()
        .staging
        .to_path_buf();
    // Replace only this synthetic operation's directory, so OwnedPart::create
    // fails at the actual filesystem boundary rather than via a driver fake.
    std::fs::rename(&staging, staging.with_extension("displaced")).unwrap();
    std::fs::write(&staging, b"synthetic blocking file").unwrap();
    assert!(pair.phone.approve_controlled_preview(&binding).is_err());
    assert!(pair.phone.state().terminal());
    assert_eq!(pair.phone.session.state(), SessionState::Terminal);
    assert!(pair.phone.authorization.is_none());
    assert!(pair.phone.outbox.is_empty());
    assert!(pair.phone.receive.is_none());
    assert!(pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .is_empty());
    assert_eq!(
        std::fs::read(&source).unwrap(),
        b"synthetic source remains intact"
    );
}
