import 'dart:convert';

/// Non-authenticating display metadata. Never use a name to identify a login.
class NintendoAccountNameRecord {
  const NintendoAccountNameRecord({
    required this.accountId,
    required this.nickname,
    required this.updatedAt,
    this.originalUpdatedAt,
  });

  final String accountId;
  final String nickname;
  final DateTime? updatedAt;
  final String? originalUpdatedAt;
  String? get serializedUpdatedAt =>
      originalUpdatedAt ?? updatedAt?.toUtc().toIso8601String();

  Map<String, Object?> toJson() => {
    'account_id': accountId,
    'nickname': nickname,
    'updated_at': serializedUpdatedAt,
  };

  @override
  String toString() => 'NintendoAccountNameRecord([REDACTED])';
}

abstract interface class NintendoAccountNameHistoryBackend {
  Future<List<NintendoAccountNameRecord>> listNintendoAccountNameHistory();
}

bool validAccountNameField(String value, int maxBytes, {bool empty = false}) =>
    (empty || value.trim().isNotEmpty) &&
    value.length <= maxBytes &&
    utf8.encode(value).length <= maxBytes &&
    !value.runes.any((r) => r < 32 || (r >= 127 && r <= 159));

DateTime? parseAccountNameTimestamp(String value) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (match == null || value.length > 64) return null;
  final parts = [
    for (var index = 1; index <= 6; index++) int.parse(match.group(index)!),
  ];
  if (parts[1] < 1 ||
      parts[1] > 12 ||
      parts[2] < 1 ||
      parts[2] > DateTime.utc(parts[0], parts[1] + 1, 0).day ||
      parts[3] > 23 ||
      parts[4] > 59 ||
      parts[5] > 60) {
    return null;
  }
  if (!value.toUpperCase().endsWith('Z')) {
    final zone = value.substring(value.length - 5);
    if (int.parse(zone.substring(0, 2)) > 23 ||
        int.parse(zone.substring(3)) > 59) {
      return null;
    }
  }
  return DateTime.tryParse(value.toUpperCase());
}

Map<String, NintendoAccountNameRecord> mergeAccountNameHistory({
  required Map<String, NintendoAccountNameRecord> local,
  required Iterable<NintendoAccountNameRecord> incoming,
}) {
  final merged = Map<String, NintendoAccountNameRecord>.of(local);
  for (final record in incoming) {
    if (record.nickname.trim().isEmpty) continue;
    final old = merged[record.accountId];
    if (old == null ||
        old.nickname.trim().isEmpty ||
        (record.updatedAt != null &&
            (old.updatedAt == null || _compareNameUpdate(record, old) > 0))) {
      merged[record.accountId] = record;
    }
  }
  return merged;
}

int _compareNameUpdate(
  NintendoAccountNameRecord left,
  NintendoAccountNameRecord right,
) {
  final microseconds = left.updatedAt!.compareTo(right.updatedAt!);
  if (microseconds != 0) return microseconds;
  // DateTime truncates fractions after six digits. Compare the retained wire
  // fraction too, so finer updates are not mistaken for equal local records.
  String remainder(NintendoAccountNameRecord record) {
    final fraction = RegExp(r'\.(\d+)')
        .firstMatch(record.serializedUpdatedAt ?? '')
        ?.group(1);
    return fraction != null && fraction.length > 6 ? fraction.substring(6) : '';
  }

  final leftTail = remainder(left);
  final rightTail = remainder(right);
  final length = leftTail.length > rightTail.length
      ? leftTail.length
      : rightTail.length;
  return leftTail
      .padRight(length, '0')
      .compareTo(rightTail.padRight(length, '0'));
}

/// Read old profile records without inventing an update time.
Map<String, NintendoAccountNameRecord> accountNamesFromProfiles(Map profiles) {
  final names = <String, NintendoAccountNameRecord>{};
  for (final entry in profiles.entries) {
    final value = entry.value;
    if (entry.key is! String || value is! Map || value['nickname'] is! String) {
      continue;
    }
    final nickname = value['nickname'] as String;
    if (!validAccountNameField(entry.key as String, 128) ||
        !validAccountNameField(nickname, 256)) {
      continue;
    }
    final raw = value['name_updated_at'];
    final stamp = raw is String ? parseAccountNameTimestamp(raw) : null;
    names[entry.key as String] = NintendoAccountNameRecord(
      accountId: entry.key as String,
      nickname: nickname,
      updatedAt: stamp,
      originalUpdatedAt: stamp == null ? null : raw as String,
    );
  }
  return names;
}
