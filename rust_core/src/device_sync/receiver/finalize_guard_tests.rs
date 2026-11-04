use super::*;
use crate::api::CoreApi;
use crate::device_sync::clock::Clock;
use crate::device_sync::driver::{Direction, Driver, State};
use crate::device_sync::planner::SyncMode;
use crate::device_sync::{Invitation, Qr, Role, Session, Transport};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

struct TestClock {
    start: i64,
    elapsed: AtomicU64,
}
impl Clock for TestClock {
    fn monotonic_ms(&self) -> u64 {
        self.elapsed.load(Ordering::SeqCst)
    }
    fn unix_ms(&self) -> i64 {
        self.start + self.monotonic_ms() as i64
    }
}

fn cycle(a: &mut Driver, b: &mut Driver) {
    a.poll().unwrap();
    let bytes = a.drain_ciphertext().unwrap();
    if !bytes.is_empty() {
        for chunk in bytes.chunks(crate::device_sync::MAX_CIPHERTEXT) {
            b.ingest_ciphertext(chunk).unwrap();
        }
        a.ciphertext_written(bytes.len()).unwrap();
    }
    b.poll().unwrap();
    let bytes = b.drain_ciphertext().unwrap();
    if !bytes.is_empty() {
        for chunk in bytes.chunks(crate::device_sync::MAX_CIPHERTEXT) {
            a.ingest_ciphertext(chunk).unwrap();
        }
        b.ciphertext_written(bytes.len()).unwrap();
    }
    std::thread::yield_now();
}

fn finalize_revoked_at_actual_update(expire: bool) {
    let roots = [
        tempfile::tempdir().unwrap().keep(),
        tempfile::tempdir().unwrap().keep(),
    ];
    let source = CoreApi::open(&roots[0]).unwrap();
    let target = CoreApi::open(&roots[1]).unwrap();
    source.create_tag("incoming".into()).unwrap();
    target.create_tag("old".into()).unwrap();
    let clock = Arc::new(TestClock {
        start: chrono::Utc::now().timestamp_millis(),
        elapsed: AtomicU64::new(0),
    });
    let now = clock.unix_ms() / 1000;
    let mut invitation = Invitation::create(Transport::Usb, now).unwrap();
    let qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), now).unwrap();
    let mut a = invitation.accept(Role::Sender, "Source", now).unwrap();
    let mut b = Session::client(qr, Role::Receiver, "Target", now).unwrap();
    for _ in 0..12 {
        let bytes = a.drain_ciphertext(now).unwrap();
        if !bytes.is_empty() {
            b.ingest_ciphertext(&bytes, now).unwrap();
        }
        let bytes = b.drain_ciphertext(now).unwrap();
        if !bytes.is_empty() {
            a.ingest_ciphertext(&bytes, now).unwrap();
        }
    }
    a.confirm(now).unwrap();
    b.confirm(now).unwrap();
    for _ in 0..12 {
        let bytes = a.drain_ciphertext(now).unwrap();
        if !bytes.is_empty() {
            b.ingest_ciphertext(&bytes, now).unwrap();
        }
        let bytes = b.drain_ciphertext(now).unwrap();
        if !bytes.is_empty() {
            a.ingest_ciphertext(&bytes, now).unwrap();
        }
    }
    let mut a = Driver::new(a, source.database(), "Source", clock.clone()).unwrap();
    let mut b = Driver::new(b, target.database(), "Target", clock.clone()).unwrap();
    a.authorize_accounts_export(br#"{"version":1,"accounts":[]}"#, &"a".repeat(64))
        .unwrap();
    b.authorize_accounts_receive(&"b".repeat(64)).unwrap();
    a.configure(Direction::DesktopToPhone, SyncMode::Overwrite, true)
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    while b.state() != State::AwaitingApproval {
        cycle(&mut a, &mut b);
        assert!(std::time::Instant::now() < deadline);
    }
    let external = uuid::Uuid::new_v4();
    let binding = b.preview_binding().unwrap().to_owned();
    b.approve_accounts_preview(&binding, &"b".repeat(64), external)
        .unwrap();
    while b.state() != State::AwaitingExternal {
        cycle(&mut a, &mut b);
        if b.state() == State::AwaitingTargetAccountFinal {
            b.approve_accounts_target_final(&"b".repeat(64)).unwrap();
        }
        if a.state() == State::AwaitingAccountFinal {
            a.approve_accounts_final(&"a".repeat(64)).unwrap();
        }
        assert!(std::time::Instant::now() < deadline);
    }
    let operation = b.receipt().unwrap().operation_uuid;
    let source_owner = Arc::new(Mutex::new(a));
    let hook_source = source_owner.clone();
    let hook_clock = clock.clone();
    let cancel = b.cancellation();
    let reached = Arc::new(AtomicBool::new(false));
    let hook_reached = reached.clone();
    let database = target.database();
    database
        .connection
        .lock()
        .unwrap()
        .update_hook(Some(move |_, _: &str, table: &str, _| {
            if table == "device_sync_apply_journal" {
                hook_reached.store(true, Ordering::SeqCst);
                if expire {
                    hook_clock.elapsed.fetch_add(30_001, Ordering::SeqCst);
                    hook_source.lock().unwrap().poll().unwrap();
                } else {
                    cancel.cancel();
                }
            }
        }));
    let result = b.finalize_accounts(external);
    database
        .connection
        .lock()
        .unwrap()
        .update_hook(None::<fn(rusqlite::hooks::Action, &str, &str, i64)>);
    assert!(
        reached.load(Ordering::SeqCst),
        "must cross the last entry check and reach real UPDATE"
    );
    assert!(
        result.is_err(),
        "revoked finalization committed at the actual durable boundary"
    );
    assert!(database.device_sync_recovery_pending());
    assert_eq!(
        database
            .device_sync_journal(operation)
            .unwrap()
            .unwrap()
            .stage,
        crate::device_sync::recovery::JournalStage::LibraryApplied
    );
    assert_ne!(b.state(), State::Completed, "no CommitAck may be queued");
    if expire {
        assert_eq!(
            source_owner.lock().unwrap().state(),
            State::CompletedUnconfirmed
        );
        source.create_tag("source already unlocked".into()).unwrap();
    }
    let mut recovery = crate::device_sync::recovery::RecoveryOperation::preview_pending(
        database.clone(),
        operation,
        "Target",
    )
    .unwrap();
    let mut auth = recovery.authorize().unwrap();
    recovery
        .restore(Some(&mut auth), &crate::sync::CancellationToken::default())
        .unwrap();
    assert_eq!(target.list_tags().unwrap(), ["old"]);
    b.cancel();
    source_owner.lock().unwrap().cancel();
    clock.elapsed.fetch_add(30_001, Ordering::SeqCst);
    source_owner.lock().unwrap().poll().unwrap();
    println!(
        "Synthetic finalize fault roots retained: {:?}; expire={expire}",
        roots
    );
}

#[test]
fn account_finalize_cancel_at_actual_update_keeps_pending_and_has_no_ack() {
    finalize_revoked_at_actual_update(false);
}

#[test]
fn account_finalize_expired_source_at_actual_update_keeps_pending_and_has_no_ack() {
    finalize_revoked_at_actual_update(true);
}

#[test]
fn account_restore_finalize_cancel_at_actual_update_keeps_pending_and_allows_offline_compensation()
{
    use crate::device_sync::receiver::{ReceiveOperation, Snapshot};
    use crate::device_sync::recovery::RecoveryOperation;
    use crate::sync::CancellationToken;
    let roots = [
        tempfile::tempdir().unwrap().keep(),
        tempfile::tempdir().unwrap().keep(),
    ];
    let source = CoreApi::open(&roots[0]).unwrap();
    let target = CoreApi::open(&roots[1]).unwrap();
    source.create_tag("incoming".into()).unwrap();
    target.create_tag("old".into()).unwrap();
    let database = target.database();
    let mut receive = ReceiveOperation::prepare(
        database.clone(),
        Snapshot::read(&source.database(), "Source").unwrap(),
        "Target",
        SyncMode::Overwrite,
    )
    .unwrap();
    let mut authorization = receive.authorize().unwrap();
    let original_external = uuid::Uuid::new_v4();
    let received = receive
        .apply(
            Some(&mut authorization),
            Some(original_external),
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    drop(receive);
    let mut finalized =
        RecoveryOperation::preview_pending(database.clone(), received.operation_uuid, "Target")
            .unwrap();
    let mut authorization = finalized.authorize().unwrap();
    finalized
        .finalize(Some(&mut authorization), Some(original_external))
        .unwrap();
    drop(finalized);
    let mut restore =
        RecoveryOperation::preview_backup(database.clone(), received.backup_uuid, "Target")
            .unwrap();
    let mut authorization = restore.authorize().unwrap();
    let external = uuid::Uuid::new_v4();
    let restored = restore
        .restore_with_external(
            Some(&mut authorization),
            Some(external),
            &CancellationToken::default(),
        )
        .unwrap();
    let mut finalization =
        RecoveryOperation::preview_pending(database.clone(), restored.operation_uuid, "Target")
            .unwrap();
    let mut authorization = finalization.authorize().unwrap();
    let cancel = CancellationToken::default();
    let hook_cancel = cancel.clone();
    database
        .connection
        .lock()
        .unwrap()
        .update_hook(Some(move |_, _: &str, table: &str, _| {
            if table == "device_sync_apply_journal" {
                hook_cancel.cancel();
            }
        }));
    let result =
        finalization.finalize_guarded(Some(&mut authorization), Some(external), &cancel, None);
    database
        .connection
        .lock()
        .unwrap()
        .update_hook(None::<fn(rusqlite::hooks::Action, &str, &str, i64)>);
    assert!(result.is_err());
    assert!(cancel.check().is_err());
    assert!(database.device_sync_recovery_pending());
    assert_eq!(target.list_tags().unwrap(), ["old"]);
    let mut recovery =
        RecoveryOperation::preview_pending(database.clone(), restored.operation_uuid, "Target")
            .unwrap();
    let mut authorization = recovery.authorize().unwrap();
    recovery
        .restore(Some(&mut authorization), &CancellationToken::default())
        .unwrap();
    assert_eq!(target.list_tags().unwrap(), ["incoming"]);
    target
        .create_tag("normal after cancelled commit hook removed".into())
        .unwrap();
    println!(
        "Synthetic account restore finalize fault roots retained: {:?}",
        roots
    );
}
