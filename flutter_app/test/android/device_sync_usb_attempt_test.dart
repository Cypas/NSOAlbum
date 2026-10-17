@Tags(['platform-android'])
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/platform/device_sync_saf.dart';
import 'package:squid_album/src/rust/device_sync/headless.dart';
import 'package:squid_album/src/rust/device_sync/native_io.dart';
import 'package:squid_album/src/rust/device_sync/read_model.dart';
import 'package:squid_album/src/rust/device_sync/usb.dart';
import 'package:squid_album/src/rust/frb_generated.dart';

import '../device_sync/account_storage_test.dart' show MemoryAccountStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.cypas.nsoalbum/device_sync_saf');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _NativeBoundary native;
  late AccountWorkGate gate;
  late DeviceSyncStartupLifecycle lifecycle;
  late Completer<void> pickerEntered;
  late Completer<Object?> picker;
  late List<MethodCall> calls;

  setUp(() async {
    native = _NativeBoundary();
    RustLib.initMock(api: native);
    pickerEntered = Completer<void>();
    picker = Completer<Object?>();
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'selectTree') {
        if (!pickerEntered.isCompleted) pickerEntered.complete();
        return picker.future;
      }
      return null;
    });
    gate = AccountWorkGate();
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
    expect(lifecycle.ready, isTrue);
  });
  tearDown(() async {
    if (!picker.isCompleted) picker.complete(null);
    await lifecycle.close();
    messenger.setMockMethodCallHandler(channel, null);
    RustLib.dispose();
  });

  test('directory refusal never creates a native client endpoint', () async {
    final attempt = lifecycle.service.prepareUsbClient(
      invitation: 'synthetic-invitation',
      name: 'Phone',
    );
    expect(calls, isEmpty, reason: 'Preparing must not invoke OS I/O.');
    expect(native.clients, 0);
    final rejected = expectLater(
      attempt.connect(),
      throwsA(
        isA<DeviceSyncSafFailure>().having(
          (failure) => failure.code,
          'code',
          DeviceSyncSafError.permissionDenied,
        ),
      ),
    );
    await Future.any([pickerEntered.future, rejected]);
    expect(pickerEntered.isCompleted, isTrue);
    picker.completeError(PlatformException(code: 'DIRECTORY_NOT_AUTHORIZED'));
    await rejected;
    expect(native.clients, 0);
    expect(native.closedEndpoints, isEmpty);
    expect(lifecycle.ready, isTrue);
  });

  test(
    'cancel settles without waiting for a late physical picker result',
    () async {
      final attempt = lifecycle.service.prepareUsbClient(
        invitation: 'synthetic-invitation',
        name: 'Phone',
      );
      final rejected = expectLater(
        attempt.connect(),
        throwsA(isA<DeviceSyncBusy>()),
      );
      await Future.any([pickerEntered.future, rejected]);
      expect(pickerEntered.isCompleted, isTrue);
      await attempt.cancel().timeout(const Duration(seconds: 1));
      await rejected;
      expect(picker.isCompleted, isFalse);
      expect(calls.map((call) => call.method), ['selectTree', 'cancel']);
      expect(calls[1].arguments, calls[0].arguments);
      expect((calls[1].arguments as Map<Object?, Object?>).keys, [
        'pickerToken',
      ]);
      picker.complete(null);
      await Future<void>.delayed(Duration.zero);
      expect(native.clients, 0);
      expect(lifecycle.ready, isTrue);
    },
  );

  test(
    'formal close cancels only owned picker before waiting for openings',
    () async {
      final attempt = lifecycle.service.prepareUsbClient(
        invitation: 'synthetic-invitation',
        name: 'Phone',
      );
      final rejected = expectLater(
        attempt.connect(),
        throwsA(isA<DeviceSyncBusy>()),
      );
      await Future.any([pickerEntered.future, rejected]);
      expect(pickerEntered.isCompleted, isTrue);
      await lifecycle.close().timeout(const Duration(seconds: 1));
      await rejected;
      expect(lifecycle.phase, DeviceStartupPhase.closed);
      expect(picker.isCompleted, isFalse);
      expect(calls.map((call) => call.method), ['selectTree', 'cancel']);
      picker.complete(null);
      await Future<void>.delayed(Duration.zero);
      expect(native.clients, 0);
    },
  );

  test(
    'late native endpoint is retired after cancel instead of published',
    () async {
      native.clientResult = Completer<String>();
      final attempt = lifecycle.service.prepareUsbClient(
        invitation: 'synthetic-invitation',
        name: 'Phone',
      );
      final rejected = expectLater(
        attempt.connect(),
        throwsA(isA<DeviceSyncBusy>()),
      );
      await Future.any([pickerEntered.future, rejected]);
      expect(pickerEntered.isCompleted, isTrue);
      expect(native.clients, 0);
      picker.complete(null);
      await native.clientEntered.future;
      expect(native.clients, 1);
      final cancelling = attempt.cancel();
      native.clientResult!.complete('late-owned-endpoint');
      await cancelling;
      await rejected;
      expect(native.closedEndpoints, ['late-owned-endpoint']);
      expect(lifecycle.ready, isTrue);
    },
  );

  test('readiness loss during picker refuses client creation', () async {
    final attempt = lifecycle.service.prepareUsbClient(
      invitation: 'synthetic-invitation',
      name: 'Phone',
    );
    final rejected = expectLater(
      attempt.connect(),
      throwsA(isA<DeviceSyncBusy>()),
    );
    await pickerEntered.future;
    // The real recovery barrier, not a page-local disabled flag.
    gate.holdRecovery();
    picker.complete(null);
    await rejected;
    expect(native.clients, 0);
    expect(native.closedEndpoints, isEmpty);
  });

  test('authorized connect owns one SAF runner and page close leaves library ready', () async {
    picker.complete(null);
    final attempt = lifecycle.service.prepareUsbClient(
      invitation: 'synthetic-invitation',
      name: 'Phone',
    );
    final first = attempt.connect();
    expect(identical(first, attempt.connect()), isTrue);
    final session = await first;
    await native.completedOpen.future;
    expect(native.clients, 1);
    expect(calls.map((call) => call.method), ['selectTree', 'openSession']);
    expect(session.issue, isNull);
    await session.close();
    expect(calls.map((call) => call.method), [
      'selectTree',
      'openSession',
      'cancel',
    ]);
    expect(calls[2].arguments, calls[1].arguments);
    expect(native.closedEndpoints, ['owned-endpoint-1']);
    expect(lifecycle.ready, isTrue);
  });

  test('SAF runner admission failure is consumed immediately and retained on close', () async {
    picker.complete(null);
    final sessions = <DeviceSyncSession>[];
    try {
      for (var index = 0; index < 17; index++) {
        final attempt = lifecycle.service.prepareUsbClient(
          invitation: 'synthetic-invitation',
          name: 'Phone',
        );
        sessions.add(await attempt.connect());
      }
      // Reaching this await without an unhandled future is part of the contract.
      await Future<void>.delayed(Duration.zero);
      final rejected = sessions.removeLast();
      expect(rejected.issue, ReadError.internal);
      Object? retained;
      StackTrace? retainedStack;
      try {
        await rejected.refresh();
        fail('Capacity failure must not become a successful observation.');
      } catch (failure, stack) {
        retained = failure;
        retainedStack = stack;
      }
      expect(
        retained,
        isA<DeviceSyncSafFailure>().having(
          (failure) => failure.code,
          'code',
          DeviceSyncSafError.busy,
        ),
      );
      expect(retainedStack.toString(), contains('DeviceSyncUsbSafOwner.run'));
      await expectLater(rejected.close(), throwsA(same(retained)));
      expect(native.closedEndpoints, contains('owned-endpoint-17'));
    } finally {
      for (final session in sessions) {
        await session.close();
      }
    }
    expect(lifecycle.ready, isTrue);
  });

  test(
    'page close waits owned byte runner even when protocol abort fails',
    () async {
      picker.complete(null);
      final session = await lifecycle.service
          .prepareUsbClient(invitation: 'synthetic-invitation', name: 'Phone')
          .connect();
      await native.completedOpen.future;
      native.failShutdown = true;
      native.retiredViewRelease = Completer<void>();
      final closing = session.close().then<Object?>(
        (_) => null,
        onError: (Object failure) => failure,
      );
      await native.retiredViewEntered.future;
      await Future<void>.delayed(Duration.zero);
      try {
        expect(
          native.closedEndpoints,
          isEmpty,
          reason: 'Endpoint close must wait for the owned byte runner on failures too.',
        );
      } finally {
        native.retiredViewRelease!.complete();
        expect(await closing, isA<StateError>());
      }
      expect(native.closedEndpoints, ['owned-endpoint-1']);
      expect(lifecycle.ready, isTrue);
    },
  );
}

class _NativeBoundary implements RustLibApi {
  int clients = 0;
  final clientEntered = Completer<void>();
  Completer<String>? clientResult;
  final completedOpen = Completer<void>();
  final _actions = <String>{};
  final _next = <String, Completer<UsbAction?>>{};
  final _closed = <String, Completer<UsbView>>{};
  final _retired = <String>{};
  bool failShutdown = false;
  Completer<void>? retiredViewRelease;
  final retiredViewEntered = Completer<void>();
  final closedEndpoints = <String>[];
  @override
  Future<LibraryInfo> crateBridgeDeviceSyncLibraryInfo({
    required String library_,
  }) async => LibraryInfo(
    handle: library_,
    libraryUuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    generation: BigInt.zero,
  );

  @override
  Future<String> crateBridgeDeviceSyncClientUsb({
    required String library_,
    required String invitation,
    required String name,
  }) async {
    clients++;
    expect(library_, 'controlled-library');
    expect(invitation, 'synthetic-invitation');
    expect(name, 'Phone');
    if (!clientEntered.isCompleted) clientEntered.complete();
    return clientResult?.future ?? 'owned-endpoint-$clients';
  }

  @override
  Future<void> crateBridgeDeviceSyncCloseEndpoint({
    required String endpoint,
  }) async {
    closedEndpoints.add(endpoint);
  }

  @override
  Future<void> crateBridgeDeviceSyncCloseLibrary({
    required String library_,
  }) async {}

  @override
  Future<UsbView> crateBridgeDeviceSyncUsbWaitClosed({
    required String endpoint,
  }) => (_closed[endpoint] ??= Completer<UsbView>()).future;

  @override
  Future<UsbAction?> crateBridgeDeviceSyncUsbNext({
    required String endpoint,
  }) async {
    if (_actions.add(endpoint)) {
      return UsbAction(
        token: 'action-token',
        generation: 'generation',
        operation: 'a' * 32,
        session: 'b' * 32,
        kind: UsbActionKind.open,
        direction: Direction.mobile,
        bytes: Uint8List(0),
      );
    }
    return (_next[endpoint] ??= Completer<UsbAction?>()).future;
  }

  @override
  Future<void> crateBridgeDeviceSyncUsbComplete({
    required String endpoint,
    required UsbReply reply,
  }) async {
    expect(reply.error, isNull);
    if (!completedOpen.isCompleted) completedOpen.complete();
  }

  @override
  Future<void> crateBridgeDeviceSyncCancelSignal({
    required String endpoint,
  }) async {}

  @override
  Future<void> crateBridgeDeviceSyncShutdown({required String endpoint}) async {
    _retired.add(endpoint);
    final next = _next[endpoint];
    if (next != null && !next.isCompleted) next.complete(null);
    final closed = _closed[endpoint];
    if (closed != null && !closed.isCompleted) {
      closed.complete(
        const UsbView(
          closed: true,
          reason: UsbCloseReason.cancelled,
          devices: [],
        ),
      );
    }
    if (failShutdown) throw StateError('Synthetic native stop failure');
  }

  @override
  Future<UsbView> crateBridgeDeviceSyncUsbView({
    required String endpoint,
  }) async {
    if (!retiredViewEntered.isCompleted) retiredViewEntered.complete();
    await retiredViewRelease?.future;
    return UsbView(
      closed: _retired.contains(endpoint),
      reason: _retired.contains(endpoint) ? UsbCloseReason.cancelled : null,
      devices: const [],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation ${invocation.memberName}');
}
