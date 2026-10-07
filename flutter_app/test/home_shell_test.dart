import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/backend/rust_backend.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/rust/settings.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/sync_controller.dart';
import 'package:squid_album/src/ui/home_shell.dart';
import 'package:squid_album/src/ui/media_viewer.dart';

void main() {
  test('video viewer preloads only the current and adjacent indexes', () {
    expect(adjacentVideoIndices(0, 4), {0, 1});
    expect(adjacentVideoIndices(2, 4), {1, 2, 3});
    expect(adjacentVideoIndices(3, 4), {2, 3});
  });

  test('selects the initial interface language from the system locale', () {
    expect(interfaceLanguageForLocale(const Locale('zh', 'TW')), 'zh');
    expect(interfaceLanguageForLocale(const Locale('en', 'US')), 'en');
    expect(interfaceLanguageForLocale(const Locale('ja', 'JP')), 'en');
  });

  testWidgets('shows the four primary pages and loads albums', (tester) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    expect(find.text('图库'), findsWidgets);
    expect(find.byKey(const Key('desktop-window-title')), findsNothing);
    expect(find.text('sample.jpg'), findsOneWidget);
    expect(find.text('Splatoon 3'), findsWidgets);
    final mediaCard = find.byKey(const ValueKey('media-card-1'));
    expect(
      find.descendant(of: mediaCard, matching: find.text('图片')),
      findsNothing,
    );

    final albumCalls = backend.listAlbumsCalls;
    await tester.tap(find.text('相册').last);
    await tester.pumpAndSettle();

    expect(backend.listAlbumsCalls, greaterThan(albumCalls));
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('1 个媒体 · 自动相册'), findsOneWidget);
    expect(find.byKey(const ValueKey('album-cover-1-1')), findsOneWidget);
  });

  testWidgets('album cover uses the newest matching media', (tester) async {
    final backend = FakeBackend(
      mediaItems: [
        _media(id: 1, name: 'older.jpg', capturedAt: DateTime.utc(2026, 10, 1)),
        _media(id: 2, name: 'newer.jpg', capturedAt: DateTime.utc(2026, 10, 3)),
      ],
      albumItems: [
        AlbumSummary(
          id: 1,
          name: '收藏',
          description: '',
          albumType: 'smart',
          pinned: true,
          systemKey: 'favorites',
          mediaCount: BigInt.from(2),
        ),
      ],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('相册').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('album-cover-1-2')), findsOneWidget);
  });

  testWidgets('combines media kind and favorite filters', (tester) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('视频'));
    await tester.pumpAndSettle();
    expect(backend.lastKind, GalleryKindFilter.video);

    await tester.tap(find.widgetWithText(FilterChip, '收藏'));
    await tester.pumpAndSettle();
    expect(backend.lastKind, GalleryKindFilter.video);
    expect(backend.lastFavoriteOnly, isTrue);
  });

  testWidgets('favorite updates only the card without reloading the gallery', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();
    final listCalls = backend.listMediaCalls;

    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();

    expect(backend.favoriteUpdates[1], isFalse);
    expect(backend.listMediaCalls, listCalls);
    expect(find.byTooltip('收藏'), findsOneWidget);
  });

  testWidgets('search ignores case and Traditional Chinese variants', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    final search = find.byKey(const Key('library-search'));
    await tester.enterText(search, '庆典');
    expect(find.byKey(const Key('library-search-submit')), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(find.text('sample.jpg'), findsOneWidget);

    await tester.enterText(search, 'RANKED');
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.text('sample.jpg'), findsOneWidget);
  });

  testWidgets('search preserves Chinese IME composing text', (tester) async {
    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();

    final search = find.byKey(const Key('library-search'));
    await tester.tap(search);
    const composingText = '不存在';
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: composingText,
        selection: TextSelection.collapsed(offset: composingText.length),
        composing: TextRange(start: 0, end: composingText.length),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('sample.jpg'), findsOneWidget);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: composingText,
        selection: TextSelection.collapsed(offset: composingText.length),
      ),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pumpAndSettle();
    expect(find.text('sample.jpg'), findsNothing);

    await tester.enterText(search, '庆典');
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.text('sample.jpg'), findsOneWidget);
  });

  testWidgets('tag and note fields preserve Chinese IME composing text', (
    tester,
  ) async {
    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('media-card-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('media-viewer-edit-metadata')));
    await tester.pumpAndSettle();

    const tagText = '中文标签';
    final tag = find.byKey(const Key('media-metadata-new-tag'));
    await tester.tap(tag);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: tagText,
        selection: TextSelection.collapsed(offset: tagText.length),
        composing: TextRange(start: 0, end: tagText.length),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<TextField>(tag).controller!.value,
      const TextEditingValue(
        text: tagText,
        selection: TextSelection.collapsed(offset: tagText.length),
        composing: TextRange(start: 0, end: tagText.length),
      ),
    );

    const noteText = '中文备注';
    final note = find.byKey(const Key('media-metadata-note'));
    await tester.tap(note);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: noteText,
        selection: TextSelection.collapsed(offset: noteText.length),
        composing: TextRange(start: 0, end: noteText.length),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<TextField>(note).controller!.value,
      const TextEditingValue(
        text: noteText,
        selection: TextSelection.collapsed(offset: noteText.length),
        composing: TextRange(start: 0, end: noteText.length),
      ),
    );
  });

  testWidgets('keeps existing media visible while filters reload', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();
    expect(find.text('sample.jpg'), findsOneWidget);

    final gate = Completer<void>();
    backend.nextMediaGate = gate;
    await tester.tap(find.text('视频'));
    await tester.pump();

    expect(find.text('sample.jpg'), findsOneWidget);
    expect(find.byKey(const Key('gallery-filter-progress')), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gallery-filter-progress')), findsNothing);
  });

  testWidgets('switches between newest and oldest creation order', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    expect(backend.lastNewestFirst, isTrue);
    await tester.tap(find.byKey(const Key('media-sort-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建时间正序'));
    await tester.pumpAndSettle();
    expect(backend.lastNewestFirst, isFalse);
  });

  testWidgets('creation date range applies after selecting both dates', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('capture-date-filter')));
    await tester.pumpAndSettle();

    final dialog = find.byKey(const Key('creation-date-range-dialog'));
    expect(dialog, findsOneWidget);
    expect(
      tester.getSize(dialog).width,
      lessThan(tester.view.physicalSize.width),
    );
    expect(find.text('确定'), findsNothing);

    tester
        .widget<CalendarDatePicker>(
          find.byKey(const ValueKey('creation-date-calendar-start')),
        )
        .onDateChanged(DateTime(2026, 10, 1));
    await tester.pump();
    expect(dialog, findsOneWidget);
    expect(
      find.byKey(const ValueKey('creation-date-calendar-end')),
      findsOneWidget,
    );

    tester
        .widget<CalendarDatePicker>(
          find.byKey(const ValueKey('creation-date-calendar-end')),
        )
        .onDateChanged(DateTime(2026, 10, 3));
    await tester.pumpAndSettle();

    expect(dialog, findsNothing);
    expect(
      backend.lastCapturedFrom,
      DateUtils.dateOnly(DateTime(2026, 10, 1)).toUtc(),
    );
    expect(
      backend.lastCapturedUntil,
      DateUtils.dateOnly(DateTime(2026, 10, 4)).toUtc(),
    );
  });

  testWidgets('filters by multiple visible game tags', (tester) async {
    final backend = FakeBackend(
      mediaItems: [
        _media(id: 1, name: 'splatoon.jpg', gameName: 'Splatoon 3'),
        _media(id: 2, name: 'zelda.jpg', gameName: 'Zelda'),
      ],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('game-filter-Splatoon 3')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('game-filter-Zelda')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('game-filter-Zelda')));
    await tester.pumpAndSettle();

    expect(find.text('zelda.jpg'), findsOneWidget);
    expect(find.text('splatoon.jpg'), findsNothing);
    expect(backend.gameSelectionCounts['Zelda'], 1);
  });

  testWidgets('expands game tags and shows total media counts', (tester) async {
    final backend = FakeBackend(
      mediaItems: List.generate(
        8,
        (index) => _media(
          id: index + 1,
          name: 'game-$index.jpg',
          gameName: 'Game ${index + 1}',
        ),
      ),
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('game-filter-Game 7')), findsNothing);
    expect(find.byKey(const Key('toggle-all-game-tags')), findsOneWidget);
    await tester.tap(find.byKey(const Key('toggle-all-game-tags')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('game-filter-Game 7')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('game-filter-count-Game 7')),
      findsOneWidget,
    );
    expect(find.text('共 1 项'), findsNWidgets(8));
  });

  testWidgets('album game filters only show games present in that album', (
    tester,
  ) async {
    final backend = FakeBackend(
      mediaItems: [
        _media(id: 1, name: 'inside.jpg', gameName: 'Splatoon 3'),
        _media(id: 2, name: 'outside.jpg', gameName: 'Zelda'),
      ],
      albumItems: [
        AlbumSummary(
          id: 2,
          name: '只看喷喷',
          description: '',
          albumType: 'manual',
          pinned: false,
          mediaCount: BigInt.one,
        ),
      ],
      albumMediaIds: const {
        2: {1},
      },
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('相册').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('album-card-2')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('game-filter-Splatoon 3')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('game-filter-Zelda')), findsNothing);
  });

  testWidgets('opens media preview and navigates with buttons and keyboard', (
    tester,
  ) async {
    final backend = FakeBackend(
      mediaItems: [
        _media(id: 1, name: 'first.jpg'),
        _media(id: 2, name: 'second.jpg'),
      ],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('media-card-1')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('media-viewer-dialog')),
        matching: find.text('first.jpg'),
      ),
      findsOneWidget,
    );
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('Splatoon 3'), findsWidgets);
    final viewerBounds = tester.getRect(
      find.byKey(const Key('media-viewer-dialog')),
    );
    final closeButtonBounds = tester.getRect(
      find.byKey(const Key('media-viewer-close')),
    );
    expect(closeButtonBounds.center.dx, lessThan(viewerBounds.center.dx));
    expect(
      tester.widget<Text>(find.byKey(const Key('media-viewer-note'))).data,
      '一条测试备注',
    );

    await tester.tap(find.byKey(const Key('media-viewer-immersive')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-viewer-note')), findsNothing);
    expect(find.byKey(const Key('media-viewer-next')), findsOneWidget);
    await tester.tap(find.byKey(const Key('media-viewer-immersive')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('media-viewer-edit-metadata')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('media-metadata-note')),
      '预览中修改的备注',
    );
    await tester.enterText(
      find.byKey(const Key('media-metadata-new-tag')),
      '新标签',
    );
    await tester.ensureVisible(find.byKey(const Key('save-media-metadata')));
    await tester.tap(find.byKey(const Key('save-media-metadata')));
    await tester.pumpAndSettle();

    expect(backend.noteUpdates[1], '预览中修改的备注');
    expect(backend.tagUpdates[1], contains('新标签'));
    expect(
      tester.widget<Text>(find.byKey(const Key('media-viewer-note'))).data,
      '预览中修改的备注',
    );
    expect(find.text('新标签'), findsOneWidget);

    await tester.tap(find.byKey(const Key('media-viewer-next')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('media-viewer-dialog')),
        matching: find.text('second.jpg'),
      ),
      findsOneWidget,
    );
    expect(find.text('2 / 2'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
  });

  testWidgets('batch selection requires confirmation before deleting files', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    expect(find.byTooltip('删除或移出相册'), findsNothing);
    await tester.tap(find.byKey(const Key('start-media-selection')));
    await tester.pumpAndSettle();
    final checkbox = find.byKey(const ValueKey('media-selected-1'));
    final checkboxBox = tester.widget<SizedBox>(
      find.ancestor(of: checkbox, matching: find.byType(SizedBox)).first,
    );
    expect(checkboxBox.width, 48);
    expect(checkboxBox.height, 48);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('batch-delete-media')), findsNothing);
    await tester.tap(find.byKey(const Key('batch-media-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batch-delete-media')));
    await tester.pumpAndSettle();
    expect(find.text('永久删除 1 项媒体？'), findsOneWidget);
    expect(backend.deletedMediaId, isNull);

    await tester.tap(find.widgetWithText(FilledButton, '永久删除'));
    await tester.pumpAndSettle();
    expect(backend.deletedMediaId, 1);
  });

  testWidgets('batch selection copies media to a regular album', (
    tester,
  ) async {
    final backend = FakeBackend(
      albumItems: [
        AlbumSummary(
          id: 1,
          name: '收藏',
          description: '',
          albumType: 'smart',
          pinned: true,
          systemKey: 'favorites',
          mediaCount: BigInt.one,
        ),
        AlbumSummary(
          id: 2,
          name: '旅行',
          description: '旅行照片',
          albumType: 'manual',
          pinned: false,
          mediaCount: BigInt.zero,
        ),
      ],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('start-media-selection')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('media-selected-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batch-media-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制到相册'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旅行'));
    await tester.pumpAndSettle();

    expect(backend.albumAdds, [(2, 1)]);
  });

  testWidgets('batch selection bar stays fixed without blocking media cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeBackend(
      mediaItems: List.generate(
        20,
        (index) => _media(id: index + 1, name: 'media-${index + 1}.jpg'),
      ),
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    final mediaBeforeSelecting = tester
        .getTopLeft(find.byKey(const ValueKey('media-card-1')))
        .dy;
    await tester.tap(find.byKey(const Key('start-media-selection')));
    await tester.pumpAndSettle();
    final sticky = find.byKey(const Key('batch-selection-sticky'));
    expect(sticky, findsOneWidget);
    expect(find.byKey(const Key('page-title')), findsNothing);
    final mediaAfterSelecting = tester
        .getTopLeft(find.byKey(const ValueKey('media-card-1')))
        .dy;
    expect(mediaAfterSelecting, lessThan(mediaBeforeSelecting));
    final initialTop = tester.getTopLeft(sticky).dy;

    await tester.tap(find.byKey(const ValueKey('media-selected-1')));
    await tester.pump();
    expect(
      tester
          .widget<Checkbox>(find.byKey(const ValueKey('media-selected-1')))
          .value,
      isTrue,
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(sticky).dy, initialTop);
    expect(find.byKey(const Key('batch-media-actions')), findsOneWidget);
  });

  testWidgets(
    'batch drag selects cards and selected cards have a strong outline',
    (tester) async {
      final backend = FakeBackend(
        mediaItems: [
          _media(id: 1, name: 'one.jpg'),
          _media(id: 2, name: 'two.jpg'),
          _media(id: 3, name: 'three.jpg'),
        ],
      );
      await tester.pumpWidget(SquidAlbumApp(backend: backend));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-media-selection')));
      await tester.pumpAndSettle();

      final first = tester.getCenter(
        find.byKey(const ValueKey('media-card-1')),
      );
      final second = tester.getCenter(
        find.byKey(const ValueKey('media-card-2')),
      );
      final gesture = await tester.startGesture(
        first,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(second);
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Checkbox>(find.byKey(const ValueKey('media-selected-1')))
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<Checkbox>(find.byKey(const ValueKey('media-selected-2')))
            .value,
        isTrue,
      );
      final card = tester.widget<Card>(
        find.byKey(const ValueKey('media-card-1')),
      );
      final shape = card.shape! as RoundedRectangleBorder;
      expect(shape.side.width, greaterThanOrEqualTo(3));
    },
  );

  testWidgets('gallery density sliders control grid columns and row height', (
    tester,
  ) async {
    final backend = FakeBackend(
      mediaItems: List.generate(
        12,
        (index) => _media(id: index + 1, name: 'media-$index.jpg'),
      ),
    );
    backend.settings = const AppSettings(
      libraryPath: 'C:/library',
      theme: 'ocean',
      language: 'zh',
      galleryColumns: 6,
      galleryRows: 6,
      showNotePreview: true,
      showGameTag: true,
      compactTagDisplay: true,
      autoPlayVideo: false,
      autoSyncOnLaunch: false,
      closeBehavior: 'ask',
      syncPolicy: SyncPolicy(
        enabled: false,
        activeIntervalMinutes: 10,
        sleepAfterHours: 24,
      ),
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    final grid = tester.widget<GridView>(find.byType(GridView).first);
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 6);
    expect(delegate.mainAxisExtent, isNotNull);
  });

  testWidgets('batch selection supports select all and invert visible media', (
    tester,
  ) async {
    final backend = FakeBackend(
      mediaItems: [
        _media(id: 1, name: 'one.jpg'),
        _media(id: 2, name: 'two.jpg'),
        _media(id: 3, name: 'three.jpg'),
      ],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-media-selection')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('batch-select-all')));
    await tester.pumpAndSettle();
    for (final id in [1, 2, 3]) {
      expect(
        tester
            .widget<Checkbox>(find.byKey(ValueKey('media-selected-$id')))
            .value,
        isTrue,
      );
    }
    await tester.tap(find.byKey(const Key('batch-invert-selection')));
    await tester.pumpAndSettle();
    for (final id in [1, 2, 3]) {
      expect(
        tester
            .widget<Checkbox>(find.byKey(ValueKey('media-selected-$id')))
            .value,
        isFalse,
      );
    }
  });

  testWidgets('single media context menu copies and deletes from library', (
    tester,
  ) async {
    final backend = FakeBackend(
      albumItems: [
        AlbumSummary(
          id: 2,
          name: '旅行',
          description: '',
          albumType: 'manual',
          pinned: false,
          mediaCount: BigInt.zero,
        ),
      ],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('media-card-1')));
    final cardRectAfterCopy = tester.getRect(
      find.byKey(const ValueKey('media-card-1')),
    );
    await tester.tapAt(
      cardRectAfterCopy.topLeft + const Offset(20, 20),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('single-media-copy')), findsOneWidget);
    expect(find.byKey(const Key('single-media-move')), findsOneWidget);
    expect(find.byKey(const Key('single-media-delete')), findsOneWidget);

    await tester.tap(find.byKey(const Key('single-media-copy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旅行'));
    await tester.pumpAndSettle();
    expect(backend.albumAdds, [(2, 1)]);

    await tester.ensureVisible(find.byKey(const ValueKey('media-card-1')));
    final cardRect = tester.getRect(find.byKey(const ValueKey('media-card-1')));
    await tester.tapAt(
      cardRect.topLeft + const Offset(20, 20),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('single-media-delete')));
    await tester.pumpAndSettle();
    expect(find.text('永久删除 1 项媒体？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '永久删除'));
    await tester.pumpAndSettle();
    expect(backend.deletedMediaId, 1);
  });

  testWidgets('single media move removes it from a manual album', (
    tester,
  ) async {
    final backend = FakeBackend(
      albumItems: [
        AlbumSummary(
          id: 2,
          name: '来源相册',
          description: '',
          albumType: 'manual',
          pinned: false,
          mediaCount: BigInt.one,
        ),
        AlbumSummary(
          id: 3,
          name: '目标相册',
          description: '',
          albumType: 'manual',
          pinned: false,
          mediaCount: BigInt.zero,
        ),
      ],
      albumMediaIds: const {
        2: {1},
      },
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('相册').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('album-card-2')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('media-card-1')));
    final cardRect = tester.getRect(find.byKey(const ValueKey('media-card-1')));
    await tester.tapAt(
      cardRect.topLeft + const Offset(20, 20),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('single-media-move')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目标相册'));
    await tester.pumpAndSettle();

    expect(backend.albumAdds, [(3, 1)]);
    expect(backend.removedAlbumId, 2);
    expect(backend.removedMediaId, 1);
  });

  testWidgets('moving from a smart album behaves as a copy', (tester) async {
    final backend = FakeBackend(
      albumItems: [
        AlbumSummary(
          id: 1,
          name: '收藏',
          description: '',
          albumType: 'smart',
          pinned: true,
          systemKey: 'favorites',
          mediaCount: BigInt.one,
        ),
        AlbumSummary(
          id: 2,
          name: '目标相册',
          description: '',
          albumType: 'manual',
          pinned: false,
          mediaCount: BigInt.zero,
        ),
      ],
      albumMediaIds: const {
        1: {1},
      },
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('相册').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('album-card-1')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('media-card-1')));
    final cardRect = tester.getRect(find.byKey(const ValueKey('media-card-1')));
    await tester.tapAt(
      cardRect.topLeft + const Offset(20, 20),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('single-media-move')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目标相册'));
    await tester.pumpAndSettle();

    expect(backend.albumAdds, [(2, 1)]);
    expect(backend.removedAlbumId, isNull);
  });

  testWidgets('batch export shows destination and naming parameters', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('start-media-selection')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('media-selected-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batch-media-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出至指定目录'));
    await tester.pumpAndSettle();

    expect(find.text('导出所选媒体'), findsOneWidget);
    expect(find.byKey(const Key('media-export-directory')), findsOneWidget);
    expect(find.byKey(const Key('media-export-name-format')), findsOneWidget);
    for (final placeholder in const [
      '{相册内名称}',
      '{游戏名}',
      '{年月日}',
      '{标签}',
      '{备注}',
    ]) {
      expect(
        find.byKey(ValueKey('export-placeholder-$placeholder')),
        findsOneWidget,
      );
    }
    await tester.tap(find.byKey(const ValueKey('export-placeholder-{游戏名}')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('media-export-name-format')))
          .controller!
          .text,
      '{相册内名称}{游戏名}',
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('confirm-media-export')))
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('media-export-directory')),
      r'C:\Exports',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirm-media-export')));
    await tester.pumpAndSettle();
    expect(find.text('打开目录'), findsOneWidget);
    await tester.tap(find.text('打开目录'));
    await tester.pump();
    expect(backend.openedDirectory, r'C:\Exports');
  });

  testWidgets('batch merge filters selected images before opening order page', (
    tester,
  ) async {
    final backend = FakeBackend(
      mediaItems: [
        _media(id: 1, name: 'cover.jpg'),
        _media(id: 2, name: 'first.mp4', kind: MediaKind.video),
        _media(id: 3, name: 'second.mp4', kind: MediaKind.video),
      ],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('start-media-selection')));
    await tester.pumpAndSettle();
    for (final id in [1, 2, 3]) {
      await tester.tap(find.byKey(ValueKey('media-selected-$id')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('batch-media-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并视频'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('video-merge-dialog')), findsOneWidget);
    expect(find.textContaining('2 个视频'), findsOneWidget);
    final dialog = find.byKey(const Key('video-merge-dialog'));
    expect(
      find.descendant(of: dialog, matching: find.text('cover.jpg')),
      findsNothing,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('first.mp4')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('second.mp4')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.byKey(const ValueKey('video-merge-thumbnail-2')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.byKey(const ValueKey('video-merge-preview-2')),
      ),
      findsOneWidget,
    );
    final mergeThumbnail = find.byKey(
      const ValueKey('video-merge-thumbnail-2'),
    );
    expect(tester.getSize(mergeThumbnail).width, greaterThan(190));
    expect(tester.getSize(mergeThumbnail).width, lessThan(240));
    expect(
      find.byKey(const Key('video-merge-window-drag-area')),
      findsOneWidget,
    );
  });

  testWidgets('video cards show a cover area and duration', (tester) async {
    final backend = FakeBackend(
      mediaItems: [_media(id: 2, name: 'clip.mp4', kind: MediaKind.video)],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('video-duration-2')), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);
  });

  testWidgets('compact tag display combines game and custom tags', (
    tester,
  ) async {
    final backend = FakeBackend(mediaItems: [_media(id: 1, name: 'shot.jpg')]);
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('media-card-compact-tags-1')),
      findsOneWidget,
    );

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    final compactSwitch = find.byKey(const Key('compact-tag-display'));
    await tester.ensureVisible(compactSwitch);
    await tester.tap(compactSwitch);
    await tester.pumpAndSettle();

    expect(backend.settings.compactTagDisplay, isFalse);
    await tester.tap(find.text('图库').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('media-card-compact-tags-1')),
      findsNothing,
    );
  });

  testWidgets('hovering a long filename starts marquee scrolling', (
    tester,
  ) async {
    final backend = FakeBackend(
      mediaItems: [
        _media(
          id: 1,
          name: 'this-is-a-very-long-media-file-name-that-needs-to-scroll.jpg',
        ),
      ],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    final filename = find.byKey(const ValueKey('media-filename-1'));
    final mouseRegion = find.descendant(
      of: filename,
      matching: find.byType(MouseRegion),
    );
    tester.widget<MouseRegion>(mouseRegion).onEnter!(const PointerEnterEvent());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 900));

    final scroll = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: filename,
        matching: find.byKey(const Key('filename-marquee-scroll')),
      ),
    );
    expect(scroll.controller!.offset, greaterThan(0));
  });

  testWidgets('manages custom tags with photo and video usage counts', (
    tester,
  ) async {
    final backend = FakeBackend(
      tagUsageItems: [
        TagUsageSummary(
          id: 1,
          name: '慶典',
          imageCount: BigInt.from(2),
          videoCount: BigInt.one,
        ),
      ],
      gameTagAliases: [
        GameTagAliasSummary(sourceName: 'BOTW', targetName: 'Splatoon 3'),
      ],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    final manageTags = find.byKey(const Key('open-tag-management'));
    final settingsScroll = find
        .ancestor(of: manageTags, matching: find.byType(CustomScrollView))
        .first;
    await tester.drag(settingsScroll, const Offset(0, -420));
    await tester.pumpAndSettle();
    await tester.ensureVisible(manageTags);
    await tester.tap(manageTags);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tag-management-dialog')), findsOneWidget);
    expect(find.text('2 张图片 · 1 个视频 · 共 3 项'), findsOneWidget);

    await tester.tap(find.byKey(const Key('create-custom-tag')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('create-tag-field')), '旅行');
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirm-create-tag')));
    await tester.pumpAndSettle();
    expect(backend.tagUsageItems.any((tag) => tag.name == '旅行'), isTrue);

    await tester.tap(find.byKey(const ValueKey('rename-tag-1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rename-tag-field')), '祭典');
    await tester.tap(find.byKey(const Key('confirm-rename-tag')));
    await tester.pumpAndSettle();
    expect(backend.tagUsageItems.singleWhere((tag) => tag.id == 1).name, '祭典');
    expect(find.text('祭典'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('delete-tag-1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('不会删除任何媒体文件'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-delete-tag')));
    await tester.pumpAndSettle();
    expect(backend.tagUsageItems.map((tag) => tag.name), ['旅行']);
    expect(find.text('旅行'), findsOneWidget);

    await tester.tap(find.text('游戏标签'));
    await tester.pumpAndSettle();
    expect(find.textContaining('原始名称：BOTW'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rename-game-tag-Splatoon 3')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('rename-game-tag-field')),
      '斯普拉遁 3',
    );
    await tester.tap(find.byKey(const Key('confirm-rename-game-tag')));
    await tester.pumpAndSettle();
    expect(backend.mediaItems!.single.gameName, '斯普拉遁 3');
  });

  testWidgets('layout sliders show their draft values while dragging', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    final columns = find.byKey(const Key('gallery-columns-slider'));
    tester.widget<Slider>(columns).onChanged!(6);
    await tester.pump();
    expect(find.text('每行 6 个媒体'), findsOneWidget);
    expect(tester.widget<Slider>(columns).label, '6');
    tester.widget<Slider>(columns).onChangeEnd!(6);
    await tester.pumpAndSettle();
    expect(backend.settings.galleryColumns, 6);

    final rows = find.byKey(const Key('gallery-rows-slider'));
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      expect(rows, findsNothing);
    } else {
      tester.widget<Slider>(rows).onChanged!(7);
      await tester.pump();
      expect(find.text('纵向预览 7 行'), findsOneWidget);
      expect(tester.widget<Slider>(rows).label, '7');
      tester.widget<Slider>(rows).onChangeEnd!(7);
      await tester.pumpAndSettle();
      expect(backend.settings.galleryRows, 7);
    }
  });

  testWidgets('collapses and expands the compact desktop sidebar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byKey(const Key('desktop-sidebar'))).width, 72);
    expect(find.byTooltip('展开侧边栏'), findsOneWidget);
    await tester.tap(find.byTooltip('展开侧边栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final animatedWidth = tester
        .getSize(find.byKey(const Key('desktop-sidebar')))
        .width;
    expect(animatedWidth, greaterThan(72));
    expect(animatedWidth, lessThan(220));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('desktop-sidebar'))).width, 220);
    expect(find.byTooltip('收起侧边栏'), findsOneWidget);
    final libraryLabel = find.descendant(
      of: find.byKey(const ValueKey('sidebar-label-图库')),
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(libraryLabel).style?.fontFamily, 'SmileySans');
  });

  testWidgets('desktop sidebar does not duplicate the native window brand', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sidebar-brand-icon')), findsNothing);
    expect(find.byKey(const Key('sidebar-brand-label')), findsNothing);
  });

  testWidgets('game filter labels remain readable in the light theme', (
    tester,
  ) async {
    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();

    final chip = tester.widget<FilterChip>(
      find.byKey(const ValueKey('game-filter-Splatoon 3')),
    );
    expect(chip.labelStyle?.color, isNotNull);
    expect(chip.labelStyle?.color, isNot(equals(Colors.white)));

    final creationDateChip = tester.widget<InputChip>(
      find.byKey(const Key('capture-date-filter')),
    );
    expect(creationDateChip.labelStyle?.color, isNot(Colors.white));
  });

  testWidgets('keeps the desktop sidebar while viewing an album', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.photo_album_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('album-card-1')));
    await tester.pumpAndSettle();

    expect(find.byTooltip('展开侧边栏'), findsOneWidget);
    expect(find.byKey(const Key('album-detail-back')), findsOneWidget);
  });

  testWidgets('renames and deletes a regular album from its context menu', (
    tester,
  ) async {
    final backend = FakeBackend(
      albumItems: [
        AlbumSummary(
          id: 1,
          name: '收藏',
          description: '',
          albumType: 'smart',
          pinned: true,
          systemKey: 'favorites',
          mediaCount: BigInt.one,
        ),
        AlbumSummary(
          id: 2,
          name: '旧相册',
          description: '',
          albumType: 'manual',
          pinned: false,
          mediaCount: BigInt.one,
        ),
      ],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('相册').last);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('album-card-2')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('编辑相册'), findsOneWidget);
    expect(find.text('转换为自动相册'), findsOneWidget);
    expect(find.text('删除相册'), findsOneWidget);

    await tester.tap(find.text('编辑相册'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rename-album-field')), '新相册');
    await tester.enterText(
      find.byKey(const Key('edit-album-description-field')),
      '新的相册描述',
    );
    await tester.tap(find.byKey(const Key('confirm-rename-album')));
    await tester.pumpAndSettle();
    expect(backend.albumItems!.last.name, '新相册');
    expect(backend.albumItems!.last.description, '新的相册描述');

    await tester.tap(
      find.byKey(const ValueKey('album-card-2')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除相册'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不会删除图库中的任何图片或视频'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-delete-album')));
    await tester.pumpAndSettle();
    expect(backend.albumItems!.any((album) => album.id == 2), isFalse);
  });

  testWidgets('switches to English and opens the log file', (tester) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsWidgets);
    expect(backend.settings.language, 'en');

    final proxyField = find.byType(TextField).last;
    await tester.ensureVisible(proxyField);
    await tester.enterText(proxyField, 'http://127.0.0.1:7890');
    final saveProxy = find.widgetWithText(FilledButton, 'Save proxy');
    await tester.ensureVisible(saveProxy);
    await tester.tap(saveProxy);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Proxy saved. New Nintendo, NXAPI, and Coral requests will use it.',
      ),
      findsOneWidget,
    );

    final openLog = find.widgetWithText(FilledButton, 'Open log').first;
    final settingsScroll = find
        .ancestor(of: openLog, matching: find.byType(CustomScrollView))
        .first;
    await tester.drag(settingsScroll, const Offset(0, -1200));
    await tester.pumpAndSettle();
    await tester.tap(openLog);
    await tester.pumpAndSettle();
    expect(backend.logOpened, isTrue);
  });

  testWidgets('about section shows the author profile and feedback links', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Fresh Album',
      packageName: 'io.squidalbum',
      version: '4.5.6',
      buildNumber: '78',
      buildSignature: '',
    );
    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    final settingsScroll = find.byType(CustomScrollView);
    await tester.drag(settingsScroll, const Offset(0, -1600));
    await tester.pumpAndSettle();

    expect(find.text('Cypas_Nya'), findsOneWidget);
    expect(find.text('小鱿鱿bot作者'), findsOneWidget);
    expect(find.textContaining('4.5.6+78'), findsOneWidget);
    if (Platform.isWindows) {
      expect(find.byKey(const Key('check-app-updates')), findsOneWidget);
    }
    expect(find.byKey(const Key('about-xiaoyouyou-link')), findsOneWidget);
    expect(find.byKey(const Key('about-feedback-link')), findsOneWidget);
    expect(find.textContaining('项目路径'), findsNothing);
    expect(find.textContaining('检查更新接口'), findsNothing);
  });

  testWidgets('shows the connected Nintendo nickname and avatar', (
    tester,
  ) async {
    final backend = FakeBackend(
      signedIn: true,
      accountProfile: NintendoAccountProfile(
        accountId: 'account-1',
        nickname: 'Inkling',
        avatarBytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      ),
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导入与同步').last);
    await tester.pumpAndSettle();

    expect(find.text('Inkling'), findsOneWidget);
    expect(find.byKey(const Key('nintendo-account-avatar')), findsOneWidget);
    expect(find.text('Nintendo Account · 已连接 1 个账号'), findsOneWidget);
  });

  testWidgets('switches between multiple Nintendo accounts', (tester) async {
    final backend = FakeBackend(
      signedIn: true,
      accountProfiles: const [
        NintendoAccountProfile(accountId: 'account-1', nickname: 'Inkling'),
        NintendoAccountProfile(accountId: 'account-2', nickname: 'Octoling'),
      ],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导入与同步').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync-account-account-1')), findsOneWidget);
    expect(find.byKey(const Key('sync-account-account-2')), findsOneWidget);

    await tester.tap(find.byKey(const Key('sync-account-account-2')));
    await tester.pumpAndSettle();

    expect(backend.selectedAccount, 'account-2');
    expect(find.text('Octoling'), findsWidgets);
  });

  testWidgets(
    'shows each Nintendo account its own latest sync time and result',
    (tester) async {
      final backend = FakeBackend(
        signedIn: true,
        accountProfiles: const [
          NintendoAccountProfile(accountId: 'account-1', nickname: 'Inkling'),
          NintendoAccountProfile(accountId: 'account-2', nickname: 'Octoling'),
        ],
        accountSyncHistories: {
          'account-1': SyncRuntimeState(
            latestAttempt: SyncAttemptSummary(
              attemptedAt: DateTime.utc(2026, 10, 6, 8, 15),
              status: 'partial_failure',
              totalFound: BigInt.from(12),
              downloaded: BigInt.from(7),
              duplicates: BigInt.from(3),
              failed: BigInt.from(2),
            ),
          ),
          'account-2': SyncRuntimeState(
            latestAttempt: SyncAttemptSummary(
              attemptedAt: DateTime.utc(2026, 10, 5, 18, 40),
              status: 'success',
              totalFound: BigInt.from(5),
              downloaded: BigInt.from(2),
              duplicates: BigInt.from(3),
              failed: BigInt.zero,
            ),
          ),
        },
      );
      await tester.pumpWidget(SquidAlbumApp(backend: backend));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入与同步').last);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('sync-account-account-1')),
          matching: find.textContaining('部分失败'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('sync-account-account-1')),
          matching: find.textContaining('新增 7'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('sync-account-account-2')),
          matching: find.textContaining('成功'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('sync-account-account-2')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                RegExp(r'2026-10-\d{2} \d{2}:\d{2} · 成功')
                    .hasMatch(widget.data ?? ''),
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('confirms before removing the current Nintendo account', (
    tester,
  ) async {
    final backend = FakeBackend(
      signedIn: true,
      accountProfile: const NintendoAccountProfile(
        accountId: 'account-1',
        nickname: 'Inkling',
      ),
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入与同步').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('remove-nintendo-account')));
    await tester.pumpAndSettle();
    expect(find.text('移除当前账号？'), findsOneWidget);
    expect(find.textContaining('已导入图库的图片、视频'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cancel-remove-nintendo-account')));
    await tester.pumpAndSettle();
    expect(backend.signOutCalls, 0);
    expect(backend.signedIn, isTrue);

    await tester.tap(find.byKey(const Key('remove-nintendo-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-remove-nintendo-account')));
    await tester.pumpAndSettle();

    expect(backend.signOutCalls, 1);
    expect(backend.signedIn, isFalse);
    final loginHelp = find.byKey(const Key('nintendo-login-help-image'));
    expect(loginHelp, findsOneWidget);
    expect(tester.getSize(loginHelp).width, lessThanOrEqualTo(420));
    await tester.drag(
      find.byKey(const Key('nintendo-sync-scroll')),
      const Offset(0, -520),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nso-auto-sync-settings')), findsOneWidget);
  });

  test('Windows default library uses the Pictures known folder', () {
    final path = defaultLibraryPathForPlatform(
      supportDirectory: r'C:\AppData\SquidAlbum',
      isWindows: true,
      picturesDirectory: r'C:\Pictures',
    );

    expect(path, r'C:\Pictures\FreshAlbum');
  });

  testWidgets('storage location change action stays enabled', (tester) async {
    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('change-library-path')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('persists the video autoplay setting', (tester) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    final autoplay = find.byKey(const Key('auto-play-video'));
    await tester.ensureVisible(autoplay);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: autoplay, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();

    expect(backend.settings.autoPlayVideo, isTrue);
  });

  testWidgets('manages automatic sync from the Nintendo page', (tester) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导入与同步').last);
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('nintendo-sync-scroll')),
      const Offset(0, -520),
    );
    await tester.pumpAndSettle();
    final panel = find.byKey(const Key('nso-auto-sync-settings'));
    expect(panel, findsOneWidget);
    expect(find.textContaining('休眠期每 60 分钟检查一次'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('nso-auto-sync-enabled')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('nso-auto-sync-enabled')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    expect(backend.settings.syncPolicy.enabled, isTrue);

    final launchSync = find.byKey(const Key('nso-auto-sync-on-launch'));
    await tester.ensureVisible(launchSync);
    await tester.tap(
      find.descendant(of: launchSync, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    expect(backend.settings.autoSyncOnLaunch, isTrue);

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nso-auto-sync-settings')), findsNothing);
    expect(find.text('自动同步与休眠'), findsNothing);
  });

  testWidgets('offers Nintendo sync, USB import, and custom import', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导入与同步').last);
    await tester.pumpAndSettle();
    expect(find.text('本地导入'), findsNothing);
    expect(find.text('Nintendo 同步'), findsOneWidget);
    expect(find.text('USB 导入'), findsOneWidget);
    expect(find.text('自定义导入'), findsOneWidget);
    expect(find.text('从本机或 microSD 导入'), findsNothing);

    final tabController = tester
        .widget<TabBar>(find.byType(TabBar))
        .controller!;
    tabController.animateTo(2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tabController.index, 2);
    expect(
      find.byKey(const Key('choose-custom-import-files'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('choose-custom-import-directory'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('custom-import-game-name'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('start-custom-import'), skipOffstage: false),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'runs Nintendo synchronization once when launch sync is enabled',
    (tester) async {
      final backend = FakeBackend(
        signedIn: true,
        syncFuture: Future.value(
          SyncSummary(
            jobId: 'launch-sync',
            totalFound: BigInt.zero,
            downloaded: BigInt.zero,
            duplicates: BigInt.zero,
            skippedRemote: BigInt.zero,
            failed: BigInt.zero,
            errors: const [],
          ),
        ),
      );
      backend.settings = AppSettings(
        proxyUrl: backend.settings.proxyUrl,
        libraryPath: backend.settings.libraryPath,
        theme: backend.settings.theme,
        language: backend.settings.language,
        galleryColumns: backend.settings.galleryColumns,
        galleryRows: backend.settings.galleryRows,
        showNotePreview: backend.settings.showNotePreview,
        showGameTag: backend.settings.showGameTag,
        compactTagDisplay: backend.settings.compactTagDisplay,
        autoPlayVideo: backend.settings.autoPlayVideo,
        autoSyncOnLaunch: true,
        closeBehavior: backend.settings.closeBehavior,
        syncPolicy: backend.settings.syncPolicy,
      );

      await tester.pumpWidget(SquidAlbumApp(backend: backend));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(backend.syncCalls, 1);
    },
  );

  testWidgets('shows an automatic sync failure in a global snackbar', (
    tester,
  ) async {
    final syncFailure = Completer<SyncSummary>();
    final backend = FakeBackend(syncFuture: syncFailure.future);
    final settings = SettingsController(backend);
    final sync = SyncController(backend);
    addTearDown(() {
      settings.dispose();
      sync.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: HomeShell(
          backend: backend,
          settings: settings,
          syncController: sync,
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(sync.run());
    await tester.pump();
    syncFailure.completeError(
      StateError(
        'provider failed: NXAPI OAuth token request failed with HTTP 401: Missing client authentication',
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(sync.state, SyncState.failed);
    expect(sync.error, isNotNull);

    expect(find.byType(MaterialBanner), findsOneWidget);
  });

  testWidgets('persists the desktop window close behavior', (tester) async {
    final backend = FakeBackend();
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    final selector = find.byKey(const Key('close-behavior-ask'));
    await tester.drag(
      find.byType(CustomScrollView).last,
      const Offset(0, -750),
    );
    await tester.pumpAndSettle();
    expect(tester.getCenter(selector).dy, lessThan(600));
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('最小化到托盘').last);
    await tester.pumpAndSettle();

    expect(backend.settings.closeBehavior, 'minimize_to_tray');
  });

  testWidgets('shows Nintendo synchronization totals and progress', (
    tester,
  ) async {
    final completer = Completer<SyncSummary>();
    final backend = FakeBackend(
      signedIn: true,
      syncFuture: completer.future,
      syncProgress: SyncProgress(
        jobId: 'job-1',
        status: 'running',
        totalItems: BigInt.from(10),
        processedItems: BigInt.from(4),
        synchronizedItems: BigInt.from(3),
        failedItems: BigInt.one,
      ),
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导入与同步').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '立即同步'));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byKey(const Key('nso-sync-progress')), findsOneWidget);
    expect(find.text('已同步 3 / 10 · 已处理 4 · 失败 1'), findsOneWidget);
    final indicator = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('nso-sync-progress')),
    );
    expect(indicator.value, closeTo(0.4, 0.001));

    completer.complete(
      SyncSummary(
        jobId: 'job-1',
        totalFound: BigInt.from(10),
        downloaded: BigInt.from(6),
        duplicates: BigInt.from(2),
        skippedRemote: BigInt.one,
        failed: BigInt.one,
        errors: const [],
      ),
    );
    await tester.pumpAndSettle();
  });
}

class FakeBackend implements AppBackend, SyncHistoryBackend {
  FakeBackend({
    this.signedIn = false,
    this.syncFuture,
    this.syncProgress,
    this.mediaItems,
    this.accountProfile,
    this.accountProfiles = const [],
    this.albumItems,
    this.albumMediaIds = const {},
    this.tagUsageItems = const [],
    this.gameTagAliases = const [],
    this.accountSyncHistories = const {},
  }) : selectedAccount =
           accountProfile?.accountId ?? accountProfiles.firstOrNull?.accountId;

  bool signedIn;
  final Future<SyncSummary>? syncFuture;
  List<MediaAsset>? mediaItems;
  final NintendoAccountProfile? accountProfile;
  final List<NintendoAccountProfile> accountProfiles;
  List<AlbumSummary>? albumItems;
  final Map<int, Set<int>> albumMediaIds;
  final Map<int, List<AlbumRule>> albumRules = {};
  List<TagUsageSummary> tagUsageItems;
  final List<GameTagAliasSummary> gameTagAliases;
  final Map<String, SyncRuntimeState> accountSyncHistories;
  final Map<String, int> gameSelectionCounts = {};
  String? selectedAccount;
  SyncProgress? syncProgress;
  Completer<void>? nextMediaGate;

  @override
  AppSettings settings = const AppSettings(
    libraryPath: 'C:/library',
    theme: 'ocean',
    language: 'zh',
    galleryColumns: 4,
    galleryRows: 3,
    showNotePreview: true,
    showGameTag: true,
    compactTagDisplay: true,
    autoPlayVideo: false,
    autoSyncOnLaunch: false,
    closeBehavior: 'ask',
    syncPolicy: SyncPolicy(
      enabled: false,
      activeIntervalMinutes: 10,
      sleepAfterHours: 24,
    ),
  );

  GalleryKindFilter lastKind = GalleryKindFilter.all;
  bool lastFavoriteOnly = false;
  bool lastNewestFirst = true;
  DateTime? lastCapturedFrom;
  DateTime? lastCapturedUntil;
  int listMediaCalls = 0;
  int listAlbumsCalls = 0;
  final Map<int, bool> favoriteUpdates = {};
  final Map<int, String> noteUpdates = {};
  final Map<int, List<String>> tagUpdates = {};
  List<int> exportedMediaIds = const [];
  String? exportDestination;
  String? exportNameFormat;
  List<String> lastImportPaths = const [];
  String? customImportGame;
  bool logOpened = false;
  String? openedDirectory;
  int? deletedMediaId;
  int? removedAlbumId;
  int? removedMediaId;
  final List<(int, int)> albumAdds = [];
  int syncCalls = 0;
  int signOutCalls = 0;

  @override
  String get logFilePath => 'C:/library/logs/squid_album.log';

  @override
  Future<void> logError(
    String message,
    Object error, [
    StackTrace? stackTrace,
  ]) async {}

  @override
  Future<void> openLogFile() async => logOpened = true;

  @override
  Future<void> openDirectory(String path) async => openedDirectory = path;

  @override
  Future<MediaExportSummary> exportMedia(
    List<int> mediaIds,
    String destination,
    String nameFormat,
  ) async {
    exportedMediaIds = List.of(mediaIds);
    exportDestination = destination;
    exportNameFormat = nameFormat;
    return MediaExportSummary(
      total: BigInt.from(mediaIds.length),
      exported: BigInt.from(mediaIds.length),
      failed: BigInt.zero,
      errors: const [],
    );
  }

  @override
  Future<MediaAsset> trimVideo(
    MediaAsset source,
    Duration start,
    Duration end, {
    required bool overwrite,
  }) async => MediaAsset(
    id: overwrite ? source.id : 9001,
    sha256: overwrite ? 'trimmed-${source.sha256}' : 'trimmed-copy',
    originalName: overwrite ? source.originalName : 'trimmed-copy.mp4',
    storagePath: overwrite ? source.storagePath : 'C:/library/trimmed-copy.mp4',
    kind: MediaKind.video,
    capturedAt: source.capturedAt,
    importedAt: source.importedAt,
    gameTitleId: source.gameTitleId,
    gameName: source.gameName,
    favorite: source.favorite,
    note: source.note,
    tags: source.tags,
  );

  @override
  Future<MediaAsset> saveVideoFrame(
    MediaAsset source,
    Uint8List bytes,
    String extension,
  ) async => _media(id: 9002, name: 'captured-frame.$extension');

  @override
  Future<String> createMergedVideoPreview(List<MediaAsset> videos) async =>
      'C:/temp/merged-preview.mp4';

  @override
  Future<MediaAsset> saveMergedVideo(
    List<MediaAsset> videos, {
    String? preparedPath,
  }) async => _media(id: 9003, name: 'merged.mp4', kind: MediaKind.video);

  @override
  Future<void> discardTemporaryMedia(String path) async {}

  @override
  Future<void> beginNintendoLogin() async {}

  @override
  Future<void> addMediaToAlbum(int albumId, int mediaId) async {
    albumAdds.add((albumId, mediaId));
  }

  @override
  Future<bool> cancelSync() async => true;

  @override
  Future<void> completeNintendoLogin(String callbackUrl) async {}

  @override
  Future<int> createAlbum(
    String name, {
    required String description,
    required bool smart,
  }) async => 2;

  @override
  Future<void> updateAlbum(
    int albumId,
    String name, {
    required String description,
    required bool smart,
  }) async {
    final albums = albumItems ??= [];
    final index = albums.indexWhere((album) => album.id == albumId);
    if (index < 0) return;
    final current = albums[index];
    albums[index] = AlbumSummary(
      id: current.id,
      name: name,
      description: description,
      albumType: smart ? 'smart' : 'manual',
      pinned: current.pinned,
      systemKey: current.systemKey,
      mediaCount: current.mediaCount,
    );
  }

  @override
  Future<void> mergeTags(List<int> tagIds, String targetName) async {}

  @override
  Future<void> mergeGameTags(List<String> gameNames, String targetName) async {}

  @override
  Future<List<AlbumRule>> listAlbumRules(int albumId) async =>
      List.of(albumRules[albumId] ?? const []);

  @override
  Future<void> replaceAlbumRules(int albumId, List<AlbumRule> rules) async {
    albumRules[albumId] = List.of(rules);
  }

  @override
  Future<void> deleteAlbum(int albumId) async {
    albumItems = albumItems?.where((album) => album.id != albumId).toList();
    albumRules.remove(albumId);
  }

  @override
  Future<MediaDeletionResult> deleteMedia(int mediaId) async {
    deletedMediaId = mediaId;
    return MediaDeletionResult(
      removedFromAlbum: false,
      deletedFromLibrary: true,
      remainingAlbumCount: BigInt.zero,
    );
  }

  @override
  Future<bool> get isSignedIn async => signedIn;

  @override
  Future<NintendoAccountProfile?> get nintendoAccountProfile async =>
      (await listNintendoAccounts())
          .where((profile) => profile.accountId == selectedAccount)
          .firstOrNull;

  @override
  Future<List<NintendoAccountProfile>> listNintendoAccounts() async {
    if (!signedIn) return const [];
    if (accountProfiles.isNotEmpty) return accountProfiles;
    if (accountProfile != null) return [accountProfile!];
    return const [
      NintendoAccountProfile(accountId: 'account-1', nickname: 'Player'),
    ];
  }

  @override
  Future<String?> get selectedNintendoAccountId async {
    selectedAccount ??= (await listNintendoAccounts()).firstOrNull?.accountId;
    return selectedAccount;
  }

  @override
  Future<SyncRuntimeState> loadSyncAccountHistory(String accountId) async =>
      accountSyncHistories[accountId] ?? const SyncRuntimeState();

  @override
  Future<void> selectNintendoAccount(String accountId) async {
    selectedAccount = accountId;
  }

  @override
  Future<void> removeNintendoAccount(String accountId) async {
    if (selectedAccount == accountId) selectedAccount = null;
  }

  @override
  Future<List<AlbumSummary>> listAlbums() async {
    listAlbumsCalls += 1;
    return List.of(
      albumItems ??
          [
            AlbumSummary(
              id: 1,
              name: '收藏',
              description: '',
              albumType: 'smart',
              pinned: true,
              systemKey: 'favorites',
              mediaCount: BigInt.one,
            ),
          ],
    );
  }

  @override
  Future<ImportSummary> importLocalFiles(List<String> paths) async {
    lastImportPaths = paths;
    return ImportSummary(
      totalFound: BigInt.one,
      imported: BigInt.one,
      duplicates: BigInt.zero,
      failed: BigInt.zero,
      errors: const [],
    );
  }

  @override
  Future<ImportSummary> importCustomFiles(
    List<String> paths,
    String gameName,
  ) async {
    customImportGame = gameName;
    return importLocalFiles(paths);
  }

  @override
  Future<ImportSummary> importMtpFiles(List<String> paths, String deviceName) =>
      importLocalFiles(paths);

  @override
  Future<List<MediaAsset>> listMedia({
    GalleryKindFilter kind = GalleryKindFilter.all,
    int limit = 100,
    int offset = 0,
    bool favoriteOnly = false,
    int? albumId,
    bool newestFirst = true,
    List<String> gameNames = const [],
    DateTime? capturedFrom,
    DateTime? capturedUntil,
  }) async {
    listMediaCalls += 1;
    lastKind = kind;
    lastFavoriteOnly = favoriteOnly;
    lastNewestFirst = newestFirst;
    lastCapturedFrom = capturedFrom;
    lastCapturedUntil = capturedUntil;
    final gate = nextMediaGate;
    if (gate != null) {
      nextMediaGate = null;
      await gate.future;
    }
    final result = [...?mediaItems]
      ..removeWhere(
        (item) =>
            albumId != null &&
            albumMediaIds.containsKey(albumId) &&
            !albumMediaIds[albumId]!.contains(item.id),
      )
      ..removeWhere(
        (item) => gameNames.isNotEmpty && !gameNames.contains(item.gameName),
      )
      ..removeWhere((item) {
        final timestamp = item.capturedAt ?? item.importedAt;
        return (capturedFrom != null && timestamp.isBefore(capturedFrom)) ||
            (capturedUntil != null && !timestamp.isBefore(capturedUntil));
      })
      ..sort((a, b) {
        final aTime = a.capturedAt ?? a.importedAt;
        final bTime = b.capturedAt ?? b.importedAt;
        return newestFirst ? bTime.compareTo(aTime) : aTime.compareTo(bTime);
      });
    return result.isEmpty && mediaItems == null
        ? [_media(id: 1, name: 'sample.jpg')]
        : result;
  }

  @override
  Future<List<String>> listTags() async => const ['慶典', 'Ranked'];

  @override
  Future<List<TagUsageSummary>> listTagUsage() async => List.of(tagUsageItems);

  @override
  Future<int> createTag(String name) async {
    final id =
        tagUsageItems.fold<int>(
          0,
          (value, tag) => tag.id > value ? tag.id : value,
        ) +
        1;
    tagUsageItems = [
      ...tagUsageItems,
      TagUsageSummary(
        id: id,
        name: name,
        imageCount: BigInt.zero,
        videoCount: BigInt.zero,
      ),
    ];
    return id;
  }

  @override
  Future<void> renameTag(int tagId, String newName) async {
    tagUsageItems = tagUsageItems
        .map(
          (tag) => tag.id == tagId
              ? TagUsageSummary(
                  id: tag.id,
                  name: newName,
                  imageCount: tag.imageCount,
                  videoCount: tag.videoCount,
                )
              : tag,
        )
        .toList();
  }

  @override
  Future<void> deleteTag(int tagId) async {
    tagUsageItems = tagUsageItems.where((tag) => tag.id != tagId).toList();
  }

  @override
  Future<List<GameTagSummary>> listGameTags() async {
    final grouped = <String, (int, int)>{};
    for (final item in mediaItems ?? [_media(id: 1, name: 'sample.jpg')]) {
      if (item.gameName.isEmpty) continue;
      final current = grouped[item.gameName] ?? (0, 0);
      grouped[item.gameName] = item.kind == MediaKind.image
          ? (current.$1 + 1, current.$2)
          : (current.$1, current.$2 + 1);
    }
    final values = grouped.entries
        .map(
          (entry) => GameTagSummary(
            name: entry.key,
            imageCount: BigInt.from(entry.value.$1),
            videoCount: BigInt.from(entry.value.$2),
            selectionCount: BigInt.from(gameSelectionCounts[entry.key] ?? 0),
          ),
        )
        .toList();
    values.sort((left, right) {
      final selected = right.selectionCount.compareTo(left.selectionCount);
      if (selected != 0) return selected;
      final total = (right.imageCount + right.videoCount).compareTo(
        left.imageCount + left.videoCount,
      );
      return total != 0 ? total : left.name.compareTo(right.name);
    });
    return values;
  }

  @override
  Future<List<GameTagAliasSummary>> listGameTagAliases() async =>
      gameTagAliases;

  @override
  Future<void> recordGameTagSelection(String gameName) async {
    gameSelectionCounts.update(
      gameName,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
  }

  @override
  Future<void> renameGameTag(String gameName, String targetName) async {
    mediaItems = (mediaItems ?? [_media(id: 1, name: 'sample.jpg')])
        .map(
          (item) => item.gameName == gameName
              ? MediaAsset(
                  id: item.id,
                  sha256: item.sha256,
                  originalName: item.originalName,
                  storagePath: item.storagePath,
                  kind: item.kind,
                  capturedAt: item.capturedAt,
                  importedAt: item.importedAt,
                  gameTitleId: item.gameTitleId,
                  gameName: targetName,
                  favorite: item.favorite,
                  note: item.note,
                  tags: item.tags,
                )
              : item,
        )
        .toList();
  }

  @override
  Future<MediaDeletionResult> removeMediaFromAlbum(
    int albumId,
    int mediaId,
  ) async {
    removedAlbumId = albumId;
    removedMediaId = mediaId;
    return MediaDeletionResult(
      removedFromAlbum: true,
      deletedFromLibrary: false,
      remainingAlbumCount: BigInt.one,
    );
  }

  @override
  Future<LibraryRelocationResult> relocateMediaLibrary(
    AppSettings value,
  ) async {
    settings = value;
    return LibraryRelocationResult(
      movedFiles: BigInt.one,
      libraryPath: value.libraryPath,
    );
  }

  @override
  Future<void> replaceTags(int mediaId, List<String> tags) async {
    tagUpdates[mediaId] = List.of(tags);
  }

  @override
  Future<void> saveSettings(AppSettings value) async => settings = value;

  @override
  Future<void> setFavorite(int mediaId, bool favorite) async {
    favoriteUpdates[mediaId] = favorite;
  }

  @override
  Future<void> setNote(int mediaId, String note) async {
    noteUpdates[mediaId] = note;
  }

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
    signedIn = false;
    selectedAccount = null;
  }

  @override
  Future<SyncProgress?> currentSyncProgress() async => syncProgress;

  @override
  Future<SyncSummary> syncNintendoAlbum() {
    syncCalls += 1;
    return syncFuture ?? Future.error(StateError('not signed in'));
  }
}

MediaAsset _media({
  required int id,
  required String name,
  MediaKind kind = MediaKind.image,
  DateTime? capturedAt,
  String gameName = 'Splatoon 3',
}) => MediaAsset(
  id: id,
  sha256: 'abc$id',
  originalName: name,
  storagePath: 'C:/library/$name',
  kind: kind,
  capturedAt: capturedAt ?? DateTime.utc(2026, 10, 3),
  importedAt: DateTime.utc(2026, 10, 3),
  gameName: gameName,
  favorite: true,
  note: '一条测试备注',
  tags: const ['慶典', 'Ranked'],
);
