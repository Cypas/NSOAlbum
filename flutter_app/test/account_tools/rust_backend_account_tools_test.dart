import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// Replace only the OS boundary; RustBackend and FlutterSecureStorage stay real.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/rust_backend.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/rust_initialization.dart';
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/rust/settings.dart';

import '../device_sync/startup_native_boundary.dart';

const _tokensKey = 'nintendo.account_tokens.v1';
const _account = 'synthetic-account';
final _snapshot = NintendoFriendsSnapshot(
  friends: const [],
  updatedAt: DateTime.utc(2026, 10, 16),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _RustBoundary rust;
  late _MemorySecureStorage storage;
  late FlutterSecureStoragePlatform previousStorage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'nsoalbum-account-tools-test-',
    );
    rust = _RustBoundary();
    RustLib.initMock(api: rust);
    previousStorage = FlutterSecureStoragePlatform.instance;
    storage = _MemorySecureStorage();
    FlutterSecureStoragePlatform.instance = storage;
  });

  tearDown(() async {
    FlutterSecureStoragePlatform.instance = previousStorage;
    RustLib.dispose();
    await root.delete(recursive: true);
  });

  Future<RustBackend> open() => RustBackend.open(
    storage: const FlutterSecureStorage(),
    applicationRoot: root.path,
  );

  test('device preparation is Busy for the whole normal credential-read/request lifetime', () async {
    final backend = await open();
    storage.readGate = Completer<void>();
    final request = backend.loadNintendoFriends(_account, 'normal-inflight');
    await storage.tokenReadStarted.future;
    DeviceAccountPermit? incorrectlyAdmitted;
    var blocked = false;
    try {
      incorrectlyAdmitted = backend.accountWorkGate.device();
    } on DeviceSyncBusy {
      blocked = true;
    } finally {
      incorrectlyAdmitted?.release();
      storage.readGate!.complete();
      await request;
    }
    expect(blocked, isTrue);
    final device = backend.accountWorkGate.device();
    final before = Map.of(storage.values);
    await expectLater(
      backend.selectNintendoAccount(_account),
      throwsA(isA<DeviceSyncBusy>()),
    );
    expect(storage.values, before);
    device.release();
  });

  test('same-ID account replacement cannot publish before its registered native cleanup completes', () async {
    final backend = await open();
    final cleaned = Completer<void>();
    final registration = backend.accountToolLifecycle.registerCleanup(
      _account,
      () => cleaned.future,
    );
    final device = backend.accountWorkGate.device();
    final invalidation = backend.invalidateDeviceAccounts({_account});
    await rust.cacheCleared.future;
    try {
      expect(backend.accountToolLifecycle.isRemoved(_account), isTrue);
      expect(
        () => backend.publishDeviceAccounts({_account}),
        throwsA(isA<DeviceSyncBusy>()),
      );
    } finally {
      cleaned.complete();
      await invalidation;
      backend.publishDeviceAccounts({_account});
      registration.remove();
      device.release();
    }
    expect(backend.accountToolLifecycle.isRemoved(_account), isFalse);
  });

  test(
    'an already initialized bridge does not load another native library',
    () async {
      await ensureRustLibInitialized();
      final backend = await open();
      expect(backend.settings.language, 'en');
      expect(rust.initializedRoots, [root.path]);
    },
  );

  test(
    'a request after the removal snapshot cannot dispatch or recreate cache',
    () async {
      final backend = await open();
      rust.clearGate = Completer<void>();
      final removal = backend.removeNintendoAccount(_account);
      await rust.cacheCleared.future;
      expect(backend.accountToolLifecycle.isRemoved(_account), isTrue);
      expect(storage.values[_tokensKey], contains('synthetic-old-session'));
      final reads = storage.tokenReads;
      try {
        await expectLater(
          backend.loadNintendoFriends(_account, 'after-removal-snapshot'),
          throwsStateError,
        );
        expect(
          storage.tokenReads,
          reads,
          reason: 'removed accounts are rejected before credential reads',
        );
        expect(rust.friendDispatches, isEmpty);
        expect(rust.accountCache, isEmpty);
      } finally {
        rust.clearGate!.complete();
        await removal;
      }
      expect(storage.values.containsKey(_tokensKey), isFalse);
      expect(rust.accountCache, isEmpty);
    },
  );

  test(
    'removal during a credential read rejects its captured old token',
    () async {
      final backend = await open();
      storage.readGate = Completer<void>();
      final request = backend.loadNintendoFriends(
        _account,
        'credential-pending',
      );
      final rejected = expectLater(request, throwsStateError);
      await storage.tokenReadStarted.future;
      await backend.removeNintendoAccount(_account);
      storage.readGate!.complete();
      await rejected;
      expect(rust.friendDispatches, isEmpty);
      expect(rust.accountCache, isEmpty);
      expect(rust.cancelled, ['credential-pending']);
      expect(storage.values.containsKey(_tokensKey), isFalse);
    },
  );

  test('late results stay cancelled after removal and explicit re-login recovery', () async {
    final backend = await open();
    final oldResult = Completer<NintendoFriendsSnapshot>();
    rust.nextFriendResult = oldResult;
    final oldRequest = backend.loadNintendoFriends(_account, 'old-pending');
    final rejected = expectLater(oldRequest, throwsStateError);
    await rust.friendDispatched.future;
    await backend.removeNintendoAccount(_account);
    expect(rust.accountCache, isEmpty);

    storage.values[_tokensKey] = jsonEncode({
      _account: 'synthetic-new-session',
    });
    // completeNintendoLogin emits this only after secure token/profile writes.
    backend.accountToolLifecycle.accountAvailable(_account);
    final current = await backend.loadNintendoFriends(_account, 'new-login');
    expect(current, _snapshot);
    expect(rust.accountCache, {_account: 'synthetic-new-session'});
    oldResult.complete(
      NintendoFriendsSnapshot(friends: const [], updatedAt: DateTime.utc(2000)),
    );
    await rejected;
    expect(rust.cancelled, ['old-pending']);
    expect(rust.friendDispatches, ['old-pending', 'new-login']);
    expect(rust.accountCache, {_account: 'synthetic-new-session'});
    expect(backend.accountToolLifecycle.isRemoved(_account), isFalse);
  });
}

class _RustBoundary with NoPendingStartupBoundary implements RustLibApi {
  final initializedRoots = <String>[];
  final friendDispatches = <String>[];
  final cancelled = <String>[];
  final accountCache = <String, String>{};
  final cacheCleared = Completer<void>();
  final friendDispatched = Completer<void>();
  Completer<void>? clearGate;
  Completer<NintendoFriendsSnapshot>? nextFriendResult;

  @override
  Future<void> crateBridgeInitCore({required String libraryRoot}) async {
    initializedRoots.add(libraryRoot);
  }

  @override
  Future<void> crateBridgeSetRuntimeProxyPolicy({
    required bool disableAppProxy,
  }) async {}

  @override
  Future<AppSettings?> crateBridgeLoadSettings() async => const AppSettings(
    libraryPath: 'synthetic-library',
    theme: 'ocean',
    language: 'en',
    galleryColumns: 4,
    galleryRows: 3,
    showNotePreview: true,
    showGameTag: true,
    compactTagDisplay: true,
    autoPlayVideo: false,
    autoSyncOnLaunch: false,
    closeBehavior: 'ask',
    customFontPaths: [],
    syncPolicy: SyncPolicy(
      enabled: false,
      activeIntervalMinutes: 30,
      sleepAfterHours: 24,
    ),
  );

  @override
  Future<void> crateBridgeClearAccountToolCache({
    required String accountId,
  }) async {
    expect(accountId, _account);
    accountCache.remove(accountId);
    if (!cacheCleared.isCompleted) cacheCleared.complete();
    await clearGate?.future;
  }

  @override
  Future<bool> crateBridgeCancelAccountToolOperation({
    required String operationId,
  }) async {
    cancelled.add(operationId);
    return true;
  }

  @override
  Future<NintendoFriendsSnapshot> crateBridgeNintendoFriends({
    required String accountId,
    required String sessionToken,
    required String operationId,
    String? proxyUrl,
  }) async {
    expect(accountId, _account);
    expect(proxyUrl, isNull);
    friendDispatches.add(operationId);
    accountCache[accountId] = sessionToken;
    final delayed = nextFriendResult;
    nextFriendResult = null;
    if (!friendDispatched.isCompleted) friendDispatched.complete();
    return delayed == null ? _snapshot : delayed.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected Rust boundary call: ${invocation.memberName}',
  );
}

class _MemorySecureStorage extends FlutterSecureStoragePlatform {
  final values = <String, String>{
    _tokensKey: jsonEncode({_account: 'synthetic-old-session'}),
    'nintendo.selected_account.v1': _account,
  };
  int tokenReads = 0;
  final tokenReadStarted = Completer<void>();
  Completer<void>? readGate;
  bool _readBlocked = false;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    final captured = values[key];
    if (key == _tokensKey) {
      tokenReads++;
      if (!tokenReadStarted.isCompleted) tokenReadStarted.complete();
      if (readGate != null && !_readBlocked) {
        _readBlocked = true;
        await readGate!.future;
      }
    }
    return captured;
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => values[key] = value;

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => values.remove(key);

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => values.containsKey(key);

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => Map.of(values);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      throw UnsupportedError('Tests must not clear unrelated secure storage');
}
