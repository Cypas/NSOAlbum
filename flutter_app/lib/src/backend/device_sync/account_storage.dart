import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../account_name_history.dart';

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
  AccountPayload(
    List<AccountCredential> values, {
    this.version = 1,
    List<NintendoAccountNameRecord> displayNames = const [],
    bool enforceTransferLimits = true,
  }) : accounts = List.unmodifiable(values),
       displayNames = List.unmodifiable(displayNames) {
    if (version != 1 && version != 2 ||
        version == 1 && displayNames.isNotEmpty) {
      throw AccountPayloadInvalid();
    }
    if (accounts.length > maxAccountCount) throw AccountPayloadInvalid();
    String? previous;
    for (final account in accounts) {
      if (previous != null && previous.compareTo(account.accountId) >= 0) {
        throw AccountPayloadInvalid();
      }
      previous = account.accountId;
    }
    previous = null;
    for (final record in displayNames) {
      if (!validAccountNameField(record.accountId, 128) ||
          !validAccountNameField(record.nickname, 256, empty: true) ||
          (record.serializedUpdatedAt != null &&
              parseAccountNameTimestamp(record.serializedUpdatedAt!) == null) ||
          (previous != null && previous.compareTo(record.accountId) >= 0)) {
        throw AccountPayloadInvalid();
      }
      previous = record.accountId;
    }
    if (enforceTransferLimits) toJson();
  }
  final List<AccountCredential> accounts;
  final int version;
  final List<NintendoAccountNameRecord> displayNames;
  factory AccountPayload.parse(String json) {
    if (json.length > maxAccountPayloadBytes ||
        utf8.encode(json).length > maxAccountPayloadBytes) {
      throw AccountPayloadInvalid();
    }
    try {
      final value = _map(json);
      final version = value['version'];
      if (!(version == 1 && value.length == 2 ||
              version == 2 &&
                  value.length == 3 &&
                  value['display_names'] is List) ||
          value['accounts'] is! List ||
          (value['accounts'] as List).length > maxAccountCount ||
          (version == 2 && (value['display_names'] as List).length > 1024)) {
        throw AccountPayloadInvalid();
      }
      return AccountPayload(
        [
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
        ],
        version: version as int,
        displayNames: version == 1
            ? const []
            : [
                for (final record in value['display_names'] as List)
                  if (record is Map<String, dynamic> &&
                      record.length == 3 &&
                      record['account_id'] is String &&
                      record['nickname'] is String &&
                      record.containsKey('updated_at') &&
                      (record['updated_at'] == null ||
                          record['updated_at'] is String &&
                              parseAccountNameTimestamp(
                                    record['updated_at'] as String,
                                  ) !=
                                  null))
                    NintendoAccountNameRecord(
                      accountId: record['account_id'] as String,
                      nickname: record['nickname'] as String,
                      updatedAt: record['updated_at'] == null
                          ? null
                          : parseAccountNameTimestamp(
                              record['updated_at'] as String,
                            ),
                      originalUpdatedAt: record['updated_at'] as String?,
                    )
                  else
                    throw AccountPayloadInvalid(),
              ],
      );
    } catch (_) {
      throw AccountPayloadInvalid();
    }
  }
  String toJson() {
    if (displayNames.length > 1024) throw AccountPayloadInvalid();
    final json = jsonEncode({
      'version': version,
      'accounts': [for (final a in accounts) a._json()],
      if (version == 2)
        'display_names': [for (final record in displayNames) record.toJson()],
    });
    if (utf8.encode(json).length > maxAccountPayloadBytes) {
      throw AccountPayloadInvalid();
    }
    return json;
  }

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
    validateRawAccountSize(raw);
    final tokens = _map(raw[accountTokensKey]);
    final legacy = raw[legacySessionKey];
    if (tokens.isEmpty && legacy != null && legacy.isNotEmpty) {
      throw LegacyAccountRequiresSignIn();
    }
    final profiles = _map(raw[accountProfilesKey]);
    final ids = tokens.keys.toList()..sort();
    if (ids.length > maxAccountCount) throw AccountPayloadInvalid();
    final names = accountNamesFromProfiles(profiles).values.toList()
      ..sort((a, b) => a.accountId.compareTo(b.accountId));
    payload = AccountPayload(
      [
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
      ],
      version: 2,
      displayNames: names,
      enforceTransferLimits: false,
    );
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

void validateRawAccountSize(Map<String, String?> raw) {
  var total = 0;
  for (final key in accountActiveKeys) {
    final value = raw[key];
    if (value == null) continue;
    if (value.length > maxAccountRawBytes) throw AccountPayloadInvalid();
    total += utf8.encode(value).length;
    if (total > maxAccountRawBytes) throw AccountPayloadInvalid();
  }
}

/// Restore the exact credential/selection keys while retaining newer names.
/// The resulting four-key candidate is journaled and rolled back as one unit.
Map<String, String?> restoreAccountStateWithNameHistory({
  required Map<String, String?> current,
  required Map<String, String?> saved,
}) {
  final savedSnapshot = AccountSnapshot.fromRaw(saved);
  final profiles = _map(saved[accountProfilesKey]);
  final names = mergeAccountNameHistory(
    local: accountNamesFromProfiles(_map(current[accountProfilesKey])),
    incoming: accountNamesFromProfiles(profiles).values,
  );
  final restoredIds = savedSnapshot.payload.accounts
      .map((account) => account.accountId)
      .toSet();
  final restoredProfiles = <String, dynamic>{
    for (final entry in profiles.entries)
      if (restoredIds.contains(entry.key)) entry.key: entry.value,
  };
  for (final record in names.values) {
    restoredProfiles[record.accountId] = {
      if (restoredProfiles[record.accountId] is Map)
        ...Map<String, dynamic>.from(restoredProfiles[record.accountId] as Map),
      'nickname': record.nickname,
      if (record.serializedUpdatedAt != null)
        'name_updated_at': record.serializedUpdatedAt,
    };
  }
  final candidate = {
    for (final key in accountActiveKeys) key: saved[key],
    accountProfilesKey: restoredProfiles.isEmpty
        ? null
        : jsonEncode(restoredProfiles),
  };
  validateRawAccountSize(candidate);
  return Map.unmodifiable(candidate);
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
    final profiles = _map(target.raw[accountProfilesKey]);
    final incomingNames = {
      for (final record in source.displayNames) record.accountId: record,
    };
    for (final account in source.accounts) {
      incomingNames.putIfAbsent(
        account.accountId,
        () => NintendoAccountNameRecord(
          accountId: account.accountId,
          nickname: account.nickname,
          updatedAt: null,
        ),
      );
    }
    final names = mergeAccountNameHistory(
      local: accountNamesFromProfiles(profiles),
      incoming: incomingNames.values,
    );
    for (final id in profiles.keys.toList()) {
      if (!merged.containsKey(id)) {
        final record = names[id];
        if (record == null) {
          profiles.remove(id);
        } else {
          profiles[id] = {
            'nickname': record.nickname,
            if (record.serializedUpdatedAt != null)
              'name_updated_at': record.serializedUpdatedAt,
          };
        }
      }
    }
    for (final record in names.values) {
      profiles[record.accountId] = {
        if (merged.containsKey(record.accountId) &&
            profiles[record.accountId] is Map)
          ...Map<String, dynamic>.from(profiles[record.accountId] as Map),
        'nickname': record.nickname,
        if (record.serializedUpdatedAt != null)
          'name_updated_at': record.serializedUpdatedAt,
      };
    }
    for (final account in merged.values) {
      profiles.putIfAbsent(
        account.accountId,
        () => {'nickname': account.nickname},
      );
    }
    final selected = target.raw[selectedAccountKey];
    final candidate = <String, String?>{
      legacySessionKey: null,
      accountTokensKey: ids.isEmpty
          ? null
          : jsonEncode({for (final id in ids) id: merged[id]!.sessionToken}),
      accountProfilesKey: profiles.isEmpty ? null : jsonEncode(profiles),
      selectedAccountKey: ids.isEmpty
          ? null
          : merged.containsKey(selected)
          ? selected
          : ids.first,
    };
    validateRawAccountSize(candidate);
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
