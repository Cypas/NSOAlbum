import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/app_logger.dart';

void main() {
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
}
