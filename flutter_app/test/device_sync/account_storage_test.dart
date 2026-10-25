import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';

void main() {
  test('oversized history is retained locally but cannot be exported or silently truncated', () async {
    final profiles = {
      for (var index = 0; index < 1025; index++)
        'synthetic-${index.toString().padLeft(4, '0')}': {
          'nickname': 'Synthetic',
        },
    };
    final storage = MemoryAccountStorage(
      values: {accountProfilesKey: jsonEncode(profiles)},
    );
    final before = Map<String, String>.of(storage.values);
    final snapshot = await AccountSnapshot.read(storage, authorized: true);
    expect(snapshot.payload.accounts, isEmpty);
    expect(snapshot.payload.displayNames.length, 1025);
    expect(
      () => snapshot.payload.toJson(),
      throwsA(isA<AccountPayloadInvalid>()),
    );
    expect(storage.values, before);
  });

  test('v1 remains byte-compatible and malformed v2 names stay bounded', () {
    const legacy =
        '{"version":1,"accounts":[{"account_id":"a","nickname":"Alice","session_token":"synthetic"}]}';
    expect(AccountPayload.parse(legacy).toJson(), legacy);
    for (final stamp in [
      '2026-02-30T00:00:00Z',
      '2026-10-24T00:00:00+24:00',
      'not-a-time',
    ]) {
      expect(
        () => AccountPayload.parse(
          jsonEncode({
            'version': 2,
            'accounts': [],
            'display_names': [
              {'account_id': 'a', 'nickname': 'Alice', 'updated_at': stamp},
            ],
          }),
        ),
        throwsA(isA<AccountPayloadInvalid>()),
      );
    }
    expect(
      () => AccountPayload.parse(
        jsonEncode({
          'version': 2,
          'accounts': [],
          'display_names': [
            {'account_id': 'a', 'nickname': '界' * 86, 'updated_at': null},
          ],
        }),
      ),
      throwsA(isA<AccountPayloadInvalid>()),
    );
  });

  test(
    'restore keeps exact saved credentials and newer local name history',
    () {
      final restored = restoreAccountStateWithNameHistory(
        current: {
          accountTokensKey: '{"current":"synthetic-current"}',
          accountProfilesKey: '{"old":{"nickname":"Latest old name","name_updated_at":"2026-10-24T00:00:00Z"},"current":{"nickname":"Current user","name_updated_at":"2026-10-24T00:00:00Z"}}',
        },
        saved: {
          legacySessionKey: 'synthetic-legacy',
          accountTokensKey: '{"old":"synthetic-old"}',
          selectedAccountKey: 'old',
          accountProfilesKey: '{"old":{"nickname":"Older name","name_updated_at":"2026-10-22T00:00:00Z","avatar_url":"synthetic-avatar"}}',
        },
      );
      expect(restored[legacySessionKey], 'synthetic-legacy');
      expect(restored[accountTokensKey], '{"old":"synthetic-old"}');
      expect(restored[selectedAccountKey], 'old');
      final names = jsonDecode(restored[accountProfilesKey]!) as Map;
      expect(names['old']['nickname'], 'Latest old name');
      expect(names['old']['avatar_url'], 'synthetic-avatar');
      expect(names['current']['nickname'], 'Current user');
    },
  );
  test('v2 transfers removed names without creating credentials and keeps local history on overwrite', () async {
    final target = AccountSnapshot.fromRaw({
      accountTokensKey: '{"a":"synthetic-a"}',
      accountProfilesKey: '{"a":{"nickname":"Alice"},"local-old":{"nickname":"Local","name_updated_at":"2026-10-23T00:00:00Z"}}',
    });
    final source = AccountPayload.parse(
      '{"version":2,"accounts":[],"display_names":[{"account_id":"removed","nickname":"Previous user","updated_at":"2026-10-24T00:00:00Z"}]}',
    );
    expect(jsonDecode(source.toJson())['display_names'], hasLength(1));
    final change = AccountChange.preview(target, source, overwrite: true);
    expect(change.candidate[accountTokensKey], isNull);
    final profiles = jsonDecode(change.candidate[accountProfilesKey]!) as Map;
    expect(profiles['removed']['nickname'], 'Previous user');
    expect(profiles['local-old']['nickname'], 'Local');
    expect(profiles['a']['nickname'], 'Alice');
    expect(change.added, isEmpty);
    expect(change.removed, ['a']);
  });
  test(
    'export requires separate local consent before reading any secure key',
    () async {
      final storage = MemoryAccountStorage()..denyReads = true;
      await expectLater(
        AccountSnapshot.read(storage, authorized: false),
        throwsA(isA<AccountConsentRequired>()),
      );
    },
  );

  test(
    'raw four-key snapshot projects credentials and minimal name history',
    () async {
      final storage = MemoryAccountStorage(
        values: {
          accountTokensKey: jsonEncode({
            'b': 'synthetic-b',
            'a': 'synthetic-a',
          }),
          accountProfilesKey: jsonEncode({
            'a': {
              'nickname': 'Alice',
              'avatar_url': 'private-url',
              'avatar_base64': 'private-bytes',
            },
          }),
          selectedAccountKey: 'b',
        },
      );
      final before = Map<String, String>.from(storage.values);
      final snapshot = await AccountSnapshot.read(storage, authorized: true);
      final json = snapshot.payload.toJson();
      expect(
        json,
        '{"version":2,"accounts":[{"account_id":"a","nickname":"Alice","session_token":"synthetic-a"},{"account_id":"b","nickname":"","session_token":"synthetic-b"}],"display_names":[{"account_id":"a","nickname":"Alice","updated_at":null}]}',
      );
      expect(json, isNot(contains('avatar')));
      expect(snapshot.toString(), isNot(contains('synthetic-a')));
      expect(snapshot.raw[legacySessionKey], isNull);
      expect(storage.values, before);
    },
  );

  test(
    'legacy single token without stable identity remains a handleable state',
    () async {
      final storage = MemoryAccountStorage(
        values: {legacySessionKey: 'synthetic-legacy'},
      );
      await expectLater(
        AccountSnapshot.read(storage, authorized: true),
        throwsA(isA<LegacyAccountRequiresSignIn>()),
      );
      expect(storage.values, {legacySessionKey: 'synthetic-legacy'});
    },
  );

  test('merge is source-priority by ID and keeps target selection without source plan', () async {
    final target = await AccountSnapshot.read(
      MemoryAccountStorage(
        values: {
          accountTokensKey: '{"a":"target-a","b":"target-b"}',
          selectedAccountKey: 'b',
          legacySessionKey: 'old-active-legacy',
        },
      ),
      authorized: true,
    );
    final incoming = AccountPayload.parse(
      '{"version":1,"accounts":[{"account_id":"a","nickname":"Alice","session_token":"source-a"},{"account_id":"c","nickname":"Chris","session_token":"source-c"}]}',
    );
    final merge = AccountChange.preview(target, incoming, overwrite: false);
    expect(jsonDecode(merge.candidate[accountTokensKey]!), {
      'a': 'source-a',
      'b': 'target-b',
      'c': 'source-c',
    });
    expect(merge.candidate[selectedAccountKey], 'b');
    expect(merge.candidate[legacySessionKey], isNull);
    expect(merge.added, ['c']);
    expect(merge.replaced, ['a']);
    expect(merge.removed, isEmpty);
    final overwrite = AccountChange.preview(target, incoming, overwrite: true);
    expect(overwrite.candidate[selectedAccountKey], 'a');
    expect(overwrite.removed, ['b']);
    final empty = AccountChange.preview(
      target,
      AccountPayload.parse('{"version":1,"accounts":[]}'),
      overwrite: true,
    );
    expect(empty.candidate.values.every((v) => v == null), isTrue);
  });

  test('payload rejects unknown secret fields duplicates and byte boundaries without echoing values', () {
    for (final json in [
      '{"version":2,"accounts":[]}',
      '{"version":1,"accounts":[],"selected":"synthetic-secret"}',
      '{"version":1,"accounts":[{"account_id":"a","nickname":"","session_token":"synthetic-secret","avatar_url":"private"}]}',
      '{"version":1,"accounts":[{"account_id":"a","nickname":"","session_token":"${'x' * 8193}"}]}',
      ' ' * 262145,
    ]) {
      try {
        AccountPayload.parse(json);
        fail('invalid payload was accepted');
      } on AccountPayloadInvalid catch (error) {
        expect(error.toString(), isNot(contains('synthetic-secret')));
      }
    }
  });
}

class MemoryAccountStorage implements AccountSecureStorage {
  MemoryAccountStorage({Map<String, String>? values}) : values = {...?values};
  final Map<String, String> values;
  bool denyReads = false;
  @override
  Future<String?> read(String key) async {
    if (denyReads) throw StateError('secure reads forbidden');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
