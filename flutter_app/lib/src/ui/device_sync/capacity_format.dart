/// Formats native u64 values without first converting them to a lossy double.
/// Unit names follow the application's existing 1024-based capacity convention.
String formatDeviceCapacity(BigInt? bytes, {String unknown = '—'}) =>
    _formatDeviceBytes(bytes, unknown: unknown, minimumUnit: 1);

String _formatDeviceBytes(
  BigInt? bytes, {
  required String unknown,
  int minimumUnit = 0,
}) {
  if (bytes == null) return unknown;
  if (bytes.isNegative) throw ArgumentError.value(bytes, 'bytes');
  const units = ['B', 'KB', 'MB', 'GB'];
  var divisor = BigInt.one;
  var unit = 0;
  final step = BigInt.from(1024);
  while (unit < units.length - 1 &&
      (unit < minimumUnit || bytes >= divisor * step)) {
    divisor *= step;
    unit++;
  }
  final hundred = BigInt.from(100);
  final rounded = (bytes * hundred + divisor ~/ BigInt.two) ~/ divisor;
  final whole = rounded ~/ hundred;
  final fractional = (rounded % hundred).toString().padLeft(2, '0');
  final suffix = fractional.replaceFirst(RegExp(r'0+$'), '');
  return '$whole${suffix.isEmpty ? '' : '.$suffix'} ${units[unit]}';
}

String formatDeviceTransferRate(
  BigInt? bytesPerSecond, {
  String unknown = '—',
}) => bytesPerSecond == null
    ? unknown
    : '${_formatDeviceBytes(bytesPerSecond, unknown: unknown, minimumUnit: 1)}/s';

String formatDeviceSyncEta(
  Duration? remaining, {
  String unknown = '正在估算',
  bool english = false,
}) {
  if (remaining == null) return unknown;
  if (remaining < const Duration(minutes: 1)) {
    return english ? 'Less than 1 min' : '不到 1 分钟';
  }
  final minutes = remaining.inMinutes;
  if (minutes < 60) return english ? '$minutes min' : '$minutes 分钟';
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  if (english) return '$hours hr${remainder == 0 ? '' : ' $remainder min'}';
  return '$hours 小时${remainder == 0 ? '' : ' $remainder 分钟'}';
}

BigInt? estimateDeviceSyncRemainingMs({
  required BigInt processedBytes,
  required BigInt totalBytes,
  required BigInt bytesPerSecond,
}) {
  if (processedBytes.isNegative ||
      totalBytes.isNegative ||
      bytesPerSecond.isNegative) {
    throw ArgumentError('Sync progress values must not be negative');
  }
  if (totalBytes <= processedBytes) return BigInt.zero;
  if (bytesPerSecond == BigInt.zero) return null;
  final remaining = totalBytes - processedBytes;
  return (remaining * BigInt.from(1000) + bytesPerSecond - BigInt.one) ~/
      bytesPerSecond;
}
