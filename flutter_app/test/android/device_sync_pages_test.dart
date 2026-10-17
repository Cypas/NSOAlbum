@Tags(['platform-android'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/device_sync/backup_page.dart';
import 'package:squid_album/src/ui/device_sync/device_sync_page.dart';
import 'package:squid_album/src/ui/device_sync/scanner_page.dart';

import '../device_sync/backup_page_test.dart' show BackupBrowser;
import '../device_sync/device_sync_page_test.dart'
    show PageAccess, pageApp, reveal;
import 'device_sync_scanner_test.dart' show TestCamera;

void main() {
  testWidgets('back releases only its restore preview and waits owned work', (
    tester,
  ) async {
    final settled = Completer<void>();
    final browser = BackupBrowser()..closeWait = settled.future;
    await tester.pumpWidget(
      pageApp(
        builder: (_) => DeviceSyncBackupPage(browser: browser, mobile: true),
      ),
    );
    await tester.tap(find.byKey(const Key('open-page')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pump();
    expect(browser.closed, isTrue);
    expect(find.byType(DeviceSyncBackupPage), findsOneWidget);
    settled.complete();
    await tester.pumpAndSettle();
    expect(find.byType(DeviceSyncBackupPage), findsNothing);
  });

  testWidgets('mobile setup backup and scanner stay usable at large text', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in [320.0, 360.0, 412.0]) {
      tester.view.physicalSize = Size(width, 820);
      tester.view.devicePixelRatio = 1;
      for (final language in ['zh', 'en']) {
        for (final brightness in Brightness.values) {
          final access = PageAccess();
          await tester.pumpWidget(
            pageApp(
              language: language,
              brightness: brightness,
              scale: 2,
              builder: (_) => DeviceSyncPage(access: access, mobile: true),
            ),
          );
          await tester.tap(find.byKey(const Key('open-page')));
          await tester.pumpAndSettle();
          expect(find.byType(NavigationBar), findsNothing);
          await reveal(tester, find.byKey(const Key('device-scan-code')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const Key('android-page-back')));
          await tester.pumpAndSettle();

          await tester.pumpWidget(
            pageApp(
              language: language,
              brightness: brightness,
              scale: 2,
              builder: (_) =>
                  DeviceSyncBackupPage(browser: BackupBrowser(), mobile: true),
            ),
          );
          await tester.tap(find.byKey(const Key('open-page')));
          await tester.pumpAndSettle();
          await reveal(
            tester,
            find.byKey(const Key('device-backup-preview-0')),
          );
          await tester.tap(find.byKey(const Key('device-backup-preview-0')));
          await tester.pumpAndSettle();
          await reveal(
            tester,
            find.byKey(const Key('device-allow-account-preview')),
          );
          await tester.tap(
            find.byKey(const Key('device-allow-account-preview')),
          );
          await tester.pumpAndSettle();
          await reveal(tester, find.byKey(const Key('device-confirm-restore')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const Key('android-page-back')));
          await tester.pumpAndSettle();

          await tester.pumpWidget(
            pageApp(
              language: language,
              brightness: brightness,
              scale: 2,
              builder: (_) => DeviceSyncScannerPage(
                cameraFactory: () =>
                    TestCamera()
                      ..failure = DeviceCameraFailure.permissionDenied,
              ),
            ),
          );
          await tester.tap(find.byKey(const Key('open-page')));
          await tester.pumpAndSettle();
          await reveal(tester, find.byKey(const Key('device-enable-camera')));
          await tester.tap(find.byKey(const Key('device-enable-camera')));
          await tester.pumpAndSettle();
          await reveal(tester, find.byKey(const Key('device-enable-camera')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const Key('android-page-back')));
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
  });
}
