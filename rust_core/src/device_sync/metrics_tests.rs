use super::*;

#[test]
fn counters_never_log_identity_or_variable_application_payloads() {
    let mut metrics = Metrics::new(0);
    metrics.phase(Some(Phase::Receipt), 10);
    let record = metrics.finish(20);
    assert!(record.starts_with("device_sync_metrics "));
    assert!(record.split_whitespace().skip(1).all(|part| {
        let (name, value) = part.split_once('=').expect("structured measurement");
        name.bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte == b'_')
            && (matches!(value, "true" | "false" | "unknown")
                || value.bytes().all(|byte| byte.is_ascii_digit()))
    }));
}
