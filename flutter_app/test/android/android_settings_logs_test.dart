@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/ui/android/android_settings_page.dart';
import 'package:squid_album/src/ui/android/android_log_viewer_page.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets('Android settings opens its in-app log viewer', (tester) async {
    final backend = FakeBackend();
    final settings = SettingsController(backend);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: AndroidSettingsPage(backend: backend, controller: settings),
      ),
    );
    final entry = find.byKey(const Key('android-view-logs'));
    await tester.scrollUntilVisible(entry, 200);
    await tester.runAsync(() async {
      await tester.tap(entry);
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.byType(AndroidLogViewerPage).evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();
    expect(find.byType(AndroidLogViewerPage), findsOneWidget);
    expect(find.text('Recent logs'), findsOneWidget);
  });
}
