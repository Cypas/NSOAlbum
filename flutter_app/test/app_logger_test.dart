import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/app_logger.dart';

void main() {
  test('diagnostics redact all credential forms and URL queries', () async {
    final directory = await Directory.systemTemp.createTemp('nso-safe-log-');
    addTearDown(() => directory.delete(recursive: true));
    final logger = AppLogger('${directory.path}/app.log');
    await logger.error('network failed', StateError(
      'https://person:proxy-password@example.com/api?private=private-query#private-fragment '
      'bullet_token=private-bullet gtoken=private-gtoken '
      r'path=C:\Users\private-user\Pictures\private-media.mp4 '
      'jwt=eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjEyM30.signature '
      'Cookie: private-cookie',
    ));
    final text = await File(logger.path).readAsString();
    for (final secret in [
      'proxy-password', 'private-query', 'private-fragment', 'private-bullet',
      'private-gtoken', 'private-user', 'private-media', 'eyJhbGci', 'private-cookie',
    ]) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
    expect(text, contains('network failed'));
  });

  test('writes errors and redacts Nintendo tokens', () async {
    final directory = await Directory.systemTemp.createTemp(
      'squid-album-logger-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/squid_album.log');
    final logger = AppLogger(file.path);

    await logger.error(
      'login failed',
      StateError('session_token_code=secret-value&state=ok'),
    );

    final contents = await file.readAsString();
    expect(contents, contains('[ERROR]'));
    expect(contents, contains('session_token_code=<redacted>'));
    expect(contents, isNot(contains('secret-value')));
  });

  test('collapses consecutive asynchronous suspension frames', () {
    expect(
      collapseRepeatedAsyncSuspension(
        'first\n<asynchronous suspension>\n'
        '<asynchronous suspension>\n'
        '<asynchronous suspension>\nlast',
      ),
      'first\n<asynchronous suspension> (repeated 3 times)\nlast',
    );
  });
}
