import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/rust_backend.dart';
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/rust/settings.dart';

import 'startup_native_boundary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Storage storage;
  late FlutterSecureStoragePlatform previous;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nsoalbum-startup-owner-');
    RustLib.initMock(api: _Native());
    previous = FlutterSecureStoragePlatform.instance;
    storage = _Storage();
    FlutterSecureStoragePlatform.instance = storage;
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    RustLib.dispose();
  });
  Future<RustBackend> prepare() => RustBackend.prepare(
    storage: const FlutterSecureStorage(),
    applicationRoot: root.path,
  );

  test(
    'closing an old owner twice never removes a replacement owner',
    () async {
      final old = await prepare();
      await old.close();
      final current = await prepare();
      expect(identical(old, current), isFalse);
      await old.close();
      final repeated = await prepare();
      expect(identical(current, repeated), isTrue);
      await current.close();
      if (!identical(current, repeated)) await repeated.close();
    },
  );

  test(
    'compatibility open failure retains the same reachable retry/close owner',
    () async {
      storage.fail = true;
      await expectLater(
        RustBackend.open(applicationRoot: root.path),
        throwsA(isA<AccountRecoveryRequired>()),
      );
      final retained = await prepare();
      expect(retained.accountWorkGate.busy, isTrue);
      expect(
        retained.deviceSyncStartup.recovery?.status,
        'protected_storage_unavailable',
      );
      await expectLater(retained.isSignedIn, throwsA(isA<DeviceSyncBusy>()));
      storage.fail = false;
      final retried = await RustBackend.open(applicationRoot: root.path);
      expect(identical(retained, retried), isTrue);
      expect(retried.deviceSyncStartup.ready, isTrue);
      await retried.close();
    },
  );
}

class _Storage extends FlutterSecureStoragePlatform {
  bool fail = false;
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    expect(key, accountCoordinationIndexKey);
    if (fail) throw StateError('Synthetic secure-store unavailable');
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No startup account mutation is authorized');
}

class _Native with NoPendingStartupBoundary implements RustLibApi {
  @override
  Future<void> crateBridgeInitCore({required String libraryRoot}) async {}
  @override
  Future<void> crateBridgeSetRuntimeProxyPolicy({
    required bool disableAppProxy,
  }) async {}
  @override
  Future<AppSettings?> crateBridgeLoadSettings() async => const AppSettings(
    libraryPath: 'synthetic-existing-media-root',
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
    showSplatoonFriendActivity: false,
    closeBehavior: 'ask',
    customFontPaths: [],
    syncPolicy: SyncPolicy(
      enabled: false,
      activeIntervalMinutes: 30,
      sleepAfterHours: 24,
    ),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native startup call');
}
