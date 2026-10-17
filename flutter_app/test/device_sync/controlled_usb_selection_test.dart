import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/rust/device_sync/headless.dart';
import 'package:squid_album/src/rust/device_sync/connection.dart';
import 'package:squid_album/src/rust/device_sync/native_io.dart';
import 'package:squid_album/src/rust/device_sync/read_model.dart';
import 'package:squid_album/src/rust/device_sync/usb.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/work.dart';
import 'package:squid_album/src/rust/frb_generated.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeBoundary native;
  late DeviceSyncStartupLifecycle lifecycle;
  setUp(() async {
    native = _NativeBoundary();
    RustLib.initMock(api: native);
    final gate = AccountWorkGate();
    lifecycle = DeviceSyncStartupLifecycle(
      gate: gate,
      openLibrary: () async => 'controlled-library',
      coordinator: (handle) => DeviceAccountCoordinator(
        library: handle,
        storage: MemoryAccountStorage(),
        gate: gate,
        invalidate: (_) async {},
        publish: (_) {},
      ),
      initialize: () async {},
      isolated: false,
    );
    await lifecycle.start();
  });
  tearDown(() async {
    await lifecycle.close();
    RustLib.dispose();
  });

  test(
    'only current owned enumeration choices can select native storage',
    () async {
      final session = await lifecycle.service.hostUsb(name: 'Desktop');
      final old = (await session.usbChoices()).single;
      expect(old.deviceName, 'Phone 日本語');
      expect(old.storageName, 'Internal storage');
      expect(old.freeBytes, BigInt.from(4096));
      final current = (await session.usbChoices()).single;
      await expectLater(session.selectUsb(old), throwsA(isA<DeviceSyncBusy>()));
      await expectLater(
        session.selectUsb(
          DeviceUsbStorageChoice(
            deviceName: current.deviceName,
            storageName: current.storageName,
            freeBytes: current.freeBytes,
          ),
        ),
        throwsA(isA<DeviceSyncBusy>()),
      );
      expect(native.selected, isEmpty);
      await session.selectUsb(current);
      expect(native.selected, [('opaque-device', 'opaque-storage')]);
      await session.close();
      expect(() => session.selectUsb(current), throwsA(isA<DeviceSyncBusy>()));
      expect(lifecycle.ready, isTrue);
    },
  );

  test('terminal USB state rejects an otherwise current choice', () async {
    final session = await lifecycle.service.hostUsb(name: 'Desktop');
    final choice = (await session.usbChoices()).single;
    native.view = const UsbView(
      closed: true,
      reason: UsbCloseReason.cancelled,
      devices: [],
    );
    await expectLater(
      session.selectUsb(choice),
      throwsA(isA<DeviceSyncBusy>()),
    );
    expect(native.selected, isEmpty);
  });

  test('unavailable helper is visible without a transport fallback', () async {
    final session = await lifecycle.service.hostUsb(name: 'Desktop');
    native.view = const UsbView(
      closed: true,
      reason: UsbCloseReason.failure,
      error: ReadError.unavailable,
      devices: [],
    );
    expect(await session.usbChoices(), isEmpty);
    expect(session.issue, ReadError.unavailable);
    expect(session.invitation, isNull);
    expect(native.selected, isEmpty);
  });

  test('successful terminal cleanup preserves helper failure until its own view recovers', () async {
    final session = await lifecycle.service.hostUsb(name: 'Desktop');
    final available = native.view;
    native.view = const UsbView(
      closed: true,
      reason: UsbCloseReason.failure,
      error: ReadError.unavailable,
      devices: [],
    );
    await session.usbChoices();
    native.stage = driver.State.cancelled;
    await session.refresh();
    expect(session.issue, ReadError.unavailable);
    native.view = available;
    expect(await session.usbChoices(), hasLength(1));
    expect(session.issue, isNull);
  });

  test('observed Completed USB host waits original native close before cancellation', () async {
    final session = await lifecycle.service.hostUsb(name: 'Desktop');
    native.stage = driver.State.completed;
    await session.refresh();
    final closing = session.close().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    await Future<void>.delayed(Duration.zero);
    try {
      expect(native.waits, 1);
      expect(native.cancelSignals, 0);
      expect(native.closedEndpoints, 0);
      expect(session.settled, isFalse);
    } finally {
      native.finished.complete(
        const UsbView(
          closed: true,
          reason: UsbCloseReason.success,
          devices: [],
        ),
      );
      expect(await closing, isNull);
    }
    expect(native.cancelSignals, greaterThan(0));
    expect(native.closedEndpoints, 1);
    expect(session.settled, isTrue);
  });

  test(
    'Completed USB wait failure cleans up but never becomes graceful success',
    () async {
      final session = await lifecycle.service.hostUsb(name: 'Desktop');
      native.stage = driver.State.completed;
      await session.refresh();
      native.finished.complete(
        const UsbView(
          closed: true,
          reason: UsbCloseReason.failure,
          error: ReadError.permissionDenied,
          devices: [],
        ),
      );
      final result = await session.close().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      expect(result, isA<DeviceSyncReadFailure>());
      expect(
        (result as DeviceSyncReadFailure).code,
        ReadError.permissionDenied,
      );
      expect(native.closedEndpoints, 1);
      expect(native.cancelSignals, greaterThan(0));
      expect(session.settled, isTrue);
    },
  );

  test('unknown USB close reason is not graceful success', () async {
    final session = await lifecycle.service.hostUsb(name: 'Desktop');
    native.stage = driver.State.completed;
    await session.refresh();
    native.finished.complete(const UsbView(closed: true, devices: []));
    final result = await session.close().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    expect(result, isA<DeviceSyncReadFailure>());
    expect((result as DeviceSyncReadFailure).code, ReadError.unavailable);
    expect(native.closedEndpoints, 1);
  });

  test('endpoint retirement failure never publishes settled', () async {
    final session = await lifecycle.service.hostUsb(name: 'Desktop');
    final failure = StateError('synthetic endpoint close failure');
    native.closeFailure = failure;
    await expectLater(session.close(), throwsA(same(failure)));
    expect(session.closed, isTrue);
    expect(session.settled, isFalse);
    expect(native.closedEndpoints, 0);
    await expectLater(session.close(), throwsA(same(failure)));
    expect(session.settled, isFalse);
  });

  for (final stage in [
    driver.State.pairing,
    driver.State.cancelled,
    driver.State.failed,
    driver.State.completedUnconfirmed,
  ]) {
    test(
      '${stage.name} USB keeps the original immediate cancel path',
      () async {
        final session = await lifecycle.service.hostUsb(name: 'Desktop');
        native.stage = stage;
        await session.refresh();
        await session.close();
        expect(native.waits, 0);
        expect(native.cancelSignals, greaterThan(0));
        expect(native.closedEndpoints, 1);
      },
    );
  }
}

class _NativeBoundary implements RustLibApi {
  final selected = <(String, String)>[];
  driver.State stage = driver.State.pairing;
  Object? closeFailure;
  int waits = 0, cancelSignals = 0, closedEndpoints = 0;
  final finished = Completer<UsbView>();
  UsbView view = UsbView(
    closed: false,
    devices: [
      NativeDevice(
        id: 'opaque-device',
        name: 'Phone 日本語',
        storages: [
          NativeStorage(
            id: 'opaque-storage',
            name: 'Internal storage',
            freeBytes: BigInt.from(4096),
          ),
        ],
      ),
    ],
  );
  @override
  Future<LibraryInfo> crateBridgeDeviceSyncLibraryInfo({
    required String library_,
  }) async => LibraryInfo(
    handle: library_,
    libraryUuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    generation: BigInt.zero,
  );

  @override
  Future<HostInfo> crateBridgeDeviceSyncHostUsb({
    required String library_,
    required String name,
    ApplicationBuild? appBuild,
  }) async => const HostInfo(handle: 'usb-host', invitation: 'temporary-qr');

  @override
  Future<UsbView> crateBridgeDeviceSyncUsbView({
    required String endpoint,
  }) async => view;

  @override
  Future<void> crateBridgeDeviceSyncUsbSelect({
    required String endpoint,
    required String device,
    required String storage,
  }) async {
    expect(endpoint, 'usb-host');
    selected.add((device, storage));
  }

  @override
  Future<void> crateBridgeDeviceSyncCancelSignal({
    required String endpoint,
  }) async => cancelSignals++;

  @override
  Future<UsbView> crateBridgeDeviceSyncUsbWaitClosed({
    required String endpoint,
  }) {
    waits++;
    return finished.future;
  }

  @override
  Future<EndpointRead> crateBridgeDeviceSyncReadEndpoint({
    required String endpoint,
  }) async {
    final progress = ProgressView(
      workStage: WorkStage.idle,
      workActive: false,
      scannedItems: BigInt.zero,
    );
    final terminal =
        stage == driver.State.completed ||
        stage == driver.State.completedUnconfirmed ||
        stage == driver.State.cancelled ||
        stage == driver.State.failed;
    return EndpointRead(
      progress: progress,
      value: EndpointView(
        pairing: terminal ? PairingStage.terminal : PairingStage.handshaking,
        confirmationAvailable: false,
        transport: TransportKind.usb,
        host: true,
        controller: false,
        phoneControlled: true,
        previewApproved: false,
        accountsConsentAuthorized: false,
        source: false,
        stage: stage,
        terminal: terminal,
        cleanupPending: false,
        progress: progress,
      ),
    );
  }

  @override
  Future<EndpointStatus> crateBridgeDeviceSyncStatus({
    required String endpoint,
  }) async => EndpointStatus(
    state: stage.name,
    terminal: [
      driver.State.completed,
      driver.State.completedUnconfirmed,
      driver.State.cancelled,
      driver.State.failed,
      driver.State.recoveryPending,
    ].contains(stage),
    source: false,
    includeAccounts: false,
    overwrite: false,
    session: 'synthetic-usb-session',
    cleanupPending: false,
  );

  @override
  Future<void> crateBridgeDeviceSyncShutdown({
    required String endpoint,
  }) async {}

  @override
  Future<void> crateBridgeDeviceSyncCloseEndpoint({
    required String endpoint,
  }) async {
    if (closeFailure case final failure?) throw failure;
    closedEndpoints++;
  }

  @override
  Future<void> crateBridgeDeviceSyncCloseLibrary({
    required String library_,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation ${invocation.memberName}');
}
