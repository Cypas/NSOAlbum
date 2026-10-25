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
