@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/ui/platform_ui.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/android/android_metadata_editor.dart';
import 'package:squid_album/src/app_branding.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:squid_album/src/ui/android/android_media_card.dart';
import 'package:squid_album/src/ui/android/android_library_page.dart';
import 'package:squid_album/src/state/settings_copy.dart';

import '../home_shell_test.dart' show FakeBackend;
import '../layout_viewport.dart';

import 'package:squid_album/src/ui/android/android_media_viewer.dart';

void main() {
  testWidgets(
    'gallery viewport reaches the keyboard without a navigation gap',
    (tester) async {
      await useLayoutTestViewport(tester, const Size(412, 860));
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetViewInsets);
      final backend = FakeBackend(
        mediaItems: [for (var id = 1; id <= 48; id++) _image(id: id)],
      );
      await tester.pumpWidget(
        SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      final scrollView = find.byType(CustomScrollView);
      final scrollElement = tester.element(scrollView);
      final controller = tester
          .widget<CustomScrollView>(scrollView)
          .controller!;
      final offset = controller.offset;
      final listCalls = backend.listMediaCalls;
      final viewportBottom = tester.getBottomRight(scrollView).dy;

      await tester.tap(find.byKey(const Key('android-library-search-toggle')));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      tester.view.padding = const FakeViewPadding(top: 24);
      await tester.pumpAndSettle();

      expect(tester.getBottomRight(scrollView).dy, closeTo(560, 1));
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.element(scrollView), same(scrollElement));
      expect(controller.offset, offset);
      expect(backend.listMediaCalls, listCalls);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const Key('android-library-search')), findsOneWidget);
      tester.view.resetViewInsets();
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      await tester.pumpAndSettle();

      expect(tester.getBottomRight(scrollView).dy, viewportBottom);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(tester.element(scrollView), same(scrollElement));
      expect(controller.offset, offset);
      expect(backend.listMediaCalls, listCalls);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('gallery toolbar switches between title, search and selection', (
    tester,
  ) async {
    await useLayoutTestViewport(tester, const Size(360, 800));
    final backend = FakeBackend(mediaItems: [_image(), _image(id: 2)]);
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();

    expect(find.text(appChineseName), findsOneWidget);
    expect(
      find.byKey(const Key('android-library-search-toggle')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('android-library-filter')), findsOneWidget);
    expect(find.byKey(const Key('android-select-media')), findsOneWidget);
    expect(find.byKey(const Key('android-library-search')), findsNothing);

    await tester.tap(find.byKey(const Key('android-library-search-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-page-back')), findsOneWidget);
    expect(find.byKey(const Key('android-library-search')), findsOneWidget);
    expect(find.byKey(const Key('android-library-filter')), findsOneWidget);
    expect(find.byKey(const Key('android-select-media')), findsOneWidget);
    expect(find.text(appChineseName), findsNothing);
    expect(find.byKey(const ValueKey('android-media-1')), findsWidgets);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    await tester.enterText(
      find.byKey(const Key('android-library-search')),
      'test-2',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('android-media-1')), findsNothing);
    expect(find.byKey(const ValueKey('android-media-2')), findsOneWidget);

    await tester.tap(find.byKey(const Key('android-select-media')));
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 项'), findsOneWidget);
    expect(find.byKey(const Key('android-library-search')), findsNothing);
    expect(find.byKey(const Key('android-library-filter')), findsNothing);
    expect(
      find.byKey(const Key('android-library-search-toggle')),
      findsNothing,
    );
    expect(find.byTooltip('更多操作'), findsOneWidget);
    expect(find.byKey(const ValueKey('android-media-2')), findsOneWidget);

    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pumpAndSettle();
    expect(find.text(appChineseName), findsOneWidget);
    expect(find.byKey(const Key('android-library-search')), findsNothing);
    expect(find.byKey(const ValueKey('android-media-2')), findsOneWidget);
    await tester.tap(find.byKey(const Key('android-library-search-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-library-search')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('android-library-search')))
          .controller!
          .text,
      'test-2',
    );
    expect(find.byKey(const ValueKey('android-media-2')), findsOneWidget);

    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pumpAndSettle();
    expect(find.text(appChineseName), findsOneWidget);
    expect(find.byKey(const Key('android-library-search')), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  for (final (width, language, textScale) in [
    (360.0, 'zh', 1.0),
    (320.0, 'zh', 2.0),
    (320.0, 'en', 2.0),
  ]) {
    testWidgets(
      'toolbar search preserves scroll, draft and query at $width in $language',
      (tester) async {
        await useLayoutTestViewport(tester, Size(width, 800));
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final backend = FakeBackend(
          mediaItems: [for (var id = 1; id <= 24; id++) _image(id: id)],
        );
        backend.settings = copyAppSettings(
          backend.settings,
          language: language,
        );
        await tester.pumpWidget(
          SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
        );
        await tester.pumpAndSettle();

        final search = find.byKey(const Key('android-library-search'));
        final toggle = find.byKey(const Key('android-library-search-toggle'));
        final filter = find.byKey(const Key('android-library-filter'));
        expect(search, findsNothing);
        expect(
          find.descendant(of: find.byType(AppBar), matching: toggle),
          findsOneWidget,
        );
        final toggleRect = tester.getRect(toggle);
        final filterRect = tester.getRect(filter);
        expect(toggleRect.right, lessThanOrEqualTo(filterRect.left));
        expect(toggleRect.center.dy, closeTo(filterRect.center.dy, 1));
        expect(
          find.text(language == 'zh' ? appChineseName : appEnglishName),
          findsOneWidget,
        );

        await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
        await tester.pumpAndSettle();
        final library = tester
            .widget<AndroidLibraryPage>(find.byType(AndroidLibraryPage))
            .controller;
        final scrollController = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!;
        final scrollOffset = scrollController.offset;
        final card = find.byType(AndroidMediaCard).first;
        final thumbnail = find.descendant(
          of: card,
          matching: find.byType(AndroidMediaThumbnail),
        );
        final thumbnailElement = tester.element(thumbnail);
        final listCalls = backend.listMediaCalls;
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(search.hitTestable(), findsOneWidget);
        expect(
          find.descendant(of: find.byType(AppBar), matching: search),
          findsOneWidget,
        );
        expect(scrollController.offset, scrollOffset);
        expect(tester.element(thumbnail), same(thumbnailElement));
        final searchRect = tester.getRect(search);
        expect(searchRect.left, greaterThanOrEqualTo(0));
        expect(
          searchRect.right,
          lessThanOrEqualTo(tester.getRect(filter).left),
        );
        expect(searchRect.width, greaterThan(112));
        expect(find.byKey(const Key('android-page-back')), findsOneWidget);
        expect(toggle, findsNothing);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .focusNode
              .hasFocus,
          isTrue,
        );
        expect(backend.listMediaCalls, listCalls);
        await tester.enterText(search, 'No matching fixture');
        await tester.pump();
        expect(library.search, isEmpty);
        expect(backend.listMediaCalls, listCalls);

        await tester.tap(find.byKey(const Key('android-page-back')));
        await tester.pumpAndSettle();
        expect(search, findsNothing);
        expect(library.search, isEmpty);
        expect(backend.listMediaCalls, listCalls);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(search).controller!.text,
          'No matching fixture',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(library.search, 'No matching fixture');
        expect(find.byType(AndroidMediaCard), findsNothing);

        await tester.tap(find.byKey(const Key('android-page-back')));
        await tester.pumpAndSettle();
        expect(search, findsNothing);
        expect(library.search, 'No matching fixture');
        expect(tester.widget<IconButton>(toggle).isSelected, isTrue);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('android-select-media')));
        await tester.pumpAndSettle();
        expect(
          find.text(language == 'zh' ? '已选择 0 项' : '0 selected'),
          findsOneWidget,
        );
        expect(search, findsNothing);
        expect(toggle, findsNothing);
        expect(filter, findsNothing);
        expect(library.search, 'No matching fixture');
        await tester.tap(find.byKey(const Key('android-page-back')));
        await tester.pumpAndSettle();
        expect(search, findsNothing);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(search).controller!.text,
          'No matching fixture',
        );
        await tester.tap(
          find.byTooltip(language == 'zh' ? '清除搜索' : 'Clear search'),
        );
        await tester.pumpAndSettle();
        expect(library.search, isEmpty);
        expect(find.byType(AndroidMediaCard), findsWidgets);
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({TargetPlatform.android}),
    );
  }

  testWidgets('batch actions retain selections when query results refresh', (
    tester,
  ) async {
    await useLayoutTestViewport(tester, const Size(360, 800));
    final backend = _FavoriteBackend(mediaItems: [_image(), _image(id: 2)]);
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-select-media')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('android-media-1')));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 项'), findsOneWidget);

    // A controller refresh must not drop action targets merely because a
    // selected item is absent from the new page/query window.
    tester
        .widget<AndroidLibraryPage>(find.byType(AndroidLibraryPage))
        .controller
        .searchFor('test-2');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('android-media-1')), findsNothing);
    expect(find.text('已选择 1 项'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('android-media-2')));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 项'), findsOneWidget);

    expect(
      find.byKey(const Key('android-library-search-toggle')),
      findsNothing,
    );
    expect(find.byKey(const Key('android-library-search')), findsNothing);
    expect(find.text('已选择 2 项'), findsOneWidget);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(backend.favoriteUpdates, {1: true, 2: true});
    expect(find.text('已选择 2 项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 项'), findsNothing);
    expect(find.byKey(const Key('android-select-media')), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  for (final partialFailure in [false, true]) {
    testWidgets(
      'repeated batch tags retain previous writes across search, partial failure $partialFailure',
      (tester) async {
        await useLayoutTestViewport(tester, const Size(360, 800));
        final backend = _TagBackend(mediaItems: [_image(), _image(id: 2)]);
        await tester.pumpWidget(
          SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('android-select-media')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('android-media-1')));
        await tester.pumpAndSettle();
        tester
            .widget<AndroidLibraryPage>(find.byType(AndroidLibraryPage))
            .controller
            .searchFor('test-2');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('android-media-2')));
        await tester.pumpAndSettle();

        for (final tag in ['First', 'Second']) {
          backend.failTagMediaId = partialFailure && tag == 'First' ? 2 : null;
          await tester.tap(find.byTooltip('更多操作'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('新增标签'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).last, tag);
          await tester.tap(find.text('保存'));
          await tester.pumpAndSettle();
          if (partialFailure && tag == 'First') {
            expect(
              find.byKey(const Key('android-notice-bubble')),
              findsOneWidget,
            );
            await tester.pump(const Duration(seconds: 4));
          }
        }

        expect(backend.tagUpdates[1], ['Existing', 'First', 'Second']);
        expect(
          backend.tagUpdates[2],
          partialFailure
              ? ['Existing', 'Second']
              : ['Existing', 'First', 'Second'],
        );
        expect(find.text('已选择 2 项'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({TargetPlatform.android}),
    );
  }

  testWidgets('Android gallery opens and closes detail with a fade', (
    tester,
  ) async {
    await useLayoutTestViewport(tester, const Size(360, 800));
    final backend = FakeBackend(mediaItems: [_image()]);
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('android-media-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(find.byType(AndroidMediaViewer), findsOneWidget);
    final fadeFinder = find.byKey(const Key('android-detail-route-fade'));
    expect(fadeFinder, findsOneWidget);
    var fade = tester.widget<FadeTransition>(fadeFinder);
    expect(fade.opacity.value, greaterThan(0));
    expect(fade.opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FadeTransition>(
            find.byKey(const Key('android-detail-route-fade')),
          )
          .opacity
          .value,
      1,
    );

    Navigator.of(tester.element(find.byType(AndroidMediaViewer))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    fade = tester.widget<FadeTransition>(fadeFinder);
    expect(fade.opacity.value, greaterThan(0));
    expect(fade.opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(find.byType(AndroidMediaViewer), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets(
    'Android favorite updates only the tapped card without reloading siblings',
    (tester) async {
      await useLayoutTestViewport(tester, const Size(360, 720));
      final backend = _FavoriteBackend(mediaItems: [_image(), _image(id: 2)]);
      await tester.pumpWidget(
        SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
      );
      await tester.pumpAndSettle();

      final listCalls = backend.listMediaCalls;
      final siblingCard = find.byKey(const ValueKey('android-media-2'));
      final siblingThumbnail = find.descendant(
        of: siblingCard,
        matching: find.byType(AndroidMediaThumbnail),
      );
      final siblingElement = tester.element(siblingThumbnail);
      final firstCard = find.byKey(const ValueKey('android-media-1'));

      await tester.tap(
        find.descendant(of: firstCard, matching: find.byTooltip('收藏')),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: firstCard, matching: find.byIcon(Icons.favorite)),
        findsOneWidget,
      );
      expect(backend.listMediaCalls, listCalls);
      expect(tester.element(siblingThumbnail), same(siblingElement));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('Android metadata editor hides paths and saves notes', (
    tester,
  ) async {
    final backend = FakeBackend();
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
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      AndroidMetadataEditor(backend: backend, asset: _image()),
                ),
              ),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    expect(find.text(_image().storagePath), findsNothing);
    expect(find.textContaining(_image().sha256), findsNothing);
    await tester.enterText(
      find.byKey(const Key('android-metadata-note')),
      'Synthetic note',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(backend.noteUpdates[1], 'Synthetic note');
    expect(find.text('Open editor'), findsOneWidget);
  });

  testWidgets('custom Android date range stays in compact calendar dialog', (
    tester,
  ) async {
    final backend = FakeBackend(mediaItems: []);
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-library-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-filter-date-button')));
    await tester.pumpAndSettle();
    final customDialog = find.byKey(const Key('android-date-filter-dialog'));
    expect(customDialog, findsOneWidget);
    expect(find.byType(CalendarDatePicker), findsOneWidget);
    expect(tester.getSize(customDialog).height, lessThan(640));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('long press keeps album, tag and delete actions reachable', (
    tester,
  ) async {
    final backend = FakeBackend(mediaItems: [_image()]);
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('android-media-1')));
    await tester.pumpAndSettle();
    for (final action in ['复制到相册', '移动到相册', '收藏', '新增标签', '覆盖标签', '删除']) {
      expect(find.text(action), findsOneWidget);
    }
    await tester.tap(find.text('新增标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '新标签');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(backend.tagUpdates[1], ['Existing', '新标签']);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
  testWidgets('batch select all and inversion preserve the media subtree', (
    tester,
  ) async {
    final backend = FakeBackend(mediaItems: [_image()]);
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('android-media-1'));
    final element = tester.element(card);
    await tester.tap(find.byKey(const Key('android-select-media')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-library-search')), findsNothing);
    expect(
      find.byKey(const Key('android-library-search-toggle')),
      findsNothing,
    );
    expect(find.byKey(const Key('android-library-filter')), findsNothing);
    expect(tester.element(card), same(element));
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 项'), findsOneWidget);
    expect(tester.element(card), same(element));
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('反选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pumpAndSettle();
    expect(tester.element(card), same(element));
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}

MediaAsset _image({int id = 1}) => MediaAsset(
  id: id,
  sha256: 'image-fixture-$id',
  originalName: 'test-$id.png',
  storagePath: 'C:/nonexistent/image-$id.png',
  kind: MediaKind.image,
  importedAt: DateTime(2026, 10, 13),
  gameName: 'Game',
  favorite: false,
  tags: const ['Existing'],
);

class _FavoriteBackend extends FakeBackend {
  _FavoriteBackend({required super.mediaItems});

  @override
  Future<void> setFavorite(int mediaId, bool favorite) async {
    await super.setFavorite(mediaId, favorite);
    mediaItems = [...?mediaItems].map((item) {
      if (item.id != mediaId) return item;
      return MediaAsset(
        id: item.id,
        sha256: item.sha256,
        originalName: item.originalName,
        storagePath: item.storagePath,
        kind: item.kind,
        capturedAt: item.capturedAt,
        importedAt: item.importedAt,
        gameTitleId: item.gameTitleId,
        gameName: item.gameName,
        favorite: favorite,
        note: item.note,
        tags: item.tags,
      );
    }).toList();
  }
}

class _TagBackend extends FakeBackend {
  _TagBackend({required super.mediaItems});

  int? failTagMediaId;

  @override
  Future<void> replaceTags(int mediaId, List<String> tags) async {
    if (mediaId == failTagMediaId) {
      throw StateError('Synthetic tag update failure');
    }
    await super.replaceTags(mediaId, tags);
    mediaItems = [
      for (final item in mediaItems!)
        if (item.id != mediaId)
          item
        else
          MediaAsset(
            id: item.id,
            sha256: item.sha256,
            originalName: item.originalName,
            storagePath: item.storagePath,
            kind: item.kind,
            capturedAt: item.capturedAt,
            importedAt: item.importedAt,
            gameTitleId: item.gameTitleId,
            gameName: item.gameName,
            favorite: item.favorite,
            note: item.note,
            tags: List.of(tags),
          ),
    ];
  }
}
