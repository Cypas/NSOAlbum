import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:squid_album/src/rust/nso/provider.dart';
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

  test(
    'removing a login preserves only its last known name and timestamp',
    () async {
      storage.values[_tokensKey] = '{"synthetic-account":"synthetic-session"}';
      storage.values['nintendo.account_profiles.v1'] = jsonEncode({
        _account: {
          'nickname': 'Previous user',
          'name_updated_at': '2026-10-24T00:00:00Z',
          'avatar_url': 'https://example.com/synthetic.png',
          'avatar_base64': 'AQID',
        },
      });
      final backend = await open();
      await backend.removeNintendoAccount(_account);
      expect(await backend.listNintendoAccounts(), isEmpty);
      final profile =
          (jsonDecode(storage.values['nintendo.account_profiles.v1']!)
                  as Map)[_account]
              as Map;
      expect(profile, {
        'nickname': 'Previous user',
        'name_updated_at': '2026-10-24T00:00:00Z',
      });
      expect(storage.values.containsKey(_tokensKey), isFalse);
      final names = await backend.listNintendoAccountNameHistory();
      expect(names.single.nickname, 'Previous user');
      expect(names.single.updatedAt, DateTime.utc(2026, 10, 24));
    },
  );

  test('selected-account sync uses the account-scoped Rust refresh entry and records separate counts', () async {
    storage.values[_tokensKey] = jsonEncode({
      _account: 'synthetic-old-session',
      'other-account': 'synthetic-other-session',
    });
    final backend = await open();
    final result = await backend.syncNintendoAlbum();

    expect(result, rust.syncResult);
    expect(rust.syncRequests, [
      (account: _account, token: 'synthetic-old-session', proxy: null),
    ]);
    expect(rust.syncHistory, [
      {
        'account': _account,
        'status': 'partial_failure',
        'found': BigInt.from(9),
        'downloaded': BigInt.from(2),
        'duplicates': BigInt.one,
        'existing': BigInt.from(5),
        'failed': BigInt.one,
      },
    ]);
    expect(jsonDecode(storage.values[_tokensKey]!), {
      _account: 'synthetic-old-session',
      'other-account': 'synthetic-other-session',
    });
  });

  test('account sync refreshes a missing cached avatar without making avatar refresh failure fail sync', () async {
    storage.values['nintendo.account_profiles.v1'] = jsonEncode({
      _account: {'nickname': 'Transferred account'},
    });
    rust.refreshedSession = CoralSession(
      accessToken: 'synthetic-coral',
      naId: _account,
      nickname: 'Transferred account',
      avatarUrl: 'https://example.com/account-avatar.png',
      avatarBytes: Uint8List.fromList([1, 2, 3]),
    );
    final backend = await open();

    final result = await backend.syncNintendoAccount(_account);

    expect(result, rust.syncResult);
    final profiles = jsonDecode(
      storage.values['nintendo.account_profiles.v1']!,
    ) as Map<String, dynamic>;
    expect(
      profiles[_account]['avatar_url'],
      'https://example.com/account-avatar.png',
    );
    expect(profiles[_account]['avatar_base64'], 'AQID');
  });

  test('selected-account rate limit is recorded once without a Flutter authentication retry', () async {
    final backend = await open();
    rust.syncError = StateError('synthetic HTTP 429 rate limit');

    await expectLater(backend.syncNintendoAlbum(), throwsStateError);

    expect(rust.syncRequests.length, 1);
    expect(rust.syncHistory, [
      {
        'account': _account,
        'status': 'rate_limited',
        'found': BigInt.zero,
        'downloaded': BigInt.zero,
        'duplicates': BigInt.zero,
        'existing': null,
        'failed': BigInt.zero,
      },
    ]);
  });

  test(
    'account removal during a sync credential read rejects the captured token',
    () async {
      final backend = await open();
      storage.readGate = Completer<void>();
      final pending = backend
          .syncNintendoAccount(_account)
          .then<Object?>(
            (_) => null,
            onError: (Object error, StackTrace _) => error,
          );
      await storage.tokenReadStarted.future;
      await backend.removeNintendoAccount(_account);
      storage.readGate!.complete();

      expect(await pending, isA<StateError>());
      expect(rust.syncRequests, isEmpty);
      expect(rust.syncHistory.single['status'], 'cancelled');
      expect(storage.values.containsKey(_tokensKey), isFalse);
    },
  );

  test(
    'a same-ID re-login cannot revive an older sync credential read',
    () async {
      final backend = await open();
      storage.readGate = Completer<void>();
      final pending = backend
          .syncNintendoAccount(_account)
          .then<Object?>(
            (_) => null,
            onError: (Object error, StackTrace _) => error,
          );
      await storage.tokenReadStarted.future;
      await backend.removeNintendoAccount(_account);
      storage.values[_tokensKey] = jsonEncode({
        _account: 'synthetic-new-session',
      });
      // Login publishes availability only after writing the new secure token.
      backend.accountToolLifecycle.accountAvailable(_account);
      storage.readGate!.complete();

      expect(await pending, isA<StateError>());
      expect(rust.syncRequests, isEmpty);
      expect(rust.syncHistory.single['status'], 'cancelled');
      final result = await backend.syncNintendoAccount(_account);
      expect(result.downloaded, BigInt.from(2));
      expect(rust.syncRequests, [
        (account: _account, token: 'synthetic-new-session', proxy: null),
      ]);
      expect(rust.syncHistory.last['status'], 'partial_failure');
    },
  );

  test(
    'cancelling while selecting the sync account prevents later dispatch',
    () async {
      final backend = await open();
      storage.readGate = Completer<void>();
      final pending = backend.syncNintendoAlbum().then<Object?>(
        (_) => null,
        onError: (Object error, StackTrace _) => error,
      );
      await storage.tokenReadStarted.future;
      expect(await backend.cancelSync(), isTrue);
      storage.readGate!.complete();

      expect(await pending, isA<StateError>());
      expect(rust.syncRequests, isEmpty);
      expect(rust.syncCancellations, 1);
    },
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
      expect(rust.initializedRoots, [await root.resolveSymbolicLinks()]);
    },
  );

  test(
    'own friend code survives a backend restart without another request',
    () async {
      final backend = await open();
      final first = await backend.loadNintendoFriendCode(_account, 'own-first');
      expect(first.friendCode, '1234-5678-9012');
      await backend.close();
      final reopened = await open();
      final cached = await reopened.loadNintendoFriendCode(
        _account,
        'own-cached',
      );
      expect(cached.friendCode, '1234-5678-9012');
      expect(rust.friendCodeDispatches, ['own-first']);
    },
  );

  test(
    'own friend codes are isolated by account and cleared on removal',
    () async {
      storage.values[_tokensKey] = jsonEncode({
        _account: 'synthetic-old-session',
        'second-account': 'synthetic-second-session',
      });
      final backend = await open();
      final first = await backend.loadNintendoFriendCode(_account, 'own-a');
      final second = await backend.loadNintendoFriendCode(
        'second-account',
        'own-b',
      );
      expect(first.friendCode, '1234-5678-9012');
      expect(second.friendCode, '9876-5432-1098');
      await backend.removeNintendoAccount(_account);
      expect(
        storage.values.values.any((value) => value.contains('1234-5678-9012')),
        isFalse,
      );
      expect(
        (await backend.loadNintendoFriendCode(
          'second-account',
          'own-b-again',
        )).friendCode,
        '9876-5432-1098',
      );
      expect(rust.friendCodeDispatches, ['own-a', 'own-b']);
    },
  );

  test(
    'a removed accounts late friend code cannot recreate its persistent cache',
    () async {
      final backend = await open();
      rust.friendCodeGate = Completer<NintendoFriendCodeSnapshot>();
      final request = backend.loadNintendoFriendCode(_account, 'own-late');
      final rejected = expectLater(request, throwsStateError);
      await rust.friendCodeStarted.future;
      await backend.removeNintendoAccount(_account);
      rust.friendCodeGate!.complete(
        const NintendoFriendCodeSnapshot(friendCode: '1234-5678-9012', url: ''),
      );
      await rejected;
      expect(
        storage.values.values.any((value) => value.contains('1234-5678-9012')),
        isFalse,
      );
    },
  );

  test('a failed friend code fetch is retried rather than cached', () async {
    final backend = await open();
    rust.friendCodeError = StateError('synthetic unavailable');
    await expectLater(
      backend.loadNintendoFriendCode(_account, 'own-failed'),
      throwsStateError,
    );
    rust.friendCodeError = null;
    expect(
      (await backend.loadNintendoFriendCode(_account, 'own-retry')).friendCode,
      '1234-5678-9012',
    );
    expect(rust.friendCodeDispatches, ['own-failed', 'own-retry']);
  });

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
  final syncRequests = <({String account, String token, String? proxy})>[];
  final syncHistory = <Map<String, Object?>>[];
  final syncResult = SyncSummary(
    jobId: 'synthetic-sync',
    totalFound: BigInt.from(9),
    downloaded: BigInt.from(2),
    duplicates: BigInt.one,
    skippedRemote: BigInt.from(5),
    failed: BigInt.one,
    errors: const [SyncItemError(message: 'synthetic media download failure')],
  );
  Object? syncError;
  CoralSession? refreshedSession;
  int syncCancellations = 0;
  final cancelled = <String>[];
  final friendCodeDispatches = <String>[];
  final friendCodeStarted = Completer<void>();
  Completer<NintendoFriendCodeSnapshot>? friendCodeGate;
  Object? friendCodeError;
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
  Future<CoralSession> crateBridgeEstablishCoralSessionForAccount({
    required String sessionToken,
    required String expectedAccount,
    String? proxyUrl,
  }) async =>
      refreshedSession ??
      CoralSession(
        accessToken: 'synthetic-coral',
        naId: expectedAccount,
        nickname: 'Synthetic account',
      );

  @override
  Future<SyncSummary> crateBridgeSyncNso({
    required CoralSession session,
    String? proxyUrl,
  }) async {
    if (syncError case final failure?) throw failure;
    return syncResult;
  }

  @override
  Future<SyncSummary> crateBridgeSyncNsoFromSessionTokenForAccount({
    required String sessionToken,
    required String expectedAccount,
    String? proxyUrl,
  }) async {
    syncRequests.add((
      account: expectedAccount,
      token: sessionToken,
      proxy: proxyUrl,
    ));
    if (syncError case final failure?) throw failure;
    return syncResult;
  }

  @override
  Future<bool> crateBridgeCancelCurrentSync() async {
    syncCancellations++;
    return true;
  }

  @override
  Future<SyncRuntimeState> crateBridgeRecordSyncAttempt({
    required String accountId,
    required String status,
    required BigInt totalFound,
    required BigInt downloaded,
    required BigInt duplicates,
    BigInt? skippedRemote,
    required BigInt failed,
  }) async {
    syncHistory.add({
      'account': accountId,
      'status': status,
      'found': totalFound,
      'downloaded': downloaded,
      'duplicates': duplicates,
      'existing': skippedRemote,
      'failed': failed,
    });
    return const SyncRuntimeState();
  }

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
    notifyOnAutoSync: true,
    showSplatoonSchedule: true,
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
  Future<NintendoFriendCodeSnapshot> crateBridgeNintendoFriendCode({
    required String accountId,
    required String sessionToken,
    required String operationId,
    String? proxyUrl,
  }) async {
    friendCodeDispatches.add(operationId);
    if (!friendCodeStarted.isCompleted) friendCodeStarted.complete();
    final error = friendCodeError;
    if (error != null) throw error;
    if (friendCodeGate != null) return friendCodeGate!.future;
    return NintendoFriendCodeSnapshot(
      friendCode: accountId == _account ? '1234-5678-9012' : '9876-5432-1098',
      url: '',
    );
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
