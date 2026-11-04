import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:squid_album/main.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/settings_copy.dart';
import 'package:squid_album/src/ui/font_families.dart';
import 'package:squid_album/src/ui/gallery_perf.dart';
import 'package:squid_album/src/ui/scroll_to_top_button.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

import 'home_shell_test.dart' show FakeBackend;

class _DelayedAccountsBackend extends FakeBackend {
  _DelayedAccountsBackend(this.gate);

  final Completer<void> gate;

  @override
  Future<List<NintendoAccountProfile>> listNintendoAccounts() async {
    await gate.future;
    return super.listNintendoAccounts();
  }

  @override
  Future<String?> get selectedNintendoAccountId async {
    await gate.future;
    return super.selectedNintendoAccountId;
  }
}

void main() {
  setUp(() async {
    await loadCustomFontFamilies(const []);
  });

  testWidgets('return scrolling shows a warm video cover in the first frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = image.encodeJpg(image.Image(width: 16, height: 9));
    final assets = List.generate(
      60,
      (index) => MediaAsset(
        id: index + 1,
        sha256: 'desktop-return-scroll-video-$index',
        originalName: 'video-$index.mp4',
        storagePath: 'unavailable-$index.mp4',
        kind: MediaKind.video,
        gameName: '',
        favorite: false,
        tags: const [],
      ),
    );
    for (final asset in assets) {
      VideoThumbnailCache.seedForTest(
        asset.sha256,
        VideoThumbnailData(bytes: bytes, duration: const Duration(seconds: 10)),
      );
    }
    await tester.pumpWidget(
      SquidAlbumApp(backend: FakeBackend(mediaItems: assets)),
    );
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('media-card-60')), findsNothing);

    scroll.jumpTo(0);
    await tester.pump();

    final card = find.byKey(const ValueKey('media-card-60'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byType(Image)),
      findsOneWidget,
      reason: 'A cached cover must not return to a placeholder after disposal.',
    );
  });

  testWidgets('desktop title bar uses plain brand text without underline', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const DesktopTitleBar(
          title: '鱿型相册',
          iconAsset: 'assets/tray/app_icon.png',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(
      find.byKey(const Key('desktop-titlebar-title')),
    );
    expect(title.style?.fontFamily, appBrandFontFamily);
    expect(title.style?.fontFamilyFallback, appBrandFontFallback);
    expect(title.style?.fontSize, 14);
    expect(title.style?.fontWeight, FontWeight.w700);
    expect(title.style?.decoration, isNull);
    expect(
      find.byKey(const Key('desktop-titlebar-brand-underline')),
      findsNothing,
    );
  });

  testWidgets('desktop transfer page shows neutral account loading state', (
    tester,
  ) async {
    final gate = Completer<void>();
    final backend = _DelayedAccountsBackend(gate);
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导入与同步').last);
    await tester.pump();

    expect(find.byKey(const Key('nintendo-account-loading')), findsOneWidget);
    expect(find.text('尚未连接 Nintendo Account'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nintendo-account-loading')), findsNothing);
  });

  testWidgets('desktop galleries leave a 10dp gap after the kind filter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final asset = _asset(1);
    final backend = FakeBackend(
      mediaItems: [asset],
      albumItems: [
        AlbumSummary(
          id: 9,
          name: 'Trip',
          description: '',
          albumType: 'manual',
          pinned: false,
          mediaCount: BigInt.one,
          imageCount: BigInt.one,
          videoCount: BigInt.zero,
        ),
      ],
      albumMediaIds: const {
        9: {1},
      },
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-search')), findsOneWidget);
    expect(find.byKey(const Key('library-search-toggle')), findsNothing);
    expect(find.byKey(const Key('library-search-back')), findsNothing);
    expect(find.byKey(const Key('library-filter')), findsOneWidget);
    expect(
      find.byKey(const Key('desktop-search-filter-group')),
      findsOneWidget,
    );

    final header = tester.getRect(find.byKey(const Key('page-header')));
    expect(
      tester.getSize(find.byKey(const Key('page-header-extent'))).height,
      64,
    );
    expect(header.top, closeTo(2, 0.01));
    final search = tester.getRect(find.byKey(const Key('library-search')));
    final filter = tester.getRect(find.byKey(const Key('library-filter')));
    final searchGroupCenter = (search.left + filter.right) / 2;
    expect(searchGroupCenter, closeTo(header.center.dx, 1));

    final kindFilter = tester.getRect(
      find.byKey(const Key('desktop-gallery-kind-filter')),
    );
    expect(kindFilter.height, lessThanOrEqualTo(36));
    expect(kindFilter.center.dx, closeTo(header.center.dx, 1));
    final firstCard = tester.getRect(
      find.byKey(const ValueKey('media-card-1')),
    );
    expect(firstCard.top - kindFilter.bottom, closeTo(10, 0.01));

    await tester.tap(find.byKey(const Key('library-filter')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('desktop-library-filter-dialog')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('desktop-filter-cancel')), findsOneWidget);

    await tester.tap(find.byKey(const Key('desktop-filter-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-destination-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trip'));
    await tester.pumpAndSettle();

    final albumKindFilter = tester.getRect(
      find.byKey(const Key('desktop-gallery-kind-filter')),
    );
    final albumFirstCard = tester.getRect(
      find.byKey(const ValueKey('media-card-1')),
    );
    expect(albumFirstCard.top - albumKindFilter.bottom, closeTo(10, 0.01));
  });

  testWidgets(
    'desktop library uses the compact stacked header on narrow windows',
    (tester) async {
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(const Key('page-header-extent'))).height,
        112,
      );
      expect(find.byKey(const Key('library-search')), findsOneWidget);
      expect(
        find.byKey(const Key('desktop-gallery-kind-filter')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('favorites header grows instead of overflowing by a pixel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeBackend(
      mediaItems: [_asset(1)],
      albumItems: [
        AlbumSummary(
          id: 1,
          name: '收藏',
          description: '',
          albumType: 'smart',
          pinned: true,
          systemKey: 'favorites',
          mediaCount: BigInt.one,
          imageCount: BigInt.one,
          videoCount: BigInt.zero,
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

    expect(tester.takeException(), isNull);
    final extent = tester.getSize(find.byKey(const Key('page-header-extent')));
    expect(extent.height, greaterThanOrEqualTo(64));
    final subtitle = tester.getRect(find.text('所有已收藏的图片与视频'));
    final header = tester.getRect(find.byKey(const Key('page-header')));
    expect(subtitle.bottom, lessThanOrEqualTo(header.bottom + 0.01));
  });

  testWidgets('desktop filter bubble highlights while filters are active', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();

    final filter = find.byKey(const Key('library-filter'));
    Color? background() => tester
        .widget<IconButton>(filter)
        .style
        ?.backgroundColor
        ?.resolve(<WidgetState>{});
    final initial = background();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('desktop-gallery-kind-filter')),
        matching: find.text('视频'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      background(),
      initial,
      reason: 'The media-kind segment is a view, not a filter item.',
    );
    await tester.tap(find.byKey(const Key('library-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('desktop-filter-favorites')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('desktop-filter-apply')));
    await tester.pumpAndSettle();
    expect(
      background(),
      Theme.of(tester.element(filter)).colorScheme.primaryContainer,
    );
  });

  testWidgets('desktop cards never show note previews', (tester) async {
    final asset = _asset(
      1,
      importedAt: DateTime.now(),
      note: 'Hidden desktop note',
    );
    final backend = FakeBackend(
      mediaItems: [asset],
      albumItems: [
        AlbumSummary(
          id: 9,
          name: 'Trip',
          description: '',
          albumType: 'manual',
          pinned: false,
          mediaCount: BigInt.one,
          imageCount: BigInt.one,
          videoCount: BigInt.zero,
        ),
      ],
      albumMediaIds: {
        9: {1},
      },
    );
    backend.settings = copyAppSettings(backend.settings, showNotePreview: true);
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    expect(find.text('Hidden desktop note'), findsNothing);

    await tester.tap(find.text('相册').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trip'));
    await tester.pumpAndSettle();

    expect(find.text('Hidden desktop note'), findsNothing);
  });

  testWidgets('desktop select all includes every matching page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeBackend(
      mediaItems: [for (var id = 1; id <= 130; id++) _asset(id)],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('start-media-selection')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batch-select-all')));
    await tester.pumpAndSettle();

    expect(find.text('已选择 130 项'), findsOneWidget);
  });

  testWidgets(
    'desktop date grouping applies and clears from the filter draft',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final today = DateUtils.dateOnly(DateTime.now());
      final yesterday = today.subtract(const Duration(days: 1));
      final backend = FakeBackend(
        mediaItems: [
          _asset(1, importedAt: today.add(const Duration(hours: 9))),
          _asset(2, importedAt: yesterday.add(const Duration(hours: 9))),
          _asset(3),
        ],
      );
      await tester.pumpWidget(SquidAlbumApp(backend: backend));
      await tester.pumpAndSettle();

      expect(find.text('今天'), findsNothing);
      await tester.tap(find.byKey(const Key('library-filter')));
      await tester.pumpAndSettle();
      final grouping = find.byKey(const Key('desktop-filter-group-by-date'));
      await tester.ensureVisible(grouping);
      await tester.tap(grouping);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop-filter-apply')));
      await tester.pumpAndSettle();

      expect(find.text('今天'), findsOneWidget);
      expect(find.text('昨天'), findsOneWidget);
      expect(find.text('日期未知'), findsOneWidget);

      await tester.tap(find.byKey(const Key('library-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop-filter-clear')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop-filter-apply')));
      await tester.pumpAndSettle();
      expect(find.text('今天'), findsNothing);
    },
  );

  testWidgets(
    'desktop date grouping bounds far-return layouts across pagination',
    (tester) async {
      final importedAt = DateUtils.dateOnly(DateTime.now())
          .add(const Duration(hours: 9));
      final backend = FakeBackend(
        mediaItems: [
          for (var id = 1; id <= 180; id++) _asset(id, importedAt: importedAt),
        ],
      );
      await tester.pumpWidget(SquidAlbumApp(backend: backend));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('library-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop-filter-group-by-date')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop-filter-apply')));
      await tester.pumpAndSettle();

      final scrollView = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      final controller = scrollView.controller!;
      for (var page = 0; page < 4; page++) {
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      final position = controller.position;
      final queries = backend.listMediaCalls;
      GalleryPerf.instance.start(scenario: GalleryScenario.returnTop);
      final returning = scrollGalleryToTop(controller);
      await tester.pumpAndSettle();
      await returning;
      final snapshot = GalleryPerf.instance.stop();
      expect(controller.position, same(position));
      expect(backend.listMediaCalls, queries);
      expect(controller.offset, 0);
      if (GalleryPerf.compiled) {
        expect((snapshot['gallery'] as Map)['loaded'], 180);
        expect(
          ((snapshot['counters'] as Map)['cardMount'] as int?) ?? 0,
          lessThan(60),
          reason: 'Returning must not mount the intervening date-group rows.',
        );
      }
      expect(find.text('今天'), findsOneWidget);
    },
  );

  testWidgets('desktop albums page provides a scroll-to-top control', (
    tester,
  ) async {
    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('相册').last);
    await tester.pumpAndSettle();

    expect(find.byTooltip('回到顶部'), findsOneWidget);
  });
}

MediaAsset _asset(int id, {DateTime? importedAt, String? note}) => MediaAsset(
  id: id,
  sha256: 'desktop-$id',
  originalName: 'desktop-$id.png',
  storagePath: 'missing-$id.png',
  kind: MediaKind.image,
  capturedAt: importedAt,
  importedAt: importedAt,
  gameName: 'Splatoon 3',
  favorite: false,
  note: note,
  tags: const [],
);
