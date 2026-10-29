@Tags(['platform-android'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/library_controller.dart';
import 'package:squid_album/src/ui/android/android_library_page.dart';
import 'package:squid_album/src/ui/android/android_log_viewer_page.dart';
import 'package:squid_album/src/ui/android/android_theme.dart';

import '../home_shell_test.dart' show FakeBackend;
import '../layout_viewport.dart';

void main() => registerAndroidBatchFeatureTests();

void registerAndroidBatchFeatureTests() {
  for (final locale in ['zh', 'en']) {
    for (final kind in [GalleryKindFilter.image, GalleryKindFilter.video]) {
      testWidgets(
        '$locale $kind media type filter marks and announces the filter button',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await useLayoutTestViewport(tester, const Size(360, 720));
            final backend = FakeBackend(mediaItems: [_image()]);
            final settings = SettingsController(backend);
            final library = _library(backend)..kind = kind;
            addTearDown(library.dispose);
            addTearDown(settings.dispose);
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(locale),
                localizationsDelegates: _delegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: androidTheme('ocean'),
                home: AndroidLibraryPage(
                  controller: library,
                  settings: settings,
                ),
              ),
            );
            await tester.pumpAndSettle();
            final filter = find.byKey(const Key('android-library-filter'));
            expect(
              (tester.widget<IconButton>(filter).icon as Icon).color,
              Theme.of(tester.element(filter)).colorScheme.primary,
            );
            expect(
              tester
                  .getSemantics(filter)
                  .flagsCollection
                  .isSelected
                  .toBoolOrNull(),
              isTrue,
            );
            expect(
              find.text(locale == 'zh' ? '已应用筛选' : 'Filters applied'),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
      testWidgets(
        '$locale $kind media type filter clears all conditions but keeps search and order',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await useLayoutTestViewport(tester, const Size(360, 720));
            final backend = FakeBackend(mediaItems: [_image()]);
            final settings = SettingsController(backend);
            final library = _library(backend)
              ..kind = kind
              ..favoriteOnly = true
              ..gameNames = ['Game']
              ..newestFirst = false
              ..search = 'kept query';
            if (kind == GalleryKindFilter.image) {
              library.capturedOnThisDay = const CapturedOnThisDay(
                month: 10,
                day: 22,
                beforeYear: 2026,
                utcOffsetSeconds: 0,
              );
            } else {
              library.importedFrom = DateTime(2026, 10, 21);
              library.importedUntil = DateTime(2026, 10, 22);
            }
            addTearDown(library.dispose);
            addTearDown(settings.dispose);
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(locale),
                localizationsDelegates: _delegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: androidTheme('ocean'),
                home: AndroidLibraryPage(
                  controller: library,
                  settings: settings,
                ),
              ),
            );
            await tester.pumpAndSettle();
            final filter = find.byKey(const Key('android-library-filter'));
            await tester.tap(filter);
            await tester.pumpAndSettle();
            final clear = find.text(locale == 'zh' ? '清除筛选' : 'Clear filters');
            await tester.ensureVisible(clear);
            await tester.tap(clear);
            await tester.pumpAndSettle();
            final apply = find.text(locale == 'zh' ? '应用' : 'Apply');
            await tester.ensureVisible(apply);
            await tester.tap(apply);
            await tester.pumpAndSettle();
            expect(library.kind, GalleryKindFilter.all);
            expect(backend.lastKind, GalleryKindFilter.all);
            expect(library.favoriteOnly, isFalse);
            expect(backend.lastFavoriteOnly, isFalse);
            expect(library.gameNames, isEmpty);
            expect(library.importedFrom, isNull);
            expect(library.importedUntil, isNull);
            expect(library.capturedOnThisDay, isNull);
            expect(backend.lastCapturedFrom, isNull);
            expect(backend.lastCapturedUntil, isNull);
            expect(backend.lastCapturedOnThisDay, isNull);
            expect(library.search, 'kept query');
            expect(library.newestFirst, isFalse);
            expect(backend.lastNewestFirst, isFalse);
            expect(
              (tester.widget<IconButton>(filter).icon as Icon).color,
              isNull,
            );
            expect(
              tester
                  .getSemantics(filter)
                  .flagsCollection
                  .isSelected
                  .toBoolOrNull(),
              isFalse,
            );
            expect(
              find.text(locale == 'zh' ? '已应用筛选' : 'Filters applied'),
              findsNothing,
            );
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

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

  testWidgets(
    'recent logs keep each error stack together and copy only that error',
    (tester) async {
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('nsoalbum-log-block-test-'),
      );
      addTearDown(() => root!.delete(recursive: true));
      final path = '${root!.path}/app.log';
      await tester.runAsync(() async {
        await File('$path.1').writeAsString(
          '2026-10-18T01:01:00Z [ERROR] first failure token=secret\n'
          '#0 firstEntry\n'
          '<asynchronous suspension>\n'
          '<asynchronous suspension>\n'
          '<asynchronous suspension>\n',
        );
        await File(path).writeAsString(
          '2026-10-18T01:02:00Z [ERROR] second failure\n'
          '#0 secondEntry\n'
          '<asynchronous suspension>\n'
          '<asynchronous suspension>\n',
        );
      });
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: _delegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AndroidLogViewerPage(backend: _LogBackend(path)),
          ),
        );
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

      final blocks = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((widget) => widget.data ?? '')
          .toList();
      expect(blocks, [
        '2026-10-18T01:01:00Z [ERROR] first failure token=<redacted>\n'
            '#0 firstEntry\n<asynchronous suspension> (repeated 3 times)',
        '2026-10-18T01:02:00Z [ERROR] second failure\n'
            '#0 secondEntry\n<asynchronous suspension> (repeated 2 times)',
      ]);
      final copy = find.byKey(const Key('android-log-copy'));
      expect(copy, findsNWidgets(2));
      await tester.ensureVisible(copy.first);
      await tester.pumpAndSettle();
      await tester.tap(copy.first);
      await tester.pump();
      expect(copied, blocks.first);
      expect(copied, isNot(contains('secret')));
      expect(copied, isNot(contains('second failure')));
    },
  );

  testWidgets('expanded library search is editable and applies on submit', (
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
    await tester.tap(find.byKey(const Key('android-library-search-toggle')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('android-library-search')))
          .readOnly,
      isFalse,
    );
    await tester.enterText(
      find.byKey(const Key('android-library-search')),
      'No match',
    );
    await tester.pump(const Duration(seconds: 1));
    expect(library.search, '');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(library.search, 'No match');
    expect(tester.takeException(), isNull);
  });

  for (final locale in ['zh', 'en']) {
    testWidgets('anniversary is a historical day filter in $locale', (
      tester,
    ) async {
      final backend = FakeBackend(mediaItems: [_image()]);
      final settings = SettingsController(backend);
      final library = _library(backend);
      addTearDown(library.dispose);
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          localizationsDelegates: _delegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AndroidLibraryPage(controller: library, settings: settings),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('android-library-filter')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('android-filter-anniversary')), findsNothing);
      await tester.tap(find.byIcon(Icons.date_range));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('android-filter-anniversary')));
      await tester.pumpAndSettle();
      expect(library.importedFrom, isNull);
      expect(library.importedUntil, isNull);
      expect(
        find.textContaining(locale == 'zh' ? '往年' : 'previous years'),
        findsOneWidget,
      );
      final apply = find.text(locale == 'zh' ? '应用' : 'Apply');
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(library.capturedOnThisDay, isNotNull);
      expect(
        backend.lastCapturedOnThisDay,
        same(library.capturedOnThisDay),
        reason: 'Historical matching belongs in Rust before pagination.',
      );
      final filter = tester.widget<IconButton>(
        find.byKey(const Key('android-library-filter')),
      );
      expect((filter.icon as Icon).color, isNotNull);
      await tester.tap(find.byKey(const Key('android-library-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.date_range));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('android-filter-today')));
      await tester.pumpAndSettle();
      expect(library.capturedOnThisDay, isNull);
      expect(library.importedFrom, isNotNull);
      final clear = find.text(locale == 'zh' ? '清除筛选' : 'Clear filters');
      await tester.ensureVisible(clear);
      await tester.tap(clear);
      await tester.pump();
      expect(library.importedFrom, isNull);
      expect(library.importedUntil, isNull);
      expect(library.capturedOnThisDay, isNull);
    });
  }

  testWidgets('filter button indicates active date filter', (tester) async {
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
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-library-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-filter-today')), findsNothing);
    await tester.tap(find.byIcon(Icons.date_range));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-filter-today')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Apply').last);
    await tester.tap(find.text('Apply').last);
    await tester.pumpAndSettle();
    final filter = tester.widget<IconButton>(
      find.byKey(const Key('android-library-filter')),
    );
    expect((filter.icon as Icon).color, isNotNull);
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
