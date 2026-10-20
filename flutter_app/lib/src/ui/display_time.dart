/// Formats user-visible dates in the device's local timezone, to whole seconds.
String formatUserDateTime(DateTime value) {
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${_twoDigits(local.month)}-${_twoDigits(local.day)} '
      '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}:'
      '${_twoDigits(local.second)}';
}

/// Compact timestamp for an NSO account's latest synchronization attempt.
String formatNsoAttemptTime(DateTime value, {bool includeSeconds = true}) =>
    formatUserDateTime(value).substring(5, includeSeconds ? null : 16);

String _twoDigits(int value) => value.toString().padLeft(2, '0');
