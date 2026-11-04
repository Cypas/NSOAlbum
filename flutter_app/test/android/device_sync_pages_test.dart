@Tags(['platform-android'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/device_sync/backup_page.dart';

import '../device_sync/backup_page_test.dart' show BackupBrowser;
import '../device_sync/device_sync_page_test.dart' show pageApp;

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
}
