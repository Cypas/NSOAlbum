import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/rust/device_sync/headless.dart';
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/rust/settings.dart';
import 'package:squid_album/src/startup/application_bootstrap.dart';
import 'package:squid_album/src/ui/device_sync/startup_page.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeBoundary native;
  setUp(() {
    native = _NativeBoundary();
    RustLib.initMock(api: native);
  });
  tearDown(RustLib.dispose);

  test(
    'failed interrupted-session cleanup keeps startup isolated until retry',
    () async {
      native.interrupted = ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'];
      native.failSessionRecovery = true;
      final backend = _Backend();
      await backend.deviceSyncStartup.start();
      expect(backend.deviceSyncStartup.ready, isFalse);
      expect(backend.deviceSyncStartup.interruptedRecovery, isTrue);
      expect(backend.initializations, 0);
      expect(native.interrupted, isNotEmpty);
      native.failSessionRecovery = false;
      await backend.deviceSyncStartup.start();
      expect(backend.deviceSyncStartup.ready, isTrue);
      expect(backend.initializations, 1);
      expect(native.interrupted, isNull);
      await backend.close();
    },
  );

  test(
    'unreadable session status cannot be interpreted as clean startup',
    () async {
      native.failIdentity = true;
      final backend = _Backend();
      await backend.deviceSyncStartup.start();
      expect(backend.deviceSyncStartup.ready, isFalse);
      expect(backend.initializations, 0);
      expect(backend.accountWorkGate.busy, isTrue);
      native.failIdentity = false;
      await backend.deviceSyncStartup.start();
      expect(backend.deviceSyncStartup.ready, isTrue);
      await backend.close();
    },
  );

  testWidgets(
    'clean startup has no data-check notice and close retains gallery',
    (tester) async {
      final backend = _Backend();
      final controller = ApplicationBootstrap(
        prepare: () async => backend,
        initializePresentation: (_) async {},
        safeMode: false,
      );
      var consumers = 0;
      await tester.pumpWidget(_app(controller, () => consumers++));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('NSOAlbum'), findsNothing);
      expect(find.text('Checking data'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Local gallery'), findsOneWidget);
      native.closeGate = Completer<void>();
      final closing = controller.close();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Local gallery'), findsOneWidget);
      expect(find.text('Closing safely'), findsNothing);
      expect(find.text('Finishing current operations'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Local gallery'), findsOneWidget);
      expect(find.text('Finishing current operations'), findsOneWidget);
      expect(consumers, 1);
      native.closeGate!.complete();
      await closing;
      await tester.pumpAndSettle();
      expect(find.text('Finishing current operations'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final language in ['zh', 'en']) {
    testWidgets('only interrupted sync shows recovery notice/$language', (
      tester,
    ) async {
      native.interrupted = ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'];
      final storage = _BlockingStorage();
      final backend = _Backend(storage: storage, language: language);
      final controller = ApplicationBootstrap(
        prepare: () async => backend,
        initializePresentation: (_) async {},
        safeMode: false,
      );
      await tester.pumpWidget(_app(controller, () {}));
      await tester.pump();
      await tester.pump();
      expect(
        find.text(
          language == 'zh'
              ? '上次同步未正常完成，正在校验数据'
              : 'The previous sync did not finish. Checking data.',
        ),
        findsOneWidget,
      );
      expect(native.recoveredSessions, isEmpty);
      storage.release.complete();
      await tester.pumpAndSettle();
      expect(native.recoveredSessions, [
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      ]);
      expect(find.text('Local gallery'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  test('settled startup publishes cleared busy to direct consumers', () async {
    final lifecycle = DeviceSyncStartupLifecycle(
      gate: AccountWorkGate(),
      openLibrary: () async => throw StateError('Isolated'),
      coordinator: (_) => throw StateError('Isolated'),
      initialize: () async {},
      isolated: true,
    );
    final observations = <({DeviceStartupPhase phase, bool busy})>[];
    lifecycle.addListener(
      () => observations.add((phase: lifecycle.phase, busy: lifecycle.busy)),
    );
    await lifecycle.start();
    expect(observations.last, (
      phase: DeviceStartupPhase.ready,
      busy: false,
    ), reason: 'The final ready listener must be able to admit tools.');
    await lifecycle.close();
  });

  test('failed startup publishes idle without claiming readiness', () async {
    final lifecycle = DeviceSyncStartupLifecycle(
      gate: AccountWorkGate(),
      openLibrary: () async => throw StateError('Isolated'),
      coordinator: (_) => throw StateError('Isolated'),
      initialize: () async => throw StateError('Synthetic initialization'),
      isolated: true,
    );
    final observations = <({DeviceStartupPhase phase, bool busy})>[];
    lifecycle.addListener(
      () => observations.add((phase: lifecycle.phase, busy: lifecycle.busy)),
    );
    await lifecycle.start();
    expect(observations.last, (phase: DeviceStartupPhase.failed, busy: false));
    expect(lifecycle.ready, isFalse);
    await lifecycle.close();
  });

  test('settled startup cannot publish ready after close begins', () async {
    final initialized = Completer<void>();
    final release = Completer<void>();
    final lifecycle = DeviceSyncStartupLifecycle(
      gate: AccountWorkGate(),
      openLibrary: () async => throw StateError('Isolated'),
      coordinator: (_) => throw StateError('Isolated'),
      initialize: () async {
        initialized.complete();
        await release.future;
      },
      isolated: true,
    );
    final observations = <({DeviceStartupPhase phase, bool busy})>[];
    lifecycle.addListener(
      () => observations.add((phase: lifecycle.phase, busy: lifecycle.busy)),
    );
    final running = lifecycle.start();
    await initialized.future;
    final closing = lifecycle.close();
    release.complete();
    await Future.wait([running, closing]);
    expect(
      observations.where((value) => value.phase == DeviceStartupPhase.ready),
      isEmpty,
    );
    expect(observations.last, (phase: DeviceStartupPhase.closed, busy: false));
  });

  test(
    'an old settled notification cannot clear a reentrant retry flight',
    () async {
      final secondStarted = Completer<void>();
      final release = Completer<void>();
      var attempts = 0;
      final lifecycle = DeviceSyncStartupLifecycle(
        gate: AccountWorkGate(),
        openLibrary: () async => throw StateError('Isolated'),
        coordinator: (_) => throw StateError('Isolated'),
        initialize: () async {
          attempts++;
          if (attempts == 1) throw StateError('First initialization');
          secondStarted.complete();
          await release.future;
        },
        isolated: true,
      );
      Future<void>? retry;
      lifecycle.addListener(() {
        if (lifecycle.phase == DeviceStartupPhase.failed &&
            !lifecycle.busy &&
            retry == null) {
          retry = lifecycle.start();
        }
      });
      await lifecycle.start();
      await secondStarted.future;
      expect(lifecycle.busy, isTrue);
      expect(lifecycle.ready, isFalse);
      release.complete();
      await retry;
      expect(lifecycle.ready, isTrue);
      expect(lifecycle.busy, isFalse);
      await lifecycle.close();
    },
  );

  test(
    'coordinator resolution cannot release a lifecycle owner barrier',
    () async {
      final gate = AccountWorkGate();
      final barrier = gate.holdStartup();
      final permit = gate.recoveryPermit();
      gate.resolveRecovery();
      permit.release();
      expect(gate.busy, isTrue);
      expect(gate.normalPermit, throwsA(isA<DeviceSyncBusy>()));
      barrier.release();
      final normal = gate.normalPermit();
      normal.release();
      expect(gate.busy, isFalse);
    },
  );

  test(
    'retry and close retain one in-flight protected-storage owner',
    () async {
      final storage = _BlockingStorage();
      final backend = _Backend(storage: storage);
      final states = <DeviceStartupPhase>[];
      backend.deviceSyncStartup.addListener(
        () => states.add(backend.deviceSyncStartup.phase),
      );
      final first = backend.deviceSyncStartup.start();
      await storage.started.future;
      final repeated = backend.deviceSyncStartup.start();
      final closing = backend.close();
      expect(backend.deviceSyncStartup.phase, DeviceStartupPhase.closing);
      expect(
        backend.accountWorkGate.normalPermit,
        throwsA(isA<DeviceSyncBusy>()),
      );
      expect(native.closes, 0);
      storage.release.complete();
      await Future.wait([first, repeated, closing]);
      expect(storage.readCount, 1);
      expect(backend.initializations, 0);
      expect(native.closes, 1);
      expect(states, isNot(contains(DeviceStartupPhase.ready)));
      expect(backend.deviceSyncStartup.phase, DeviceStartupPhase.closed);
      expect(backend.accountWorkGate.busy, isTrue);
      await backend.close();
      expect(native.closes, 1);
    },
  );

  test(
    'protected-storage failure remains gated until an explicit retry',
    () async {
      final storage = _BlockingStorage()..fail = true;
      storage.release.complete();
      final backend = _Backend(storage: storage);
      await backend.deviceSyncStartup.start();
      expect(
        backend.deviceSyncStartup.phase,
        DeviceStartupPhase.actionRequired,
      );
      expect(
        backend.deviceSyncStartup.recovery?.status,
        'protected_storage_unavailable',
      );
      expect(backend.accountWorkGate.busy, isTrue);
      expect(backend.initializations, 0);
      await Future<void>.delayed(Duration.zero);
      expect(storage.readCount, 1);
      storage.fail = false;
      await backend.deviceSyncStartup.start();
      expect(backend.deviceSyncStartup.ready, isTrue);
      expect(backend.initializations, 1);
      expect(storage.readCount, 2);
      await backend.deviceSyncStartup.start();
      expect(backend.initializations, 1);
      await backend.close();
    },
  );

  test(
    'runtime recovery invalidates historical ready and initializes once',
    () async {
      final backend = _Backend();
      final lifecycle = backend.deviceSyncStartup;
      await lifecycle.start();
      expect(backend.initializations, 1);
      backend.accountWorkGate.holdRecovery();
      expect(
        lifecycle.ready,
        isFalse,
        reason: 'Runtime recovery must invalidate a previous ready result.',
      );
      expect(() => lifecycle.service, throwsA(isA<DeviceSyncBusy>()));
      await lifecycle.start();
      expect(lifecycle.ready, isTrue);
      expect(backend.accountWorkGate.busy, isFalse);
      expect(backend.initializations, 1);
      await backend.close();
    },
  );

  test(
    'close during native identity lookup waits without starting account work',
    () async {
      native.identityGate = Completer<void>();
      final storage = MemoryAccountStorage();
      final backend = _Backend(storage: storage);
      final checking = backend.deviceSyncStartup.start();
      await native.identityStarted.future;
      final closing = backend.close();
      expect(native.closes, 0);
      expect(backend.initializations, 0);
      native.identityGate!.complete();
      await Future.wait([checking, closing]);
      expect(native.closes, 1);
      expect(backend.deviceSyncStartup.phase, DeviceStartupPhase.closed);
      expect(backend.accountWorkGate.busy, isTrue);
      expect(storage.values, isEmpty);
    },
  );

  test(
    'synchronous close from checking feedback does not open a library',
    () async {
      var opens = 0;
      final gate = AccountWorkGate();
      late DeviceSyncStartupLifecycle lifecycle;
      Future<void>? closing;
      lifecycle = DeviceSyncStartupLifecycle(
        gate: gate,
        openLibrary: () async {
          opens++;
          return 'unexpected-library';
        },
        coordinator: (_) => throw StateError('Not admitted'),
        initialize: () async => fail('Not admitted'),
        isolated: false,
      );
      lifecycle.addListener(() {
        if (lifecycle.phase == DeviceStartupPhase.checking) {
          closing = lifecycle.close();
        }
      });
      await lifecycle.start();
      await closing;
      expect(opens, 0);
      expect(lifecycle.phase, DeviceStartupPhase.closed);
      expect(gate.busy, isTrue);
    },
  );

  for (final language in ['zh', 'en']) {
    testWidgets(
      'first frame and delayed recovery stay isolated at 320dp/$language/2x',
      (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final storage = _BlockingStorage();
        final backend = _Backend(storage: storage, language: language);
        var presentationStarts = 0;
        var consumers = 0;
        final controller = ApplicationBootstrap(
          prepare: () async => backend,
          initializePresentation: (_) async => presentationStarts++,
          safeMode: false,
        );
        await tester.pumpWidget(_app(controller, () => consumers++));
        await tester.pump();
        await tester.pump();
        expect(consumers, 0);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(BottomNavigationBar), findsNothing);
        await tester.pump(const Duration(seconds: 45));
        expect(controller.phase, BootstrapPhase.recovering);
        expect(consumers, 0);
        expect(presentationStarts, 0);
        expect(tester.takeException(), isNull);
        storage.release.complete();
        await tester.pumpAndSettle();
        expect(consumers, 1);
        expect(presentationStarts, 1);
        await controller.start();
        await tester.pump();
        expect(consumers, 1);
        expect(presentationStarts, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets('failure retry is reachable at 320dp/$language/2x', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = _BlockingStorage()..fail = true;
      storage.release.complete();
      final backend = _Backend(storage: storage, language: language);
      final controller = ApplicationBootstrap(
        prepare: () async => backend,
        initializePresentation: (_) async {},
        safeMode: false,
      );
      var consumers = 0;
      await tester.pumpWidget(_app(controller, () => consumers++));
      await tester.pumpAndSettle();
      expect(consumers, 0);
      final retry = find.widgetWithText(
        FilledButton,
        language == 'zh' ? '重试' : 'Retry',
      );
      expect(retry, findsOneWidget);
      expect(tester.takeException(), isNull);
      storage.fail = false;
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(consumers, 1);
      expect(backend.accountWorkGate.busy, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
    'prepare deadline retains ownership until settlement and disables retry',
    (tester) async {
      final preparation = Completer<AppBackend>();
      final backend = _Backend();
      var prepares = 0;
      var consumers = 0;
      final controller = ApplicationBootstrap(
        prepare: () {
          prepares++;
          return preparation.future;
        },
        initializePresentation: (_) async => fail('Late initialization'),
        safeMode: false,
      );
      await tester.pumpWidget(_app(controller, () => consumers++));
      await tester.pump(const Duration(seconds: 31));
      expect(controller.phase, BootstrapPhase.timedOut);
      expect(controller.busy, isTrue);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      unawaited(controller.start());
      expect(prepares, 1);
      preparation.complete(backend);
      await tester.pumpAndSettle();
      expect(consumers, 0);
      expect(controller.phase, BootstrapPhase.timedOut);
      expect(controller.busy, isFalse);
      expect(backend.deviceSyncStartup.phase, DeviceStartupPhase.closed);
      expect(backend.initializations, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'safe mode draws local content without protected reads and resumes explicitly',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final storage = _BlockingStorage();
      storage.release.complete();
      final backend = _Backend(storage: storage);
      var consumers = 0;
      final controller = ApplicationBootstrap(
        prepare: () async => backend,
        initializePresentation: (_) async {},
        safeMode: true,
      );
      await tester.pumpWidget(_app(controller, () => consumers++));
      await tester.pumpAndSettle();
      expect(controller.phase, BootstrapPhase.localOnly);
      expect(backend.deviceSyncStartup.deferred, isTrue);
      expect(backend.accountWorkGate.busy, isTrue);
      expect(storage.readCount, 0);
      expect(consumers, 1);
      expect(backend.initializations, 0);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Check and restore'));
      await tester.pumpAndSettle();
      expect(controller.phase, BootstrapPhase.ready);
      expect(storage.readCount, 1);
      expect(backend.initializations, 1);
      expect(backend.accountWorkGate.busy, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

Widget _app(ApplicationBootstrap controller, VoidCallback consume) =>
    DeviceSyncStartupApp(
      controller: controller,
      theme: (_) => ThemeData(useMaterial3: true),
      frame: (child, _) => MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: child,
      ),
      application: (_) => _Consumer(onStart: consume),
    );

class _Consumer extends StatefulWidget {
  const _Consumer({required this.onStart});
  final VoidCallback onStart;
  @override
  State<_Consumer> createState() => _ConsumerState();
}

class _ConsumerState extends State<_Consumer> {
  @override
  void initState() {
    super.initState();
    widget.onStart();
  }

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: Scaffold(body: Text('Local gallery')));
}

class _Backend implements AppBackend, DeviceSyncStartupBackend {
  _Backend({MemoryAccountStorage? storage, String language = 'en'})
    : settings = AppSettings(
        libraryPath: 'synthetic-existing-media-root',
        theme: 'ocean',
        language: language,
        galleryColumns: 4,
        galleryRows: 3,
        showNotePreview: true,
        showGameTag: true,
        compactTagDisplay: true,
        autoPlayVideo: false,
        autoSyncOnLaunch: false,
        notifyOnAutoSync: true,
        showSplatoonSchedule: true,
        showSplatoonFriendActivity: false,
        closeBehavior: 'ask',
        customFontPaths: const [],
        syncPolicy: const SyncPolicy(
          enabled: false,
          activeIntervalMinutes: 30,
          sleepAfterHours: 6,
        ),
      ) {
    deviceSyncStartup = DeviceSyncStartupLifecycle(
      gate: accountWorkGate,
      openLibrary: () async => 'synthetic-library-handle',
      coordinator: (handle) => DeviceAccountCoordinator(
        library: handle,
        storage: storage ?? MemoryAccountStorage(),
        gate: accountWorkGate,
        invalidate: (_) async {},
        publish: (_) {},
      ),
      initialize: () async => initializations++,
      isolated: false,
    );
  }
  final accountWorkGate = AccountWorkGate();
  int initializations = 0;
  @override
  final AppSettings settings;
  @override
  late final DeviceSyncStartupLifecycle deviceSyncStartup;
  @override
  Future<void> close() => deviceSyncStartup.close();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Ordinary consumer ran before recovery');
}

class _BlockingStorage extends MemoryAccountStorage {
  final started = Completer<void>();
  final release = Completer<void>();
  int readCount = 0;
  bool fail = false;
  @override
  Future<String?> read(String key) async {
    readCount++;
    if (!started.isCompleted) started.complete();
    await release.future;
    if (fail) throw StateError('Synthetic protected-storage read failure');
    return super.read(key);
  }
}

class _NativeBoundary implements RustLibApi {
  int closes = 0;
  Completer<void>? closeGate;
  List<String>? interrupted;
  bool failIdentity = false;
  bool failSessionRecovery = false;
  final recoveredSessions = <String>[];
  Completer<void>? identityGate;
  final identityStarted = Completer<void>();
  @override
  Future<LibraryInfo> crateBridgeDeviceSyncLibraryInfo({
    required String library_,
  }) async {
    if (!identityStarted.isCompleted) identityStarted.complete();
    await identityGate?.future;
    if (failIdentity) throw StateError('Synthetic marker read failure');
    return LibraryInfo(
      handle: library_,
      libraryUuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      generation: BigInt.zero,
      interruptedSessions: interrupted,
    );
  }

  @override
  Future<void> crateBridgeDeviceSyncCloseLibrary({
    required String library_,
  }) async {
    await closeGate?.future;
    closes++;
  }

  @override
  Future<void> crateBridgeDeviceSyncRecoverInterruptedSessions({
    required String library_,
    required List<String> sessions,
  }) async {
    if (failSessionRecovery) {
      throw StateError('Synthetic session cleanup failure');
    }
    recoveredSessions.addAll(sessions);
    interrupted = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation ${invocation.memberName}');
}
