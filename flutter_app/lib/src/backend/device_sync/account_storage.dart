import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const legacySessionKey = 'nintendo.session_token';
const accountTokensKey = 'nintendo.account_tokens.v1';
const accountProfilesKey = 'nintendo.account_profiles.v1';
const selectedAccountKey = 'nintendo.selected_account.v1';
const accountActiveKeys = [
  legacySessionKey,
  accountTokensKey,
  accountProfilesKey,
  selectedAccountKey,
];
const maxAccountPayloadBytes = 262144;
const maxAccountCount = 32;
const maxAccountRawBytes = 8 * 1024 * 1024;

abstract interface class AccountSecureStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterAccountSecureStorage implements AccountSecureStorage {
  FlutterAccountSecureStorage(this.storage);
  final FlutterSecureStorage storage;
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

class AccountConsentRequired implements Exception {
  @override
  String toString() => 'Separate local account confirmation is required';
}

class AccountPayloadInvalid implements Exception {
  @override
  String toString() =>
      'Account data is invalid or exceeds its resource boundary';
}

class LegacyAccountRequiresSignIn implements Exception {
  @override
  String toString() =>
      'The legacy account must be signed in before account transfer';
}

bool _bounded(String value, int bytes, {bool empty = false}) =>
    (empty || value.trim().isNotEmpty) &&
    value.length <= bytes &&
    utf8.encode(value).length <= bytes &&
    !value.runes.any((r) => r < 32 || (r >= 127 && r <= 159));

Map<String, dynamic> _map(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final value = jsonDecode(raw);
    if (value is Map<String, dynamic>) return value;
  } catch (_) {
    // JSON/parser messages must never escape with credential fragments.
  }
  throw AccountPayloadInvalid();
}

class AccountCredential {
  AccountCredential(this.accountId, this.nickname, this.sessionToken) {
    if (!_bounded(accountId, 128) ||
        !_bounded(nickname, 256, empty: true) ||
        !_bounded(sessionToken, 8192)) {
      throw AccountPayloadInvalid();
    }
  }
  final String accountId;
  final String nickname;
  final String sessionToken;
  Map<String, String> _json() => {
    'account_id': accountId,
    'nickname': nickname,
    'session_token': sessionToken,
  };
  @override
  String toString() => 'AccountCredential([REDACTED])';
}

class AccountPayload {
  AccountPayload(List<AccountCredential> values)
    : accounts = List.unmodifiable(values) {
    if (accounts.length > maxAccountCount) throw AccountPayloadInvalid();
    String? previous;
    for (final account in accounts) {
      if (previous != null && previous.compareTo(account.accountId) >= 0) {
        throw AccountPayloadInvalid();
      }
      previous = account.accountId;
    }
    if (utf8.encode(toJson()).length > maxAccountPayloadBytes) {
      throw AccountPayloadInvalid();
    }
  }
  final List<AccountCredential> accounts;
  factory AccountPayload.parse(String json) {
    if (json.length > maxAccountPayloadBytes ||
        utf8.encode(json).length > maxAccountPayloadBytes) {
      throw AccountPayloadInvalid();
    }
    try {
      final value = _map(json);
      if (value.length != 2 ||
          value['version'] != 1 ||
          value['accounts'] is! List ||
          (value['accounts'] as List).length > maxAccountCount) {
        throw AccountPayloadInvalid();
      }
      return AccountPayload([
        for (final account in value['accounts'] as List)
          if (account is Map<String, dynamic> &&
              account.length == 3 &&
              account['account_id'] is String &&
              account['nickname'] is String &&
              account['session_token'] is String)
            AccountCredential(
              account['account_id'] as String,
              account['nickname'] as String,
              account['session_token'] as String,
            )
          else
            throw AccountPayloadInvalid(),
      ]);
    } catch (_) {
      throw AccountPayloadInvalid();
    }
  }
  String toJson() => jsonEncode({
    'version': 1,
    'accounts': [for (final a in accounts) a._json()],
  });
  @override
  String toString() => 'AccountPayload(count: ${accounts.length}, [REDACTED])';
}

class AccountSnapshot {
  factory AccountSnapshot.fromRaw(Map<String, String?> values) =>
      AccountSnapshot._({
        for (final key in accountActiveKeys) key: values[key],
      });
  AccountSnapshot._(Map<String, String?> values)
    : raw = Map.unmodifiable(values) {
    final tokens = _map(raw[accountTokensKey]);
    final legacy = raw[legacySessionKey];
    if (tokens.isEmpty && legacy != null && legacy.isNotEmpty) {
      throw LegacyAccountRequiresSignIn();
    }
    final profiles = _map(raw[accountProfilesKey]);
    final ids = tokens.keys.toList()..sort();
    if (ids.length > maxAccountCount) throw AccountPayloadInvalid();
    payload = AccountPayload([
      for (final id in ids)
        AccountCredential(
          id,
          profiles[id] is Map && (profiles[id] as Map)['nickname'] is String
              ? (profiles[id] as Map)['nickname'] as String
              : '',
          tokens[id] is String
              ? tokens[id] as String
              : throw AccountPayloadInvalid(),
        ),
    ]);
  }
  final Map<String, String?> raw;
  late final AccountPayload payload;
  String get digest => rawAccountDigest(raw);

  static Future<AccountSnapshot> read(
    AccountSecureStorage storage, {
    required bool authorized,
  }) async {
    if (!authorized) throw AccountConsentRequired();
    return AccountSnapshot._(await readRawAccountKeys(storage));
  }

  @override
  String toString() => 'AccountSnapshot([REDACTED])';
}

Future<Map<String, String?>> readRawAccountKeys(
  AccountSecureStorage storage,
) async {
  final raw = <String, String?>{};
  var total = 0;
  for (final key in accountActiveKeys) {
    final value = await storage.read(key);
    if (value != null) {
      if (value.length > maxAccountRawBytes) throw AccountPayloadInvalid();
      total += utf8.encode(value).length;
      if (total > maxAccountRawBytes) throw AccountPayloadInvalid();
    }
    raw[key] = value;
  }
  return raw;
}

String rawAccountDigest(Map<String, String?> raw) => sha256
    .convert(
      utf8.encode(jsonEncode([for (final key in accountActiveKeys) raw[key]])),
    )
    .toString();

class AccountChange {
  AccountChange._(
    this.before,
    this.candidate,
    this.added,
    this.replaced,
    this.removed,
  );
  final AccountSnapshot before;
  final Map<String, String?> candidate;
  final List<String> added;
  final List<String> replaced;
  final List<String> removed;
  factory AccountChange.preview(
    AccountSnapshot target,
    AccountPayload source, {
    required bool overwrite,
  }) {
    final old = {for (final a in target.payload.accounts) a.accountId: a};
    final incoming = {for (final a in source.accounts) a.accountId: a};
    final merged = <String, AccountCredential>{
      if (!overwrite) ...old,
      ...incoming,
    };
    if (merged.length > maxAccountCount) throw AccountPayloadInvalid();
    final ids = merged.keys.toList()..sort();
    final profiles = overwrite
        ? <String, dynamic>{}
        : _map(target.raw[accountProfilesKey]);
    profiles.removeWhere((key, _) => !merged.containsKey(key));
    for (final account in source.accounts) {
      profiles[account.accountId] = {'nickname': account.nickname};
    }
    final selected = target.raw[selectedAccountKey];
    final candidate = <String, String?>{
      legacySessionKey: null,
      accountTokensKey: ids.isEmpty
          ? null
          : jsonEncode({for (final id in ids) id: merged[id]!.sessionToken}),
      accountProfilesKey: ids.isEmpty ? null : jsonEncode(profiles),
      selectedAccountKey: ids.isEmpty
          ? null
          : merged.containsKey(selected)
          ? selected
          : ids.first,
    };
    final added = incoming.keys.where((id) => !old.containsKey(id)).toList()
      ..sort();
    final replaced =
        incoming.keys
            .where(
              (id) =>
                  old.containsKey(id) &&
                  (old[id]!.sessionToken != incoming[id]!.sessionToken ||
                      old[id]!.nickname != incoming[id]!.nickname),
            )
            .toList()
          ..sort();
    final removed = overwrite
        ? old.keys.where((id) => !incoming.containsKey(id)).toList()
        : <String>[];
    removed.sort();
    return AccountChange._(
      target,
      Map.unmodifiable(candidate),
      List.unmodifiable(added),
      List.unmodifiable(replaced),
      List.unmodifiable(removed),
    );
  }
  @override
  String toString() => 'AccountChange([REDACTED])';
}
