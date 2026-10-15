import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/account_tool_lifecycle.dart';

void main() {
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
