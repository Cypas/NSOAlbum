import 'package:flutter_test/flutter_test.dart';

import '../../tool/device_sync_real_noop_report.dart';

const _record =
    'device_sync_metrics valid=true session_ms=2100 operation_ms=900 '
    'media_bytes=0 transfer_bytes_per_second=0 snapshot_ms=500 preview_ms=200 '
    'transfer_ms=100 verify_ms=150 apply_ms=350 receipt_ms=300 '
    'benchmark_noop_armed=1 strict_noop_applied=1 '
    'apply_snapshot_us=25000 apply_snapshot_count=1';

void main() {
  test('work counters and nested timing marker survive sanitized reporting', () {
    final metrics = NoopBenchmarkMetrics.parse(
      '$_record staging_checksum_read_bytes=0 receive_hashed_bytes=0 '
      'snapshot_digests=4 binding_digests=2 copy_bytes=0 apply_timings_nested=1',
    );
    expect(metrics.toJson()['staging_checksum_read_bytes'], 0);
    expect(metrics.toJson()['snapshot_digests'], 4);
    expect(metrics.toJson()['apply_timings_nested'], 1);
  });

  test('report keeps native phases without substituting summed total time', () {
    final metrics = NoopBenchmarkMetrics.parse(_record);
    expect(metrics.values['session_ms'], 2100);
    expect(metrics.values['operation_ms'], 900);
    expect(metrics.values['snapshot_ms'], 500);
    expect(metrics.values['apply_ms'], 350);
    expect(metrics.values['apply_snapshot_us'], 25000);
    expect(metrics.values['apply_snapshot_count'], 1);
    expect(metrics.isGuardedNoop(receiver: true), isTrue);
  });

  test('untrusted diagnostic fields never enter a saved numeric report', () {
    final metrics = NoopBenchmarkMetrics.parse(
      '$_record invitation=private-invitation '
      'path=C:/private/media.jpg account=private-account',
    );
    expect(metrics.values.containsKey('invitation'), isFalse);
    expect(metrics.values.containsKey('path'), isFalse);
    expect(metrics.values.containsKey('account'), isFalse);
    expect(metrics.toJson().toString(), isNot(contains('private')));
  });

  test('missing native phase cannot be reported as a measured zero', () {
    expect(
      () => NoopBenchmarkMetrics.parse(
        _record.replaceFirst(' verify_ms=150', ''),
      ),
      throwsFormatException,
    );
  });

  test('ambiguous or invalid numeric measurements are rejected', () {
    for (final record in [
      '$_record apply_ms=2',
      _record.replaceFirst('apply_ms=350', 'apply_ms=-3'),
      _record.replaceFirst('apply_ms=350', 'apply_ms=private-value'),
      _record.replaceFirst('valid=true', 'valid=false'),
    ]) {
      expect(() => NoopBenchmarkMetrics.parse(record), throwsFormatException);
    }
  });

  test('zero media bytes alone do not prove guarded no-op completion', () {
    final unarmed = NoopBenchmarkMetrics.parse(
      _record.replaceFirst('benchmark_noop_armed=1', 'benchmark_noop_armed=0'),
    );
    expect(unarmed.isGuardedNoop(receiver: true), isFalse);
    final notApplied = NoopBenchmarkMetrics.parse(
      _record.replaceFirst('strict_noop_applied=1', 'strict_noop_applied=0'),
    );
    expect(notApplied.isGuardedNoop(receiver: true), isFalse);
    expect(notApplied.isGuardedNoop(receiver: false), isTrue);
    final transferred = NoopBenchmarkMetrics.parse(
      _record.replaceFirst('media_bytes=0', 'media_bytes=10'),
    );
    expect(transferred.isGuardedNoop(receiver: true), isFalse);
  });

  test('optional unknown timing stays absent instead of becoming zero', () {
    final metrics = NoopBenchmarkMetrics.parse(
      _record.replaceFirst(
        'transfer_bytes_per_second=0',
        'transfer_bytes_per_second=unknown',
      ),
    );
    expect(metrics.values.containsKey('transfer_bytes_per_second'), isFalse);
    expect(metrics.values.containsKey('apply_sql_us'), isFalse);
  });

  test('odd and even medians are derived from actual completed samples', () {
    expect(benchmarkMedian([30, 10, 20]), 20);
    expect(benchmarkMedian([40, 10, 20, 30]), 25);
    expect(() => benchmarkMedian([]), throwsArgumentError);
  });
}
