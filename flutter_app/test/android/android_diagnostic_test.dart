@Tags(['platform-android'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/android/android_page_frame.dart';

void main() {
  test(
    'copyable diagnostics redact JSON tokens, bearer headers, and callbacks',
    () {
      final diagnostic = androidSafeDiagnostic(
        'network error\n'
        '{"session_token":"private-session","access_token":"private-access"}\n'
        'Authorization: Bearer private-bearer\nCookie: private-cookie\n'
        'npf123://auth?session_token_code=private-callback\n'
        'https://example.invalid/media?secret=private-query',
      );
      for (final secret in [
        'private-session',
        'private-access',
        'private-bearer',
        'private-cookie',
        'private-callback',
        'private-query',
      ]) {
        expect(diagnostic, isNot(contains(secret)));
      }
      expect(diagnostic, contains('network error'));
    },
  );
}
