import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/rust/device_sync/headless.dart';
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/rust/settings.dart';
import 'package:squid_album/src/startup/application_bootstrap.dart';
import 'package:squid_album/src/startup/desktop_startup_close.dart';
import 'package:squid_album/src/startup/startup_options.dart';
import 'package:squid_album/src/ui/device_sync/startup_page.dart';
import 'package:window_manager/window_manager.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;

const _channel = MethodChannel('window_manager');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late _Window nativeWindow;
  late _NativeBoundary native;
  final errors = <Object>[];
  setUp(() {
    errors.clear();
    nativeWindow = _Window(binding);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      nativeWindow.call,
    );
    native = _NativeBoundary();
    RustLib.initMock(api: native);
  });
  tearDown(() {
    for (final listener in windowManager.listeners) {
      windowManager.removeListener(listener);
    }
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    RustLib.dispose();
  });

  DesktopStartupClose guard(ApplicationBootstrap bootstrap) =>
      DesktopStartupClose(bootstrap, onError: (error, _) => errors.add(error));

  test('instance ownership survives failed shutdown and releases after window close', () async {
    final backend = _Backend();
    final bootstrap = ApplicationBootstrap(
      prepare: () async => backend,
      initializePresentation: (_) async {},
      safeMode: false,
    );
    var releases = 0;
    final close = DesktopStartupClose(
      bootstrap,
      onError: (error, _) => errors.add(error),
      onClosed: () async {
        expect(bootstrap.phase, BootstrapPhase.closed);
        expect(nativeWindow.destroyed, 1);
        releases++;
      },
    );
    await close.install();
    await bootstrap.start();
    native.failClose = true;
    await expectLater(close.closeApplication(), throwsStateError);
    expect(releases, 0);
    expect(nativeWindow.preventClose, isTrue);
    native.failClose = false;
    await close.closeApplication();
    expect(releases, 1);
    await close.closeApplication();
    expect(releases, 1);
  });

  test(
    'isolated smoke and mobile do not install desktop close hooks',
    () async {
      final bootstrap = ApplicationBootstrap(
        prepare: () async => fail('Not admitted'),
        initializePresentation: (_) async {},
        safeMode: false,
      );
      for (final isolated in [false, true]) {
        final result = await DesktopStartupClose.protect(
          bootstrap: bootstrap,
          options: StartupOptions(
            ciSmokeRoot: isolated ? 'synthetic-isolated-root' : null,
          ),
          desktop: isolated,
          onError: (error, _) => errors.add(error),
        );
        expect(result, isNull);
      }
      expect(nativeWindow.calls, isEmpty);
      expect(bootstrap.phase, BootstrapPhase.unchecked);
    },
  );

  for (final expire in [false, true]) {
    testWidgets(
      'native/titlebar close awaits pending prepare, timeout=$expire',
      (tester) async {
        final prepared = Completer<AppBackend>();
        final backend = _Backend();
        var consumers = 0;
        final phases = <BootstrapPhase>[];
        final bootstrap = ApplicationBootstrap(
          prepare: () => prepared.future,
          initializePresentation: (_) async => fail('Late presentation'),
          safeMode: false,
        )..addListener(() {});
        bootstrap.addListener(() => phases.add(bootstrap.phase));
        final close = guard(bootstrap);
        await close.install();
        await tester.pumpWidget(_app(bootstrap, () => consumers++));
        await tester.pump();
        if (expire) await tester.pump(const Duration(seconds: 31));
        expect(
          bootstrap.phase,
          expire ? BootstrapPhase.timedOut : BootstrapPhase.preparing,
        );
        await tester.tap(find.byKey(const Key('desktop-titlebar-close')));
        await tester.pump();
        await nativeWindow.event();
        await tester.pump();
        expect(bootstrap.phase, BootstrapPhase.closing);
        expect(nativeWindow.destroyed, 0);
        expect(nativeWindow.preventClose, isTrue);
        prepared.complete(backend);
        await close.closeApplication();
        await tester.pump();
        expect(nativeWindow.destroyed, 1);
        expect(bootstrap.phase, BootstrapPhase.closed);
        expect(phases, isNot(contains(BootstrapPhase.ready)));
        expect(consumers, 0);
        expect(backend.initializations, 0);
        expect(errors, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final waitForStorage in [false, true]) {
    testWidgets(
      'native repeated close awaits ${waitForStorage ? 'protected storage' : 'native query'}',
      (tester) async {
        final storage = _Storage(blocked: waitForStorage);
        if (!waitForStorage) native.pendingQuery = Completer<void>();
        final backend = _Backend(storage: storage);
        var consumers = 0;
        final bootstrap = ApplicationBootstrap(
          prepare: () async => backend,
          initializePresentation: (_) async => fail('Late presentation'),
          safeMode: false,
        );
        final close = guard(bootstrap);
        await close.install();
        await tester.pumpWidget(_app(bootstrap, () => consumers++));
        await tester.pump();
        await tester.pump();
        expect(
          waitForStorage ? storage.started.isCompleted : native.started,
          isTrue,
        );
        await nativeWindow.event();
        await nativeWindow.event();
        await tester.pump();
        expect(nativeWindow.destroyed, 0);
        expect(native.closes, 0);
        expect(backend.gate.normalPermit, throwsA(isA<DeviceSyncBusy>()));
        if (waitForStorage) {
          storage.release.complete();
        } else {
          native.pendingQuery!.complete();
        }
        await close.closeApplication();
        await tester.pump();
        expect(native.closes, 1);
        expect(nativeWindow.destroyed, 1);
        expect(bootstrap.phase, BootstrapPhase.closed);
        expect(consumers, 0);
        expect(backend.initializations, 0);
        expect(errors, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('Shell handoff keeps one owner and separates policy from quit', (
    tester,
  ) async {
    final backend = _Backend();
    final bootstrap = ApplicationBootstrap(
      prepare: () async => backend,
      initializePresentation: (_) async {},
      safeMode: false,
    );
    final close = guard(bootstrap);
    await close.install();
    await bootstrap.start();
    expect(bootstrap.phase, BootstrapPhase.ready);
    final owner = Object();
    final decision = Completer<void>();
    var policies = 0;
    close.adoptPolicy(owner, () async {
      policies++;
      await decision.future;
      await windowManager.hide();
    });
    await nativeWindow.event();
    await nativeWindow.event();
    await tester.pump();
    expect(policies, 1, reason: 'one outstanding ask/close policy');
    expect(nativeWindow.preventClose, isTrue);
    expect(windowManager.listeners.whereType<DesktopStartupClose>().length, 1);
    decision.complete();
    await tester.pump();
    expect(nativeWindow.hidden, 1);
    expect(native.closes, 0, reason: 'hiding must not close the backend');
    expect(bootstrap.phase, BootstrapPhase.ready);
    close.adoptPolicy(owner, () async {
      policies++;
      await close.closeApplication();
    });
    close.releasePolicy(Object()); // An old Shell cannot release the new owner.
    await nativeWindow.event();
    await tester.pumpAndSettle();
    expect(policies, 2);
    expect(native.closes, 1);
    expect(nativeWindow.destroyed, 1);
    expect(bootstrap.phase, BootstrapPhase.closed);
    expect(errors, isEmpty);
  });

  testWidgets(
    'safe mode retains startup close protection without Shell policy',
    (tester) async {
      final storage = _Storage(blocked: true);
      final backend = _Backend(storage: storage);
      final bootstrap = ApplicationBootstrap(
        prepare: () async => backend,
        initializePresentation: (_) async => fail('Safe-mode presentation'),
        safeMode: true,
      );
      await DesktopStartupClose.protect(
        bootstrap: bootstrap,
        options: const StartupOptions(safeMode: true),
        desktop: true,
        onError: (error, _) => errors.add(error),
      );
      await bootstrap.start();
      expect(bootstrap.phase, BootstrapPhase.localOnly);
      expect(storage.started.isCompleted, isFalse);
      await nativeWindow.event();
      await tester.pumpAndSettle();
      expect(bootstrap.phase, BootstrapPhase.closed);
      expect(nativeWindow.destroyed, 1);
      expect(storage.started.isCompleted, isFalse);
      expect(backend.gate.busy, isTrue);
    },
  );

  testWidgets(
    'failed backend close remains prevented and reports the failure',
    (tester) async {
      native.failClose = true;
      final backend = _Backend();
      final bootstrap = ApplicationBootstrap(
        prepare: () async => backend,
        initializePresentation: (_) async {},
        safeMode: false,
      );
      final close = guard(bootstrap);
      await close.install();
      await bootstrap.start();
      await tester.pumpWidget(_app(bootstrap, () {}));
      await nativeWindow.event();
      await tester.pumpAndSettle();
      expect(errors, hasLength(1));
      expect(nativeWindow.preventClose, isTrue);
      expect(nativeWindow.destroyed, 0);
      expect(bootstrap.phase, BootstrapPhase.closing);
      expect(find.text('Unable to close safely'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      await nativeWindow.event();
      await tester.pumpAndSettle();
      expect(errors, hasLength(2));
      expect(nativeWindow.destroyed, 0);
    },
  );

  testWidgets('a fresh explicit exit resumes native retirement after failure', (
    tester,
  ) async {
    native.failClose = true;
    final backend = _Backend();
    final bootstrap = ApplicationBootstrap(
      prepare: () async => backend,
      initializePresentation: (_) async {},
      safeMode: false,
    );
    final close = guard(bootstrap);
    await close.install();
    await bootstrap.start();
    await nativeWindow.event();
    await tester.pumpAndSettle();
    expect(errors, hasLength(1));
    expect(nativeWindow.preventClose, isTrue);
    expect(nativeWindow.destroyed, 0);
    native.failClose = false;
    await nativeWindow.event();
    await tester.pumpAndSettle();
    expect(nativeWindow.destroyed, 1);
    expect(bootstrap.phase, BootstrapPhase.closed);
    expect(native.closes, 1);
    expect(backend.initializations, 1);
    expect(backend.gate.normalPermit, throwsA(isA<DeviceSyncBusy>()));
  });

  test('stopper failure still drains the owned presentation flight', () async {
    final backend = _Backend();
    final entered = Completer<void>(), release = Completer<void>();
    final bootstrap = ApplicationBootstrap(
      prepare: () async => backend,
      initializePresentation: (_) async {
        entered.complete();
        await release.future;
      },
      safeMode: false,
    );
    final starting = bootstrap.start();
    await entered.future;
    native.failClose = true;
    var ended = false;
    final closing = bootstrap.close().then<Object?>(
      (_) {
        ended = true;
        return null;
      },
      onError: (Object failure) {
        ended = true;
        return failure;
      },
    );
    await Future<void>.delayed(Duration.zero);
    try {
      expect(ended, isFalse);
      expect(bootstrap.phase, BootstrapPhase.closing);
    } finally {
      release.complete();
      await starting;
    }
    expect(await closing, isA<StateError>());
    native.failClose = false;
    await bootstrap.close();
    expect(backend.initializations, 1);
    expect(native.closes, 1);
  });

  test(
    'late factory retirement is not silently retried in the same exit',
    () async {
      final prepared = Completer<AppBackend>();
      final backend = _Backend();
      final bootstrap = ApplicationBootstrap(
        prepare: () => prepared.future,
        initializePresentation: (_) async => fail('No late presentation'),
        safeMode: false,
      );
      final starting = bootstrap.start();
      final closing = bootstrap.close().then<Object?>(
        (_) => null,
        onError: (Object failure) => failure,
      );
      // Open the same native library before returning the late prepared owner.
      await backend.deviceSyncStartup.start();
      native.failClose = true;
      prepared.complete(backend);
      await starting;
      expect(await closing, isA<StateError>());
      expect(native.closeAttempts, 1);
      expect(bootstrap.phase, BootstrapPhase.closing);
      native.failClose = false;
      await bootstrap.close();
      expect(native.closeAttempts, 2);
      expect(bootstrap.backend, same(backend));
      expect(backend.initializations, 1);
    },
  );

  testWidgets(
    'reentrant explicit exit is not cleared by the old request finally',
    (tester) async {
      final backend = _Backend();
      final bootstrap = ApplicationBootstrap(
        prepare: () async => backend,
        initializePresentation: (_) async {},
        safeMode: false,
      );
      late DesktopStartupClose close;
      close = DesktopStartupClose(
        bootstrap,
        onError: (failure, _) {
          errors.add(failure);
          native.failClose = false;
          native.closeRelease = Completer<void>();
          // This is a new explicit request delivered during the old error callback.
          close.onWindowClose();
        },
      );
      await close.install();
      await bootstrap.start();
      native.failClose = true;
      close.onWindowClose();
      await tester.pump();
      await tester.pump();
      try {
        expect(errors, hasLength(1));
        expect(native.closeAttempts, 2);
        expect(nativeWindow.preventClose, isTrue);
        close.onWindowClose();
        await tester.pump();
        expect(native.closeAttempts, 2);
      } finally {
        native.closeRelease?.complete();
      }
      await tester.pumpAndSettle();
      expect(nativeWindow.destroyed, 1);
      expect(native.closes, 1);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Widget _app(ApplicationBootstrap bootstrap, VoidCallback consumer) =>
    DeviceSyncStartupApp(
      controller: bootstrap,
      theme: (_) => ThemeData(),
      // DesktopWindowFrame intentionally hides chrome under FLUTTER_TEST.
      // Exercise its real production titlebar rather than a test close button.
      frame: (child, title) => Column(
        children: [
          DesktopTitleBar(title: title, iconAsset: 'assets/tray/app_icon.png'),
          Expanded(child: child),
        ],
      ),
      application: (_) {
        consumer();
        return const SizedBox.shrink();
      },
    );

class _Window {
  _Window(this.binding);
  final TestWidgetsFlutterBinding binding;
  bool preventClose = false;
  int destroyed = 0;
  int hidden = 0;
  final calls = <String>[];
  Future<void> event() async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'window_manager',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onEvent', {'eventName': 'close'}),
      ),
      (_) {},
    );
  }

  Future<Object?> call(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'setPreventClose':
        preventClose = (call.arguments as Map)['isPreventClose'] as bool;
      case 'close':
        if (preventClose) {
          await event();
        } else {
          destroyed++;
        }
      case 'hide':
        hidden++;
      case 'isMaximized':
        return false;
    }
    return null;
  }
}

class _Backend implements AppBackend, DeviceSyncStartupBackend {
  _Backend({_Storage? storage}) {
    deviceSyncStartup = DeviceSyncStartupLifecycle(
      gate: gate,
      openLibrary: () async => 'synthetic-window-close-library',
      coordinator: (library) => DeviceAccountCoordinator(
        library: library,
        storage: storage ?? _Storage(blocked: false),
        gate: gate,
        invalidate: (_) async {},
        publish: (_) {},
      ),
      initialize: () async => initializations++,
      isolated: false,
    );
  }
  final gate = AccountWorkGate();
  int initializations = 0;
  @override
  late final DeviceSyncStartupLifecycle deviceSyncStartup;
  @override
  Future<void> close() => deviceSyncStartup.close();
  @override
  final AppSettings settings = const AppSettings(
    libraryPath: 'synthetic-window-close-root',
    theme: 'ocean',
    language: 'en',
    galleryColumns: 4,
    galleryRows: 3,
    showNotePreview: true,
    showGameTag: true,
    compactTagDisplay: true,
    autoPlayVideo: false,
    autoSyncOnLaunch: false,
    notifyOnAutoSync: true,
    showSplatoonSchedule: true,
    closeBehavior: 'ask',
    customFontPaths: [],
    syncPolicy: SyncPolicy(
      enabled: false,
      activeIntervalMinutes: 30,
      sleepAfterHours: 6,
    ),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Ordinary consumer before recovery');
}

class _Storage extends MemoryAccountStorage {
  _Storage({required bool blocked}) {
    if (!blocked) release.complete();
  }
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<String?> read(String key) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return super.read(key);
  }
}

class _NativeBoundary implements RustLibApi {
  Completer<void>? pendingQuery;
  bool started = false;
  bool failClose = false;
  int closes = 0;
  int closeAttempts = 0;
  Completer<void>? closeRelease;
  @override
  Future<LibraryInfo> crateBridgeDeviceSyncLibraryInfo({
    required String library_,
  }) async {
    started = true;
    await pendingQuery?.future;
    return LibraryInfo(
      handle: library_,
      libraryUuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      generation: BigInt.zero,
    );
  }

  @override
  Future<void> crateBridgeDeviceSyncCloseLibrary({
    required String library_,
  }) async {
    closeAttempts++;
    if (failClose) throw StateError('Synthetic native close failure');
    await closeRelease?.future;
    closes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native call ${invocation.memberName}');
}
