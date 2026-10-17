import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/headless.dart';
import 'package:squid_album/src/rust/device_sync/connection.dart';
import 'package:squid_album/src/rust/device_sync/read_model.dart';
import 'package:squid_album/src/rust/device_sync/work.dart';
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/ui/device_sync/backup_page.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;
import 'controlled_backups_test.dart' show BackupNativeBoundary;
import 'device_sync_page_test.dart' show pageApp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CloseNative native;
  late DeviceSyncStartupLifecycle lifecycle;
  late AccountWorkGate gate;
  setUp(() async {
    native = _CloseNative();
    RustLib.initMock(api: native);
    gate = AccountWorkGate();
    lifecycle = DeviceSyncStartupLifecycle(
      gate: gate,
      openLibrary: () async => 'owned-library',
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
    native.restoreCloseFailure = null;
    native.endpointCloseFailure = null;
    native.libraryCloseFailure = null;
    native.releasePending();
    // A RED can leave the old owner's rejected close cached. The assertions
    // above own that failure; retain no asynchronous test work afterward.
    await lifecycle.close().then<void>((_) {}, onError: (Object _) {});
    RustLib.dispose();
  });

  test(
    'late opening retirement failure is reported after native takeover',
    () async {
      final service = lifecycle.service;
      native.hostRelease = Completer<void>();
      final opened = service
          .hostUsb(name: 'Desktop')
          .then<Object?>(
            (value) => value,
            onError: (Object failure) => failure,
          );
      await native.hostEntered.future;
      final first = native.endpointCloseFailure = StateError(
        'late endpoint close',
      );
      final closing = lifecycle.close().then<Object?>(
        (_) => null,
        onError: (Object failure) => failure,
      );
      await Future<void>.delayed(Duration.zero);
      expect(native.libraryCloses, 0);
      native.hostRelease!.complete();
      expect(await opened, same(first));
      expect(await closing, same(first));
      expect(native.libraryCloses, 1);
    },
  );

  test('earlier late-opening failure keeps its stack ahead of a later browser failure', () async {
    final service = lifecycle.service;
    final browser = service.openBackups();
    await browser.prepareRestore((await browser.page()).items.last);
    final retireBrowser = Completer<void>();
    native.restoreCloseWait = retireBrowser.future;
    final second = native.restoreCloseFailure = StateError(
      'later browser retirement',
    );
    native.hostRelease = Completer<void>();
    final opened = service
        .hostUsb(name: 'Desktop')
        .then<Object?>((value) => value, onError: (Object failure) => failure);
    await native.hostEntered.future;
    final first = native.endpointCloseFailure = StateError(
      'earlier late opening',
    );
    Object? failure;
    StackTrace? failureStack;
    var ended = false;
    final closing = lifecycle.close().then<void>(
      (_) {
        ended = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        failureStack = stack;
        ended = true;
      },
    );
    native.hostRelease!.complete();
    expect(await opened, same(first));
    expect(ended, isFalse);
    retireBrowser.complete();
    await closing;
    expect(failure, same(first), reason: 'Later browser failure: $second');
    expect(failureStack.toString(), contains('synthetic-late-opening-stack'));
    expect(native.libraryCloses, 0);
    native.restoreCloseFailure = null;
    native.endpointCloseFailure = null;
    await lifecycle.close();
    expect(native.libraryCloses, 1);
  });

  test(
    'formal close waits actual picker retirement despite another group error',
    () async {
      const channel = MethodChannel('io.github.cypas.nsoalbum/device_sync_saf');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final selected = Completer<void>(), selectEntered = Completer<void>();
      final cancelled = Completer<void>(), cancelEntered = Completer<void>();
      var providerDrained = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'selectTree':
            selectEntered.complete();
            await selected.future;
          case 'cancel':
            if (!cancelEntered.isCompleted) cancelEntered.complete();
            await cancelled.future;
            providerDrained = true;
            if (!selected.isCompleted) selected.complete();
          default:
            fail('Unexpected OS operation ${call.method}');
        }
        return null;
      });
      final browser = lifecycle.service.openBackups();
      final shown = await browser.prepareRestore(
        (await browser.page()).items.last,
      );
      final attempt = lifecycle.service.prepareUsbClient(
        invitation: 'synthetic',
        name: 'Phone',
      );
      final connecting = attempt.connect().then<Object?>(
        (value) => value,
        onError: (Object failure) => failure,
      );
      await selectEntered.future;
      native.applyRelease = Completer<void>();
      final applying = browser
          .confirmRestore(shown)
          .then<Object?>(
            (value) => value,
            onError: (Object failure) => failure,
          );
      await native.applyEntered.future;
      final first = native.cancelFailure = StateError(
        'first browser cancellation',
      );
      var ended = false;
      final closing = lifecycle.close().then<Object?>(
        (_) {
          ended = true;
          return null;
        },
        onError: (Object failure) {
          ended = true;
          return failure;
        },
      );
      await cancelEntered.future;
      native.applyRelease!.complete();
      await applying;
      await Future<void>.delayed(Duration.zero);
      try {
        expect(ended, isFalse);
        expect(providerDrained, isFalse);
        expect(native.libraryCloses, 0);
      } finally {
        cancelled.complete();
        await connecting;
        expect(await closing, same(first));
        messenger.setMockMethodCallHandler(channel, null);
      }
      expect(providerDrained, isTrue);
      expect(native.hostCalls, 0);
      expect(native.libraryCloses, 1);
    },
  );

  test('failed summary retains exact preview and blocks library until explicit cleanup', () async {
    final browser = lifecycle.service.openBackups();
    final entry = (await browser.page()).items.last;
    final first = native.summaryFailure = StateError('summary read failed');
    final retirement = native.restoreCloseFailure = StateError(
      'preview close failed',
    );
    await expectLater(browser.prepareRestore(entry), throwsA(same(first)));
    expect(browser.preview, isNull);
    await expectLater(lifecycle.close(), throwsA(same(retirement)));
    expect(browser.settled, isFalse);
    expect(native.libraryCloses, 0);
    await expectLater(lifecycle.close(), throwsA(same(retirement)));
    expect(native.libraryCloses, 0);
    native.restoreCloseFailure = null;
    await lifecycle.close();
    expect(browser.settled, isTrue);
    expect(native.closedRestores, ['owned-restore-1']);
    expect(native.summaryReads, 1);
    expect(native.applies, 0);
    expect(native.libraryCloses, 1);
  });

  test('unreturned native preview remains owned until explicit retirement succeeds', () async {
    final browser = lifecycle.service.openBackups();
    final entry = (await browser.page()).items.last;
    native.wrongPreviewLibrary = true;
    final retirement = native.restoreCloseFailure = StateError(
      'unreturned preview retirement',
    );
    await expectLater(
      browser.prepareRestore(entry),
      throwsA(isA<AccountPreviewChanged>()),
    );
    await expectLater(lifecycle.close(), throwsA(same(retirement)));
    expect(native.libraryCloses, 0);
    expect(native.closedRestores, isEmpty);
    native.restoreCloseFailure = null;
    await lifecycle.close();
    expect(native.closedRestores, ['owned-restore-1']);
    expect(native.restoreOpens, 1);
    expect(native.applies, 0);
    expect(native.libraryCloses, 1);
  });

  test('formal close retains first error stack across endpoint and library failures', () async {
    await lifecycle.service.hostUsb(name: 'Desktop');
    final first = native.endpointCancelFailure = StateError(
      'first cancel error',
    );
    native.endpointCloseFailure = StateError('later endpoint error');
    native.libraryCloseFailure = StateError('later library error');
    Object? result;
    StackTrace? resultStack;
    try {
      await lifecycle.close();
    } catch (failure, stack) {
      result = failure;
      resultStack = stack;
    }
    expect(result, same(first));
    expect(resultStack.toString(), contains('synthetic-first-cancel-stack'));
    expect(native.libraryCloseAttempts, 1);
    expect(lifecycle.phase, DeviceStartupPhase.closing);
    native.endpointCancelFailure = null;
    native.libraryCloseFailure = null;
    final cancels = native.endpointCancels;
    await lifecycle.close();
    expect(native.libraryCloses, 1);
    expect(
      native.endpointCancels,
      cancels,
      reason: 'No command or write replay.',
    );
  });

  test(
    'formal close is single flight even during its closing notification',
    () async {
      await lifecycle.service.hostUsb(name: 'Desktop');
      native.libraryCloseRelease = Completer<void>();
      Future<void>? reentrant;
      lifecycle.addListener(() {
        if (lifecycle.phase == DeviceStartupPhase.closing) {
          reentrant ??= lifecycle.close();
        }
      });
      final first = lifecycle.close();
      expect(reentrant, same(first));
      expect(lifecycle.close(), same(first));
      await Future<void>.delayed(Duration.zero);
      try {
        expect(native.libraryCloseAttempts, 1);
        expect(native.libraryCloses, 0);
        await expectLater(lifecycle.start(), throwsA(isA<DeviceSyncBusy>()));
      } finally {
        native.libraryCloseRelease!.complete();
        await first;
      }
      await lifecycle.close();
      expect(native.libraryCloses, 1);
      expect(native.libraryCloseAttempts, 1);
    },
  );

  test('exact preview cleanup is single flight and never restores confirmation eligibility', () async {
    final coordinator = DeviceAccountCoordinator(
      library: 'owned-library',
      storage: MemoryAccountStorage(),
      gate: gate,
      invalidate: (_) async {},
      publish: (_) {},
    );
    final raw = await coordinator.previewRestore(BackupNativeBoundary.backup);
    final release = Completer<void>();
    native.restoreCloseWait = release.future;
    final first = native.restoreCloseFailure = StateError('retirement failure');
    final closing = coordinator.discardRestorePreview(raw);
    final result = closing.then<Object?>(
      (_) => null,
      onError: (Object failure) => failure,
    );
    expect(coordinator.discardRestorePreview(raw), same(closing));
    await native.restoreCloseEntered.future;
    expect(native.restoreCloseCalls, 1);
    release.complete();
    expect(await result, same(first));
    expect(coordinator.restorePreviewsSettled, isFalse);
    await expectLater(
      coordinator.confirmRestore(raw, authorized: true),
      throwsA(isA<AccountPreviewChanged>()),
    );
    expect(native.applies, 0);
    native.restoreCloseFailure = null;
    await coordinator.discardRestorePreview(raw);
    expect(coordinator.restorePreviewsSettled, isTrue);
    expect(native.closedRestores, ['owned-restore-1']);
  });

  test('formal close preserves a browser error but drains the other session observer before native library close', () async {
    final session = await lifecycle.service.hostUsb(name: 'Desktop');
    native.readRelease = Completer<void>();
    final observing = session.refresh().then<Object?>(
      (value) => value,
      onError: (Object failure) => failure,
    );
    await native.readEntered.future;
    final browser = lifecycle.service.openBackups();
    final entry = (await browser.page()).items.last;
    final shown = await browser.prepareRestore(entry);
    native.applyRelease = Completer<void>();
    final applying = browser
        .confirmRestore(shown)
        .then<Object?>((value) => value, onError: (Object failure) => failure);
    await native.applyEntered.future;
    final first = native.cancelFailure = StateError('first cancel failure');
    var finished = false;
    final closing = lifecycle.close().then<Object?>(
      (_) {
        finished = true;
        return null;
      },
      onError: (Object failure) {
        finished = true;
        return failure;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    native.applyRelease!.complete();
    await applying;
    await Future<void>.delayed(Duration.zero);
    try {
      expect(
        finished,
        isFalse,
        reason: 'The other resource group still owns a native observation.',
      );
      expect(native.endpointCancels, greaterThan(0));
      expect(native.libraryCloses, 0);
    } finally {
      native.readRelease!.complete();
      await observing;
      expect(await closing, same(first));
    }
    expect(native.endpointCloses, 1);
    expect(native.libraryCloses, 1);
    expect(gate.normalPermit, throwsA(isA<DeviceSyncBusy>()));
  });

  test(
    'formal-first endpoint error still reaches native library retirement',
    () async {
      await lifecycle.service.hostUsb(name: 'Desktop');
      final first = native.endpointCloseFailure = StateError(
        'first endpoint retirement failure',
      );
      final result = await lifecycle.close().then<Object?>(
        (_) => null,
        onError: (Object failure) => failure,
      );
      expect(result, same(first));
      expect(native.libraryCloses, 1);
      native.endpointCloseFailure = null;
      await lifecycle.close();
      expect(
        native.libraryCloses,
        1,
        reason: 'No native library reopen or replay.',
      );
    },
  );

  test('page-first endpoint error keeps original native library takeover reachable', () async {
    final session = await lifecycle.service.hostUsb(name: 'Desktop');
    final failure = native.endpointCloseFailure = StateError('page retirement');
    await expectLater(session.close(), throwsA(same(failure)));
    expect(session.settled, isFalse);
    await lifecycle.close();
    expect(native.libraryCloses, 1);
  });

  testWidgets(
    'real backup page waits its restore and reports first close error then allows explicit safe return',
    (tester) async {
      final browser = lifecycle.service.openBackups();
      await openBackup(tester, browser);
      await prepareBackup(tester);
      native.applyRelease = Completer<void>();
      native.cancelFailure = StateError('cancel signal failed');
      try {
        await confirmBackup(tester);
        await pumpUntil(tester, () => native.applyEntered.isCompleted);
        expect(native.applyEntered.isCompleted, isTrue);
        gate.holdRecovery();
        await tester.tap(find.byTooltip('Back'));
        await tester.pump();
        await tester.tap(find.byTooltip('Back'));
        await tester.pump();
        expect(find.byType(DeviceSyncBackupPage), findsOneWidget);
        expect(native.closedRestores, isEmpty);
      } finally {
        native.releasePending();
      }
      await pumpUntil(tester, () => native.closedRestores.isNotEmpty);
      await tester.pump();
      expect(native.closedRestores, ['owned-restore-1']);
      expect(find.textContaining('operation did not complete'), findsOneWidget);
      expect(find.byType(DeviceSyncBackupPage), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceSyncBackupPage), findsNothing);
      expect(gate.recoveryRequired, isTrue);
      expect(native.applies, 1);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets('old backup close callback cannot pop a newer route', (
    tester,
  ) async {
    final browser = lifecycle.service.openBackups();
    await openBackup(tester, browser);
    await prepareBackup(tester);
    final release = Completer<void>();
    native.restoreCloseWait = release.future;
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    final navigator = Navigator.of(
      tester.element(find.byType(DeviceSyncBackupPage)),
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('new route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    release.complete();
    await tester.pumpAndSettle();
    expect(find.text('new route'), findsOneWidget);
    expect(browser.settled, isTrue);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byType(DeviceSyncBackupPage), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceSyncBackupPage), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('one browser cleanup leaves another exact preview usable', () async {
    final a = lifecycle.service.openBackups(),
        b = lifecycle.service.openBackups();
    await a.prepareRestore((await a.page()).items.last);
    final shownB = await b.prepareRestore((await b.page()).items.last);
    await a.close();
    expect(a.settled, isTrue);
    expect(b.settled, isFalse);
    expect(b.preview, same(shownB));
    expect(native.closedRestores, ['owned-restore-1']);
    await b.confirmRestore(shownB);
    expect(native.applies, 1);
    expect(native.closedRestores, ['owned-restore-1', 'owned-restore-2']);
  });

  testWidgets(
    'failed preview retirement cannot leave until exact owned cleanup succeeds',
    (tester) async {
      final browser = lifecycle.service.openBackups();
      await openBackup(tester, browser);
      await prepareBackup(tester);
      native.restoreCloseFailure = StateError('preview retirement failed');
      final release = Completer<void>();
      native.restoreCloseWait = release.future;
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      expect(find.byType(DeviceSyncBackupPage), findsOneWidget);
      expect(native.closedRestores, isEmpty);
      release.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceSyncBackupPage), findsOneWidget);
      expect(native.closedRestores, isEmpty);
      native.restoreCloseFailure = null;
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceSyncBackupPage), findsNothing);
      expect(native.closedRestores, ['owned-restore-1']);
      expect(native.applies, 0);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'consumed restore with native retirement failure cannot be mistaken for safe page close',
    (tester) async {
      final browser = lifecycle.service.openBackups();
      await openBackup(tester, browser);
      await prepareBackup(tester);
      native.restoreCloseFailure = StateError(
        'consumed restore retirement failed',
      );
      await confirmBackup(tester);
      await tester.pumpAndSettle();
      expect(native.applies, 1);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceSyncBackupPage), findsOneWidget);
      expect(native.closedRestores, isEmpty);
      native.restoreCloseFailure = null;
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceSyncBackupPage), findsNothing);
      expect(native.applies, 1, reason: 'Cleanup never repeats restoration.');
      expect(native.closedRestores, ['owned-restore-1']);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Future<void> openBackup(
  WidgetTester tester,
  DeviceBackupBrowserController browser,
) async {
  await tester.pumpWidget(
    pageApp(
      builder: (_) => DeviceSyncBackupPage(browser: browser, mobile: false),
    ),
  );
  await tester.tap(find.byKey(const Key('open-page')));
  await tester.pumpAndSettle();
}

Future<void> prepareBackup(WidgetTester tester) async {
  final preview = find.byKey(const Key('device-backup-preview-2'));
  await tester.ensureVisible(preview);
  await tester.tap(preview);
  await tester.pumpAndSettle();
}

Future<void> confirmBackup(WidgetTester tester) async {
  final button = find.byKey(const Key('device-confirm-restore'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
  await tester.tap(button);
  await tester.pump();
}

Future<void> pumpUntil(WidgetTester tester, bool Function() predicate) async {
  for (var i = 0; i < 100 && !predicate(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

class _CloseNative extends BackupNativeBoundary {
  Completer<void>? hostRelease;
  final hostEntered = Completer<void>();
  int hostCalls = 0;
  bool wrongPreviewLibrary = false;
  Object? endpointCancelFailure;
  int libraryCloseAttempts = 0;
  Completer<void>? libraryCloseRelease;
  Completer<void>? readRelease;
  final readEntered = Completer<void>();
  bool reading = false;
  int endpointCancels = 0, endpointCloses = 0, libraryCloses = 0;
  Object? endpointCloseFailure, libraryCloseFailure;
  void releasePending() {
    for (final pending in [
      readRelease,
      applyRelease,
      hostRelease,
      libraryCloseRelease,
    ]) {
      if (pending != null && !pending.isCompleted) pending.complete();
    }
  }

  @override
  Future<RestoreInfo> crateBridgeDeviceSyncPreviewRestore({
    required String library_,
    required String backup,
  }) async {
    final info = await super.crateBridgeDeviceSyncPreviewRestore(
      library_: library_,
      backup: backup,
    );
    if (!wrongPreviewLibrary) return info;
    return RestoreInfo(
      handle: info.handle,
      operation: info.operation,
      library_: 'foreign-library',
      binding: info.binding,
      currentDigest: info.currentDigest,
      restoredDigest: info.restoredDigest,
    );
  }

  @override
  Future<HostInfo> crateBridgeDeviceSyncHostUsb({
    required String library_,
    required String name,
    ApplicationBuild? appBuild,
  }) async {
    hostCalls++;
    if (!hostEntered.isCompleted) hostEntered.complete();
    await hostRelease?.future;
    return const HostInfo(handle: 'owned-endpoint', invitation: 'synthetic-qr');
  }

  @override
  Future<void> crateBridgeDeviceSyncCancelSignal({
    required String endpoint,
  }) async {
    endpointCancels++;
    if (endpointCancelFailure case final failure?) {
      Error.throwWithStackTrace(
        failure,
        StackTrace.fromString('synthetic-first-cancel-stack'),
      );
    }
  }

  @override
  Future<void> crateBridgeDeviceSyncShutdown({
    required String endpoint,
  }) async {}
  @override
  Future<void> crateBridgeDeviceSyncCloseEndpoint({
    required String endpoint,
  }) async {
    if (endpointCloseFailure case final failure?) {
      Error.throwWithStackTrace(
        failure,
        StackTrace.fromString('synthetic-late-opening-stack'),
      );
    }
    endpointCloses++;
  }

  @override
  Future<void> crateBridgeDeviceSyncCloseLibrary({
    required String library_,
  }) async {
    expect(reading, isFalse);
    libraryCloseAttempts++;
    await libraryCloseRelease?.future;
    if (libraryCloseFailure case final failure?) throw failure;
    libraryCloses++;
  }

  @override
  Future<EndpointRead> crateBridgeDeviceSyncReadEndpoint({
    required String endpoint,
  }) async {
    reading = true;
    if (!readEntered.isCompleted) readEntered.complete();
    try {
      await readRelease?.future;
      final progress = ProgressView(
        workStage: WorkStage.idle,
        workActive: false,
        scannedItems: BigInt.zero,
      );
      return EndpointRead(
        progress: progress,
        value: EndpointView(
          pairing: PairingStage.handshaking,
          confirmationAvailable: false,
          transport: TransportKind.usb,
          host: true,
          controller: false,
          phoneControlled: true,
          previewApproved: false,
          accountsConsentAuthorized: false,
          source: false,
          stage: driver.State.pairing,
          terminal: false,
          cleanupPending: false,
          progress: progress,
        ),
      );
    } finally {
      reading = false;
    }
  }
}
