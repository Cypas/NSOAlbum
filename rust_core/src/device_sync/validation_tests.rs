use super::ApplyTimingPhase as ApplyPhase;
use super::*;

fn field<'a>(record: &'a str, key: &str) -> &'a str {
    record
        .split_whitespace()
        .filter_map(|part| part.split_once('='))
        .find_map(|(name, value)| (name == key).then_some(value))
        .unwrap()
}

#[test]
fn benchmark_apply_timings_distinguish_unexecuted_from_zero_duration() {
    let metrics = ValidationMetrics::default();
    metrics.record_apply(ApplyPhase::Binding, std::time::Duration::ZERO);
    metrics.record_apply(ApplyPhase::Snapshot, std::time::Duration::from_micros(1700));
    metrics.record_apply(ApplyPhase::Snapshot, std::time::Duration::from_micros(2300));
    let result = metrics.observe().to_string();
    assert_eq!(field(&result, "apply_binding_us"), "0");
    assert_eq!(field(&result, "apply_binding_count"), "1");
    assert_eq!(field(&result, "apply_snapshot_us"), "4000");
    assert_eq!(field(&result, "apply_snapshot_count"), "2");
    assert_eq!(field(&result, "apply_sql_count"), "0");
    assert_eq!(field(&result, "strict_noop_applied"), "0");
}

#[test]
fn benchmark_apply_scope_records_on_error_and_is_shared_with_worker_clones() {
    let work = crate::device_sync::work::WorkControl::default();
    let worker = work.with_cancellation(crate::sync::CancellationToken::default());
    let fail = || -> Result<(), ()> {
        let _scope = worker.validation.time_apply(ApplyPhase::Plan);
        Err(())
    };
    assert!(fail().is_err());
    let result = work.validation_metrics().to_string();
    assert_eq!(field(&result, "apply_plan_count"), "1");
    assert_eq!(field(&result, "apply_journal_count"), "0");
    assert_eq!(field(&result, "apply_timings_nested"), "1");
}
