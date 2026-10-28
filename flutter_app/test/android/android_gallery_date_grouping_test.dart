@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/state/library_controller.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/ui/android/android_library_page.dart';
import 'package:squid_album/src/ui/android/android_theme.dart';
import 'package:squid_album/src/rust/models.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets(
    'Android date filter opens the compact picker directly with quick ranges',
    (tester) async {
      final backend = FakeBackend(mediaItems: [_media(1)]);
      final settings = SettingsController(backend);
      final library = LibraryController(backend);
      addTearDown(settings.dispose);
      addTearDown(library.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: androidTheme('ocean'),
          home: AndroidLibraryPage(controller: library, settings: settings),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('android-library-filter')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('android-filter-game-section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('android-filter-date-section')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('android-filter-date-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('android-date-filter-dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('android-filter-today')), findsOneWidget);
      expect(find.byKey(const Key('android-filter-this-week')), findsOneWidget);
      expect(
        find.byKey(const Key('android-filter-anniversary')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'Android date grouping shows today, yesterday and unknown-date headers',
    (tester) async {
      final today = DateUtils.dateOnly(DateTime.now());
      final yesterday = today.subtract(const Duration(days: 1));
      final backend = FakeBackend(
        mediaItems: [
          _media(1, importedAt: today.add(const Duration(hours: 9))),
          _media(2, importedAt: yesterday.add(const Duration(hours: 9))),
          _media(3, importedAt: null),
        ],
      );
      final settings = SettingsController(backend);
      final library = LibraryController(backend);
      addTearDown(settings.dispose);
      addTearDown(library.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: androidTheme('ocean'),
          home: AndroidLibraryPage(controller: library, settings: settings),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('今天'), findsNothing);
      await tester.tap(find.byKey(const Key('android-library-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('android-filter-group-by-date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();

      expect(find.text('今天'), findsOneWidget);
      expect(find.text('昨天'), findsOneWidget);
      expect(find.text('日期未知'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'Android game filter searches large catalogs and keeps selected tags visible',
    (tester) async {
      final backend = FakeBackend(
        mediaItems: [
          for (var index = 0; index < 12; index++)
            _media(
              index + 1,
              gameName: 'Game $index',
              importedAt: DateTime(2026, 10, 18),
            ),
        ],
      );
      final settings = SettingsController(backend);
      final library = LibraryController(backend);
      addTearDown(settings.dispose);
      addTearDown(library.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: androidTheme('ocean'),
          home: AndroidLibraryPage(controller: library, settings: settings),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('android-library-filter')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('android-filter-game-search')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('android-filter-game-count')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('android-filter-game-Game 0')),
        findsOneWidget,
      );
      expect(find.byType(FilterChip), findsNWidgets(8));
      expect(
        find.byKey(const ValueKey('android-filter-game-Game 8')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('android-filter-expand-games')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('android-filter-game-Game 11')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('android-filter-game-search')),
        'Game 11',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('android-filter-game-Game 11')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('android-filter-game-Game 0')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey('android-filter-game-Game 11')),
      );
      await tester.pumpAndSettle();
      expect(library.gameNames, contains('Game 11'));
      await tester.enterText(
        find.byKey(const Key('android-filter-game-search')),
        '',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('android-filter-game-Game 11')),
        findsOneWidget,
      );
      expect(
        tester
            .getRect(
              find.byKey(const Key('android-filter-group-by-date-switch')),
            )
            .right,
        closeTo(
          tester
              .getRect(find.byKey(const Key('android-filter-favorites-switch')))
              .right,
          0.1,
        ),
      );
      expect(
        tester
            .getRect(find.byKey(const Key('android-filter-newest-switch')))
            .right,
        closeTo(
          tester
              .getRect(find.byKey(const Key('android-filter-favorites-switch')))
              .right,
          0.1,
        ),
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}

MediaAsset _media(int id, {DateTime? importedAt, String gameName = 'Game'}) =>
    MediaAsset(
      id: id,
      sha256: 'group-$id',
      originalName: 'group-$id.png',
      storagePath: 'missing-$id.png',
      kind: MediaKind.image,
      importedAt: importedAt,
      gameName: gameName,
      favorite: false,
      tags: const [],
    );
