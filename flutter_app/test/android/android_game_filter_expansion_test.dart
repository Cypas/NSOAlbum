@Tags(['platform-android'])
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/library_controller.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/ui/android/android_library_page.dart';
import 'package:squid_album/src/ui/android/android_theme.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets(
    'selected Android games have one clear action that preserves the search',
    (tester) async {
      final library = await _openFilters(tester);
      final game = find.byKey(ValueKey('android-filter-game-${_game(1)}'));
      await tester.ensureVisible(game);
      await tester.tap(game);
      await tester.pumpAndSettle();
      final section = find.byKey(const Key('android-filter-game-section'));
      final clear = find.descendant(
        of: section,
        matching: find.widgetWithText(TextButton, 'Clear'),
      );
      expect(clear, findsOneWidget);
      final search = find.byKey(const Key('android-filter-game-search'));
      await tester.enterText(search, 'Game 00');
      await tester.pumpAndSettle();
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(library.gameNames, isEmpty);
      expect(tester.widget<TextField>(search).controller!.text, 'Game 00');
      expect(clear, findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'Android mouse hover does not reveal the full game name or remove its accessible label',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await _openFilters(tester, width: 1024);
        final game = find.byKey(ValueKey('android-filter-game-${_game(0)}'));
        await tester.ensureVisible(game);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(0, 0));
        await mouse.moveTo(tester.getCenter(game));
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text(_game(0)), findsOneWidget);
        expect(
          tester.getSemantics(game).getSemanticsData().label,
          contains(_game(0)),
        );
        await mouse.down(tester.getCenter(game));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(tester.widget<FilterChip>(game).selected, isTrue);
        expect(find.text(_game(0)), findsOneWidget);
        await mouse.moveTo(const Offset(0, 0));
        await mouse.removePointer();
        await tester.pumpAndSettle();
        expect(find.text(_game(0)), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'leaving an Android game after mouse long press hides its name and does not rearm hover',
    (tester) async {
      await _openFilters(tester, width: 1024);
      final game = find.byKey(ValueKey('android-filter-game-${_game(0)}'));
      await tester.ensureVisible(game);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(0, 0));
      await mouse.down(tester.getCenter(game));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text(_game(0)), findsNWidgets(2));
      await mouse.up();
      await mouse.moveTo(const Offset(0, 0));
      await tester.pumpAndSettle();
      expect(find.text(_game(0)), findsOneWidget);
      await mouse.moveTo(tester.getCenter(game));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text(_game(0)), findsOneWidget);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'Android mouse hold reveals a game name only after a long press and expires without leaving',
    (tester) async {
      await _openFilters(tester, width: 1024);
      final game = find.byKey(ValueKey('android-filter-game-${_game(0)}'));
      await tester.ensureVisible(game);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(0, 0));
      await mouse.down(tester.getCenter(game));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(_game(0)), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text(_game(0)), findsNWidgets(2));
      expect(tester.widget<FilterChip>(game).selected, isFalse);
      await mouse.up();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text(_game(0)), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(_game(0)), findsOneWidget);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'closing Android filters during a long press removes the name overlay and pending work',
    (tester) async {
      await _openFilters(tester);
      final game = find.byKey(ValueKey('android-filter-game-${_game(0)}'));
      await tester.ensureVisible(game);
      final gesture = await tester.startGesture(tester.getCenter(game));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text(_game(0)), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox.shrink());
      await gesture.up();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(_game(0)), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'selected Android games move first and deselected games return to catalog order',
    (tester) async {
      await _openFilters(tester);
      Finder game(int index) =>
          find.byKey(ValueKey('android-filter-game-${_game(index)}'));
      await tester.ensureVisible(game(2));
      await tester.tap(game(2));
      await tester.pumpAndSettle();
      expect(
        tester.widgetList<FilterChip>(find.byType(FilterChip)).first.key,
        game(2).evaluate().single.widget.key,
      );
      await tester.ensureVisible(game(1));
      await tester.tap(game(1));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<FilterChip>(find.byType(FilterChip))
            .take(3)
            .map((chip) => chip.key),
        [
          ValueKey('android-filter-game-${_game(1)}'),
          ValueKey('android-filter-game-${_game(2)}'),
          ValueKey('android-filter-game-${_game(0)}'),
        ],
      );
      await tester.tap(game(1));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<FilterChip>(find.byType(FilterChip))
            .take(3)
            .map((chip) => chip.key),
        [
          ValueKey('android-filter-game-${_game(2)}'),
          ValueKey('android-filter-game-${_game(0)}'),
          ValueKey('android-filter-game-${_game(1)}'),
        ],
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  for (final scenario in [
    (width: 320.0, textScale: 1.0, minimumColumns: 2),
    (width: 360.0, textScale: 2.0, minimumColumns: 2),
    (width: 1024.0, textScale: 1.0, minimumColumns: 3),
    (width: 1024.0, textScale: 2.0, minimumColumns: 3),
  ]) {
    testWidgets(
      'Android game filters keep ${scenario.minimumColumns} columns at ${scenario.width}px and ${scenario.textScale}x text',
      (tester) async {
        await _openFilters(
          tester,
          width: scenario.width,
          textScale: scenario.textScale,
        );
        final chips = find.byType(FilterChip);
        final firstRect = tester.getRect(chips.first);
        final firstRow = [
          for (var index = 0; index < chips.evaluate().length; index++)
            if ((tester.getRect(chips.at(index)).top - firstRect.top).abs() < 1)
              tester.getRect(chips.at(index)),
        ];
        expect(firstRow.length, greaterThanOrEqualTo(scenario.minimumColumns));
        expect(firstRow[0].width, closeTo(firstRow[1].width, 1));
        final section = tester.getRect(
          find.byKey(const Key('android-filter-game-section')),
        );
        for (final chip in firstRow) {
          expect(chip.left, greaterThanOrEqualTo(section.left));
          expect(chip.right, lessThanOrEqualTo(section.right));
          expect(chip.height, greaterThanOrEqualTo(48));
        }
        final text = tester.widget<Text>(
          find.descendant(of: chips.first, matching: find.byType(Text)).first,
        );
        expect(text.maxLines, 1);
        expect(text.overflow, TextOverflow.ellipsis);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({TargetPlatform.android}),
    );
  }

  testWidgets(
    'Android game full name appears on long press, not a selection tap',
    (tester) async {
      await _openFilters(tester);
      final game = find.byKey(ValueKey('android-filter-game-${_game(0)}'));
      await tester.ensureVisible(game);
      await tester.tap(game);
      await tester.pumpAndSettle();
      expect(tester.widget<FilterChip>(game).selected, isTrue);
      expect(find.text(_game(0)), findsOneWidget);
      await tester.longPress(game);
      await tester.pumpAndSettle();
      expect(find.text(_game(0)), findsNWidgets(2));
      expect(tester.widget<FilterChip>(game).selected, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('expanding a large game catalog scrolls with the filter sheet', (
    tester,
  ) async {
    await _openFilters(tester);
    final expand = find.byKey(const Key('android-filter-expand-games'));
    await tester.ensureVisible(expand);
    await tester.tap(expand);
    await tester.pumpAndSettle();

    final outer = _filterScroll(tester);
    final first = find.byKey(ValueKey('android-filter-game-${_game(0)}'));
    await tester.ensureVisible(first);
    await tester.pumpAndSettle();
    final before = outer.position.pixels;
    await tester.drag(first, const Offset(0, -220));
    await tester.pumpAndSettle();

    expect(
      outer.position.pixels,
      greaterThan(before + 80),
      reason: 'game gestures must advance the sheet, not a nested viewport',
    );
    final last = find.byKey(ValueKey('android-filter-game-${_game(49)}'));
    await tester.ensureVisible(last);
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(last).selected, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets(
    'collapsing after the last game returns to the game search without losing selection',
    (tester) async {
      await _openFilters(tester);
      final expand = find.byKey(const Key('android-filter-expand-games'));
      await tester.ensureVisible(expand);
      await tester.tap(expand);
      await tester.pumpAndSettle();
      final last = find.byKey(ValueKey('android-filter-game-${_game(49)}'));
      await tester.ensureVisible(last);
      await tester.tap(last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(expand);
      await tester.tap(expand);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('android-filter-game-search')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.widget<FilterChip>(last).selected, isTrue);
      expect(find.byType(FilterChip), findsNWidgets(9));
      await tester.ensureVisible(find.text('Apply'));
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('search and clear preserve expanded choice and selected games', (
    tester,
  ) async {
    final library = await _openFilters(tester);
    final expand = find.byKey(const Key('android-filter-expand-games'));
    await tester.ensureVisible(expand);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    final last = find.byKey(ValueKey('android-filter-game-${_game(49)}'));
    await tester.ensureVisible(last);
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(library.gameNames, [_game(49)]);

    final search = find.byKey(const Key('android-filter-game-search'));
    await tester.ensureVisible(search);
    await tester.enterText(search, 'Game 0');
    await tester.pumpAndSettle();
    expect(find.text('Show less'), findsOneWidget);
    expect(find.byType(FilterChip), findsNWidgets(11));
    expect(tester.widget<FilterChip>(last).selected, isTrue);

    await tester.enterText(search, 'Game 00');
    await tester.pumpAndSettle();
    expect(expand, findsNothing);
    expect(find.byType(FilterChip), findsNWidgets(2));
    expect(tester.widget<FilterChip>(last).selected, isTrue);

    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    expect(find.text('Show less'), findsOneWidget);
    expect(find.byType(FilterChip), findsNWidgets(50));

    await tester.ensureVisible(expand);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    await tester.enterText(search, 'Game 0');
    await tester.pumpAndSettle();
    expect(find.text('Show all (11)'), findsOneWidget);
    expect(find.byType(FilterChip), findsNWidgets(9));
    expect(tester.widget<FilterChip>(last).selected, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}

String _game(int index) =>
    'Game ${index.toString().padLeft(2, '0')} long catalog entry';

ScrollableState _filterScroll(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find
          .ancestor(
            of: find.byKey(const Key('android-filter-game-section')),
            matching: find.byType(Scrollable),
          )
          .first,
    );

Future<LibraryController> _openFilters(
  WidgetTester tester, {
  double width = 360,
  double textScale = 1,
}) async {
  tester.view
    ..physicalSize = Size(width, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final backend = FakeBackend(
    mediaItems: [
      for (var index = 0; index < 50; index++)
        MediaAsset(
          id: index + 1,
          sha256: 'filter-$index',
          originalName: 'filter-$index.png',
          storagePath: 'missing-filter-$index.png',
          kind: MediaKind.image,
          importedAt: DateTime(2026, 11, 2),
          gameName: _game(index),
          favorite: false,
          tags: const [],
        ),
    ],
  );
  final settings = SettingsController(backend);
  final library = LibraryController(backend);
  addTearDown(settings.dispose);
  addTearDown(library.dispose);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
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
  return library;
}
