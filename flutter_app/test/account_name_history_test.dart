import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/account_name_history.dart';

void main() {
  test(
    'history compares sub-microsecond updates without changing wire time',
    () {
      final local = accountNamesFromProfiles({
        'a': {
          'nickname': 'Local',
          'name_updated_at': '2026-10-24T08:00:00.123456700+08:00',
        },
      });
      final newer = accountNamesFromProfiles({
        'a': {
          'nickname': 'Newer',
          'name_updated_at': '2026-10-24T00:00:00.123456789Z',
        },
      });
      final merged = mergeAccountNameHistory(
        local: local,
        incoming: newer.values,
      );
      expect(merged['a']!.nickname, 'Newer');
      expect(
        merged['a']!.serializedUpdatedAt,
        '2026-10-24T00:00:00.123456789Z',
      );
      final sameInstant = accountNamesFromProfiles({
        'a': {
          'nickname': 'Same instant',
          'name_updated_at': '2026-10-24T08:00:00.1234567890+08:00',
        },
      });
      expect(
        mergeAccountNameHistory(
          local: merged,
          incoming: sameInstant.values,
        )['a']!.nickname,
        'Newer',
      );
    },
  );

  test(
    'profile history preserves unknown age and rejects invalid timestamps',
    () {
      final records = accountNamesFromProfiles({
        'old': {'nickname': 'Old user'},
        'known': {
          'nickname': 'Current',
          'name_updated_at': '2026-10-24T00:00:00.123456789Z',
        },
      });
      expect(records['old']!.updatedAt, isNull);
      expect(
        records['known']!.serializedUpdatedAt,
        '2026-10-24T00:00:00.123456789Z',
      );
      expect(parseAccountNameTimestamp('2026-02-30T00:00:00Z'), isNull);
      expect(parseAccountNameTimestamp('2026-10-24T00:00:00+24:00'), isNull);
    },
  );
  test(
    'history keeps newer known local names and accepts newer remote names',
    () {
      final local = {
        'a': NintendoAccountNameRecord(
          accountId: 'a',
          nickname: 'Local',
          updatedAt: DateTime.utc(2026, 10, 24),
        ),
        'b': const NintendoAccountNameRecord(
          accountId: 'b',
          nickname: 'Old',
          updatedAt: null,
        ),
      };
      final merged = mergeAccountNameHistory(
        local: local,
        incoming: [
          const NintendoAccountNameRecord(
            accountId: 'a',
            nickname: 'Unknown age',
            updatedAt: null,
          ),
          NintendoAccountNameRecord(
            accountId: 'b',
            nickname: 'Updated',
            updatedAt: DateTime.utc(2026, 10, 24),
          ),
          const NintendoAccountNameRecord(
            accountId: 'removed',
            nickname: 'Previous',
            updatedAt: null,
          ),
        ],
      );
      expect(merged['a']!.nickname, 'Local');
      expect(merged['b']!.nickname, 'Updated');
      expect(merged['removed']!.nickname, 'Previous');
      expect(local.length, 2);
      expect(local['b']!.nickname, 'Old');
    },
  );

  test('equal times and empty remote names never erase local history', () {
    final stamp = DateTime.utc(2026, 10, 24);
    final merged = mergeAccountNameHistory(
      local: {
        'a': NintendoAccountNameRecord(
          accountId: 'a',
          nickname: 'Local',
          updatedAt: stamp,
        ),
      },
      incoming: [
        NintendoAccountNameRecord(
          accountId: 'a',
          nickname: 'Other',
          updatedAt: stamp,
        ),
        NintendoAccountNameRecord(
          accountId: 'a',
          nickname: '',
          updatedAt: stamp.add(const Duration(days: 1)),
        ),
      ],
    );
    expect(merged['a']!.nickname, 'Local');
  });
}
