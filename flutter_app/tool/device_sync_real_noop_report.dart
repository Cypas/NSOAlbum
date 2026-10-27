/// Numeric-only reports for the explicitly enabled real-library Debug probe.
final class NoopBenchmarkMetrics {
  NoopBenchmarkMetrics.parse(String record) {
    final parts = record.trim().split(RegExp(r'\s+'));
    if (parts.firstOrNull != 'device_sync_metrics') {
      throw const FormatException('Invalid benchmark metrics');
    }
    final parsed = <String, int>{};
    var valid = false;
    var sawValid = false;
    final seen = <String>{};
    for (final part in parts.skip(1)) {
      final split = part.indexOf('=');
      if (split < 1) continue;
      final key = part.substring(0, split);
      if (key != 'valid' && !_allowed.contains(key)) continue;
      if (!seen.add(key)) {
        throw const FormatException('Duplicate benchmark measurement');
      }
      final text = part.substring(split + 1);
      if (key == 'valid') {
        sawValid = true;
        valid = text == 'true';
      } else if (text != 'unknown') {
        if (!RegExp(r'^[0-9]+$').hasMatch(text)) {
          throw const FormatException('Invalid benchmark measurement');
        }
        final value = int.tryParse(text);
        if (value == null) {
          throw const FormatException('Benchmark measurement overflow');
        }
        parsed[key] = value;
      }
    }
    if (!sawValid || !valid || !_required.every(parsed.containsKey)) {
      throw const FormatException('Incomplete benchmark measurements');
    }
    values = Map.unmodifiable(parsed);
  }

  late final Map<String, int> values;

  bool isGuardedNoop({required bool receiver}) =>
      values['benchmark_noop_armed'] == 1 &&
      values['media_bytes'] == 0 &&
      (!receiver || values['strict_noop_applied'] == 1);

  Map<String, int> toJson() => Map.of(values);

  static const _required = {
    'session_ms',
    'operation_ms',
    'media_bytes',
    'snapshot_ms',
    'preview_ms',
    'transfer_ms',
    'verify_ms',
    'apply_ms',
    'receipt_ms',
    'benchmark_noop_armed',
    'strict_noop_applied',
  };
  static final _allowed = {
    ..._required,
    'transfer_bytes_per_second',
    'snapshot_digests',
    'binding_digests',
    'staging_checksum_read_bytes',
    'receive_hashed_bytes',
    'copy_bytes',
    'apply_timings_nested',
    for (final phase in [
      'binding',
      'snapshot',
      'plan',
      'originals',
      'space',
      'backup',
      'sql',
      'postcheck',
      'journal',
    ]) ...['apply_${phase}_us', 'apply_${phase}_count'],
    for (final kind in ['list', 'read', 'write', 'acknowledge'])
      for (final field in ['count', 'ms', 'bytes', 'failed'])
        'usb_${kind}_$field',
    'usb_media_drains',
    'usb_immediate_drains',
    'usb_published_bundles',
    'usb_multi_bundles',
    'usb_max_bundle_drains',
    'usb_carrier_bytes',
    'usb_carrier_max_bytes',
    'usb_carrier_below_mib',
    'usb_carrier_below_four_mib',
    'usb_carrier_four_mib_or_more',
    'usb_flush_target',
    'usb_flush_timer',
    'usb_flush_control',
    'usb_flush_boundary',
  };
}

num benchmarkMedian(List<int> values) {
  if (values.isEmpty) throw ArgumentError('No completed benchmark rounds');
  final sorted = List<int>.of(values)..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}
