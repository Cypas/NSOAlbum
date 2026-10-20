import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/backend/device_sync/usb_saf_owner.dart';
import 'package:squid_album/src/platform/device_sync_saf.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/frb_generated.dart';

import 'local_apply_boundary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStorage storage;
  late LocalNativeBoundary native;
  late AccountWorkGate gate;
  late DeviceAccountCoordinator coordinator;
  late DeviceSyncStartupLifecycle owner;
  setUp(() async {
    storage = LocalStorage();
    native = LocalNativeBoundary(storage);
    RustLib.initMock(api: native);
    gate = AccountWorkGate();
    owner = DeviceSyncStartupLifecycle(
      gate: gate,
      openLibrary: () async => 'owned-library',
      coordinator: (library) => coordinator = DeviceAccountCoordinator(
        library: library,
        storage: storage,
        gate: gate,
        invalidate: (_) async {},
        publish: (_) {},
      ),
      initialize: () async {},
      isolated: false,
    );
    await owner.start();
  });
  tearDown(() async {
    await owner.close();
    RustLib.dispose();
  });

  test('genuine GrantIssued releases the original source gate before ACK or terminal', () async {
    native.source = true;
    native.stage = driver.State.awaitingAccountFinal;
    await coordinator.authorizeSource('source', authorized: true);
    await coordinator.authorizeFinalSource('source');
    expect(gate.busy, isTrue);
    expect(native.grantIssued, isTrue);
    expect(native.terminal, isFalse);
    try {
      await coordinator.releaseSource('source');
      expect(gate.busy, isFalse);
      expect(storage.values[selectedAccountKey], 'old');
      final normal = gate.normalPermit();
      normal.release();
    } finally {
      native.stage = driver.State.completedUnconfirmed;
      await coordinator.releaseSource('source');
    }
  });

  test(
    'close native-settles before awaiting an admitted protected OS write',
    () async {
      final session = await _pending(owner, native);
      storage.writeEntered = Completer<void>();
      storage.writeRelease = Completer<void>();
      final applying = session.refresh();
      await storage.writeEntered!.future;
      final closing = session.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final settledBeforeWriteReturned = native.nativeSettled.isCompleted;
      storage.writeRelease!.complete();
      await applying;
      await closing;
      expect(
        settledBeforeWriteReturned,
        isTrue,
        reason: 'native shutdown must not wait Dart write/gate/future advance',
      );
      expect(native.journalStage, 'rolled_back');
      expect(native.libraryRecords, ['old media']);
      expect(storage.values[accountTokensKey], '{"old":"synthetic-old"}');
      expect(native.compensations, 1);
      expect(gate.busy, isFalse);
      expect(native.events.last, 'retire');
    },
  );

  for (final failure in ['next', 'complete']) {
    test(
      'unknown SAF $failure return detaches transport and original coordinator finalizes',
      () async {
        final session = await _pending(owner, native);
        final channel = MethodChannel('local-apply-$failure');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              channel,
              (call) async => call.method == 'listBlocks' ? <String>[] : null,
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final saf = DeviceSyncSaf(channel: channel);
        await saf.openSession('a' * 32, 'b' * 32);
        native.usbNextFails = failure == 'next';
        native.usbCompleteFails = failure == 'complete';
        final transport = await DeviceSyncUsbSafOwner(
          endpoint: 'local-endpoint',
          saf: saf,
        ).run().timeout(const Duration(seconds: 3));
        expect(transport.closed, isTrue);
        await session.refresh();
        expect(native.journalStage, 'finalized');
        expect(native.libraryRecords, ['incoming media']);
        expect(storage.values[accountTokensKey], contains('synthetic-new'));
        expect(native.checked, greaterThan(1));
        expect(native.steps, greaterThan(1));
        expect(native.compensations, 0);
        expect(native.cache, [1, 2, 3, 4]);
        expect(gate.busy, isFalse);
      },
    );
  }

  test('durable finalized journal wins over lost return and later native cleanup failure', () async {
    final session = await _pending(owner, native);
    native.lostFinalizeReturn = true;
    native.failShutdown = true;
    try {
      final result = await coordinator.applyPending('local-endpoint');
      expect(result.finalized, isTrue);
      expect(result.cleanupPending, isTrue);
      expect(native.journalStage, 'finalized');
      expect(native.libraryRecords, ['incoming media']);
      expect(storage.values[accountTokensKey], contains('synthetic-new'));
      expect(native.compensations, 0);
      expect(
        gate.transferActive,
        isTrue,
        reason: 'The session has not observed its terminal state yet.',
      );
      await session.refresh();
      expect(gate.busy, isFalse);
    } finally {
      native.failShutdown = false;
      await session.close();
    }
  });

  test('owned SAF failure remains a transport issue while same session completes local accounts', () async {
    const channel = MethodChannel('io.github.cypas.nsoalbum/device_sync_saf');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    native.usbNextRelease = Completer<void>();
    final session = await owner.service
        .prepareUsbClient(invitation: 'synthetic', name: 'Synthetic')
        .connect();
    await _pending(owner, native, session: session);
    native.usbNextFails = true;
    native.usbNextRelease!.complete();
    await native.usbClosed.future;
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await session.refresh();
    expect(native.journalStage, 'finalized');
    expect(
      session.issue,
      isNull,
      reason: 'transport failure must not become a local task failure',
    );
    expect(session.transportIssue, isNotNull);
    expect(native.compensations, 0);
    expect(gate.busy, isFalse);
    await session.close();
  });

  test('finalized archive failure is a cleanup warning rather than operation failure', () async {
    final session = await _pending(owner, native);
    storage.failArchive = true;
    await session.refresh();
    expect(native.journalStage, 'finalized');
    expect(session.issue, isNull);
    expect(session.localCleanupPending, isTrue);
    expect(storage.values[accountTokensKey], contains('synthetic-new'));
    expect(gate.busy, isFalse);
  });

  for (var nth = 1; nth <= 4; nth++) {
    test(
      'protected active key $nth failure restores actual old media and all account keys',
      () async {
        final session = await _pending(owner, native);
        storage.failActiveMutation = nth;
        await session.refresh();
        expect(native.journalStage, 'rolled_back');
        expect(native.libraryRecords, ['old media']);
        expect(await readRawAccountKeys(storage), {
          legacySessionKey: null,
          accountTokensKey: '{"old":"synthetic-old"}',
          accountProfilesKey: null,
          selectedAccountKey: 'old',
        });
        expect(native.cache, [1, 2, 3, 4]);
        expect(native.compensations, 1);
        expect(gate.busy, isFalse);
      },
    );
  }

  test('close with no admitted drive compensates AwaitingExternal once without a future refresh', () async {
    final session = await _pending(owner, native);
    await Future.wait([
      session.close(),
      coordinator.abort('local-endpoint'),
      coordinator.abort('local-endpoint'),
    ]);
    expect(native.journalStage, 'rolled_back');
    expect(native.libraryRecords, ['old media']);
    expect(storage.values[accountTokensKey], '{"old":"synthetic-old"}');
    expect(native.compensations, 1);
    expect(native.cache, [1, 2, 3, 4]);
    expect(gate.busy, isFalse);
    expect(native.events.last, 'retire');
  });

  test('unknown native settle retains the original pending permit until its owner retries compensation', () async {
    final session = await _pending(owner, native);
    storage.failActiveMutation = 2;
    native.failShutdown = true;
    await expectLater(
      coordinator.applyPending('local-endpoint'),
      throwsStateError,
    );
    expect(gate.recoveryRequired, isTrue);
    expect(native.journalStage, 'library_applied');
    expect(native.compensations, 0);
    expect(() => gate.normalPermit(), throwsA(isA<DeviceSyncBusy>()));
    native.failShutdown = false;
    await coordinator.abort('local-endpoint');
    expect(native.journalStage, 'rolled_back');
    expect(native.compensations, 1);
    await session.refresh();
    expect(gate.busy, isFalse);
    await session.close();
  });

  test('GrantIssued from a changed source session or binding cannot release the original gate', () async {
    native.source = true;
    native.stage = driver.State.awaitingAccountFinal;
    await coordinator.authorizeSource('source', authorized: true);
    await coordinator.authorizeFinalSource('source');
    final session = native.session;
    native.session = 'late-new-session';
    await expectLater(
      coordinator.releaseSource('source'),
      throwsA(isA<AccountPreviewChanged>()),
    );
    expect(gate.busy, isTrue);
    native.session = session;
    native.binding = 'late-new-binding';
    await expectLater(
      coordinator.releaseSource('source'),
      throwsA(isA<AccountPreviewChanged>()),
    );
    expect(gate.busy, isTrue);
    native.binding = localBinding;
    await coordinator.releaseSource('source');
    expect(gate.busy, isFalse);
    expect(storage.values[selectedAccountKey], 'old');
  });

  test('source with genuine nullable receiver operation releases only its own issued binding', () async {
    native.source = true;
    native.sourceOperation = null;
    native.stage = driver.State.awaitingAccountFinal;
    await coordinator.authorizeSource('source', authorized: true);
    await coordinator.authorizeFinalSource('source');
    native.sourceOperation = localOperation;
    await expectLater(
      coordinator.releaseSource('source'),
      throwsA(isA<AccountPreviewChanged>()),
    );
    expect(gate.busy, isTrue);
    native.sourceOperation = null;
    await coordinator.releaseSource('source');
    expect(gate.busy, isFalse);
    expect(storage.values[selectedAccountKey], 'old');
  });

  test('failed compensation keeps endpoint owned and a second close retries only original cleanup', () async {
    final session = await _pending(owner, native);
    native.failCompensation = true;
    await expectLater(session.close(), throwsA(isA<AccountRecoveryRequired>()));
    final retiredBeforeRetry = native.retired;
    final settledBeforeRetry = session.settled;
    final journalBeforeRetry = native.journalStage;
    native.failCompensation = false;
    final retryFailure = await session.close().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    // Leave the test boundary safe even when the current close cannot retry.
    if (retryFailure != null) await coordinator.abort('local-endpoint');
    expect(
      retiredBeforeRetry,
      isFalse,
      reason: 'command address must survive unproven coordinator cleanup',
    );
    expect(settledBeforeRetry, isFalse);
    expect(journalBeforeRetry, 'library_applied');
    expect(native.cache, [1, 2, 3, 4]);
    expect(retryFailure, isNull);
    expect(native.journalStage, 'rolled_back');
    expect(native.libraryRecords, ['old media']);
    expect(native.compensations, 1);
    expect(native.retired, isTrue);
    expect(session.settled, isTrue);
    expect(gate.recoveryRequired, isFalse);
  });

  test('unknown native domain stays unknown and cannot grant or cancel local account work', () async {
    final session = await _pending(owner, native);
    native.detached = true;
    native.readUnavailable = true;
    final unknown = await session.refresh();
    expect(unknown.value, isNull);
    expect(native.journalStage, 'library_applied');
    expect(native.checked, 0);
    expect(native.cancelled, isFalse);
    expect(gate.busy, isTrue);
    native.readUnavailable = false;
    await session.refresh();
    expect(native.journalStage, 'finalized');
    expect(gate.busy, isFalse);
  });
  test('startup close retries retained original session cleanup through the service facade', () async {
    final session = await _pending(owner, native);
    native.failCompensation = true;
    final first = await owner.close().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    final closedBeforeRetry = native.libraryClosed;
    final retiredBeforeRetry = native.retired;
    expect(() => session.confirmPairing(), throwsA(isA<DeviceSyncBusy>()));
    native.failCompensation = false;
    await owner.close();
    expect(first, isA<AccountRecoveryRequired>());
    expect(closedBeforeRetry, isFalse);
    expect(retiredBeforeRetry, isFalse);
    expect(owner.phase, DeviceStartupPhase.closed);
    expect(native.journalStage, 'rolled_back');
    expect(native.compensations, 1);
    expect(native.retired, isTrue);
    expect(native.libraryClosed, isTrue);
    expect(native.events.last, 'library-retire');
  });
}

Future<DeviceSyncSession> _pending(
  DeviceSyncStartupLifecycle owner,
  LocalNativeBoundary native, {
  DeviceSyncSession? session,
}) async {
  session ??= await owner.service.hostWifi(
    address: '192.168.1.2',
    name: 'Synthetic',
  );
  await session.refresh();
  await session.confirmPairing();
  await session.configure(
    phoneToDesktop: false,
    overwrite: true,
    includeAccounts: true,
  );
  await session.refresh();
  await session.consentAccounts(accepted: true);
  final preview = await session.refreshPreview();
  await session.approvePreview(preview);
  await session.refresh(); // real coordinator reserve/readbacks + TargetFinal.
  expect(native.installed, isTrue);
  expect(native.journalStage, 'library_applied');
  return session;
}
