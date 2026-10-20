@Tags(['platform-android'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/library_controller.dart';
import 'package:squid_album/src/ui/android/android_library_page.dart';
import 'package:squid_album/src/ui/android/android_log_viewer_page.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets('settings log viewer shows recent filtered and copy controls', (
    tester,
  ) async {
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('nsoalbum-log-test-'),
    );
    final backend = _LogBackend('${root!.path}/app.log');
    addTearDown(() async {
      await root.delete(recursive: true);
    });
    final file = File('${root.path}/app.log');
    await tester.runAsync(
      () => file.writeAsString(
        '2026-10-18T01:00:00Z [INFO] sync started\n'
        '2026-10-18T01:01:00Z [ERROR] token=secret\n',
      ),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: _delegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AndroidLogViewerPage(backend: backend),
        ),
      );
      // File APIs use real async I/O, including the chained existence checks.
      // Keep their entire startup in the real zone rather than fake time.
      for (
        var attempt = 0;
        attempt < 100 &&
            find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-log-filter')), findsOneWidget);
    expect(find.textContaining('sync started'), findsOneWidget);
    expect(find.byKey(const Key('android-log-copy')), findsOneWidget);
  });

  testWidgets('library search stays collapsed until confirmation', (
    tester,
  ) async {
    final backend = FakeBackend(mediaItems: [_image()]);
    final settings = SettingsController(backend);
    final library = _library(backend);
    addTearDown(library.dispose);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: _delegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AndroidLibraryPage(controller: library, settings: settings),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byKey(const Key('android-library-search-toggle')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('android-library-search')))
          .readOnly,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('android-library-search-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('android-library-search-input')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('android-library-search')),
      'No match',
    );
    await tester.pump(const Duration(seconds: 1));
    expect(library.search, '');
    await tester.tap(find.byKey(const Key('android-library-search-confirm')));
    await tester.pumpAndSettle();
    expect(library.search, 'No match');
    await tester.tap(find.byKey(const Key('android-library-search-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('android-library-search')),
      'unapplied',
    );
    await tester.tap(find.byKey(const Key('android-library-search-cancel')));
    await tester.pumpAndSettle();
    expect(library.search, 'No match');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('android-library-search')))
          .controller!
          .text,
      'No match',
    );
    expect(tester.takeException(), isNull);
  });
}

const _delegates = [
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

class _LogBackend extends FakeBackend {
  _LogBackend(this.path) : super(mediaItems: []);
  final String path;
  @override
  String get logFilePath => path;
}

MediaAsset _image() => MediaAsset(
  id: 1,
  sha256: 'fixture',
  originalName: 'test.png',
  storagePath: 'C:/missing.png',
  kind: MediaKind.image,
  importedAt: DateTime(2026, 10, 18),
  gameName: 'Game',
  favorite: false,
  tags: const [],
);

LibraryController _library(AppBackend backend) => LibraryController(backend);
