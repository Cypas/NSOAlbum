import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';

void main() {
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
    'raw four-key snapshot projects only stable ID nickname and session token',
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
        '{"version":1,"accounts":[{"account_id":"a","nickname":"Alice","session_token":"synthetic-a"},{"account_id":"b","nickname":"","session_token":"synthetic-b"}]}',
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
