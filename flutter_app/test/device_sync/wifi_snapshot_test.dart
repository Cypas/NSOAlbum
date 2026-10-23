import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/device_sync_network.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(permissions, null));

  for (final granted in [false, true]) {
    test(
      'Android Wi-Fi permission keeps its native request contract ($granted)',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(permissions, (call) async {
          calls.add(call);
          expect(call.method, 'requestPermissions');
          expect(call.arguments, [5]);
          return <int, int>{5: granted ? 1 : 0};
        });
        var networkReads = 0;
        final reader = DeviceNetworkReader(
          android: true,
          windows: false,
          macos: false,
          readName: () async {
            networkReads++;
            return '"Synthetic Wi-Fi"';
          },
          readAddress: () async => '192.168.20.2',
        );
        final snapshot = await reader.read(requestPermission: true);
        expect(calls, hasLength(1));
        expect(networkReads, granted ? 2 : 0);
        expect(snapshot.ssid, granted ? 'Synthetic Wi-Fi' : isNull);
      },
    );
  }

  test(
    'Android passive Wi-Fi status never opens a permission request',
    () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(permissions, (call) async {
        methods.add(call.method);
        expect(call.method, 'checkPermissionStatus');
        expect(call.arguments, 5);
        return 1;
      });
      final reader = DeviceNetworkReader(
        android: true,
        windows: false,
        macos: false,
        readName: () async => '"Synthetic Wi-Fi"',
        readAddress: () async => '192.168.20.2',
      );
      expect((await reader.read()).ssid, 'Synthetic Wi-Fi');
      expect(methods, ['checkPermissionStatus']);
    },
  );

  for (final windows in [false, true]) {
    test(
      'desktop Wi-Fi does not call Android permission APIs (windows=$windows)',
      () async {
        final methods = <String>[];
        messenger.setMockMethodCallHandler(permissions, (call) async {
          methods.add(call.method);
          throw StateError('Desktop must not request Android permission.');
        });
        final reader = DeviceNetworkReader(
          android: false,
          windows: windows,
          macos: !windows,
          readName: () async => 'Synthetic Wi-Fi',
          readAddress: () async => '192.168.20.2',
        );
        expect(
          (await reader.read(requestPermission: true)).ssid,
          'Synthetic Wi-Fi',
        );
        expect(methods, isEmpty);
      },
    );
  }

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
        windows: false,
        macos: false,
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
        windows: false,
        macos: false,
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
        android: false,
        windows: true,
        macos: false,
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
          android: false,
          windows: false,
          macos: false,
          readName: () async => name,
          readAddress: () async => '192.168.1.5',
        );
        expect((await reader.read()).ssid, isNull);
      }
      final failed = DeviceNetworkReader(
        android: false,
        windows: false,
        macos: false,
        readName: () async => throw StateError('private network diagnostic'),
        readAddress: () async => '192.168.1.5',
      );
      expect((await failed.read()).ssid, isNull);
      var reads = 0;
      final changed = DeviceNetworkReader(
        android: false,
        windows: false,
        macos: false,
        readName: () async => reads++ == 0 ? 'Home' : 'Other',
        readAddress: () async => '192.168.1.5',
      );
      final result = await changed.read();
      expect(result.ssid, isNull);
      expect(result.address, isNull);
    },
  );
}
