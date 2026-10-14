import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/sync_failure_status.dart';

void main() {
  test(
    'persisted account outcomes retain retry and authentication semantics',
    () {
      for (final sample in {
        'task cancelled': 'cancelled',
        'rate limited: retry after 60 seconds': 'rate_limited',
        'HTTP 429': 'rate_limited',
        'authentication failed: token expired': 'authentication_failure',
        'HTTP 401 Unauthorized': 'authentication_failure',
        'network error: timeout': 'failure',
        'I/O error: storage unavailable': 'failure',
      }.entries) {
        expect(syncFailureStatus(StateError(sample.key)), sample.value);
      }
    },
  );
}
