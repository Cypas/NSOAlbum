import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// OS storage and network completions are the only replaced boundaries.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/backend/rust_backend.dart';
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/rust/nso/provider.dart';
import 'package:squid_album/src/rust/settings.dart';

import 'startup_native_boundary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Network rust;
  late _Storage storage;
  late FlutterSecureStoragePlatform previous;
  late Directory root;
  const browser = MethodChannel('plugins.flutter.io/url_launcher');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nsoalbum-fix1-login-');
    rust = _Network();
    RustLib.initMock(api: rust);
    previous = FlutterSecureStoragePlatform.instance;
    storage = _Storage();
    FlutterSecureStoragePlatform.instance = storage;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browser, (_) async => true);
  });
  tearDown(() async {
    FlutterSecureStoragePlatform.instance = previous;
    RustLib.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browser, null);
    debugPrintSynchronously(
      'Synthetic login fault root retained: ${root.path}',
    );
  });
  Future<RustBackend> open() => RustBackend.open(
    storage: const FlutterSecureStorage(),
    applicationRoot: root.path,
  );
  Map<String, String?> active() => {
    for (final key in accountActiveKeys) key: storage.values[key],
  };
  Future<Object?> complete(RustBackend backend, String flow) => backend
      .completeNintendoLogin('synthetic-callback-$flow')
      .then<Object?>(
        (_) => null,
        onError: (Object error, StackTrace _) => error,
      );

  test('late login cannot overwrite newer credentials or clear the newer pending flow', () async {
    final backend = await open();
    rust.delayed['a'] = Completer<CoralSession>();
    await backend.beginNintendoLogin();
    final old = complete(backend, 'a');
    await rust.started('a');
    await backend.beginNintendoLogin();
    expect(await complete(backend, 'b'), isNull);
    expect(storage.values[accountTokensKey], '{"b":"synthetic-token-b"}');
    final current = active();
    await backend.beginNintendoLogin(); // C remains pending when A returns.
    rust.delayed['a']!.complete(_session('a'));
    final oldResult = await old;
    expect(active(), current);
    expect(oldResult, isStateError);
    expect((await backend.nintendoAccountProfile)?.accountId, 'b');
    expect(await complete(backend, 'c'), isNull);
    expect(rust.exchanges.last, 'c');
    expect(jsonDecode(storage.values[accountTokensKey]!), {
      'b': 'synthetic-token-b',
      'c': 'synthetic-token-c',
    });
    expect(storage.values[selectedAccountKey], 'c');
    expect(jsonDecode(storage.values[accountProfilesKey]!).keys, ['b', 'c']);
    expect(rust.cleared, isNot(contains('a')));
  });

  for (final signOut in [false, true]) {
    test(
      'in-flight login cannot resurrect credentials after ${signOut ? 'signOut' : 'remove'}',
      () async {
        storage.values.addAll({
          accountTokensKey: '{"a":"synthetic-old-a"}',
          selectedAccountKey: 'a',
          accountProfilesKey: '{"a":{"nickname":"Old"}}',
        });
        final backend = await open();
        rust.delayed['a'] = Completer<CoralSession>();
        await backend.beginNintendoLogin();
        final old = complete(backend, 'a');
        await rust.started('a');
        if (signOut) {
          await backend.signOut();
        } else {
          await backend.removeNintendoAccount('a');
        }
        rust.delayed['a']!.complete(_session('a'));
        final oldResult = await old;
        expect(active(), {for (final key in accountActiveKeys) key: null});
        expect(oldResult, isStateError);
        expect(backend.accountToolLifecycle.isRemoved('a'), isTrue);
        expect(await backend.nintendoAccountProfile, isNull);
      },
    );
  }

  test(
    'late legacy migration cannot overwrite a newly selected login',
    () async {
      storage.values[legacySessionKey] = 'synthetic-token-legacy';
      final backend = await open();
      rust.delayed['legacy'] = Completer<CoralSession>();
      final old = backend.listNintendoAccounts().then<Object?>(
        (value) => value,
        onError: (Object error, StackTrace _) => error,
      );
      await rust.started('legacy');
      await backend.beginNintendoLogin();
      final newer = complete(backend, 'a');
      Object? newerResult;
      Map<String, String?>? current;
      try {
        newerResult = await newer.timeout(
          const Duration(seconds: 2),
          onTimeout: () =>
              StateError('new login blocked behind stale migration'),
        );
        if (newerResult == null) {
          await backend.selectNintendoAccount('a');
          current = active();
        }
      } finally {
        rust.delayed['legacy']!.complete(_session('legacy'));
      }
      final oldResult = await old;
      await newer;
      expect(newerResult, isNull);
      expect(oldResult, isStateError);
      expect(active(), current);
      expect(storage.values[accountTokensKey], '{"a":"synthetic-token-a"}');
      expect(storage.values[selectedAccountKey], 'a');
      expect((await backend.nintendoAccountProfile)?.accountId, 'a');
    },
  );

  test('normal multi-key credential commit cannot interleave a removal after its first write', () async {
    final backend = await open();
    await backend.beginNintendoLogin();
    storage.pauseToken = true;
    final login = complete(backend, 'a');
    await storage.writeStarted.future;
    var removed = false;
    final removal = backend.removeNintendoAccount('a').then((_) {
      removed = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final returnedEarly = removed;
    storage.writeRelease.complete();
    await login;
    await removal;
    expect(returnedEarly, isFalse);
    expect(active(), {for (final key in accountActiveKeys) key: null});
    expect(backend.accountToolLifecycle.isRemoved('a'), isTrue);
  });
}

CoralSession _session(String id) => CoralSession(
  accessToken: 'synthetic-coral-$id',
  naId: id,
  nickname: 'Synthetic $id',
);

class _Network with NoPendingStartupBoundary implements RustLibApi {
  int flows = 0;
  final delayed = <String, Completer<CoralSession>>{};
  final starts = <String, Completer<void>>{};
  final exchanges = <String>[];
  final cleared = <String>[];
  Future<void> started(String id) => (starts[id] ??= Completer<void>()).future;
  @override
  Future<void> crateBridgeInitCore({required String libraryRoot}) async {}
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
  Future<LoginChallenge> crateBridgeCreateNintendoLoginChallenge({
    String? proxyUrl,
  }) async {
    final flow = String.fromCharCode(97 + flows++);
    return LoginChallenge(
      authorizationUrl: 'https://accounts.nintendo.com/authorize',
      state: flow,
      verifier: 'synthetic-verifier-$flow',
    );
  }

  @override
  Future<String> crateBridgeExchangeNintendoCallback({
    required String callbackUrl,
    required String expectedState,
    required String verifier,
    String? proxyUrl,
  }) async {
    exchanges.add(expectedState);
    return 'synthetic-token-$expectedState';
  }

  @override
  Future<CoralSession> crateBridgeEstablishCoralSession({
    required String sessionToken,
    String? proxyUrl,
  }) async {
    final id = sessionToken.substring('synthetic-token-'.length);
    final start = starts[id] ??= Completer<void>();
    if (!start.isCompleted) start.complete();
    return delayed[id]?.future ?? _session(id);
  }

  @override
  Future<void> crateBridgeClearAccountToolCache({
    required String accountId,
  }) async {
    cleared.add(accountId);
  }

  @override
  Future<bool> crateBridgeCancelAccountToolOperation({
    required String operationId,
  }) async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected synthetic native operation ${invocation.memberName}',
  );
}

class _Storage extends FlutterSecureStoragePlatform {
  final values = <String, String>{};
  bool pauseToken = false;
  final writeStarted = Completer<void>();
  final writeRelease = Completer<void>();
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => values[key];
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (pauseToken && key == accountTokensKey) {
      pauseToken = false;
      writeStarted.complete();
      await writeRelease.future;
    }
    values[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    values.remove(key);
  }

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
      throw UnsupportedError(
        'Synthetic tests never clear unrelated secure storage',
      );
}
