use super::*;

fn field<'a>(record: &'a str, key: &str) -> &'a str {
    record
        .split_whitespace()
        .filter_map(|part| part.split_once('='))
        .find_map(|(name, value)| (name == key).then_some(value))
        .unwrap_or_else(|| panic!("measurement field {key} missing"))
}

#[test]
fn transfer_intervals_exclude_verification_and_duplicate_media_reports() {
    let mut metrics = Metrics::new(0);
    metrics.phase(Some(Phase::Transfer), 10);
    metrics.observe_media_bytes(1_024);
    metrics.observe_media_bytes(1_024);
    metrics.phase(Some(Phase::Verify), 110);
    metrics.phase(Some(Phase::Transfer), 160);
    let record = metrics.finish(260);
    assert_eq!(field(&record, "transfer_ms"), "200");
    assert_eq!(field(&record, "verify_ms"), "50");
    assert_eq!(field(&record, "media_bytes"), "1024");
    assert_eq!(field(&record, "transfer_bytes_per_second"), "5120");
    assert_eq!(field(&record, "operation_ms"), "250");
}

#[test]
fn waiting_before_confirmation_does_not_inflate_transfer_or_operation_time() {
    let mut metrics = Metrics::new(0);
    metrics.phase(Some(Phase::Snapshot), 5);
    metrics.phase(None, 25);
    metrics.phase(Some(Phase::Preview), 125);
    metrics.phase(None, 175);
    metrics.phase(Some(Phase::Transfer), 2_000);
    metrics.observe_media_bytes(8_192);
    let record = metrics.finish(2_100);
    assert_eq!(field(&record, "snapshot_ms"), "20");
    assert_eq!(field(&record, "preview_ms"), "50");
    assert_eq!(field(&record, "transfer_ms"), "100");
    assert_eq!(field(&record, "operation_ms"), "100");
    assert_eq!(field(&record, "session_ms"), "2100");
}

#[test]
fn io_latency_bytes_and_failures_are_separate_from_unique_media_bytes() {
    let mut metrics = Metrics::new(0);
    metrics.io(IoKind::List, 3, 0, false);
    metrics.io(IoKind::Read, 9, 65_536, false);
    metrics.io(IoKind::Read, 4, 0, true);
    metrics.io(IoKind::Write, 7, 65_536, false);
    metrics.io(IoKind::Acknowledge, 11, 0, false);
    let record = metrics.finish(100);
    assert_eq!(field(&record, "usb_read_count"), "2");
    assert_eq!(field(&record, "usb_read_ms"), "13");
    assert_eq!(field(&record, "usb_read_bytes"), "65536");
    assert_eq!(field(&record, "usb_read_failed"), "1");
    assert_eq!(field(&record, "usb_acknowledge_ms"), "11");
    assert_eq!(field(&record, "media_bytes"), "0");
    assert_eq!(field(&record, "transfer_bytes_per_second"), "unknown");
}

#[test]
fn clock_regression_invalidates_rate_without_underflowing_or_panicking() {
    let mut metrics = Metrics::new(100);
    metrics.phase(Some(Phase::Transfer), 110);
    metrics.observe_media_bytes(32_768);
    metrics.phase(Some(Phase::Verify), 105);
    let record = metrics.finish(200);
    assert_eq!(field(&record, "valid"), "false");
    assert_eq!(field(&record, "transfer_bytes_per_second"), "unknown");
}

#[test]
fn counter_overflow_is_bounded_and_does_not_change_business_outcome() {
    let mut metrics = Metrics::new(0);
    metrics.io(IoKind::Write, u64::MAX, u64::MAX, false);
    metrics.io(IoKind::Write, 1, 1, false);
    let record = metrics.finish(1);
    assert_eq!(field(&record, "valid"), "false");
    assert_eq!(field(&record, "usb_write_ms"), "18446744073709551615");
    assert_eq!(field(&record, "usb_write_bytes"), "18446744073709551615");
}

#[test]
fn finalized_measurement_is_stable_and_cannot_be_reused_by_late_callbacks() {
    let mut metrics = Metrics::new(0);
    metrics.phase(Some(Phase::Transfer), 10);
    metrics.observe_media_bytes(1_024);
    let first = metrics.finish(110);
    metrics.phase(Some(Phase::Apply), 1_000);
    metrics.io(IoKind::Write, 5, 8_192, false);
    metrics.observe_media_bytes(2_048);
    assert_eq!(metrics.finish(2_000), first);
}

#[test]
fn zero_duration_and_cancelled_before_transfer_do_not_claim_a_transfer_rate() {
    let mut metrics = Metrics::new(0);
    metrics.phase(Some(Phase::Transfer), 0);
    assert_eq!(
        field(&metrics.finish(0), "transfer_bytes_per_second"),
        "unknown"
    );
    let mut cancelled = Metrics::new(0);
    cancelled.phase(Some(Phase::Snapshot), 10);
    let record = cancelled.finish(20);
    assert_eq!(field(&record, "operation_ms"), "unknown");
    assert_eq!(field(&record, "transfer_bytes_per_second"), "unknown");
}

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

#[test]
fn usb_aggregation_counts_classified_preparation_separately_from_real_publication() {
    let mut metrics = Metrics::new(0);
    metrics.usb_drain(true);
    metrics.usb_drain(true);
    metrics.usb_drain(false);
    // Failed/WindowFull native attempts never call usb_published.
    metrics.usb_published(2);
    let record = metrics.finish(10);
    assert_eq!(field(&record, "usb_media_drains"), "2");
    assert_eq!(field(&record, "usb_immediate_drains"), "1");
    assert_eq!(field(&record, "usb_published_bundles"), "1");
    assert_eq!(field(&record, "usb_multi_bundles"), "1");
    assert_eq!(field(&record, "usb_max_bundle_drains"), "2");
    metrics.usb_published(3);
    assert_eq!(metrics.finish(20), record);
}

#[test]
fn large_usb_carriers_do_not_invalidate_measurements_at_the_old_four_drain_limit() {
    let mut metrics = Metrics::new(0);
    metrics.usb_published(64);
    let record = metrics.finish(10);
    assert_eq!(field(&record, "valid"), "true");
    assert_eq!(field(&record, "usb_max_bundle_drains"), "64");
}

#[test]
fn native_subtimings_are_numeric_nested_and_retained_in_the_summary() {
    let mut timing = super::super::io_metrics::IoMetrics::default();
    timing.record(super::super::io_metrics::IoStep::Create, 1200, 0);
    timing.record(super::super::io_metrics::IoStep::CreateWrite, 3500, 4096);
    let summary = timing.to_string();
    assert!(summary.contains("create_count=1"));
    assert!(summary.contains("create_us=1200"));
    assert!(summary.contains("create_write_bytes=4096"));
    assert!(summary.contains("create_write_us=3500"));
    assert!(summary.contains("nested=true"));
}

#[test]
fn carrier_measurements_report_real_sizes_and_publication_reasons() {
    let mut metrics = Metrics::new(0);
    metrics.usb_carrier(
        4 * 1024 * 1024,
        super::super::mailbox::bundle::FlushReason::Target,
    );
    metrics.usb_carrier(128, super::super::mailbox::bundle::FlushReason::Control);
    metrics.usb_carrier(
        512 * 1024,
        super::super::mailbox::bundle::FlushReason::Timer,
    );
    let record = metrics.finish(10);
    assert_eq!(field(&record, "usb_carrier_bytes"), "4718720");
    assert_eq!(field(&record, "usb_carrier_max_bytes"), "4194304");
    assert_eq!(field(&record, "usb_flush_target"), "1");
    assert_eq!(field(&record, "usb_flush_control"), "1");
    assert_eq!(field(&record, "usb_flush_timer"), "1");
    assert_eq!(field(&record, "usb_carrier_below_mib"), "2");
}
