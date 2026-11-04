import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/font_families.dart';

import 'home_shell_test.dart' show FakeBackend;

class _GamesBackend extends FakeBackend {
  _GamesBackend() : super(mediaItems: []);

  @override
  Future<List<GameTagSummary>> listGameTags() async => [
    for (var index = 0; index < 50; index++)
      GameTagSummary(
        name: 'Game ${index.toString().padLeft(2, '0')}',
        imageCount: BigInt.one,
        videoCount: BigInt.zero,
        selectionCount: BigInt.zero,
      ),
  ];
}

Future<void> _openFilters(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(SquidAlbumApp(backend: _GamesBackend()));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('library-filter')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async => loadCustomFontFamilies(const []));

  testWidgets(
    'desktop selected games move first in catalog order and deselection restores the remaining order',
    (tester) async {
      await _openFilters(tester);
      Finder game(int index) => find.byKey(
        Key('desktop-filter-game-Game ${index.toString().padLeft(2, '0')}'),
      );
      await tester.ensureVisible(game(2));
      await tester.tap(game(2));
      await tester.pumpAndSettle();
      final list = tester.widget<ListView>(
        find.byKey(const Key('desktop-filter-game-list')),
      );
      final scroll = list.controller!;
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(game(2)).dy,
        lessThan(tester.getTopLeft(game(0)).dy),
      );
      await tester.ensureVisible(game(1));
      await tester.tap(game(1));
      await tester.pumpAndSettle();
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(game(1)).dy,
        lessThan(tester.getTopLeft(game(2)).dy),
      );
      expect(
        tester.getTopLeft(game(2)).dy,
        lessThan(tester.getTopLeft(game(0)).dy),
      );
      await tester.tap(game(1));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(game(2)).dy,
        lessThan(tester.getTopLeft(game(0)).dy),
      );
      expect(
        tester.getTopLeft(game(0)).dy,
        lessThan(tester.getTopLeft(game(1)).dy),
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'desktop filter scroll tracks have a gutter clear of trailing controls',
    (tester) async {
      await _openFilters(tester);
      final dialog = find.byKey(const Key('desktop-library-filter-dialog'));
      final outerScroll = find
          .descendant(of: dialog, matching: find.byType(SingleChildScrollView))
          .first;
      final group = find.byKey(const Key('desktop-filter-group-by-date'));
      expect(
        tester.getRect(outerScroll).right - tester.getRect(group).right,
        greaterThanOrEqualTo(12),
        reason: 'The outer scrollbar must not paint over switches or arrows.',
      );
      final list = find.byKey(const Key('desktop-filter-game-list'));
      final firstGame = find.byKey(const Key('desktop-filter-game-Game 00'));
      expect(
        tester.getRect(list).right - tester.getRect(firstGame).right,
        greaterThanOrEqualTo(12),
        reason: 'The game scrollbar must have its own checkbox-free gutter.',
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'desktop expanding a large game list increases the visible game region',
    (tester) async {
      await _openFilters(tester);
      final list = find.byKey(const Key('desktop-filter-game-list'));
      final collapsedHeight = tester.getSize(list).height;
      final expand = find.byKey(const Key('desktop-filter-game-expand'));
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(list).height,
        greaterThan(collapsedHeight),
        reason: 'Show all must visibly expand instead of only changing text.',
      );
      await tester.drag(list, const Offset(0, -4000));
      await tester.pumpAndSettle();
      final lastGame = find.byKey(const Key('desktop-filter-game-Game 49'));
      expect(lastGame.hitTestable(), findsOneWidget);
      await tester.tap(lastGame);
      await tester.pumpAndSettle();
      await tester.ensureVisible(expand);
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(tester.getSize(list).height, collapsedHeight);
      expect(
        find.byKey(const Key('desktop-filter-game-Game 00')).hitTestable(),
        findsOneWidget,
        reason: 'Collapsing a scrolled list must return to its first games.',
      );
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(lastGame).value, isTrue);
      expect(
        tester.getTopLeft(lastGame).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const Key('desktop-filter-game-Game 00')))
              .dy,
        ),
        reason: 'The selected game remains first when the list is expanded.',
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'desktop expansion count follows searched games and retained selections',
    (tester) async {
      await _openFilters(tester);
      await tester.tap(find.byKey(const Key('desktop-filter-game-Game 00')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('desktop-filter-game-search')),
        'Game 1',
      );
      await tester.pumpAndSettle();
      final expand = find.byKey(const Key('desktop-filter-game-expand'));
      expect(
        find.descendant(of: expand, matching: find.text('展开全部（11）')),
        findsOneWidget,
        reason: 'Ten matches plus the retained selection are eleven games.',
      );
      await tester.tap(expand);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('desktop-filter-game-search')),
        'Game 19',
      );
      await tester.pumpAndSettle();
      expect(expand, findsNothing);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('desktop-filter-game-Game 00')),
            )
            .value,
        isTrue,
      );
      await tester.enterText(
        find.byKey(const Key('desktop-filter-game-search')),
        '',
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: expand, matching: find.text('收起')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
}
