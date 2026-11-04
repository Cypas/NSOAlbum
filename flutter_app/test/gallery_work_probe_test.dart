import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/diagnostics/gallery_work_probe.dart';

void main() {
  test(
    'secure read tracing preserves results and never exports keys or values',
    () async {
      final probe = GalleryWorkProbe(enabled: true);
      var calls = 0;
      probe.start();
      final value = await probe.secureRead('private-key-account-123', () async {
        calls++;
        return 'private-token-456';
      });
      expect(value, 'private-token-456');
      expect(calls, 1);
      final report = probe.snapshot();
      expect(report['started'], 1);
      final span = (report['spans'] as List).single as Map;
      expect(span['keyGroup'], 'other');
      expect(span['complete'], true);
      expect(
        span['endMicros'],
        greaterThanOrEqualTo(span['startMicros'] as int),
      );
      expect(jsonEncode(report), isNot(contains('private')));
      probe.stop();
      await probe.secureRead('nintendo.account_tokens.v1', () async => null);
      expect(probe.snapshot()['started'], 1);
    },
  );

  test('trace retains the original error without exporting its text', () async {
    final probe = GalleryWorkProbe(enabled: true)..start();
    final failure = StateError('private-token');
    await expectLater(
      probe.secureRead(
        'nintendo.account_profiles.v1',
        () async => throw failure,
      ),
      throwsA(same(failure)),
    );
    final span = (probe.snapshot()['spans'] as List).single as Map;
    expect(span['keyGroup'], 'profiles');
    expect(span['failed'], true);
    expect(jsonEncode(probe.snapshot()), isNot(contains('private')));
    probe.stop();
  });

  test(
    'unfinished old reads cannot finish a new capture and storage is bounded',
    () async {
      final probe = GalleryWorkProbe(enabled: true, limit: 2)..start();
      final pending = Completer<String>();
      final old = probe.secureRead(
        'nintendo.selected_account.v1',
        () => pending.future,
      );
      expect(
        ((probe.snapshot()['spans'] as List).single as Map)['complete'],
        false,
      );
      probe.stop();
      probe.start();
      pending.complete('secret');
      await old;
      expect(probe.snapshot()['started'], 0);
      expect(probe.snapshot()['completed'], 0);
      for (var i = 0; i < 4; i++) {
        await probe.secureRead('nintendo.account_tokens.v1', () async => null);
      }
      expect(probe.snapshot()['started'], 4);
      expect(probe.snapshot()['completed'], 4);
      expect(probe.snapshot()['dropped'], 2);
      expect(probe.snapshot()['spans'], hasLength(2));
      probe.stop();
    },
  );

  test(
    'inactive tracing does not schedule a read or retain diagnostic data',
    () async {
      final probe = GalleryWorkProbe(enabled: false)..start();
      final pending = Completer<String>();
      expect(
        identical(
          probe.secureRead('secret', () => pending.future),
          pending.future,
        ),
        true,
      );
      pending.complete('value');
      expect(probe.snapshot()['spans'], isEmpty);
      expect(probe.snapshot()['started'], 0);
    },
  );

  test(
    'caller attribution retains fixed symbols but never raw stack paths',
    () {
      final callers = secureReadCallers(
        StackTrace.fromString(
          '#0 RustBackend._readStoredAccountTokens (file:///private/account.dart:10)\n'
          '#1 RustBackend._isSignedIn (package:squid_album/src/backend/rust_backend.dart:20)\n'
          '#2 AutomaticSyncCoordinator._reschedule (file:///private/token.dart:30)\n'
          '#3 arbitrary_user_account_token (file:///private/photo.jpg:40)',
        ),
      );
      expect(callers, [
        'RustBackend._readStoredAccountTokens',
        'RustBackend._isSignedIn',
        'AutomaticSyncCoordinator._reschedule',
      ]);
      expect(jsonEncode(callers), isNot(contains('private')));
      expect(jsonEncode(callers), isNot(contains('arbitrary')));
    },
  );
}
