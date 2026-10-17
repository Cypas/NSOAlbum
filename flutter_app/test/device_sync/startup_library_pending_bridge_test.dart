import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/backend/rust_backend.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/startup/application_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];
  final peer = Platform.environment['NSOALBUM_DEVICE_SYNC_USB_PEER'];
  test(
    'formal safe-mode bootstrap preserves the real library-only pending until explicit recovery',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'nsoalbum-startup-bridge-',
      );
      // The fixture must finish before the parent opens this library: the real
      // interprocess root lock is part of the contract, not a test bypass.
      final fixture = await Process.run(
        peer!,
        [
          'database::receiver_sql_tests::device_sync_startup_pending_fixture_peer',
          '--exact',
          '--ignored',
          '--nocapture',
        ],
        environment: {'NSOALBUM_DEVICE_SYNC_STARTUP_FIXTURE_ROOT': root.path},
      );
      expect(
        fixture.exitCode,
        0,
        reason: '${fixture.stdout}\n${fixture.stderr}',
      );
      expect(fixture.stdout, contains('1 passed'));
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      final previous = FlutterSecureStoragePlatform.instance;
      final storage = _Storage();
      FlutterSecureStoragePlatform.instance = storage;
      try {
        final backend = await RustBackend.prepare(
          storage: const FlutterSecureStorage(),
          applicationRoot: root.path,
        );
        final controller = ApplicationBootstrap(
          prepare: () async => backend,
          initializePresentation: (_) async {},
          safeMode: true,
        );
        await controller.start();
        expect(controller.phase, BootstrapPhase.localOnly);
        expect(backend.settings.syncPolicy.activeIntervalMinutes, 30);
        expect(backend.settings.libraryPath, root.path);
        expect(await native.listTags(), ['incoming library']);
        expect(await backend.isSignedIn, isFalse);
        expect(await backend.listNintendoAccounts(), isEmpty);
        expect(await backend.selectedNintendoAccountId, isNull);
        expect(await backend.nintendoAccountProfile, isNull);
        expect(storage.reads, isEmpty);
        expect(storage.mutations, isEmpty);
        await expectLater(
          backend.importLocalFiles(const []),
          throwsA(isA<DeviceSyncBusy>()),
        );
        await expectLater(
          backend.beginNintendoLogin(),
          throwsA(isA<DeviceSyncBusy>()),
        );
        expect(backend.deviceSyncStartup.phase, DeviceStartupPhase.deferred);
        final phases = <DeviceStartupPhase>[];
        backend.deviceSyncStartup.addListener(
          () => phases.add(backend.deviceSyncStartup.phase),
        );
        await controller.resumeRecovery();
        expect(controller.phase, BootstrapPhase.ready);
        expect(phases, contains(DeviceStartupPhase.restoring));
        expect(await native.listTags(), ['old library']);
        expect(backend.accountWorkGate.busy, isFalse);
        expect(storage.reads, [accountCoordinationIndexKey]);
        expect(storage.mutations, isEmpty);
        await controller.close();
      } finally {
        FlutterSecureStoragePlatform.instance = previous;
        RustLib.dispose();
      }
    },
    skip: library == null || peer == null
        ? 'Enable the explicit fresh native library and its current Cargo peer.'
        : false,
  );
}

class _Storage extends FlutterSecureStoragePlatform {
  final reads = <String>[];
  final mutations = <String>[];
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    reads.add(key);
    return null;
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    mutations.add(key);
    throw StateError('Library-only recovery must not write account keys');
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    mutations.add(key);
    throw StateError('Library-only recovery must not delete account keys');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected protected-storage operation');
}
