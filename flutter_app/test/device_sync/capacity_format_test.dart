import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/device_sync/capacity_format.dart';

void main() {
  test('capacities retain zero, boundaries and exact large integer input', () {
    final cases = <String, String>{
      '0': '0 KB',
      '1': '0 KB',
      '512': '0.5 KB',
      '1023': '1 KB',
      '1024': '1 KB',
      '1536': '1.5 KB',
      '1048575': '1024 KB',
      '1048576': '1 MB',
      '1073741824': '1 GB',
      '1325607178': '1.23 GB',
      '18446744073709551615': '17179869184 GB',
    };
    for (final entry in cases.entries) {
      expect(formatDeviceCapacity(BigInt.parse(entry.key)), entry.value);
    }
  });

  test('unknown is supplied by localization, not presented as zero', () {
    expect(formatDeviceCapacity(null, unknown: '未知'), '未知');
    expect(formatDeviceCapacity(null, unknown: 'Unknown'), 'Unknown');
    expect(formatDeviceCapacity(BigInt.zero, unknown: '未知'), '0 KB');
    expect(() => formatDeviceCapacity(-BigInt.one), throwsArgumentError);
  });

  test('rates start at KB per second while capacities still support bytes', () {
    expect(formatDeviceTransferRate(BigInt.from(512)), '0.5 KB/s');
    expect(formatDeviceTransferRate(BigInt.from(1023)), '1 KB/s');
    expect(formatDeviceTransferRate(BigInt.from(1536)), '1.5 KB/s');
    expect(formatDeviceTransferRate(BigInt.from(2097152)), '2 MB/s');
    expect(formatDeviceTransferRate(BigInt.zero), '0 KB/s');
    expect(formatDeviceTransferRate(null, unknown: '—'), '—');
    expect(() => formatDeviceTransferRate(-BigInt.one), throwsArgumentError);
  });

  test(
    'device sync ETA switches from minutes to hours and handles unknowns',
    () {
      expect(formatDeviceSyncEta(const Duration(minutes: 8)), '8 分钟');
      expect(formatDeviceSyncEta(const Duration(minutes: 65)), '1 小时 5 分钟');
    expect(formatDeviceSyncEta(Duration.zero), '不到 1 分钟');
    expect(formatDeviceSyncEta(const Duration(seconds: 30)), '不到 1 分钟');
      expect(formatDeviceSyncEta(null, unknown: '正在估算'), '正在估算');
    },
  );

  test('transfer ETA requires a positive measured rate', () {
    expect(
      estimateDeviceSyncRemainingMs(
        processedBytes: BigInt.from(250),
        totalBytes: BigInt.from(1000),
        bytesPerSecond: BigInt.from(50),
      ),
      BigInt.from(15000),
    );
    expect(
      estimateDeviceSyncRemainingMs(
        processedBytes: BigInt.from(1000),
        totalBytes: BigInt.from(1000),
        bytesPerSecond: BigInt.from(50),
      ),
      BigInt.zero,
    );
    expect(
      estimateDeviceSyncRemainingMs(
        processedBytes: BigInt.zero,
        totalBytes: BigInt.from(1000),
        bytesPerSecond: BigInt.zero,
      ),
      isNull,
    );
  });
}
