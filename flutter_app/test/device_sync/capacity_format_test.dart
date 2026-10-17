import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/device_sync/capacity_format.dart';

void main() {
  test('capacities retain zero, boundaries and exact large integer input', () {
    final cases = <String, String>{
      '0': '0 B',
      '1': '1 B',
      '1023': '1023 B',
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
    expect(formatDeviceCapacity(BigInt.zero, unknown: '未知'), '0 B');
    expect(() => formatDeviceCapacity(-BigInt.one), throwsArgumentError);
  });

  test(
    'rates share capacity units and never manufacture unknown throughput',
    () {
      expect(formatDeviceTransferRate(BigInt.from(512)), '512 B/s');
      expect(formatDeviceTransferRate(BigInt.from(1536)), '1.5 KB/s');
      expect(formatDeviceTransferRate(BigInt.from(2097152)), '2 MB/s');
      expect(formatDeviceTransferRate(BigInt.zero), '0 B/s');
      expect(formatDeviceTransferRate(null, unknown: '—'), '—');
    },
  );
}
