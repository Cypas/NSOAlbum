use super::*;
use crate::device_sync::clock::SystemClock;

fn identity() -> Identity {
    Identity {
        binding: "a".repeat(64),
        operation: Uuid::new_v4(),
        external: None,
    }
}

fn publications(length: u64) -> BTreeMap<String, u64> {
    if length == 0 {
        BTreeMap::new()
    } else {
        BTreeMap::from([("sha".into(), length)])
    }
}

#[test]
fn local_authority_cancel_install_are_one_lifecycle_decision() {
    for cancel_first in [false, true] {
        let control = LifecycleControl::new(CancellationToken::default());
        let id = identity();
        control.ready(id.clone()).unwrap();
        if cancel_first {
            control.cancel();
        }
        let result = control.install(
            &id,
            "receiver".into(),
            publications(0),
            Arc::new(SystemClock::default()),
        );
        if cancel_first {
            assert!(result.is_err());
            assert!(!control.installed());
        } else {
            let authority = result.unwrap();
            assert!(authority.matches(&id, "receiver"));
            assert!(!authority.matches(&id, "other"));
            control.cancel();
            assert!(authority.check().is_err());
            assert!(control
                .install(
                    &id,
                    "receiver".into(),
                    publications(0),
                    Arc::new(SystemClock::default())
                )
                .is_err());
        }
    }
}

#[test]
fn local_authority_full_cache_budget_is_not_zero_download_bytes() {
    let control = LifecycleControl::new(CancellationToken::default());
    let id = identity();
    control.ready(id.clone()).unwrap();
    let authority = control
        .install(
            &id,
            "receiver".into(),
            publications(3),
            Arc::new(SystemClock::default()),
        )
        .unwrap();
    authority.publication_started("sha", 3).unwrap();
    for phase in [Phase::Copying, Phase::Verifying, Phase::Published] {
        authority.publication_progress(&Progress {
            phase,
            completed_bytes: 3,
            total_bytes: Some(3),
        });
    }
    authority.check().unwrap();
    authority.publication_progress(&Progress {
        phase: Phase::Published,
        completed_bytes: 2,
        total_bytes: Some(3),
    });
    assert!(authority.check().is_err());
}

#[test]
fn local_authority_issue_failure_does_not_forge_or_repeat_grant() {
    let control = LifecycleControl::new(CancellationToken::default());
    let id = identity();
    control.source_checking(id.clone()).unwrap();
    assert!(control.issue(&id, || Err(CoreError::Cancelled)).is_err());
    assert!(!control.issued());
    control.issue(&id, || Ok(0)).unwrap();
    assert!(control.issued());
    assert!(control.issue(&id, || Ok(0)).is_err());
}

#[test]
fn local_authority_rejects_unknown_publication() {
    let control = LifecycleControl::new(CancellationToken::default());
    let id = identity();
    control.ready(id.clone()).unwrap();
    let authority = control
        .install(
            &id,
            "receiver".into(),
            publications(3),
            Arc::new(SystemClock::default()),
        )
        .unwrap();
    assert!(authority
        .publication_started("not-in-approved-plan", 3)
        .is_err());
}

#[test]
fn local_authority_rejects_sixty_fifth_account_step() {
    let control = LifecycleControl::new(CancellationToken::default());
    let id = identity();
    control.ready(id.clone()).unwrap();
    let authority = control
        .install(
            &id,
            "receiver".into(),
            publications(0),
            Arc::new(SystemClock::default()),
        )
        .unwrap();
    authority.sql_started();
    for _ in 0..64 {
        authority.account_step().unwrap();
    }
    assert!(authority.account_step().is_err());
    assert!(
        authority.check().is_err(),
        "a rejected step cannot subsequently finalize"
    );
}

#[test]
fn local_authority_rejects_backward_publication_phase() {
    let control = LifecycleControl::new(CancellationToken::default());
    let id = identity();
    control.ready(id.clone()).unwrap();
    let authority = control
        .install(
            &id,
            "receiver".into(),
            publications(3),
            Arc::new(SystemClock::default()),
        )
        .unwrap();
    authority.publication_started("sha", 3).unwrap();
    for (phase, completed_bytes) in [
        (Phase::Copying, 3),
        (Phase::Verifying, 3),
        (Phase::Copying, 0),
    ] {
        authority.publication_progress(&Progress {
            phase,
            completed_bytes,
            total_bytes: Some(3),
        });
    }
    assert!(authority.check().is_err());
}

#[test]
fn local_authority_actual_contended_cancel_and_install_cannot_revive() {
    for _ in 0..16 {
        let control = LifecycleControl::new(CancellationToken::default());
        let id = identity();
        control.ready(id.clone()).unwrap();
        let held = control.life.lock().unwrap();
        let (entered, waiting) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            let tx = entered.clone();
            let reference = &control;
            let identity = &id;
            let install = scope.spawn(move || {
                tx.send(()).unwrap();
                reference.install(
                    identity,
                    "receiver".into(),
                    publications(0),
                    Arc::new(SystemClock::default()),
                )
            });
            let cancel = scope.spawn(|| {
                entered.send(()).unwrap();
                control.cancel();
            });
            waiting.recv().unwrap();
            waiting.recv().unwrap();
            drop(held);
            let result = install.join().unwrap();
            cancel.join().unwrap();
            if let Ok(authority) = result {
                assert!(authority.check().is_err());
            }
            assert!(control
                .install(
                    &id,
                    "receiver".into(),
                    publications(0),
                    Arc::new(SystemClock::default())
                )
                .is_err());
        });
    }
}

struct ClockValue(std::sync::atomic::AtomicU64);
impl Clock for ClockValue {
    fn monotonic_ms(&self) -> u64 {
        self.0.load(std::sync::atomic::Ordering::SeqCst)
    }
    fn unix_ms(&self) -> i64 {
        1_700_000_000_000
    }
}

#[test]
fn local_authority_sql_deadline_and_real_work_limits_cannot_be_reset() {
    let control = LifecycleControl::new(CancellationToken::default());
    let id = identity();
    control.ready(id.clone()).unwrap();
    let clock = Arc::new(ClockValue(std::sync::atomic::AtomicU64::new(0)));
    let authority = control
        .install(&id, "receiver".into(), publications(0), clock.clone())
        .unwrap();
    authority.sql_started();
    clock.0.store(299_999, std::sync::atomic::Ordering::SeqCst);
    authority.sql_started();
    authority.check().unwrap();
    clock.0.store(300_000, std::sync::atomic::Ordering::SeqCst);
    assert!(authority.check().is_err());

    let control = LifecycleControl::new(CancellationToken::default());
    control.ready(id.clone()).unwrap();
    let authority = control
        .install(
            &id,
            "receiver".into(),
            publications(0),
            Arc::new(SystemClock::default()),
        )
        .unwrap();
    authority.sql_started();
    for _ in 0..250_000 {
        authority.sql_progress();
    }
    authority.check().unwrap();
    authority.sql_progress();
    assert!(authority.check().is_err());
}

#[test]
fn local_authority_checked_publication_overflow_does_not_install() {
    let control = LifecycleControl::new(CancellationToken::default());
    let id = identity();
    control.ready(id.clone()).unwrap();
    assert!(control
        .install(
            &id,
            "receiver".into(),
            publications(u64::MAX),
            Arc::new(SystemClock::default())
        )
        .is_err());
    assert!(!control.installed());
}
