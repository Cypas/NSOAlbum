import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// Replace only the operating-system credential boundary.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/services.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/backend/rust_backend.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/rust/settings.dart';
import 'package:squid_album/src/startup/application_bootstrap.dart';
import 'package:squid_album/src/startup/desktop_startup_close.dart';

import 'account_bridge_test.dart' show pump;
import 'account_storage_test.dart' show MemoryAccountStorage;
import 'bridge_fault_matrix.dart' show FaultAccountStorage;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];
  final peer = Platform.environment['NSOALBUM_DEVICE_SYNC_USB_PEER'];

  test(
    'formal backend checks protected recovery material before admitting startup',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      final root = await Directory.systemTemp.createTemp(
        'nsoalbum-startup-bridge-',
      );
      final previous = FlutterSecureStoragePlatform.instance;
      final storage = _SecureBoundary();
      FlutterSecureStoragePlatform.instance = storage;
      try {
        await native.initCore(libraryRoot: root.path);
        await native.saveSettings(
          settings: AppSettings(
            libraryPath: '${root.path}/media',
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
            customFontPaths: const [],
            syncPolicy: const SyncPolicy(
              enabled: false,
              activeIntervalMinutes: 30,
              sleepAfterHours: 24,
            ),
          ),
        );
        final backend = await RustBackend.open(
          storage: const FlutterSecureStorage(),
          applicationRoot: root.path,
        );
        expect(
          storage.reads,
          [accountCoordinationIndexKey],
          reason:
              'A no-pending journal still requires the protected orphan check '
              'before normal settings and account consumers are admitted.',
        );
        expect(backend.settings.libraryPath, '${root.path}/media');
        expect(backend.accountWorkGate.busy, isFalse);
        expect(storage.mutations, isEmpty);
        await backend.close();
        debugPrintSynchronously(
          'Startup fixture: no-pending backend verified and closed',
        );

        await native.createTag(name: 'old library');
        final operation = await _leaveAccountPending(root, storage);
        debugPrintSynchronously(
          'Startup fixture: real account pending created',
        );
        final index = jsonDecode(
          storage.store.values[accountCoordinationIndexKey]!,
        ) as Map<String, dynamic>;
        final materialKey = accountMaterialKey(
          (index['entries'] as List).single as String,
        );
        final material = storage.store.values.remove(materialKey)!;
        storage.store.armed = false;
        storage.reads.clear();
        final recovering = await RustBackend.prepare(
          storage: const FlutterSecureStorage(),
          applicationRoot: root.path,
        );
        expect(
          identical(
            await RustBackend.prepare(applicationRoot: root.path),
            recovering,
          ),
          isTrue,
        );
        expect(recovering.accountWorkGate.busy, isTrue);
        await expectLater(
          recovering.loadSettings(),
          throwsA(isA<DeviceSyncBusy>()),
        );
        await expectLater(
          recovering.isSignedIn,
          throwsA(isA<DeviceSyncBusy>()),
        );
        await expectLater(
          recovering.selectedNintendoAccountId,
          throwsA(isA<DeviceSyncBusy>()),
        );
        await expectLater(
          recovering.syncNintendoAlbum(),
          throwsA(isA<DeviceSyncBusy>()),
        );
        await expectLater(
          recovering.saveSettings(recovering.settings),
          throwsA(isA<DeviceSyncBusy>()),
        );
        await expectLater(
          recovering.importCustomFonts(const []),
          throwsA(isA<DeviceSyncBusy>()),
        );

        await recovering.deviceSyncStartup.start();
        debugPrintSynchronously(
          'Startup fixture: missing protected material retained',
        );
        expect(
          recovering.deviceSyncStartup.recovery?.status,
          'material_missing',
        );
        expect(recovering.deviceSyncStartup.ready, isFalse);
        expect(recovering.accountWorkGate.busy, isTrue);
        storage.store.values[materialKey] = '{"version":1}';
        await recovering.deviceSyncStartup.start();
        expect(
          recovering.deviceSyncStartup.recovery?.status,
          'protected_storage_unavailable',
        );
        storage.store.values[materialKey] = material;
        storage.failIndexRead = true;
        await recovering.deviceSyncStartup.start();
        expect(
          recovering.deviceSyncStartup.recovery?.status,
          'protected_storage_unavailable',
        );
        storage.failIndexRead = false;
        storage.failActiveWrite = true;
        await recovering.deviceSyncStartup.start();
        expect(
          recovering.deviceSyncStartup.recovery?.status,
          'protected_storage_unavailable',
        );
        expect(recovering.accountWorkGate.busy, isTrue);
        storage.failActiveWrite = false;
        storage.pauseIndex = Completer<void>();
        storage.indexStarted = Completer<void>();
        final completion = recovering.deviceSyncStartup.start();
        await storage.indexStarted!.future;
        final repeated = recovering.deviceSyncStartup.start();
        expect(recovering.deviceSyncStartup.ready, isFalse);
        storage.pauseIndex!.complete();
        await Future.wait([completion, repeated]);
        debugPrintSynchronously('Startup fixture: account recovery completed');
        storage.pauseIndex = null;
        expect(recovering.deviceSyncStartup.ready, isTrue);
        expect(recovering.accountWorkGate.busy, isFalse);
        expect(
          {for (final key in accountActiveKeys) key: storage.store.values[key]},
          {
            legacySessionKey: 'synthetic-old-legacy',
            accountTokensKey: '{"b":"synthetic-old"}',
            accountProfilesKey: null,
            selectedAccountKey: 'b',
          },
        );
        expect(await native.listTags(), ['old library']);
        final probe = await native.deviceSyncOpenLibrary(
          libraryRoot: root.path,
        );
        expect(
          (await native.deviceSyncJournal(
            library_: probe.handle,
            operation: operation,
          ))!.stage,
          'rolled_back',
        );
        expect(
          (await native.deviceSyncLibraryInfo(library_: probe.handle))
              .pendingOperation,
          isNull,
        );
        await native.deviceSyncCloseLibrary(library_: probe.handle);
        await recovering.close();

        await _leaveAccountPending(root, storage);
        debugPrintSynchronously(
          'Startup fixture: second real account pending created',
        );
        storage.store.armed = false;
        storage.activeWriteStarted = Completer<void>();
        storage.pauseActiveWrite = Completer<void>();
        final closingBackend = await RustBackend.prepare(
          storage: const FlutterSecureStorage(),
          applicationRoot: root.path,
        );
        final closingPhases = <DeviceStartupPhase>[];
        closingBackend.deviceSyncStartup.addListener(
          () => closingPhases.add(closingBackend.deviceSyncStartup.phase),
        );
        final bootstrap = ApplicationBootstrap(
          prepare: () async => closingBackend,
          initializePresentation: (_) async =>
              fail('Closing cannot admit presentation'),
          safeMode: false,
        );
        var preventClose = false;
        var nativeCloses = 0;
        final closeErrors = <Object>[];
        const channel = MethodChannel('window_manager');
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          if (call.method == 'setPreventClose') {
            preventClose = (call.arguments as Map)['isPreventClose'] as bool;
          } else if (call.method == 'close') {
            expect(preventClose, isFalse);
            nativeCloses++;
          }
          return null;
        });
        final desktopClose = DesktopStartupClose(
          bootstrap,
          onError: (error, _) => closeErrors.add(error),
        );
        await desktopClose.install();
        final writing = bootstrap.start();
        await storage.activeWriteStarted!.future;
        for (var attempt = 0; attempt < 2; attempt++) {
          await binding.defaultBinaryMessenger.handlePlatformMessage(
            'window_manager',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('onEvent', {'eventName': 'close'}),
            ),
            (_) {},
          );
        }
        expect(preventClose, isTrue);
        expect(nativeCloses, 0);
        expect(bootstrap.phase, BootstrapPhase.closing);
        expect(
          closingBackend.deviceSyncStartup.phase,
          DeviceStartupPhase.closing,
        );
        expect(closingBackend.accountWorkGate.busy, isTrue);
        storage.pauseActiveWrite!.complete();
        await Future.wait([writing, desktopClose.closeApplication()]);
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        expect(bootstrap.phase, BootstrapPhase.closed);
        expect(nativeCloses, 1);
        expect(closeErrors, isEmpty);
        debugPrintSynchronously(
          'Startup fixture: native close adapter waited for real protected write and SQL recovery',
        );
        storage.pauseActiveWrite = null;
        expect(closingPhases, isNot(contains(DeviceStartupPhase.ready)));
        expect(
          closingBackend.deviceSyncStartup.phase,
          DeviceStartupPhase.closed,
        );
        expect(closingBackend.accountWorkGate.busy, isTrue);
        expect(storage.store.values[accountTokensKey], '{"b":"synthetic-old"}');
        expect(await native.listTags(), ['old library']);

        // Even without native pending, a protected orphan must be checked.
        storage.store.values[accountCoordinationIndexKey] =
            '{"version":1,"entries":["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]}';
        final orphan = await RustBackend.prepare(
          storage: const FlutterSecureStorage(),
          applicationRoot: root.path,
        );
        await orphan.deviceSyncStartup.start();
        expect(orphan.deviceSyncStartup.recovery?.status, 'material_missing');
        expect(orphan.accountWorkGate.busy, isTrue);
        await orphan.close();

        // The isolated diagnostic path never even asks the OS for its index.
        storage.reads.clear();
        storage.mutations.clear();
        final isolated = await RustBackend.open(
          storage: const FlutterSecureStorage(),
          applicationRoot: root.path,
          isolated: true,
        );
        expect(await isolated.isSignedIn, isFalse);
        expect(await isolated.listNintendoAccounts(), isEmpty);
        expect(storage.reads, isEmpty);
        expect(storage.mutations, isEmpty);
        await isolated.close();
      } finally {
        FlutterSecureStoragePlatform.instance = previous;
        RustLib.dispose();
      }
    },
    // Each deliberately interrupted source retains its real issued permission
    // for LEASE_MS=30s. This bounds the whole two-crash fixture, not app startup.
    timeout: const Timeout(Duration(minutes: 3)),
    skip: library == null || peer == null
        ? 'Enable the explicit fresh native-library test boundary.'
        : false,
  );
}

class _SecureBoundary extends FlutterSecureStoragePlatform {
  final store = FaultAccountStorage();
  final reads = <String>[];
  final mutations = <String>[];
  bool failIndexRead = false;
  bool failActiveWrite = false;
  Completer<void>? pauseIndex;
  Completer<void>? indexStarted;
  Completer<void>? pauseActiveWrite;
  Completer<void>? activeWriteStarted;
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    reads.add(key);
    if (key == accountCoordinationIndexKey) {
      if (failIndexRead) throw StateError('Synthetic index unavailable');
      if (indexStarted != null && !indexStarted!.isCompleted) {
        indexStarted!.complete();
      }
      await pauseIndex?.future;
    }
    return store.read(key);
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    mutations.add(key);
    if (failActiveWrite && accountActiveKeys.contains(key)) {
      throw StateError('Synthetic OS write failure');
    }
    if (accountActiveKeys.contains(key)) {
      if (activeWriteStarted != null && !activeWriteStarted!.isCompleted) {
        activeWriteStarted!.complete();
      }
      await pauseActiveWrite?.future;
    }
    return store.write(key, value);
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    mutations.add(key);
    if (failActiveWrite && accountActiveKeys.contains(key)) {
      throw StateError('Synthetic OS deletion failure');
    }
    if (accountActiveKeys.contains(key)) {
      if (activeWriteStarted != null && !activeWriteStarted!.isCompleted) {
        activeWriteStarted!.complete();
      }
      await pauseActiveWrite?.future;
    }
    return store.delete(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected credential operation');
}

Future<String> _leaveAccountPending(
  Directory root,
  _SecureBoundary storage,
) async {
  final sourceRoot = await Directory.systemTemp.createTemp(
    'nsoalbum-startup-source-',
  );
  final sourceLibrary = await native.deviceSyncOpenLibrary(
    libraryRoot: sourceRoot.path,
  );
  final targetLibrary = await native.deviceSyncOpenLibrary(
    libraryRoot: root.path,
  );
  final invitation = await native.deviceSyncHost(
    library_: sourceLibrary.handle,
    name: 'Synthetic source',
    tcpAddress: '127.0.0.1:1',
  );
  final host = invitation.handle;
  final phone = await native.deviceSyncClient(
    library_: targetLibrary.handle,
    invitation: invitation.invitation,
    name: 'Synthetic target',
  );
  DeviceAccountCoordinator? sourceOwner;
  try {
    for (var n = 0; n < 40; n++) {
      await pump(host, phone);
    }
    await native.deviceSyncConfirm(endpoint: host);
    await native.deviceSyncConfirm(endpoint: phone);
    for (var n = 0; n < 20; n++) {
      await pump(host, phone);
    }
    final source = DeviceAccountCoordinator(
      library: sourceLibrary.handle,
      storage: MemoryAccountStorage(
        values: {accountTokensKey: '{"a":"synthetic-new"}'},
      ),
      gate: AccountWorkGate(),
      invalidate: (_) async {},
      publish: (_) {},
    );
    sourceOwner = source;
    final target = DeviceAccountCoordinator(
      library: targetLibrary.handle,
      storage: FlutterAccountSecureStorage(const FlutterSecureStorage()),
      gate: AccountWorkGate(),
      invalidate: (_) async {},
      publish: (_) {},
    );
    await source.authorizeSource(host, authorized: true);
    await target.authorizeTarget(phone, authorized: true);
    await native.deviceSyncConfigure(
      endpoint: host,
      phoneToDesktop: false,
      overwrite: true,
      includeAccounts: true,
    );
    for (var n = 0; n < 1000; n++) {
      await pump(host, phone);
      if ((await native.deviceSyncStatus(endpoint: phone)).state ==
          'AwaitingApproval') {
        break;
      }
    }
    final preview = await target.preview(phone);
    storage.store
      ..mutations = 0
      ..verifiedReads = 0
      ..consumed = false
      ..compensationConsumed = false
      ..failMutation = 5
      ..failCompensation = true
      ..armed = true;
    await target.approve(preview, authorized: true);
    for (var n = 0; n < 1000; n++) {
      await pump(host, phone);
      if ((await native.deviceSyncStatus(endpoint: phone)).state ==
          'AwaitingTargetAccountFinal') {
        await target.authorizeFinalTarget(phone);
      }
      if ((await native.deviceSyncStatus(endpoint: host)).state ==
          'AwaitingAccountFinal') {
        await source.authorizeFinalSource(host);
      }
      if ((await native.deviceSyncStatus(endpoint: phone)).state ==
          'AwaitingExternal') {
        break;
      }
    }
    await expectLater(
      target.applyPending(phone),
      throwsA(isA<AccountRecoveryRequired>()),
    );
    debugPrintSynchronously(
      'Startup fixture: candidate/compensation faults left pending',
    );
    expect(
      (await native.deviceSyncLibraryInfo(library_: targetLibrary.handle))
          .pendingOperation,
      preview.operation,
    );
    return preview.operation;
  } finally {
    debugPrintSynchronously('Startup fixture: endpoint shutdown starting');
    await native.deviceSyncShutdown(endpoint: phone);
    await native.deviceSyncShutdown(endpoint: host);
    await native.deviceSyncCloseLibrary(library_: targetLibrary.handle);
    await native.deviceSyncCloseLibrary(library_: sourceLibrary.handle);
    debugPrintSynchronously(
      'Startup fixture: library handles closed; retiring source permit',
    );
    await sourceOwner?.releaseSource(host);
    await native.deviceSyncCloseEndpoint(endpoint: phone);
    await native.deviceSyncCloseEndpoint(endpoint: host);
    debugPrintSynchronously('Startup fixture: endpoint fixture retired');
  }
}
