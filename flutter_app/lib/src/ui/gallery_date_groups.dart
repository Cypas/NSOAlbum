String galleryDateGroupKey(DateTime? importedAt) {
  final value = importedAt?.toLocal();
  if (value == null) return 'unknown';
  return '${value.year}-${value.month}-${value.day}';
}

String galleryDateGroupLabel(
  DateTime? importedAt, {
  required bool english,
  DateTime? today,
}) {
  final value = importedAt?.toLocal();
  if (value == null) return english ? 'Unknown date' : '日期未知';
  final current = _localDate(today ?? DateTime.now());
  final day = _localDate(value);
  if (day == current) return english ? 'Today' : '今天';
  if (day == current.subtract(const Duration(days: 1))) {
    return english ? 'Yesterday' : '昨天';
  }
  return english
      ? '${value.month}/${value.day}/${value.year}'
      : '${value.month}月${value.day}日';
}

DateTime _localDate(DateTime value) =>
    DateTime(value.year, value.month, value.day);
