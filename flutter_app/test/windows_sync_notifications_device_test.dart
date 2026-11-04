@Tags(['platform-windows'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/sync_notifications.dart';
import 'package:window_manager/window_manager.dart';

// Explicit live run without --ci-smoke: that runner mode deliberately disables
// real notification registration. This entry never initializes Rust or accounts.
Future<void> main() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final enabled =
      Platform.isWindows &&
      binding is LiveTestWidgetsFlutterBinding &&
      Platform.environment['NSOALBUM_VERIFY_SYSTEM_NOTIFICATIONS'] == '1';
  group(
    'Windows live system notification probe',
    () {
      testWidgets(
        'system toast history and COM activation retain the owned probe page',
        (tester) async {
          final helper =
              Platform.environment['NSOALBUM_NOTIFICATION_NATIVE_FIXTURE'];
          expect(helper, isNotNull);
          expect(File(helper!).existsSync(), isTrue);
          await windowManager.ensureInitialized();
          await tester.pumpWidget(
            const MaterialApp(
              home: Scaffold(body: Text('Synthetic notification verification')),
            ),
          );
          await tester.pump();
          final notifications = SyncNotifications(platform: 'windows');
          String? ownedTitle;
          String? ownedBody;
          try {
            for (final (language, title, body) in [
              (
                'en',
                'NSOAlbum · Automatic sync complete',
                'Added 1 · Existing 2 · Failed 3 · 2 accounts',
              ),
              ('zh', '鱿型相册 · 自动同步完成', '新增 1 · 已存在 2 · 失败 3 · 2 个账号'),
            ]) {
              await notifications.show(
                language: language,
                downloaded: 1,
                existing: 2,
                failed: 3,
                accountCount: 2,
              );
              ownedTitle = title;
              ownedBody = body;
              await _waitForHistory(helper, title, body);
              debugPrint('SYSTEM_NOTIFICATION_QA historyVerified=$language');
            }
            await windowManager.hide();
            expect(await windowManager.isVisible(), isFalse);
            final activation = await Process.run(helper, [
              'system-activate',
              '$pid',
            ]);
            expect(
              activation.exitCode,
              0,
              reason: '${activation.stdout}\n${activation.stderr}',
            );
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (!await windowManager.isVisible()) {
              if (DateTime.now().isAfter(deadline)) {
                fail(
                  'The actual COM activation did not restore its owner window.',
                );
              }
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            await tester.pump();
            expect(
              find.text('Synthetic notification verification'),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
            debugPrint(
              'SYSTEM_NOTIFICATION_QA PASS history=en,zh '
              'actualComRestoredOwner=true pageRetained=true',
            );
          } finally {
            if (ownedTitle != null && ownedBody != null) {
              final cleanup = await Process.run(helper, [
                'system-remove-owned',
                ownedTitle,
                ownedBody,
              ]);
              expect(
                cleanup.exitCode,
                anyOf(0, 3),
                reason: 'Remove only this probe summary, never other notifications.',
              );
            }
            await windowManager.show();
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    },
    skip: enabled
        ? false
        : 'Requires explicitly enabled Windows live system notification probe.',
  );
}

Future<void> _waitForHistory(String helper, String title, String body) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (true) {
    final result = await Process.run(helper, ['system-history', title, body]);
    if (result.exitCode == 0) return;
    if (result.exitCode != 3 || DateTime.now().isAfter(deadline)) {
      fail(
        'The system history did not contain the exact synthetic summary: '
        'exit=${result.exitCode}\n${result.stderr}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
