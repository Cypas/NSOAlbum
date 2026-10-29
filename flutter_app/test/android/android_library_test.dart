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

import '../home_shell_test.dart' show FakeBackend;
import '../layout_viewport.dart';

void main() {
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
