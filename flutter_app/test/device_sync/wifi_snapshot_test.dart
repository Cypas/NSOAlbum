import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/device_sync_network.dart';

void main() {
  test(
    'macOS plugin IP is not asserted to belong to the SSID interface',
    () async {
      final reader = DeviceNetworkReader(
        macos: true,
        windows: false,
        readName: () async => 'Home',
        readAddress: () async => '192.168.1.5',
      );
      final snapshot = await reader.read();
      expect(snapshot.ssid, 'Home');
      expect(snapshot.ssidForAddress('192.168.1.5'), isNull);
    },
  );
  test(
    'Wi-Fi name comparison is exact, advisory and unknown when unavailable',
    () {
      const snapshot = DeviceWifiSnapshot(ssid: 'Home', address: '192.168.1.5');
      expect(snapshot.compareName('Home'), DeviceWifiMatch.sameName);
      expect(snapshot.compareName('home'), DeviceWifiMatch.differentName);
      expect(snapshot.compareName(null), DeviceWifiMatch.unknown);
      expect(
        const DeviceWifiSnapshot().compareName('Home'),
        DeviceWifiMatch.unknown,
      );
      expect(snapshot.ssidForAddress('192.168.1.5'), 'Home');
      expect(snapshot.ssidForAddress('192.168.2.5'), isNull);
      expect(snapshot.ssidForAddress(null), isNull);
    },
  );

  test(
    'Android denied permission never reads protected network details',
    () async {
      final reader = DeviceNetworkReader(
        android: true,
        requestAccess: () async => false,
        readName: () async => fail('Denied access must not read SSID'),
        readAddress: () async => fail('Denied access must not read IP'),
      );
      final result = await reader.read(requestPermission: true);
      expect(result.ssid, isNull);
      expect(result.address, isNull);
    },
  );

  test(
    'Android unwraps OS quotes without discarding meaningful spaces',
    () async {
      final reader = DeviceNetworkReader(
        android: true,
        requestAccess: () async => true,
        readName: () async => '" Home "',
        readAddress: () async => '192.168.1.5',
      );
      final result = await reader.read(requestPermission: true);
      expect(result.ssid, ' Home ');
      expect(result.address, '192.168.1.5');
    },
  );

  test(
    'Windows plugin raw UTF-8 bytes are decoded before SSID comparison',
    () async {
      final reader = DeviceNetworkReader(
        windows: true,
        readName: () async => String.fromCharCodes(utf8.encode('家里的 Wi-Fi')),
        readAddress: () async => '192.168.1.5',
      );
      expect((await reader.read()).ssid, '家里的 Wi-Fi');
    },
  );

  test(
    'unknown, malformed and changed network readings are never called a match',
    () async {
      for (final name in ['<unknown ssid>', '', 'bad\nname', '网' * 11]) {
        final reader = DeviceNetworkReader(
          readName: () async => name,
          readAddress: () async => '192.168.1.5',
        );
        expect((await reader.read()).ssid, isNull);
      }
      final failed = DeviceNetworkReader(
        readName: () async => throw StateError('private network diagnostic'),
        readAddress: () async => '192.168.1.5',
      );
      expect((await failed.read()).ssid, isNull);
      var reads = 0;
      final changed = DeviceNetworkReader(
        readName: () async => reads++ == 0 ? 'Home' : 'Other',
        readAddress: () async => '192.168.1.5',
      );
      final result = await changed.read();
      expect(result.ssid, isNull);
      expect(result.address, isNull);
    },
  );
}
