import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/account_tool_requests.dart';

void main() {
  test(
    'cancelled authentication preparation cannot start its network request',
    () {
      final requests = AccountToolRequests();
      final request = requests.begin('account-a', 'friends-1');
      expect(requests.isCurrent(request), isTrue);
      requests.cancel('friends-1');
      expect(requests.isCurrent(request), isFalse);
    },
  );

  test('removing one account invalidates only its own requests', () {
    final requests = AccountToolRequests();
    final a = requests.begin('account-a', 'friends-a');
    final b = requests.begin('account-b', 'friends-b');
    expect(requests.removeAccount('account-a'), ['friends-a']);
    expect(requests.isCurrent(a), isFalse);
    expect(requests.isCurrent(b), isTrue);
  });

  test('finishing an old operation does not remove a newer operation', () {
    final requests = AccountToolRequests();
    final first = requests.begin('a', 'same-id');
    final second = requests.begin('b', 'same-id');
    requests.finish(first);
    expect(requests.isCurrent(first), isFalse);
    expect(requests.isCurrent(second), isTrue);
    requests.finish(second);
    expect(requests.isCurrent(second), isFalse);
  });
}
