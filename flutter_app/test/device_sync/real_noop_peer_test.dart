import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/rust/device_sync/work.dart';

import '../../tool/device_sync_real_noop_peer.dart';
import '../../tool/device_sync_real_noop_controller.dart';

void main() {
  test('explicit verified interface selects its unique discovered address', () {
    const wlan = DeviceLanAddress(
      interfaceName: 'WLAN',
      address: '192.168.1.8',
    );
    final selected = selectRealNoopWifiAddress(const [
      DeviceLanAddress(interfaceName: 'cfw-tap', address: '10.0.0.1'),
      DeviceLanAddress(
        interfaceName: 'KSA Host Adapter',
        address: '172.16.0.1',
      ),
      DeviceLanAddress(
        interfaceName: 'KSA Network Adapter',
        address: '10.1.0.1',
      ),
      wlan,
    ], interfaceName: 'WLAN');
    expect(identical(selected, wlan), isTrue);
  });

  test(
    'explicit missing or non-unique interface never falls back elsewhere',
    () {
      const wlan = DeviceLanAddress(
        interfaceName: 'WLAN',
        address: '192.168.1.8',
      );
      expect(
        () => selectRealNoopWifiAddress(const [wlan], interfaceName: 'missing'),
        throwsStateError,
      );
      expect(
        () => selectRealNoopWifiAddress(const [wlan], interfaceName: 'wlan'),
        throwsStateError,
      );
      expect(
        () => selectRealNoopWifiAddress(const [
          wlan,
          DeviceLanAddress(interfaceName: 'WLAN', address: '192.168.2.8'),
        ], interfaceName: 'WLAN'),
        throwsStateError,
      );
    },
  );

  test(
    'unconfigured selection preserves bounded legacy interface filtering',
    () {
      const wlan = DeviceLanAddress(
        interfaceName: 'WLAN',
        address: '192.168.1.8',
      );
      expect(
        selectRealNoopWifiAddress(const [
          DeviceLanAddress(interfaceName: 'VPN', address: '10.0.0.1'),
          wlan,
        ]),
        same(wlan),
      );
      expect(
        () => selectRealNoopWifiAddress(const [
          wlan,
          DeviceLanAddress(interfaceName: 'Ethernet', address: '192.168.2.8'),
        ]),
        throwsStateError,
      );
    },
  );

  test(
    'status never enumerates or invalidates USB selection identities',
    () async {
      final session = _Session();
      final peer = NativeRealNoopPeer(
        session: session,
        requireNoop: (_) async => true,
        readMetrics: () async => null,
      );
      await peer.status();
      await peer.status();
      expect(session.enumerations, 0);
    },
  );

  test(
    'status interleaving cannot invalidate the selection being applied',
    () async {
      final session = _Session();
      final peer = NativeRealNoopPeer(
        session: session,
        requireNoop: (_) async => true,
        readMetrics: () async => null,
      );
      session.afterEnumeration = () async {
        await peer.status();
      };
      expect(await peer.selectOnlyUsb(), isTrue);
      expect(session.selected, isTrue);
      expect(session.enumerations, 1);
    },
  );

  test(
    'prepare and selection stay serial across asynchronous identity lookup',
    () async {
      final session = _Session();
      final peer = NativeRealNoopPeer(
        session: session,
        requireNoop: (_) async => true,
        readMetrics: () async => null,
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      session.afterEnumeration = () async {
        entered.complete();
        await release.future;
      };
      final selection = peer.selectOnlyUsb();
      await entered.future;
      final preparation = peer.prepareUsb();
      await peer.status();
      expect(session.enumerations, 1);
      release.complete();
      expect(await selection, isTrue);
      expect(await preparation, 0);
      expect(session.enumerations, 1);
    },
  );

  test('zero and ambiguous USB candidates never select a storage', () async {
    for (final count in [0, 2]) {
      final session = _Session()..candidateCount = count;
      final peer = NativeRealNoopPeer(
        session: session,
        requireNoop: (_) async => true,
        readMetrics: () async => null,
      );
      expect(await peer.prepareUsb(), count);
      if (count == 0) {
        expect(await peer.selectOnlyUsb(), isFalse);
      } else {
        await expectLater(
          peer.selectOnlyUsb(),
          throwsA(isA<RealNoopAmbiguousUsb>()),
        );
      }
      expect(session.selected, isFalse);
    }
  });
}

final class _Session extends DeviceSyncSessionController {
  int enumerations = 0, candidateCount = 1;
  bool selected = false;
  Future<void> Function()? afterEnumeration;
  DeviceUsbStorageChoice? _valid;
  @override
  bool get settled => false;
  @override
  bool get busy => false;
  @override
  bool get confirmedLocally => false;
  @override
  String? get confirmationCode => null;
  @override
  read.ReadError? get issue => null;
  @override
  read.EndpointRead get snapshot {
    final progress = read.ProgressView(
      workStage: WorkStage.idle,
      workActive: false,
      scannedItems: BigInt.zero,
    );
    return read.EndpointRead(
      progress: progress,
      value: read.EndpointView(
        pairing: read.PairingStage.handshaking,
        confirmationAvailable: false,
        transport: read.TransportKind.usb,
        host: true,
        controller: false,
        phoneControlled: true,
        accountsConsentAuthorized: false,
        previewApproved: false,
        stage: driver.State.pairing,
        terminal: false,
        cleanupPending: false,
        localApplyInstalled: false,
        sourceGrantIssued: false,
        transportDetached: false,
        progress: progress,
      ),
    );
  }

  @override
  Future<read.EndpointRead> refresh() async => snapshot;
  @override
  Future<List<DeviceUsbStorageChoice>> usbChoices() async {
    enumerations++;
    final choice = DeviceUsbStorageChoice(
      deviceName: 'synthetic',
      storageName: 'synthetic',
      freeBytes: BigInt.zero,
    );
    _valid = choice;
    final interleave = afterEnumeration;
    afterEnumeration = null;
    await interleave?.call();
    return List.generate(candidateCount, (_) => choice);
  }

  @override
  Future<void> selectUsb(DeviceUsbStorageChoice choice) async {
    if (!identical(choice, _valid)) throw StateError('Stale identity');
    selected = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
