import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/app_logger.dart';

void main() {
  test(
    'OAuth endpoint names do not consume adjacent network diagnostic fields',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nso-network-log-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final logger = AppLogger('${directory.path}/app.log');
      await logger.error(
        'request failed',
        'network error: stage=nxapi_oauth reason=timeout '
            'url=https://nxapi-auth.fancy.org.uk/api/oauth/token '
            'code_kind=none code=none refresh_token=PRIVATE',
      );
      final contents = await File(logger.path).readAsString();
      expect(contents, contains('/api/oauth/token code_kind=none code=none'));
      expect(contents, contains('reason=timeout'));
      expect(contents, isNot(contains('PRIVATE')));
    },
  );

  test(
    'runtime log timestamps use system local time at second precision',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nso-local-time-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final logger = AppLogger('${directory.path}/app.log');
      final before = DateTime.now();
      await logger.info('local timestamp probe');
      final after = DateTime.now();
      final contents = await File(logger.path).readAsString();
      final timestamp = contents.split(' ').first;
      expect(
        timestamp,
        matches(
          RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$'),
        ),
        reason:
            'Log headers must have seconds and an explicit local UTC offset.',
      );
      final offset = before.timeZoneOffset;
      final minutes = offset.inMinutes.abs();
      final expectedOffset =
          '${offset.isNegative ? '-' : '+'}'
          '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
          '${(minutes % 60).toString().padLeft(2, '0')}';
      expect(timestamp, endsWith(expectedOffset));
      final parsed = DateTime.parse(timestamp);
      expect(
        parsed.millisecondsSinceEpoch,
        inInclusiveRange(
          before.millisecondsSinceEpoch - 999,
          after.millisecondsSinceEpoch,
        ),
      );
      expect(contents, contains('[INFO] local timestamp probe'));
    },
  );

  test('logged local debug URLs do not retain path access codes', () async {
    final directory = await Directory.systemTemp.createTemp('nso-local-log-');
    addTearDown(() => directory.delete(recursive: true));
    final logger = AppLogger('${directory.path}/app.log');
    await logger.info(
      'VM diagnostics http://127.0.0.1:12345/synthetic-vm-key=/ '
      'ws://localhost:23456/synthetic-ws-key=/ws '
      'http://[::1]:34567/synthetic-ipv6-key=/ '
      'proxy http://127.0.0.1:7890',
    );
    final contents = await File(logger.path).readAsString();
    for (final secret in [
      'synthetic-vm-key',
      'synthetic-ws-key',
      'synthetic-ipv6-key',
    ]) {
      expect(contents, isNot(contains(secret)));
    }
    expect(contents, contains('VM diagnostics'));
    expect(contents, contains('proxy http://127.0.0.1:7890'));
  });

  test('diagnostics redact all credential forms and URL queries', () async {
    final directory = await Directory.systemTemp.createTemp('nso-safe-log-');
    addTearDown(() => directory.delete(recursive: true));
    final logger = AppLogger('${directory.path}/app.log');
    await logger.error(
      'network failed',
      StateError(
        'https://person:proxy-password@example.com/api?private=private-query#private-fragment '
        'bullet_token=private-bullet gtoken=private-gtoken '
        r'path=C:\Users\private-user\Pictures\private-media.mp4 '
        'jwt=eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjEyM30.signature '
        'Cookie: private-cookie',
      ),
    );
    final text = await File(logger.path).readAsString();
    for (final secret in [
      'proxy-password',
      'private-query',
      'private-fragment',
      'private-bullet',
      'private-gtoken',
      'private-user',
      'private-media',
      'eyJhbGci',
      'private-cookie',
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
