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
fn benchmark_guard_refuses_overwrite_even_when_contents_match() {
    let mut pair = synchronized_pair();
    pair.preview(Direction::DesktopToPhone, SyncMode::Overwrite);
    let binding = pair.host.preview_binding().unwrap().to_owned();
    assert!(!pair.host.benchmark_require_noop(&binding).unwrap());
}
