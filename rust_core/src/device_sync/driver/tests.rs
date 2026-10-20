use super::*;

#[path = "bundle_pump_tests.rs"]
mod bundle_pump_tests;
use crate::api::CoreApi;
use crate::device_sync::clock::SystemClock;
use crate::device_sync::planner::SyncMode;
use crate::device_sync::tests::confirmed;
use crate::device_sync::Role;
use crate::models::GalleryQuery;
use sha2::{Digest, Sha256};
use std::sync::Arc;

#[path = "local_apply_tests.rs"]
mod local_apply_tests;
#[path = "phone_control_tests.rs"]
mod phone_control_tests;
#[path = "preparation_tests.rs"]
mod preparation_tests;
#[path = "stream_tests.rs"]
mod stream_tests;

struct TestClock {
    mono: AtomicU64,
    wall: std::sync::atomic::AtomicI64,
}
impl TestClock {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            mono: AtomicU64::new(0),
            wall: std::sync::atomic::AtomicI64::new(chrono::Utc::now().timestamp_millis()),
        })
    }
    fn advance(&self, ms: u64) {
        self.mono.fetch_add(ms, Ordering::SeqCst);
        self.wall.fetch_add(ms as i64, Ordering::SeqCst);
    }
}
impl Clock for TestClock {
    fn monotonic_ms(&self) -> u64 {
        self.mono.load(Ordering::SeqCst)
    }
    fn unix_ms(&self) -> i64 {
        self.wall.load(Ordering::SeqCst)
    }
}
struct Pair {
    a: CoreApi,
    b: CoreApi,
    host: Driver,
    phone: Driver,
    hc: Arc<TestClock>,
    pc: Arc<TestClock>,
    _roots: [tempfile::TempDir; 2],
}
impl Drop for Pair {
    fn drop(&mut self) {
        self.host.cancel();
        self.phone.cancel();
        self.hc.advance(LEASE_MS + 1);
        self.pc.advance(LEASE_MS + 1);
        self.host.cleanup_pending();
        self.phone.cleanup_pending();
        self.host.finish_shutdown();
        self.phone.finish_shutdown();
    }
}
impl Pair {
    fn new() -> Self {
        let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let a = CoreApi::open(roots[0].path()).unwrap();
        let b = CoreApi::open(roots[1].path()).unwrap();
        let (host, phone, _) = confirmed(Role::Receiver);
        let hc = TestClock::new();
        let pc = TestClock::new();
        pc.wall.store(hc.unix_ms(), Ordering::SeqCst);
        let host = Driver::new(host, a.database(), "Desktop", hc.clone()).unwrap();
        let phone = Driver::new(phone, b.database(), "Phone", pc.clone()).unwrap();
        Self {
            _roots: roots,
            a,
            b,
            host,
            phone,
            hc,
            pc,
        }
    }
    fn preview(&mut self, direction: Direction, mode: SyncMode) {
        self.host.configure(direction, mode, false).unwrap();
        for _ in 0..10_000 {
            cycle(&mut self.host, &mut self.phone);
            if self.host.state() == State::AwaitingApproval
                && self.phone.state() == State::AwaitingApproval
            {
                return;
            }
        }
        panic!("preview not reached");
    }
    fn complete(&mut self, direction: Direction) {
        match direction {
            Direction::DesktopToPhone => self.phone.approve_preview().unwrap(),
            Direction::PhoneToDesktop => self.host.approve_preview().unwrap(),
        }
        let seconds = if self.host.progress.transfer_total_bytes > 256 * 1024 * 1024 {
            600
        } else {
            30
        };
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(seconds);
        while std::time::Instant::now() < deadline {
            cycle(&mut self.host, &mut self.phone);
            if self.host.state() == State::Completed && self.phone.state() == State::Completed {
                return;
            }
        }
        panic!(
            "completion not reached: {:?} {:?}",
            self.host.state(),
            self.phone.state()
        );
    }
}

fn cycle(a: &mut Driver, b: &mut Driver) {
    a.poll().unwrap();
    let bytes = if b.ready_for_input() {
        a.drain_ciphertext().unwrap()
    } else {
        vec![]
    };
    if !bytes.is_empty() {
        for chunk in bytes.chunks(crate::device_sync::MAX_CIPHERTEXT) {
            b.ingest_ciphertext(chunk).unwrap();
        }
        a.ciphertext_written(bytes.len()).unwrap();
    }
    b.poll().unwrap();
    let bytes = if a.ready_for_input() {
        b.drain_ciphertext().unwrap()
    } else {
        vec![]
    };
    if !bytes.is_empty() {
        for chunk in bytes.chunks(crate::device_sync::MAX_CIPHERTEXT) {
            a.ingest_ciphertext(chunk).unwrap();
        }
        b.ciphertext_written(bytes.len()).unwrap();
    }
    if a.worker.is_some()
        || b.worker.is_some()
        || a.verification.is_some()
        || b.verification.is_some()
        || a.preparation.is_some()
        || b.preparation.is_some()
    {
        std::thread::sleep(std::time::Duration::from_millis(1));
    } else {
        std::thread::yield_now();
    }
}

#[test]
fn driver_scan_cancel_during_real_paged_work_releases_gate_and_does_not_retain() {
    let root = tempfile::tempdir().unwrap();
    let api = CoreApi::open(root.path()).unwrap();
    for index in 0..4096 {
        api.create_tag(format!("scan-{index:05}")).unwrap();
    }
    let database = api.database();
    let generation = database.device_sync_header().unwrap().generation;
    let (host, _, _) = confirmed(Role::Receiver);
    let mut driver = Driver::new(host, database.clone(), "Desktop", TestClock::new()).unwrap();
    driver.config = Some(Config {
        direction: Direction::DesktopToPhone,
        mode: SyncMode::Merge,
        accounts: false,
    });
    let cancel = driver.cancellation();
    let work = driver.work_control();
    std::thread::scope(|scope| {
        let scanning = scope.spawn(|| driver.begin_snapshots());
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            if work.observe().scanned_items >= 128 {
                assert!(matches!(
                    database.device_sync_exclusive(),
                    Err(CoreError::LibraryBusy)
                ));
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "scan never acquired gate"
            );
            std::thread::yield_now();
        }
        cancel.cancel();
        assert!(
            work.observe().scanned_items < 4096,
            "cancel must occur before all pages complete"
        );
        assert!(
            matches!(scanning.join().unwrap(), Err(DriverError::Cancelled)),
            "cancellation during real scanning must not complete or become a library error"
        );
    });
    assert!(driver.retained.is_none());
    assert_eq!(
        database.device_sync_header().unwrap().generation,
        generation
    );
    assert!(database.device_sync_pending_journal().unwrap().is_none());
    api.create_tag("ordinary-write-after-cancel".into())
        .unwrap();
}

#[test]
fn driver_read_models_match_real_negotiation_preview_and_all_terminal_states() {
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        let mut pair = Pair::new();
        let paired = pair.host.read_view();
        assert_eq!(paired.peer_name.as_deref(), Some("Phone"));
        assert!(paired.host);
        assert!(paired.configuration.is_none());
        pair.a
            .create_album("Desktop album".into(), "".into(), false)
            .unwrap();
        pair.b
            .create_album("Phone album".into(), "".into(), false)
            .unwrap();
        pair.preview(direction, SyncMode::Overwrite);
        let host = pair.host.read_view();
        let phone = pair.phone.read_view();
        assert_eq!(host.source, Some(direction == Direction::DesktopToPhone));
        assert_eq!(phone.source, Some(direction == Direction::PhoneToDesktop));
        assert_eq!(
            host.configuration.unwrap().phone_to_desktop,
            direction == Direction::PhoneToDesktop
        );
        assert_eq!(phone.configuration.unwrap().mode, SyncMode::Overwrite);
        let summary = pair.host.preview_summary().unwrap();
        assert_eq!(summary.binding, pair.host.preview_binding().unwrap());
        assert_eq!(summary.albums.added, 1);
        assert_eq!(summary.albums.removed, 1);
        assert_eq!(summary.albums.kept, 1);
        assert_eq!(
            summary.source_device.as_ref().unwrap().display_name,
            if direction == Direction::DesktopToPhone {
                "Desktop"
            } else {
                "Phone"
            }
        );
        assert_eq!(summary.space, pair.host.plan().unwrap().space);
        assert_eq!(
            summary.receiver_budget.is_some(),
            direction == Direction::PhoneToDesktop
        );
        let phone_summary = pair.phone.preview_summary().unwrap();
        assert_eq!(
            phone_summary.receiver_budget.is_some(),
            direction == Direction::DesktopToPhone
        );
        let budget = if direction == Direction::PhoneToDesktop {
            summary
        } else {
            phone_summary
        }
        .receiver_budget
        .as_ref()
        .unwrap();
        assert!(budget.includes_metadata && budget.includes_allocation_estimate);
        assert!(!budget.volumes.is_empty());
        assert!(budget
            .volumes
            .iter()
            .all(|volume| volume.required_bytes <= volume.available_bytes));
        for state in [
            State::Completed,
            State::CompletedUnconfirmed,
            State::Cancelled,
            State::Failed,
            State::RecoveryPending,
        ] {
            pair.host.state = state;
            pair.host.progress.transfer_total_bytes = 100;
            pair.host.progress.transferred_bytes = 10;
            let view = pair.host.read_view();
            assert_eq!(view.stage, state);
            assert!(view.terminal);
            assert!(view.progress.transfer_total_bytes.is_none());
            assert!(view.progress.total_items.is_none());
            assert_eq!(
                view.progress.work_stage,
                crate::device_sync::work::WorkStage::Idle
            );
        }
    }
}

#[test]
fn driver_account_option_without_local_authorizations_falls_back_to_library_only() {
    let mut pair = Pair::new();
    pair.a.create_tag("library-only".into()).unwrap();
    assert!(
        pair.host
            .configure(Direction::DesktopToPhone, SyncMode::Merge, true)
            .is_ok(),
        "a remote account option must not force account access or block library-only sync"
    );
    for _ in 0..100 {
        cycle(&mut pair.host, &mut pair.phone);
    }
    assert_eq!(pair.host.state(), State::AwaitingAccountConsent);
    assert_eq!(pair.phone.state(), State::AwaitingAccountConsent);
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
    pair.host.decline_accounts().unwrap();
    for _ in 0..100 {
        cycle(&mut pair.host, &mut pair.phone);
    }
    assert_eq!(pair.phone.state(), State::AwaitingAccountConsent);
    pair.phone.decline_accounts().unwrap();
    for _ in 0..10_000 {
        cycle(&mut pair.host, &mut pair.phone);
        if pair.host.state() == State::AwaitingApproval
            && pair.phone.state() == State::AwaitingApproval
        {
            break;
        }
    }
    assert_eq!(pair.phone.state(), State::AwaitingApproval);
    pair.complete(Direction::DesktopToPhone);
    assert_eq!(pair.b.list_tags().unwrap(), ["library-only"]);
    assert_eq!(
        pair.b
            .database()
            .device_sync_journal(pair.phone.receipt().unwrap().operation_uuid)
            .unwrap()
            .unwrap()
            .external_reference,
        None
    );
}

#[test]
fn driver_authorized_accounts_use_same_tls_and_wait_for_real_external_finalize() {
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        for mode in [SyncMode::Merge, SyncMode::Overwrite] {
            for json in [
                r#"{"version":1,"accounts":[{"account_id":"a","nickname":"Alice","session_token":"synthetic-secret"}]}"#,
                r#"{"version":1,"accounts":[]}"#,
            ] {
                let mut pair = Pair::new();
                let (source, target) = match direction {
                    Direction::DesktopToPhone => (&mut pair.host, &mut pair.phone),
                    Direction::PhoneToDesktop => (&mut pair.phone, &mut pair.host),
                };
                source
                    .authorize_accounts_export(json.as_bytes(), &"a".repeat(64))
                    .unwrap();
                target.authorize_accounts_receive(&"b".repeat(64)).unwrap();
                pair.host.configure(direction, mode, true).unwrap();
                for _ in 0..10_000 {
                    cycle(&mut pair.host, &mut pair.phone);
                    if pair.host.state() == State::AwaitingApproval
                        && pair.phone.state() == State::AwaitingApproval
                    {
                        break;
                    }
                }
                let external = uuid::Uuid::new_v4();
                let (source, target) = match direction {
                    Direction::DesktopToPhone => (&mut pair.host, &mut pair.phone),
                    Direction::PhoneToDesktop => (&mut pair.phone, &mut pair.host),
                };
                assert_eq!(
                    &*target.accounts_payload().unwrap().unwrap(),
                    json.as_bytes()
                );
                assert!(target.approve_preview().is_err());
                let binding = target.preview_binding().unwrap().to_owned();
                target
                    .approve_accounts_preview(&binding, &"b".repeat(64), external)
                    .unwrap();
                assert!(source.accounts_payload().unwrap().is_none());
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
                loop {
                    cycle(&mut pair.host, &mut pair.phone);
                    let (source, target) = match direction {
                        Direction::DesktopToPhone => (&mut pair.host, &mut pair.phone),
                        Direction::PhoneToDesktop => (&mut pair.phone, &mut pair.host),
                    };
                    if source.state() == State::AwaitingAccountFinal {
                        assert!(source.approve_accounts_final(&"c".repeat(64)).is_err());
                        source.approve_accounts_final(&"a".repeat(64)).unwrap();
                    }
                    if target.state() == State::AwaitingTargetAccountFinal {
                        assert!(target
                            .approve_accounts_target_final(&"c".repeat(64))
                            .is_err());
                        target
                            .approve_accounts_target_final(&"b".repeat(64))
                            .unwrap();
                    }
                    if target.state() == State::AwaitingExternal {
                        let receipt = target.receipt().unwrap();
                        assert_eq!(
                            receipt.state,
                            super::super::receiver::ApplyState::LibraryAppliedPending
                        );
                        let journal = target
                            .database
                            .device_sync_pending_journal()
                            .unwrap()
                            .unwrap();
                        assert_eq!(journal.external_reference, Some(external));
                        assert!(source.database.create_tag("must-stay-locked").is_err());
                        target.external_step().unwrap();
                        assert!(target.finalize_accounts(uuid::Uuid::new_v4()).is_err());
                        target.finalize_accounts(external).unwrap();
                        break;
                    }
                    assert!(std::time::Instant::now() < deadline);
                }
                for _ in 0..100 {
                    cycle(&mut pair.host, &mut pair.phone);
                    if pair.host.state() == State::Completed
                        && pair.phone.state() == State::Completed
                    {
                        break;
                    }
                }
                assert_eq!(pair.host.state(), State::Completed);
                assert_eq!(pair.phone.state(), State::Completed);
                let target = match direction {
                    Direction::DesktopToPhone => &pair.phone,
                    Direction::PhoneToDesktop => &pair.host,
                };
                assert!(!target.database.device_sync_recovery_pending());
                assert_eq!(
                    target.receipt().unwrap().state,
                    super::super::receiver::ApplyState::Finalized
                );
            }
        }
    }
}

#[test]
fn driver_large_account_payload_is_segmented_inside_existing_frame_and_queue_budgets() {
    let mut pair = Pair::new();
    let records: Vec<_> = (0..32)
        .map(|id| {
            format!(
                r#"{{"account_id":"a{id:02}","nickname":"","session_token":"{}"}}"#,
                "x".repeat(7000)
            )
        })
        .collect();
    let json = format!(r#"{{"version":1,"accounts":[{}]}}"#, records.join(","));
    assert!(json.len() > 65_536);
    assert!(json.len() <= super::super::accounts::MAX_ACCOUNT_BYTES);
    pair.host
        .authorize_accounts_export(json.as_bytes(), &"a".repeat(64))
        .unwrap();
    pair.phone
        .authorize_accounts_receive(&"b".repeat(64))
        .unwrap();
    pair.host
        .configure(Direction::DesktopToPhone, SyncMode::Overwrite, true)
        .unwrap();
    for _ in 0..10_000 {
        cycle(&mut pair.host, &mut pair.phone);
        if pair.phone.state() == State::AwaitingApproval {
            break;
        }
    }
    assert_eq!(pair.phone.state(), State::AwaitingApproval);
    assert_eq!(
        &*pair.phone.accounts_payload().unwrap().unwrap(),
        json.as_bytes()
    );
    assert!(pair.phone.progress.peak_plaintext_bytes > wire::RAW_CHUNK);
    assert!(pair.phone.progress.peak_plaintext_bytes <= super::super::MAX_PAYLOAD);
    assert!(pair.host.progress.peak_outbox_messages <= MAX_OUTBOX);
    assert!(pair.phone.progress.peak_outbox_messages <= MAX_OUTBOX);
    println!("4B2 account payload={} target_plaintext_peak={} source_ciphertext_peak={} target_outbox_peak={}",
        json.len(), pair.phone.progress.peak_plaintext_bytes,
        pair.host.progress.peak_ciphertext_bytes, pair.phone.progress.peak_outbox_messages);
}

#[test]
fn driver_real_tls_rejects_malformed_replayed_and_unbounded_account_segments_before_preview() {
    fn send(pair: &mut Pair, message: Message) -> Result<()> {
        let envelope = Envelope {
            version: 1,
            session: pair.host.session.session_id().into(),
            operation: pair.host.session.operation_id().into(),
            generation: 1,
            sequence: pair.host.sent_sequence,
            message,
        };
        pair.host
            .session
            .send_payload(&envelope.encode().unwrap(), pair.hc.unix_ms() / 1000)
            .unwrap();
        pair.host.sent_sequence += 1;
        let bytes = pair.host.drain_ciphertext().unwrap();
        pair.phone.ingest_ciphertext(&bytes).unwrap();
        pair.host.ciphertext_written(bytes.len()).unwrap();
        pair.phone.poll()
    }
    const VALID: &str = r#"{"version":1,"accounts":[{"account_id":"a","nickname":"","session_token":"synthetic-secret"}]}"#;
    for case in 0..8 {
        let mut pair = Pair::new();
        pair.b.create_tag("unchanged".into()).unwrap();
        pair.phone
            .authorize_accounts_receive(&"b".repeat(64))
            .unwrap();
        pair.host
            .configure(Direction::DesktopToPhone, SyncMode::Overwrite, true)
            .unwrap();
        for _ in 0..100 {
            cycle(&mut pair.host, &mut pair.phone);
        }
        assert!(pair.phone.step == Step::AccountConsent);
        // Malicious authenticated peer claims its own consent. It cannot grant
        // target consent; the target's independent local grant above is real.
        send(&mut pair, Message::AccountConsent { accepted: true }).unwrap();
        assert!(pair.phone.step == Step::ReceiveAccounts);
        let payload = match case {
            3 => VALID.replace(
                "\"nickname\":\"\"",
                "\"nickname\":\"\",\"avatar_url\":\"private\"",
            ),
            4 => VALID.replace("\"version\":1", "\"version\":2"),
            5 => VALID.replace("synthetic-secret", &"x".repeat(8193)),
            _ => VALID.into(),
        };
        let result = match case {
            0 | 1 => send(
                &mut pair,
                Message::AccountPart {
                    offset: usize::from(case == 0),
                    total: if case == 1 {
                        super::super::accounts::MAX_ACCOUNT_BYTES + 1
                    } else {
                        payload.len()
                    },
                    data: wire::encode_chunk(payload.as_bytes()),
                },
            ),
            2 => {
                let part = &payload.as_bytes()[..10];
                send(
                    &mut pair,
                    Message::AccountPart {
                        offset: 0,
                        total: payload.len(),
                        data: wire::encode_chunk(part),
                    },
                )
                .unwrap();
                assert!(pair.phone.accounts_payload().unwrap().is_none());
                send(
                    &mut pair,
                    Message::AccountPart {
                        offset: 0,
                        total: payload.len(),
                        data: wire::encode_chunk(part),
                    },
                )
            }
            _ => {
                if case != 7 {
                    send(
                        &mut pair,
                        Message::AccountPart {
                            offset: 0,
                            total: payload.len(),
                            data: wire::encode_chunk(payload.as_bytes()),
                        },
                    )
                    .unwrap();
                    assert!(pair.phone.accounts_payload().unwrap().is_none());
                }
                send(
                    &mut pair,
                    Message::AccountEnd {
                        digest: if case == 6 {
                            "0".repeat(64)
                        } else {
                            hex::encode(Sha256::digest(VALID.as_bytes()))
                        },
                        state_digest: "a".repeat(64),
                    },
                )
            }
        };
        assert!(
            result.is_err(),
            "malformed account case {case} was accepted"
        );
        assert_eq!(pair.phone.state(), State::Failed);
        assert_eq!(pair.phone.session.state(), SessionState::Terminal);
        assert!(pair.phone.accounts_payload().unwrap().is_none());
        assert!(pair.phone.preview_binding().is_none());
        assert!(pair
            .b
            .database()
            .device_sync_pending_journal()
            .unwrap()
            .is_none());
        assert_eq!(pair.b.list_tags().unwrap(), ["unchanged"]);
    }
}

#[test]
fn driver_account_cancel_before_finalize_compensates_but_lost_ack_after_finalize_keeps_commit() {
    for finalized in [false, true] {
        let mut pair = Pair::new();
        pair.a.create_tag("incoming".into()).unwrap();
        pair.b.create_tag("old target".into()).unwrap();
        pair.host
            .authorize_accounts_export(br#"{"version":1,"accounts":[]}"#, &"a".repeat(64))
            .unwrap();
        pair.phone
            .authorize_accounts_receive(&"b".repeat(64))
            .unwrap();
        pair.host
            .configure(Direction::DesktopToPhone, SyncMode::Overwrite, true)
            .unwrap();
        for _ in 0..10_000 {
            cycle(&mut pair.host, &mut pair.phone);
            if pair.phone.state() == State::AwaitingApproval {
                break;
            }
        }
        let external = uuid::Uuid::new_v4();
        let binding = pair.phone.preview_binding().unwrap().to_owned();
        pair.phone
            .approve_accounts_preview(&binding, &"b".repeat(64), external)
            .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while pair.phone.state() != State::AwaitingExternal {
            cycle(&mut pair.host, &mut pair.phone);
            if pair.phone.state() == State::AwaitingTargetAccountFinal {
                pair.phone
                    .approve_accounts_target_final(&"b".repeat(64))
                    .unwrap();
            }
            if pair.host.state() == State::AwaitingAccountFinal {
                pair.host.approve_accounts_final(&"a".repeat(64)).unwrap();
            }
            assert!(std::time::Instant::now() < deadline);
        }
        let operation = pair.phone.receipt().unwrap().operation_uuid;
        assert_eq!(pair.b.list_tags().unwrap(), ["incoming"]);
        if finalized {
            pair.phone.finalize_accounts(external).unwrap();
            // Never deliver the queued account-bearing CommitAck.
            pair.phone.cancel();
            assert_eq!(pair.phone.state(), State::Completed);
        } else {
            pair.phone.cancel();
            pair.phone.finish_shutdown();
            assert!(pair.b.database().device_sync_recovery_pending());
            let mut recovery = super::super::recovery::RecoveryOperation::preview_pending(
                pair.b.database(),
                operation,
                "Target",
            )
            .unwrap();
            let mut authorization = recovery.authorize().unwrap();
            recovery
                .restore(Some(&mut authorization), &CancellationToken::default())
                .unwrap();
        }
        pair.hc.advance(LEASE_MS + 1);
        pair.host.poll().unwrap();
        assert_eq!(pair.host.state(), State::CompletedUnconfirmed);
        pair.a.create_tag("source lock released".into()).unwrap();
        let reopened = CoreApi::open(pair._roots[1].path()).unwrap();
        assert_eq!(
            reopened.list_tags().unwrap(),
            if finalized {
                ["incoming"]
            } else {
                ["old target"]
            }
        );
        assert!(!reopened.database().device_sync_recovery_pending());
        assert_eq!(
            reopened
                .database()
                .device_sync_journal(operation)
                .unwrap()
                .unwrap()
                .stage,
            if finalized {
                super::super::recovery::JournalStage::Finalized
            } else {
                super::super::recovery::JournalStage::RolledBack
            }
        );
    }
}

fn finalized_without_ack(close: impl FnOnce() + Send + 'static) -> Pair {
    let mut pair = Pair::new();
    pair.phone.set_transport_close(close).unwrap();
    pair.a.create_tag("committed".into()).unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while std::time::Instant::now() < deadline {
        pair.host.poll().unwrap();
        let bytes = pair.host.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.phone.ingest_ciphertext(&bytes).unwrap();
            pair.host.ciphertext_written(bytes.len()).unwrap();
        }
        pair.phone.poll().unwrap();
        if pair.phone.state() == State::Completed {
            assert!(!pair.host.state().terminal());
            return pair;
        }
        let bytes = pair.phone.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.host.ingest_ciphertext(&bytes).unwrap();
            pair.phone.ciphertext_written(bytes.len()).unwrap();
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    panic!("target did not finalize");
}

#[test]
fn driver_final_ack_waits_for_actual_partial_writes_and_closes_owner_once() {
    use std::io::Write;
    use std::net::{Shutdown, TcpListener, TcpStream};
    struct LimitedWriter {
        stream: TcpStream,
        blocked: bool,
        total: usize,
    }
    impl Write for LimitedWriter {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if self.blocked {
                return Err(std::io::ErrorKind::WouldBlock.into());
            }
            let count = self.stream.write(&bytes[..bytes.len().min(13)])?;
            self.total += count;
            Ok(count)
        }
        fn flush(&mut self) -> std::io::Result<()> {
            self.stream.flush()
        }
    }
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mut peer = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (stream, _) = listener.accept().unwrap();
    drop(listener);
    peer.set_read_timeout(Some(std::time::Duration::from_millis(100)))
        .unwrap();
    let control = stream.try_clone().unwrap();
    let closes = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let closed = closes.clone();
    let mut pair = finalized_without_ack(move || {
        closed.fetch_add(1, Ordering::SeqCst);
        let _ = control.shutdown(Shutdown::Both);
    });
    let mut pending = pair.phone.drain_ciphertext().unwrap();
    let ack_bytes = pending.len();
    assert!(ack_bytes > 13);
    assert!(pair.phone.drain_ciphertext().unwrap().is_empty());
    assert!(
        !pair.phone.finish_success(),
        "TLS drain is not sink completion"
    );
    let mut written = 0;
    let mut sink = LimitedWriter {
        stream,
        blocked: true,
        total: 0,
    };
    super::pump::flush_output(&mut pair.phone, &mut pending, &mut written, &mut sink).unwrap();
    assert_eq!(pending.len(), ack_bytes);
    assert_eq!(written, 0);
    assert_eq!(pair.phone.session.state(), SessionState::Confirmed);
    assert!(
        matches!(peer.read(&mut [0]), Err(error) if matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut))
    );
    sink.blocked = false;
    for _ in 0..ack_bytes {
        let previous = sink.total;
        super::pump::flush_output(&mut pair.phone, &mut pending, &mut written, &mut sink).unwrap();
        let mut bytes = vec![0; sink.total - previous];
        peer.read_exact(&mut bytes).unwrap();
        pair.host.ingest_ciphertext(&bytes).unwrap();
        pair.host.poll().unwrap();
        if pending.is_empty() {
            break;
        }
        assert_ne!(pair.host.state(), State::Completed);
        assert_eq!(pair.phone.session.state(), SessionState::Confirmed);
        assert_eq!(closes.load(Ordering::SeqCst), 0);
    }
    assert_eq!(sink.total, ack_bytes);
    assert_eq!(pair.host.state(), State::Completed);
    assert_eq!(peer.read(&mut [0]).unwrap(), 0);
    assert_eq!(pair.phone.session.state(), SessionState::Terminal);
    assert_eq!(pair.phone.state(), State::Completed);
    assert_eq!(closes.load(Ordering::SeqCst), 1);
    pair.phone.poll().unwrap();
    pair.phone.cancel();
    pair.phone.disconnect();
    assert!(pair.phone.finish_success());
    assert_eq!(closes.load(Ordering::SeqCst), 1);
    assert!(pair.phone.receipt().is_some());
    assert_eq!(pair.b.list_tags().unwrap(), vec!["committed"]);
}

#[test]
fn driver_success_backpressure_expires_without_ack_or_rollback() {
    use std::net::{Shutdown, TcpListener, TcpStream};
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mut peer = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (stream, _) = listener.accept().unwrap();
    drop(listener);
    peer.set_read_timeout(Some(std::time::Duration::from_millis(100)))
        .unwrap();
    let mut pair = finalized_without_ack(move || {
        let _ = stream.shutdown(Shutdown::Both);
    });
    let held_ack = pair.phone.drain_ciphertext().unwrap();
    assert!(!held_ack.is_empty());
    assert!(pair.phone.drain_ciphertext().unwrap().is_empty());
    assert!(!pair.phone.finish_success());
    pair.pc.advance(LEASE_MS - 1);
    pair.phone.poll().unwrap();
    assert_eq!(pair.phone.session.state(), SessionState::Confirmed);
    pair.pc.advance(1);
    pair.phone.poll().unwrap();
    assert_eq!(peer.read(&mut [0]).unwrap(), 0);
    assert_eq!(pair.phone.session.state(), SessionState::Terminal);
    assert_eq!(pair.phone.state(), State::Completed);
    assert!(pair.phone.receipt().is_some());
    pair.hc.advance(LEASE_MS + 1);
    pair.host.poll().unwrap();
    assert_eq!(pair.host.state(), State::CompletedUnconfirmed);
    let reopened = CoreApi::open(pair._roots[1].path()).unwrap();
    assert_eq!(reopened.list_tags().unwrap(), vec!["committed"]);
    assert!(!reopened.database().device_sync_recovery_pending());
}

#[test]
fn driver_mailbox_final_ack_requires_atomic_block_write_or_bounded_expiry() {
    use super::pump::MailboxPump;
    use std::net::{Shutdown, TcpListener, TcpStream};
    for persist in [false, true] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut probe = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (owner, _) = listener.accept().unwrap();
        drop(listener);
        probe
            .set_read_timeout(Some(std::time::Duration::from_millis(100)))
            .unwrap();
        let mut pair = finalized_without_ack(move || {
            let _ = owner.shutdown(Shutdown::Both);
        });
        let mut outgoing = MailboxPump::default();
        let mut incoming = MailboxPump::default();
        let (name, block) = outgoing
            .outgoing(&mut pair.phone)
            .unwrap()
            .map(|(name, block)| (name.to_owned(), block.to_vec()))
            .unwrap();
        assert!(!outgoing.finish_success(&mut pair.phone));
        outgoing.window_full();
        assert!(outgoing.outgoing(&mut pair.phone).unwrap().is_none());
        assert_eq!(outgoing.buffered_bytes(), block.len());
        assert_eq!(pair.phone.session.state(), SessionState::Confirmed);
        if persist {
            let mailbox = tempfile::tempdir().unwrap();
            let partial = mailbox.path().join(format!("{name}.part"));
            let complete = mailbox.path().join(&name);
            std::fs::write(&partial, &block).unwrap();
            std::fs::rename(&partial, &complete).unwrap();
            let read = std::fs::read(complete).unwrap();
            assert_eq!(incoming.accept(&mut pair.host, &name, &read).unwrap(), name);
            outgoing.written(&mut pair.phone).unwrap();
            // WindowFull is retired by the actual read/ACK, not by a timer.
            assert!(!outgoing.finish_success(&mut pair.phone));
            outgoing.capacity_released();
            assert!(outgoing.outgoing(&mut pair.phone).unwrap().is_none());
            assert!(outgoing.finish_success(&mut pair.phone));
            pair.host.poll().unwrap();
            assert_eq!(pair.host.state(), State::Completed);
        } else {
            pair.pc.advance(LEASE_MS);
            pair.phone.poll().unwrap();
            pair.hc.advance(LEASE_MS + 1);
            pair.host.poll().unwrap();
            assert_eq!(pair.host.state(), State::CompletedUnconfirmed);
            assert!(outgoing.outgoing(&mut pair.phone).unwrap().is_none());
            assert_eq!(outgoing.buffered_bytes(), 0);
        }
        assert_eq!(probe.read(&mut [0]).unwrap(), 0);
        assert_eq!(pair.phone.session.state(), SessionState::Terminal);
        assert_eq!(pair.phone.state(), State::Completed);
        assert!(pair.phone.receipt().is_some());
        assert_eq!(pair.b.list_tags().unwrap(), vec!["committed"]);
    }
}

#[tokio::test]
async fn driver_receives_all_media_before_any_content_hash_and_commits_only_after_batch_validation()
{
    let mut pair = Pair::new();
    let input = tempfile::tempdir().unwrap();
    let mut paths = Vec::new();
    for index in 0..3 {
        let path = input.path().join(format!("batch-{index}.jpg"));
        std::fs::write(&path, vec![index as u8; 131_072]).unwrap();
        paths.push(path.to_string_lossy().into_owned());
    }
    assert_eq!(pair.a.import_local_files(paths).await.unwrap().imported, 3);
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    let total = 3 * 131_072;
    let mut observed_intermediate = false;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while std::time::Instant::now() < deadline {
        cycle(&mut pair.host, &mut pair.phone);
        let transferred = pair.phone.progress.transferred_bytes;
        if transferred > 131_072 && transferred < total {
            observed_intermediate = true;
            assert_eq!(pair.phone.state(), State::Transferring);
            let metrics = pair.phone.work.validation_metrics();
            assert_eq!(metrics.receive_hashed_bytes, 0);
            assert_eq!(metrics.checksum_read_bytes, 0);
            assert!(pair
                .b
                .list_media(GalleryQuery::default())
                .unwrap()
                .is_empty());
        }
        if pair.host.state() == State::Completed && pair.phone.state() == State::Completed {
            break;
        }
    }
    assert!(observed_intermediate);
    assert_eq!(pair.phone.state(), State::Completed);
    assert_eq!(pair.b.list_media(GalleryQuery::default()).unwrap().len(), 3);
    let metrics = pair.phone.work.validation_metrics();
    assert_eq!(metrics.receive_hashed_bytes, 0);
    assert_eq!(metrics.checksum_read_bytes, total);
    assert_eq!(metrics.copy_bytes, total);
}

#[tokio::test]
async fn driver_measurements_count_verified_media_without_user_confirmation_wait() {
    let mut pair = Pair::new();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("measured.jpeg");
    let bytes = vec![7; 65_537];
    std::fs::write(&path, &bytes).unwrap();
    pair.a
        .import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.hc.advance(5_000);
    pair.pc.advance(5_000);
    pair.host.poll().unwrap();
    pair.phone.poll().unwrap();
    pair.phone.approve_preview().unwrap();
    for _ in 0..10_000 {
        pair.hc.advance(1);
        pair.pc.advance(1);
        cycle(&mut pair.host, &mut pair.phone);
        if pair.host.state() == State::Completed && pair.phone.state() == State::Completed {
            break;
        }
    }
    assert_eq!(pair.host.state(), State::Completed);
    assert_eq!(pair.phone.state(), State::Completed);
    for (driver, now) in [
        (&mut pair.host, pair.hc.monotonic_ms()),
        (&mut pair.phone, pair.pc.monotonic_ms()),
    ] {
        let record = driver.metrics.finish(now);
        let value = |key: &str| {
            record
                .split_whitespace()
                .find_map(|part| {
                    let (name, value) = part.split_once('=')?;
                    (name == key).then_some(value)
                })
                .expect("actual Driver must publish structured measurements")
                .parse::<u64>()
                .unwrap()
        };
        assert_eq!(value("media_bytes"), 65_537);
        assert!(value("transfer_ms") > 0);
        assert!(value("operation_ms") < 5_000);
        assert!(value("session_ms") >= 5_000);
    }
}

#[tokio::test]
async fn driver_real_tls_two_libraries_requires_local_approval_then_streams_and_finalizes() {
    let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
    let a = CoreApi::open(roots[0].path()).unwrap();
    let b = CoreApi::open(roots[1].path()).unwrap();
    let input = tempfile::tempdir().unwrap();
    let bytes = b"actual streamed original";
    let path = input.path().join("example.jpeg");
    std::fs::write(&path, bytes).unwrap();
    a.import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    a.create_tag("wire catalog".into()).unwrap();
    let before = b.database().device_sync_header().unwrap().generation;
    let (host, phone, _) = confirmed(Role::Receiver);
    let mut host = Driver::new(
        host,
        a.database(),
        "Desktop",
        Arc::new(SystemClock::default()),
    )
    .unwrap();
    let mut phone = Driver::new(
        phone,
        b.database(),
        "Phone",
        Arc::new(SystemClock::default()),
    )
    .unwrap();
    host.configure(Direction::DesktopToPhone, SyncMode::Overwrite, false)
        .unwrap();
    for _ in 0..5000 {
        cycle(&mut host, &mut phone);
        if phone.state() == State::AwaitingApproval {
            break;
        }
    }
    assert_eq!(phone.state(), State::AwaitingApproval);
    assert_eq!(
        b.database().device_sync_header().unwrap().generation,
        before
    );
    assert!(b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
    assert!(b.list_media(GalleryQuery::default()).unwrap().is_empty());
    phone.approve_preview().unwrap();
    for _ in 0..100_000 {
        cycle(&mut host, &mut phone);
        if host.state() == State::Completed {
            break;
        }
    }
    assert_eq!(host.state(), State::Completed);
    assert_eq!(phone.state(), State::Completed);
    let media = b.list_media(GalleryQuery::default()).unwrap();
    assert_eq!(media.len(), 1);
    assert_eq!(media[0].sha256, hex::encode(Sha256::digest(bytes)));
    assert_eq!(std::fs::read(&media[0].storage_path).unwrap(), bytes);
    assert!(b.list_tags().unwrap().contains(&"wire catalog".into()));
    assert!(!b.database().device_sync_recovery_pending());
    assert_eq!(phone.progress().transferred_bytes, bytes.len() as u64);
}

#[test]
fn driver_reverse_direction_and_empty_overwrite_apply_actual_catalog() {
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        for mode in [SyncMode::Merge, SyncMode::Overwrite] {
            let mut pair = Pair::new();
            let (source, target) = if direction == Direction::DesktopToPhone {
                (&pair.a, &pair.b)
            } else {
                (&pair.b, &pair.a)
            };
            source.create_tag("incoming".into()).unwrap();
            target.create_tag("existing".into()).unwrap();
            pair.preview(direction, mode);
            pair.complete(direction);
            let target = if direction == Direction::DesktopToPhone {
                &pair.b
            } else {
                &pair.a
            };
            let tags = target.list_tags().unwrap();
            assert!(tags.contains(&"incoming".into()));
            assert_eq!(tags.contains(&"existing".into()), mode == SyncMode::Merge);
        }
    }
    let mut pair = Pair::new();
    pair.b.create_tag("delete standalone".into()).unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Overwrite);
    pair.complete(Direction::DesktopToPhone);
    assert!(pair.b.list_tags().unwrap().is_empty());
}

#[test]
fn driver_waiting_for_user_does_not_consume_data_timeout() {
    let mut pair = Pair::new();
    pair.a.create_tag("wait".into()).unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.hc.advance(240_000);
    pair.pc.advance(240_000);
    pair.complete(Direction::DesktopToPhone);
}

#[test]
fn driver_source_change_invalidates_final_ready_and_releases_pins() {
    let mut pair = Pair::new();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.a.create_tag("late local change".into()).unwrap();
    pair.phone.approve_preview().unwrap();
    let mut failed = false;
    for _ in 0..1000 {
        if pair.host.poll().is_err() {
            failed = true;
            break;
        }
        let bytes = pair.host.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.phone.ingest_ciphertext(&bytes).unwrap();
        }
        pair.phone.poll().unwrap();
        let bytes = pair.phone.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.host.ingest_ciphertext(&bytes).unwrap();
        }
    }
    assert!(failed);
    assert_eq!(pair.host.state(), State::Failed);
    assert!(pair.b.list_tags().unwrap().is_empty());
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
    pair.a.create_tag("released".into()).unwrap();
}

#[test]
fn driver_source_ready_issued_lease_survives_disconnect_until_conservative_deadline() {
    let mut pair = Pair::new();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    for _ in 0..1000 {
        pair.phone.poll().unwrap();
        let bytes = pair.phone.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.host.ingest_ciphertext(&bytes).unwrap();
        }
        pair.host.poll().unwrap();
        if pair.host.source_lease.is_some() {
            break;
        }
        let bytes = pair.host.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.phone.ingest_ciphertext(&bytes).unwrap();
        }
    }
    assert!(pair.host.source_lease.is_some());
    assert!(matches!(
        pair.a.create_tag("blocked".into()),
        Err(CoreError::LibraryBusy)
    ));
    pair.host.disconnect();
    assert_eq!(pair.host.state(), State::CompletedUnconfirmed);
    assert!(pair.host.cleanup_pending());
    assert!(matches!(
        pair.a.create_tag("still protected".into()),
        Err(CoreError::LibraryBusy)
    ));
    pair.hc.advance(LEASE_MS + 1);
    assert!(!pair.host.cleanup_pending());
    pair.a.create_tag("released".into()).unwrap();
}

#[test]
fn driver_late_lease_grant_cannot_activate_commit_permission() {
    let mut pair = Pair::new();
    pair.a.create_tag("must not apply".into()).unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    for _ in 0..1000 {
        pair.phone.poll().unwrap();
        let bytes = pair.phone.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.host.ingest_ciphertext(&bytes).unwrap();
        }
        pair.host.poll().unwrap();
        if pair.host.source_lease.is_some() {
            break;
        }
        let bytes = pair.host.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.phone.ingest_ciphertext(&bytes).unwrap();
        }
    }
    let late = pair.host.drain_ciphertext().unwrap();
    pair.hc.advance(LEASE_MS + 1);
    pair.pc.advance(LEASE_MS + 1);
    pair.host.poll().unwrap();
    assert_eq!(pair.host.state(), State::CompletedUnconfirmed);
    pair.a.create_tag("source lock released".into()).unwrap();
    pair.phone.ingest_ciphertext(&late).unwrap();
    assert!(matches!(pair.phone.poll(), Err(DriverError::Timeout)));
    assert!(!pair.phone.permit.active.load(Ordering::SeqCst));
    assert!(pair.b.list_tags().unwrap().is_empty());
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
}

#[test]
fn driver_final_ack_loss_never_rolls_back_finalized_target_or_reports_source_success() {
    let mut pair = Pair::new();
    pair.a.create_tag("committed".into()).unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while pair.phone.state() != State::Completed && std::time::Instant::now() < deadline {
        pair.host.poll().unwrap();
        let bytes = pair.host.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.phone.ingest_ciphertext(&bytes).unwrap();
        }
        pair.phone.poll().unwrap();
        if pair.phone.state() == State::Completed {
            break;
        }
        let bytes = pair.phone.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.host.ingest_ciphertext(&bytes).unwrap();
        }
        if pair
            .phone
            .worker
            .as_ref()
            .is_some_and(|worker| !worker.is_finished())
        {
            std::thread::park_timeout(std::time::Duration::from_millis(1));
        } else {
            std::thread::yield_now();
        }
    }
    assert_eq!(pair.phone.state(), State::Completed);
    pair.phone.cancel();
    assert_eq!(pair.phone.state(), State::Completed);
    pair.hc.advance(LEASE_MS + 1);
    pair.host.poll().unwrap();
    assert_eq!(pair.host.state(), State::CompletedUnconfirmed);
    let reopened = CoreApi::open(pair._roots[1].path()).unwrap();
    assert!(reopened.list_tags().unwrap().contains(&"committed".into()));
    assert!(!reopened.database().device_sync_recovery_pending());
}

#[test]
fn driver_account_selection_and_remote_approval_cannot_authorize_target() {
    let mut pair = Pair::new();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    let binding = pair.phone.preview_binding().unwrap().to_owned();
    let envelope = Envelope {
        version: 1,
        session: pair.host.session.session_id().into(),
        operation: pair.host.session.operation_id().into(),
        generation: 1,
        sequence: pair.host.sent_sequence,
        message: Message::Approved { binding },
    };
    pair.host
        .session
        .send_payload(&envelope.encode().unwrap(), pair.hc.unix_ms() / 1000)
        .unwrap();
    let bytes = pair.host.drain_ciphertext().unwrap();
    pair.phone.ingest_ciphertext(&bytes).unwrap();
    assert!(matches!(pair.phone.poll(), Err(DriverError::Protocol)));
    assert!(pair.phone.authorization.is_none());
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
}

#[test]
fn driver_cross_session_generation_replay_and_wrong_stage_frames_are_terminal() {
    for alteration in 0..5 {
        let mut pair = Pair::new();
        let mut envelope = Envelope {
            version: 1,
            session: pair.host.session.session_id().into(),
            operation: pair.host.session.operation_id().into(),
            generation: 1,
            sequence: 0,
            message: Message::FilesComplete {},
        };
        match alteration {
            0 => envelope.session = "0".repeat(32),
            1 => envelope.operation = "1".repeat(32),
            2 => envelope.generation = 2,
            3 => envelope.sequence = 1,
            _ => {}
        }
        pair.host
            .session
            .send_payload(&envelope.encode().unwrap(), pair.hc.unix_ms() / 1000)
            .unwrap();
        let bytes = pair.host.drain_ciphertext().unwrap();
        pair.phone.ingest_ciphertext(&bytes).unwrap();
        assert!(pair.phone.poll().is_err());
        assert_eq!(pair.phone.state(), State::Failed);
        assert_eq!(pair.phone.session.state(), SessionState::Terminal);
        assert!(pair
            .b
            .database()
            .device_sync_pending_journal()
            .unwrap()
            .is_none());
    }
}

#[test]
fn driver_stalled_configuration_and_metadata_have_distinct_deadlines() {
    let mut pair = Pair::new();
    pair.hc.advance(USER_MS + 1);
    assert!(matches!(pair.host.poll(), Err(DriverError::Timeout)));
    assert_eq!(pair.host.state(), State::Failed);
    let mut pair = Pair::new();
    pair.host
        .configure(Direction::DesktopToPhone, SyncMode::Merge, false)
        .unwrap();
    for _ in 0..100 {
        cycle(&mut pair.host, &mut pair.phone);
        if pair.host.sample.is_some() {
            break;
        }
    }
    pair.hc.advance(DATA_MS + 1);
    assert!(matches!(pair.host.poll(), Err(DriverError::Timeout)));
}

#[test]
fn driver_unbounded_or_repeated_lease_progress_cannot_keep_source_locked() {
    for work in [0, u64::MAX] {
        let mut pair = Pair::new();
        pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
        pair.phone.approve_preview().unwrap();
        for _ in 0..100 {
            pair.phone.poll().unwrap();
            let bytes = pair.phone.drain_ciphertext().unwrap();
            if !bytes.is_empty() {
                pair.host.ingest_ciphertext(&bytes).unwrap();
            }
            pair.host.poll().unwrap();
            if pair.host.source_lease.is_some() {
                break;
            }
            let bytes = pair.host.drain_ciphertext().unwrap();
            if !bytes.is_empty() {
                pair.phone.ingest_ciphertext(&bytes).unwrap();
            }
        }
        let envelope = Envelope {
            version: 1,
            session: pair.phone.session.session_id().into(),
            operation: pair.phone.session.operation_id().into(),
            generation: 1,
            sequence: pair.phone.sent_sequence,
            message: Message::LeaseRequest {
                binding: pair.phone.binding.clone().unwrap(),
                id: 1,
                work: ApplyWork {
                    phase: ApplyPhase::Preparing,
                    publication_bytes: work,
                    sql_steps: 0,
                    account_steps: 0,
                },
            },
        };
        pair.phone
            .session
            .send_payload(&envelope.encode().unwrap(), pair.pc.unix_ms() / 1000)
            .unwrap();
        let bytes = pair.phone.drain_ciphertext().unwrap();
        pair.host.ingest_ciphertext(&bytes).unwrap();
        assert!(
            pair.host.poll().is_err(),
            "invalid progress kept the source lock"
        );
        pair.hc.advance(LEASE_MS + 1);
        assert!(!pair.host.cleanup_pending());
        pair.a
            .create_tag("released after bad progress".into())
            .unwrap();
    }
}

#[test]
fn driver_source_independently_bounds_progressing_sql_even_when_phase_is_skipped() {
    for phase in [ApplyPhase::Sql, ApplyPhase::Finalizing] {
        let mut pair = Pair::new();
        pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
        pair.phone.approve_preview().unwrap();
        for _ in 0..100 {
            pair.phone.poll().unwrap();
            let bytes = pair.phone.drain_ciphertext().unwrap();
            if !bytes.is_empty() {
                pair.host.ingest_ciphertext(&bytes).unwrap();
            }
            pair.host.poll().unwrap();
            if pair.host.source_lease.is_some() {
                break;
            }
            let bytes = pair.host.drain_ciphertext().unwrap();
            if !bytes.is_empty() {
                pair.phone.ingest_ciphertext(&bytes).unwrap();
            }
        }
        assert!(pair.host.source_lease.is_some());
        let _ = pair.host.drain_ciphertext().unwrap();
        let mut released = false;
        for id in 1..=13 {
            pair.hc.advance(29_000);
            let envelope = Envelope {
                version: 1,
                session: pair.phone.session.session_id().into(),
                operation: pair.phone.session.operation_id().into(),
                generation: 1,
                sequence: pair.phone.sent_sequence,
                message: Message::LeaseRequest {
                    binding: pair.phone.binding.clone().unwrap(),
                    id,
                    work: ApplyWork {
                        phase,
                        publication_bytes: 0,
                        sql_steps: id,
                        account_steps: 0,
                    },
                },
            };
            pair.phone
                .session
                .send_payload(&envelope.encode().unwrap(), pair.pc.unix_ms() / 1000)
                .unwrap();
            pair.phone.sent_sequence += 1;
            let bytes = pair.phone.drain_ciphertext().unwrap();
            pair.host.ingest_ciphertext(&bytes).unwrap();
            let result = pair.host.poll();
            if result.is_err() || pair.host.source_lease.is_none() {
                released = true;
                break;
            }
            let _ = pair.host.drain_ciphertext().unwrap();
        }
        assert!(
            released,
            "incrementing SQL counters bypassed source-side phase deadline: {phase:?}"
        );
        pair.hc.advance(LEASE_MS + 1);
        assert!(!pair.host.cleanup_pending());
        pair.a
            .create_tag("source writable after bounded SQL".into())
            .unwrap();
    }
}

#[test]
fn driver_target_sql_guard_has_independent_injected_monotonic_limit() {
    let pair = Pair::new();
    let permit = &pair.phone.permit;
    permit.active.store(true, Ordering::SeqCst);
    permit.until.store(1_000_000, Ordering::SeqCst);
    permit.sql_started();
    pair.pc.advance(SQL_MS - 1);
    permit.check().unwrap();
    pair.pc.advance(2);
    assert!(matches!(permit.check(), Err(CoreError::Cancelled)));
}

#[tokio::test]
async fn driver_same_sha_jpeg_full_version_album_provenance_and_fresh_pair_idempotence() {
    let mut pair = Pair::new();
    let input = tempfile::tempdir().unwrap();
    let source = input.path().join("source.jpeg");
    let target = input.path().join("target.jpg");
    std::fs::write(&source, b"same sha original").unwrap();
    std::fs::write(&target, b"same sha original").unwrap();
    pair.a
        .import_local_files(vec![source.to_string_lossy().into_owned()])
        .await
        .unwrap();
    pair.b
        .import_local_files(vec![target.to_string_lossy().into_owned()])
        .await
        .unwrap();
    let source_id = pair.a.list_media(GalleryQuery::default()).unwrap()[0].id;
    let target_before = pair.b.list_media(GalleryQuery::default()).unwrap()[0].clone();
    pair.b.set_note(target_before.id, "clear".into()).unwrap();
    pair.b.set_favorite(target_before.id, true).unwrap();
    pair.b.add_tag(target_before.id, "clear".into()).unwrap();
    let album = pair
        .a
        .create_album("forwarded".into(), "description".into(), false)
        .unwrap();
    pair.a.add_media_to_album(album, source_id).unwrap();
    let source_before = Snapshot::read(&pair.a.database(), "Desktop").unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Overwrite);
    assert_eq!(pair.phone.plan().unwrap().space.new_staging_bytes, 0);
    pair.complete(Direction::DesktopToPhone);
    let result = pair.b.list_media(GalleryQuery::default()).unwrap();
    assert_eq!(result[0].id, target_before.id);
    assert_eq!(result[0].storage_path, target_before.storage_path);
    assert!(result[0].note.as_deref().is_none_or(str::is_empty));
    assert!(result[0].tags.is_empty());
    assert!(!result[0].favorite);
    assert_eq!(pair.phone.progress().transferred_bytes, 0);
    let before = Snapshot::read(&pair.b.database(), "Phone").unwrap();
    assert_eq!(
        Snapshot::read(&pair.a.database(), "Desktop")
            .unwrap()
            .manifest
            .records,
        source_before.manifest.records
    );
    let (h, p, _) = confirmed(Role::Sender);
    pair.host = Driver::new(h, pair.a.database(), "Desktop", pair.hc.clone()).unwrap();
    pair.phone = Driver::new(p, pair.b.database(), "Phone", pair.pc.clone()).unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Overwrite);
    pair.complete(Direction::DesktopToPhone);
    assert_eq!(
        Snapshot::read(&pair.b.database(), "Phone")
            .unwrap()
            .manifest
            .records,
        before.manifest.records
    );
    let third = tempfile::tempdir().unwrap();
    let c = CoreApi::open(third.path()).unwrap();
    let (h, p, _) = confirmed(Role::Receiver);
    let mut h = Driver::new(
        h,
        pair.b.database(),
        "Phone",
        Arc::new(SystemClock::default()),
    )
    .unwrap();
    let mut p = Driver::new(p, c.database(), "Third", Arc::new(SystemClock::default())).unwrap();
    h.configure(Direction::DesktopToPhone, SyncMode::Merge, false)
        .unwrap();
    for _ in 0..10_000 {
        cycle(&mut h, &mut p);
        if p.state() == State::AwaitingApproval && h.state() == State::AwaitingApproval {
            break;
        }
    }
    p.approve_preview().unwrap();
    for _ in 0..100_000 {
        cycle(&mut h, &mut p);
        if h.state() == State::Completed {
            break;
        }
    }
    assert_eq!(h.state(), State::Completed);
    let result = Snapshot::read(&c.database(), "Third").unwrap();
    let original = source_before
        .manifest
        .validate()
        .unwrap()
        .albums
        .into_values()
        .find(|v| v.definition.name == "forwarded")
        .unwrap();
    let forwarded = result
        .manifest
        .validate()
        .unwrap()
        .albums
        .remove(&original.definition.uuid)
        .unwrap();
    assert_eq!(
        forwarded.definition.source_library_uuid,
        original.definition.source_library_uuid
    );
    assert_eq!(forwarded.members, original.members);
    assert_eq!(
        c.database()
            .device_sync_source_name(&original.definition.source_library_uuid)
            .unwrap()
            .unwrap()
            .display_name,
        "Desktop"
    );
}

#[test]
fn driver_cancel_and_eof_at_actual_durable_boundaries_preserve_recovery_or_commit() {
    for boundary in [
        ApplyBoundary::Prepared,
        ApplyBoundary::LibraryApplied,
        ApplyBoundary::Finalized,
    ] {
        for eof in [false, true] {
            let mut pair = Pair::new();
            pair.a.create_tag("incoming".into()).unwrap();
            pair.b.create_tag("old".into()).unwrap();
            let (notice, noticed) = std::sync::mpsc::sync_channel(1);
            let (release, released) = std::sync::mpsc::sync_channel(1);
            let released = std::sync::Mutex::new(released);
            pair.phone
                .set_apply_observer(Arc::new(move |at| {
                    if at == boundary {
                        notice.send(()).unwrap();
                        released
                            .lock()
                            .unwrap()
                            .recv_timeout(std::time::Duration::from_secs(5))
                            .unwrap();
                    }
                }))
                .unwrap();
            pair.preview(Direction::DesktopToPhone, SyncMode::Overwrite);
            pair.phone.approve_preview().unwrap();
            let mut observed = false;
            for _ in 0..10_000 {
                cycle(&mut pair.host, &mut pair.phone);
                if noticed.try_recv().is_ok() {
                    observed = true;
                    break;
                }
            }
            assert!(observed);
            if eof {
                pair.phone.disconnect();
            } else {
                pair.phone.cancel();
            }
            pair.host.disconnect();
            release.send(()).unwrap();
            pair.phone.finish_shutdown();
            let reopened = CoreApi::open(pair._roots[1].path()).unwrap();
            let pending = reopened.database().device_sync_pending_journal().unwrap();
            match boundary {
                ApplyBoundary::Prepared => {
                    assert!(pending.is_none());
                    assert_eq!(reopened.list_tags().unwrap(), vec!["old"]);
                    reopened
                        .create_tag("normal writes released".into())
                        .unwrap();
                }
                ApplyBoundary::LibraryApplied => {
                    assert!(pending.is_some());
                    assert_eq!(pair.phone.state(), State::RecoveryPending);
                    let mut recovery = super::super::recovery::RecoveryOperation::preview_pending(
                        reopened.database(),
                        pending.unwrap().operation_uuid,
                        "Phone",
                    )
                    .unwrap();
                    let mut authorization = recovery.authorize().unwrap();
                    recovery
                        .restore(Some(&mut authorization), &CancellationToken::default())
                        .unwrap();
                    assert_eq!(reopened.list_tags().unwrap(), vec!["old"]);
                }
                ApplyBoundary::Finalized => {
                    assert!(pending.is_none());
                    assert_eq!(pair.phone.state(), State::Completed);
                    assert_eq!(reopened.list_tags().unwrap(), vec!["incoming"]);
                }
            }
        }
    }
}

#[tokio::test]
async fn driver_257_mib_real_file_streams_with_bounded_buffers_and_final_sha() {
    use std::io::Write;
    let mut pair = Pair::new();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("large.mp4");
    let mut file = File::create(&path).unwrap();
    let chunk = [0x53u8; 65_536];
    let mut hash = Sha256::new();
    let length = 257 * 1024 * 1024u64;
    for _ in 0..length / chunk.len() as u64 {
        file.write_all(&chunk).unwrap();
        hash.update(chunk);
    }
    file.sync_all().unwrap();
    drop(file);
    let expected_sha = hex::encode(hash.finalize());
    let (_, root) = pair.a.database().device_sync_file_roots().unwrap();
    pair.a.database().ensure_original_root(&root).unwrap();
    let managed = root
        .join("originals")
        .join(&expected_sha[..2])
        .join(&expected_sha[2..4])
        .join(format!("{expected_sha}.mp4"));
    std::fs::create_dir_all(managed.parent().unwrap()).unwrap();
    std::fs::rename(&path, &managed).unwrap();
    let candidate = crate::models::MediaCandidate {
        remote_id: None,
        title_id: None,
        game_name: "Large fixture".into(),
        kind: crate::models::MediaKind::Video,
        content_url: None,
        thumbnail_url: None,
        expected_size: Some(length),
        captured_at: None,
        uploaded_at: None,
        expires_at: None,
        original_name: Some("large.mp4".into()),
        file_extension: Some("mp4".into()),
        source_type: crate::models::SourceType::Folder,
        source_path: None,
    };
    assert!(
        pair.a
            .database()
            .register_media(&expected_sha, length, &managed, &candidate, None)
            .unwrap()
            .1
    );
    assert_eq!(pair.a.list_media(GalleryQuery::default()).unwrap().len(), 1);
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.complete(Direction::DesktopToPhone);
    let media = pair.b.list_media(GalleryQuery::default()).unwrap();
    assert_eq!(media.len(), 1);
    assert_eq!(media[0].sha256, expected_sha);
    let mut output = File::open(&media[0].storage_path).unwrap();
    let mut actual = Sha256::new();
    let mut read = [0; 65_536];
    loop {
        let n = output.read(&mut read).unwrap();
        if n == 0 {
            break;
        }
        actual.update(&read[..n]);
    }
    assert_eq!(hex::encode(actual.finalize()), media[0].sha256);
    assert_eq!(output.metadata().unwrap().len(), length);
    for driver in [&pair.host, &pair.phone] {
        assert_eq!(driver.progress().transferred_bytes, length);
        assert_eq!(driver.progress().transfer_total_bytes, length);
        assert!(driver.progress().peak_outbox_messages <= 4);
        assert!(driver.progress().peak_plaintext_bytes <= super::super::MAX_PAYLOAD);
        assert!(driver.progress().peak_ciphertext_bytes <= 65_536);
        assert!(driver.progress().peak_receiving_files <= 1);
    }
}

#[tokio::test]
async fn driver_ordered_mailbox_uses_same_two_library_flow_and_waits_for_real_capacity_release() {
    use super::pump::MailboxPump;
    use std::net::{Shutdown, TcpListener, TcpStream};
    let mut pair = Pair::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mut probe = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (local_owner, _) = listener.accept().unwrap();
    drop(listener);
    probe
        .set_read_timeout(Some(std::time::Duration::from_millis(100)))
        .unwrap();
    pair.phone
        .set_transport_close(move || {
            let _ = local_owner.shutdown(Shutdown::Both);
        })
        .unwrap();
    pair.a.create_tag("over mailbox".into()).unwrap();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("multiple-tls-records.jpg");
    let original = vec![0x7c; 130 * 1024];
    std::fs::write(&path, &original).unwrap();
    let summary = pair
        .a
        .import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    assert_eq!(summary.imported, 1);
    let mut a = MailboxPump::default();
    let mut b = MailboxPump::default();
    pair.host
        .configure(Direction::DesktopToPhone, SyncMode::Merge, false)
        .unwrap();
    pair.host.poll().unwrap();
    let (name, bytes) = a
        .outgoing(&mut pair.host)
        .unwrap()
        .map(|(n, b)| (n.to_owned(), b.to_vec()))
        .unwrap();
    a.window_full();
    assert!(a.outgoing(&mut pair.host).unwrap().is_none());
    assert_eq!(a.buffered_bytes(), bytes.len());
    // Actual counterpart read is the release condition, not a timer retry.
    assert_eq!(b.accept(&mut pair.phone, &name, &bytes).unwrap(), name);
    a.capacity_released();
    assert_eq!(a.outgoing(&mut pair.host).unwrap().unwrap().1, bytes);
    a.written(&mut pair.host).unwrap();
    let mut approved = false;
    for _ in 0..20_000 {
        pair.host.poll().unwrap();
        if let Some((name, bytes)) = a
            .outgoing(&mut pair.host)
            .unwrap()
            .map(|(n, b)| (n.to_owned(), b.to_vec()))
        {
            b.accept(&mut pair.phone, &name, &bytes).unwrap();
            a.written(&mut pair.host).unwrap();
        }
        pair.phone.poll().unwrap();
        if !approved
            && pair.host.state() == State::AwaitingApproval
            && pair.phone.state() == State::AwaitingApproval
        {
            pair.phone.approve_preview().unwrap();
            approved = true;
        }
        if let Some((name, bytes)) = b
            .outgoing(&mut pair.phone)
            .unwrap()
            .map(|(n, b)| (n.to_owned(), b.to_vec()))
        {
            a.accept(&mut pair.host, &name, &bytes).unwrap();
            b.written(&mut pair.phone).unwrap();
        }
        if pair.host.state() == State::Completed {
            break;
        }
        if pair.phone.worker.is_some()
            || pair.phone.verification.is_some()
            || pair.phone.preparation.is_some()
        {
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
    }
    assert_eq!(
        pair.host.state(),
        State::Completed,
        "mailbox target={:?}, preparing={}, preparation_finished={}, scanned={}",
        pair.phone.state(),
        pair.phone.preparation.is_some(),
        pair.phone
            .preparation
            .as_ref()
            .is_some_and(|owner| owner.worker.is_finished()),
        pair.phone.work.observe().scanned_items,
    );
    assert!(a.outgoing(&mut pair.host).unwrap().is_none());
    assert!(b.outgoing(&mut pair.phone).unwrap().is_none());
    assert!(b.finish_success(&mut pair.phone));
    assert_eq!(probe.read(&mut [0]).unwrap(), 0);
    assert_eq!(pair.host.session.state(), SessionState::Terminal);
    assert_eq!(pair.phone.session.state(), SessionState::Terminal);
    assert_eq!(pair.b.list_tags().unwrap(), vec!["over mailbox"]);
    let media = pair.b.list_media(GalleryQuery::default()).unwrap();
    assert_eq!(media.len(), 1);
    assert_eq!(std::fs::read(&media[0].storage_path).unwrap(), original);
    assert_eq!(pair.phone.progress.transferred_bytes, 130 * 1024);
    assert!(pair.host.progress.peak_ciphertext_bytes > 16_384);
    assert!(a.buffered_bytes() <= super::super::native_io::MAX_BLOCK);
    assert!(b.buffered_bytes() <= super::super::native_io::MAX_BLOCK);
    assert!(
        a.accept(&mut pair.host, &name, &bytes).is_err(),
        "replay must not produce an ACK"
    );
    let mut fresh = MailboxPump::default();
    let (_, block) = super::super::mailbox::OrderedCiphertext::default()
        .encode(b"not TLS")
        .unwrap();
    let mut pair = Pair::new();
    assert!(
        fresh
            .accept(&mut pair.phone, "0000000000000000.block", &block)
            .is_err(),
        "invalid TLS must not produce an ACK"
    );
}

#[test]
fn driver_real_tcp_loopback_same_protocol_applies_and_closes_on_success() {
    use super::pump::TcpDriver;
    use crate::device_sync::{Invitation, Qr, Transport};
    use std::net::{TcpListener, TcpStream};
    for direction in [Direction::DesktopToPhone, Direction::PhoneToDesktop] {
        let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let a = CoreApi::open(roots[0].path()).unwrap();
        let b = CoreApi::open(roots[1].path()).unwrap();
        let (source, target) = if direction == Direction::DesktopToPhone {
            (&a, &b)
        } else {
            (&b, &a)
        };
        source.create_tag("source catalog".into()).unwrap();
        let time = chrono::Utc::now().timestamp();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let mut invitation = Invitation::create(Transport::Tcp(address), time).unwrap();
        let qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), time).unwrap();
        let socket = TcpStream::connect(address).unwrap();
        let (server, _) = listener.accept().unwrap();
        let mut host_probe = server.try_clone().unwrap();
        let mut phone_probe = socket.try_clone().unwrap();
        drop(listener);
        let host = Driver::new(
            invitation.accept(Role::Sender, "Desktop", time).unwrap(),
            a.database(),
            "Desktop",
            Arc::new(SystemClock::default()),
        )
        .unwrap();
        let phone = Driver::new(
            Session::client(qr, Role::Receiver, "Phone", time).unwrap(),
            b.database(),
            "Phone",
            Arc::new(SystemClock::default()),
        )
        .unwrap();
        let mut host = TcpDriver::from_stream(server, host).unwrap();
        let mut phone = TcpDriver::from_stream(socket, phone).unwrap();
        assert!(host
            .driver_mut()
            .configure(direction, SyncMode::Overwrite, false)
            .is_err());
        for _ in 0..10000 {
            phone.poll().unwrap();
            host.poll().unwrap();
            if host.driver().session.state() == SessionState::AwaitingConfirmation
                && phone.driver().session.state() == SessionState::AwaitingConfirmation
            {
                break;
            }
            std::thread::yield_now();
        }
        host.driver_mut().confirm_pairing().unwrap();
        phone.driver_mut().confirm_pairing().unwrap();
        for _ in 0..10000 {
            phone.poll().unwrap();
            host.poll().unwrap();
            if host.driver().session.state() == SessionState::Confirmed
                && phone.driver().session.state() == SessionState::Confirmed
            {
                break;
            }
        }
        host.driver_mut()
            .configure(direction, SyncMode::Overwrite, false)
            .unwrap();
        let mut approved = false;
        for _ in 0..20000 {
            phone.poll().unwrap();
            host.poll().unwrap();
            if !approved
                && host.driver().state() == State::AwaitingApproval
                && phone.driver().state() == State::AwaitingApproval
            {
                if direction == Direction::PhoneToDesktop {
                    host.driver_mut().approve_preview().unwrap();
                } else {
                    phone.driver_mut().approve_preview().unwrap();
                }
                approved = true;
            }
            if host.driver().state() == State::Completed
                && phone.driver().state() == State::Completed
            {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert_eq!(host.driver().state(), State::Completed);
        assert_eq!(phone.driver().state(), State::Completed);
        assert_eq!(target.list_tags().unwrap(), vec!["source catalog"]);
        for _ in 0..4 {
            host.poll().unwrap();
            phone.poll().unwrap();
        }
        for probe in [&mut host_probe, &mut phone_probe] {
            probe.set_nonblocking(false).unwrap();
            probe
                .set_read_timeout(Some(std::time::Duration::from_millis(100)))
                .unwrap();
            // Completed objects stay alive; success itself must close actual I/O.
            assert_eq!(probe.read(&mut [0]).unwrap(), 0);
        }
        assert_eq!(host.driver().session.state(), SessionState::Terminal);
        assert_eq!(phone.driver().session.state(), SessionState::Terminal);
        assert_eq!(host.driver().state(), State::Completed);
        assert_eq!(phone.driver().state(), State::Completed);
        assert!(
            host.driver().metrics_reported && phone.driver().metrics_reported,
            "both live completed TCP endpoints must publish measurements before the UI retires them"
        );
    }
}

#[test]
fn driver_direct_cancel_closes_owned_external_tcp_io_without_another_poll() {
    use super::pump::TcpDriver;
    use crate::device_sync::{Invitation, Transport};
    use std::net::{TcpListener, TcpStream};
    for failure in 0..4 {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let time = chrono::Utc::now().timestamp();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let mut invitation = Invitation::create(Transport::Tcp(address), time).unwrap();
        let mut peer = TcpStream::connect(address).unwrap();
        peer.set_read_timeout(Some(std::time::Duration::from_millis(100)))
            .unwrap();
        let (server, _) = listener.accept().unwrap();
        drop(listener);
        let driver = Driver::new(
            invitation.accept(Role::Sender, "Desktop", time).unwrap(),
            api.database(),
            "Desktop",
            Arc::new(SystemClock::default()),
        )
        .unwrap();
        let mut transport = TcpDriver::from_stream(server, driver).unwrap();
        match failure {
            0 => transport.driver_mut().cancel(),
            1 => transport.driver_mut().disconnect(),
            2 => {
                assert!(transport
                    .driver_mut()
                    .ingest_ciphertext(b"invalid TLS")
                    .is_err());
            }
            _ => {
                drop(transport);
                assert_eq!(peer.read(&mut [0]).unwrap(), 0);
                continue;
            }
        }
        let mut byte = [0];
        assert_eq!(peer.read(&mut byte).unwrap(), 0);
        // Late registration cannot keep a fresh transport alive after termination.
        let late_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut late_peer = TcpStream::connect(late_listener.local_addr().unwrap()).unwrap();
        late_peer
            .set_read_timeout(Some(std::time::Duration::from_millis(100)))
            .unwrap();
        let (late, _) = late_listener.accept().unwrap();
        assert!(transport
            .driver_mut()
            .set_transport_close(move || {
                let _ = late.shutdown(std::net::Shutdown::Both);
            })
            .is_err());
        assert_eq!(late_peer.read(&mut [0]).unwrap(), 0);
    }
}

#[test]
fn driver_unissued_cancel_releases_immediately_and_dispose_preserves_inflight_permission() {
    let mut pair = Pair::new();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    assert_eq!(pair.host.issued_until, 0);
    pair.host.cancel();
    assert!(!pair.host.cleanup_pending());
    pair.a.create_tag("immediate".into()).unwrap();

    let mut pair = Pair::new();
    pair.a.create_tag("authorized incoming".into()).unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    for _ in 0..100 {
        pair.phone.poll().unwrap();
        let bytes = pair.phone.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.host.ingest_ciphertext(&bytes).unwrap();
        }
        pair.host.poll().unwrap();
        if pair.host.source_lease.is_some() {
            break;
        }
        let bytes = pair.host.drain_ciphertext().unwrap();
        if !bytes.is_empty() {
            pair.phone.ingest_ciphertext(&bytes).unwrap();
        }
    }
    let in_flight = pair.host.drain_ciphertext().unwrap();
    pair.host.cancel();
    let cleanup = pair.host.cleanup.as_ref().unwrap().clone();
    // Drop the cancelled source object while retaining only the bounded cleanup.
    let (replacement, _, _) = confirmed(Role::Sender);
    let replacement =
        Driver::new(replacement, pair.a.database(), "Inactive", pair.hc.clone()).unwrap();
    let disposed = std::mem::replace(&mut pair.host, replacement);
    drop(disposed);
    assert!(matches!(
        pair.a.create_tag("must remain busy".into()),
        Err(CoreError::LibraryBusy)
    ));
    pair.phone.ingest_ciphertext(&in_flight).unwrap();
    for _ in 0..10_000 {
        pair.phone.poll().unwrap();
        let _ = pair.phone.drain_ciphertext().unwrap();
        if pair.phone.state() == State::Completed {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    assert_eq!(pair.phone.state(), State::Completed);
    assert_eq!(pair.b.list_tags().unwrap(), vec!["authorized incoming"]);
    assert!(cleanup.poll());
    pair.hc.advance(LEASE_MS + 1);
    assert!(!cleanup.poll());
    pair.a.create_tag("released after disposal".into()).unwrap();
}

#[tokio::test]
async fn driver_valid_file_progress_extends_data_deadline_without_renewing_duplicate_acks() {
    let mut pair = Pair::new();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("progress.jpg");
    std::fs::write(&path, vec![0x45; 2 * 1024 * 1024]).unwrap();
    let summary = pair
        .a
        .import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    assert_eq!(summary.imported, 1);
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    let mut previous = 0;
    for _ in 0..50_000 {
        cycle(&mut pair.host, &mut pair.phone);
        let transferred = pair.phone.progress().transferred_bytes;
        if transferred > previous {
            pair.hc.advance(20_000);
            pair.pc.advance(20_000);
            previous = transferred;
        }
        if pair.host.state() == State::Completed {
            break;
        }
    }
    assert!(pair.hc.monotonic_ms() > DATA_MS);
    assert_eq!(pair.host.state(), State::Completed);
    assert_eq!(pair.phone.progress().transferred_bytes, 2 * 1024 * 1024);
}

#[tokio::test]
async fn driver_target_changes_wrong_sha_and_transport_cancel_do_not_replace_old_library() {
    for failure in 0..3 {
        let mut pair = Pair::new();
        let input = tempfile::tempdir().unwrap();
        let path = input.path().join("source.jpg");
        std::fs::write(&path, vec![3; 128 * 1024]).unwrap();
        let summary = pair
            .a
            .import_local_files(vec![path.to_string_lossy().into_owned()])
            .await
            .unwrap();
        assert_eq!(summary.imported, 1);
        pair.b.create_tag("old target".into()).unwrap();
        pair.preview(Direction::DesktopToPhone, SyncMode::Overwrite);
        if failure == 0 {
            pair.b.create_tag("local after preview".into()).unwrap();
        }
        if failure == 1 {
            let source = pair.a.list_media(GalleryQuery::default()).unwrap();
            std::fs::write(&source[0].storage_path, vec![4; 128 * 1024]).unwrap();
        }
        pair.phone.approve_preview().unwrap();
        let mut stopped = false;
        for _ in 0..10_000 {
            if pair.host.poll().is_err() {
                stopped = true;
                break;
            }
            let bytes = pair.host.drain_ciphertext().unwrap();
            if !bytes.is_empty() && pair.phone.ingest_ciphertext(&bytes).is_err() {
                stopped = true;
                break;
            }
            if pair.phone.poll().is_err() {
                stopped = true;
                break;
            }
            if failure == 2 && pair.phone.progress.transferred_bytes > 0 {
                pair.phone.disconnect();
                stopped = true;
                break;
            }
            let bytes = pair.phone.drain_ciphertext().unwrap();
            if !bytes.is_empty() && pair.host.ingest_ciphertext(&bytes).is_err() {
                stopped = true;
                break;
            }
            if pair.phone.worker.is_some() || pair.phone.verification.is_some() {
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
        }
        assert!(stopped);
        pair.phone.finish_shutdown();
        assert!(pair
            .b
            .list_media(GalleryQuery::default())
            .unwrap()
            .is_empty());
        assert!(pair.b.list_tags().unwrap().contains(&"old target".into()));
        assert!(pair
            .b
            .database()
            .device_sync_pending_journal()
            .unwrap()
            .is_none());
    }
}

#[tokio::test]
async fn driver_fresh_tls_reconfirms_preview_and_requests_only_missing_verified_objects() {
    let mut pair = Pair::new();
    let input = tempfile::tempdir().unwrap();
    for (name, bytes) in [("one.jpg", vec![11; 8192]), ("two.jpg", vec![22; 8192])] {
        let path = input.path().join(name);
        std::fs::write(&path, bytes).unwrap();
        pair.a
            .import_local_files(vec![path.to_string_lossy().into_owned()])
            .await
            .unwrap();
    }
    let target_generation = pair.b.database().device_sync_header().unwrap().generation;
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    let old_session = pair.phone.session.session_id().to_owned();
    let old_operation = pair.phone.receive.as_ref().unwrap().operation_id();
    pair.phone.approve_preview().unwrap();
    let mut old_authorization = pair.phone.authorization.take().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    while pair.phone.progress.transferred_bytes == 0 {
        cycle(&mut pair.host, &mut pair.phone);
        assert!(std::time::Instant::now() < deadline);
    }
    assert!(pair.phone.work.validation_metrics().checksum_read_bytes == 0);
    pair.host.cancel();
    pair.phone.cancel();
    pair.host.finish_shutdown();
    pair.phone.finish_shutdown();
    assert!(pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .is_empty());
    let (host, phone, _) = confirmed(Role::Receiver);
    pair.host = Driver::new(host, pair.a.database(), "Desktop", pair.hc.clone()).unwrap();
    pair.phone = Driver::new(phone, pair.b.database(), "Phone", pair.pc.clone()).unwrap();
    assert_ne!(pair.phone.session.session_id(), old_session);
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    assert_ne!(
        pair.phone.receive.as_ref().unwrap().operation_id(),
        old_operation
    );
    assert!(pair.phone.authorization.is_none());
    assert!(matches!(
        pair.phone.receive.as_mut().unwrap().apply(
            Some(&mut old_authorization),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        ),
        Err(super::super::receiver::ReceiverError::AuthorizationMismatch)
    ));
    assert!(matches!(
        pair.phone.receive.as_mut().unwrap().apply(
            None,
            None,
            &CancellationToken::default(),
            &mut |_| {},
        ),
        Err(super::super::receiver::ReceiverError::AuthorizationRequired)
    ));
    assert_eq!(pair.phone.needed.len(), 2);
    assert_eq!(pair.phone.progress.transfer_total_bytes, 16384);
    assert_eq!(pair.phone.plan().unwrap().space.new_staging_bytes, 16384);
    assert_eq!(pair.phone.progress.transferred_bytes, 0);
    assert_eq!(
        pair.b.database().device_sync_header().unwrap().generation,
        target_generation
    );
    assert!(pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .is_empty());
    pair.complete(Direction::DesktopToPhone);
    assert_eq!(pair.host.served.len(), 2);
    assert_eq!(pair.host.progress.transferred_bytes, 16384);
    assert_eq!(pair.phone.progress.transferred_bytes, 16384);
    assert_eq!(pair.b.list_media(GalleryQuery::default()).unwrap().len(), 2);
    for source in pair.a.list_media(GalleryQuery::default()).unwrap() {
        let target = pair
            .b
            .list_media(GalleryQuery::default())
            .unwrap()
            .into_iter()
            .find(|media| media.sha256 == source.sha256)
            .unwrap();
        assert_eq!(
            std::fs::read(target.storage_path).unwrap(),
            std::fs::read(source.storage_path).unwrap()
        );
    }
}

#[tokio::test]
async fn media_sender_keeps_a_bounded_window_without_waiting_for_each_usb_roundtrip() {
    let mut pair = Pair::new();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("window.jpg");
    std::fs::write(&path, vec![91; 1024 * 1024]).unwrap();
    pair.a
        .import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    for _ in 0..1000 {
        cycle(&mut pair.host, &mut pair.phone);
        if pair.host.file.as_ref().is_some_and(|file| file.awaiting) {
            break;
        }
    }
    // Stop delivering peer ACKs, while draining real encrypted output as a
    // successful mailbox write would. One already-ingested ACK may still drain.
    for _ in 0..20 {
        pair.host.poll().unwrap();
        let bytes = pair.host.drain_ciphertext().unwrap();
        pair.host.ciphertext_written(bytes.len()).unwrap();
    }
    let file = pair.host.file.as_ref().unwrap();
    assert!(
        file.offset >= (wire::RAW_CHUNK * 4) as u64,
        "sender remained stop-and-wait despite available bounded capacity"
    );
    assert!(file.offset <= 2 * 1024 * 1024);
    assert!(pair.host.progress.transferred_bytes <= wire::RAW_CHUNK as u64);
    let sha = file.sha.clone();
    let last = file.offset;
    assert!(
        pair.host
            .handle(Message::ChunkAccepted {
                sha256: sha,
                offset: last
            })
            .is_ok(),
        "an authenticated cumulative boundary must release all its earlier chunks"
    );
    assert!(pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn driver_cached_subset_keeps_inflight_duplicate_and_out_of_plan_requests_rejected() {
    let mut pair = Pair::new();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("fixture.jpg");
    std::fs::write(&path, vec![31; 128 * 1024]).unwrap();
    pair.a
        .import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Merge);
    pair.phone.approve_preview().unwrap();
    for _ in 0..1000 {
        cycle(&mut pair.host, &mut pair.phone);
        if pair.host.file.as_ref().is_some_and(|file| file.awaiting) {
            break;
        }
    }
    assert!(pair.host.file.as_ref().is_some_and(|file| file.awaiting));
    assert_eq!(
        pair.host.read_view().progress.transfer_total_bytes,
        Some(128 * 1024)
    );
    assert_eq!(
        pair.phone.read_view().progress.transfer_total_bytes,
        Some(128 * 1024)
    );
    assert!(matches!(
        pair.host.handle(Message::FilesComplete {}),
        Err(DriverError::Protocol)
    ));
    assert!(pair.host.step == Step::Sending);
    let sha = pair.host.file.as_ref().unwrap().sha.clone();
    assert!(matches!(
        pair.host.handle(Message::FileRequest {
            sha256: sha.clone()
        }),
        Err(DriverError::Protocol)
    ));
    let file = pair.host.file.take().unwrap();
    // The served set keeps rejecting duplicate requests even after the window is gone.
    assert!(matches!(
        pair.host.handle(Message::FileRequest { sha256: sha }),
        Err(DriverError::Protocol)
    ));
    assert!(matches!(
        pair.host.handle(Message::FileRequest {
            sha256: "0".repeat(64)
        }),
        Err(DriverError::Protocol)
    ));
    pair.host.file = Some(file);
    assert!(pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn driver_files_complete_without_local_bytes_cannot_apply_or_change_target() {
    let mut pair = Pair::new();
    let input = tempfile::tempdir().unwrap();
    let path = input.path().join("missing.jpg");
    std::fs::write(&path, b"missing original").unwrap();
    pair.a
        .import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    pair.b.create_tag("preserved target".into()).unwrap();
    let before = Snapshot::read(&pair.b.database(), "Phone").unwrap();
    pair.preview(Direction::DesktopToPhone, SyncMode::Overwrite);
    assert_eq!(pair.phone.needed.len(), 1);
    // Simulate an erroneous receiver scheduler emitting FilesComplete early:
    // neither a source frame nor a skipped network request supplies local bytes.
    pair.phone.needed.clear();
    pair.phone.approve_preview().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    let mut failed = false;
    while std::time::Instant::now() < deadline {
        let result = (|| {
            pair.host.poll()?;
            let bytes = pair.host.drain_ciphertext()?;
            if !bytes.is_empty() {
                pair.phone.ingest_ciphertext(&bytes)?;
            }
            pair.phone.poll()?;
            let bytes = pair.phone.drain_ciphertext()?;
            if !bytes.is_empty() {
                pair.host.ingest_ciphertext(&bytes)?;
            }
            Ok::<_, DriverError>(())
        })();
        if result.is_err() || pair.phone.state == State::Failed {
            failed = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    assert!(failed);
    pair.host.cancel();
    pair.phone.finish_shutdown();
    assert_eq!(pair.phone.progress.transferred_bytes, 0);
    assert_eq!(
        Snapshot::read(&pair.b.database(), "Phone")
            .unwrap()
            .manifest
            .records,
        before.manifest.records
    );
    assert_eq!(
        pair.b.database().device_sync_header().unwrap().generation,
        before.manifest.header.generation
    );
    assert!(pair
        .b
        .list_media(GalleryQuery::default())
        .unwrap()
        .is_empty());
    assert!(pair
        .b
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
}
