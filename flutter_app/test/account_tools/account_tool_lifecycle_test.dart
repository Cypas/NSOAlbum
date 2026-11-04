import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/account_tool_lifecycle.dart';

void main() {
  test('same-ID credential invalidation awaits actual registered cleanup before availability', () async {
    final events = AccountToolLifecycle();
    final nativeDisposed = Completer<void>();
    var closed = false;
    final registration = events.registerCleanup('a', () async {
      await nativeDisposed.future;
      closed = true;
    });
    var invalidated = false;
    final invalidation = events
        .invalidateAndWait({'a'})
        .then((_) => invalidated = true);
    await Future<void>.delayed(Duration.zero);
    expect(events.isRemoved('a'), isTrue);
    expect(closed, isFalse);
    expect(invalidated, isFalse);
    nativeDisposed.complete();
    await invalidation;
    expect(closed, isTrue);
    events.accountAvailable('a');
    expect(events.isRemoved('a'), isFalse);
    registration.remove();
    events.dispose();
  });
  test(
    'removal invalidates only its account and re-login allows new pages',
    () {
      final events = AccountToolLifecycle();
      var notifications = 0;
      events.addListener(() => notifications++);
      events.removeAccount('a');
      expect(events.isRemoved('a'), isTrue);
      expect(events.isRemoved('b'), isFalse);
      expect(notifications, 1);
      events.accountAvailable('a');
      expect(events.isRemoved('a'), isFalse);
      expect(notifications, 2);
      events.networkChanged();
      expect(notifications, 3);
      events.dispose();
    },
  );
}
