import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/account_tools/web_resource_lifecycle.dart';

void main() {
  test(
    'closing waits for delayed native creation and releases it exactly once',
    () async {
      final lifecycle = WebResourceLifecycle();
      final created = Completer<void>();
      var allocated = false;
      var releases = 0;
      final opening = lifecycle.initialize(() async {
        await created.future;
        allocated = true;
      });
      final closing = lifecycle.close(() async {
        expect(allocated, isTrue);
        releases++;
      });
      expect(lifecycle.active, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(releases, 0);
      created.complete();
      await opening;
      await closing;
      await lifecycle.close(() async => releases++);
      expect(releases, 1);
    },
  );

  test(
    'failed initialization still releases resources and keeps cleanup failure',
    () async {
      final lifecycle = WebResourceLifecycle();
      final opening = lifecycle.initialize(
        () async => throw StateError('allocate'),
      );
      await expectLater(opening, throwsStateError);
      var releases = 0;
      final closing = lifecycle.close(() async {
        releases++;
        throw StateError('cleanup');
      });
      await expectLater(closing, throwsStateError);
      await expectLater(
        lifecycle.close(() async => releases++),
        throwsStateError,
      );
      expect(releases, 1);
    },
  );
}
