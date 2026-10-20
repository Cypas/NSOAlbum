import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/video_preview_cache.dart';

void main() {
  test(
    'shared decode is cancelled only after its last consumer leaves',
    () async {
      final gate = Completer<int?>();
      var loads = 0, cancels = 0;
      final cache = PreviewCache<int>(
        maxEntries: 2,
        maxBytes: 10,
        sizeOf: (_) => 1,
      );
      Future<int?> load(PreviewWork work) {
        loads++;
        work.onCancel = () {
          cancels++;
        };
        return gate.future;
      }

      final first = cache.request('a', load: load);
      final second = cache.request('a', load: load);
      first.cancel();
      expect(loads, 1);
      expect(cancels, 0);
      second.cancel();
      expect(cancels, 1);
      gate.complete(7);
      expect(await second.future, isNull);
      final fresh = cache.request('a', load: (_) async => 9);
      expect(await fresh.future, 9);
    },
  );

  test(
    'cancelled queued work is skipped and current item takes priority',
    () async {
      final gate = Completer<int?>();
      final cache = PreviewCache<int>(
        maxEntries: 4,
        maxBytes: 10,
        sizeOf: (_) => 1,
      );
      final starts = <String>[];
      final active = cache.request(
        'active',
        load: (_) {
          starts.add('active');
          return gate.future;
        },
      );
      final stale = cache.request(
        'stale',
        load: (_) async {
          starts.add('stale');
          return 2;
        },
      );
      final ordinary = cache.request(
        'ordinary',
        load: (_) async {
          starts.add('ordinary');
          return 3;
        },
      );
      stale.cancel();
      final current = cache.request(
        'current',
        urgent: true,
        load: (_) async {
          starts.add('current');
          return 4;
        },
      );
      gate.complete(1);
      await Future.wait([
        active.future,
        stale.future,
        ordinary.future,
        current.future,
      ]);
      expect(starts, ['active', 'current', 'ordinary']);
    },
  );

  test(
    'cache byte budget evicts old bytes without decoding an unchanged hit',
    () async {
      final cache = PreviewCache<int>(
        maxEntries: 3,
        maxBytes: 5,
        sizeOf: (n) => n,
      );
      var loads = 0;
      Future<int?> load(PreviewWork _) async {
        loads++;
        return 3;
      }

      expect(await cache.request('a', load: load).future, 3);
      expect(await cache.request('a', load: load).future, 3);
      expect(loads, 1);
      await cache.request('b', load: load).future;
      await cache.request('a', load: load).future;
      expect(loads, 3);
    },
  );

  test(
    'bounded queue drops excess prefetch but admits current media',
    () async {
      final gate = Completer<int?>();
      final cache = PreviewCache<int>(
        maxEntries: 2,
        maxBytes: 10,
        sizeOf: (_) => 1,
      );
      final starts = <String>[];
      final active = cache.request(
        'active',
        load: (_) {
          starts.add('active');
          return gate.future;
        },
      );
      final pending = cache.request(
        'pending',
        load: (_) async {
          starts.add('pending');
          return 2;
        },
      );
      final excess = cache.request(
        'excess',
        load: (_) async {
          starts.add('excess');
          return 3;
        },
      );
      expect(await excess.future, isNull);
      final current = cache.request(
        'current',
        urgent: true,
        load: (_) async {
          starts.add('current');
          return 4;
        },
      );
      expect(await pending.future, isNull);
      gate.complete(1);
      await Future.wait([active.future, current.future]);
      expect(starts, ['active', 'current']);
    },
  );
}
