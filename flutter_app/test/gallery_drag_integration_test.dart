import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image/image.dart' as image;
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/ui/gallery_drag_loading.dart';
import 'package:squid_album/src/ui/gallery_perf.dart';
import 'package:squid_album/src/ui/home_shell.dart';
import 'package:squid_album/src/ui/image_thumbnail.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';
import 'package:squid_album/src/ui/desktop_fluid_scroll_physics.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  tearDown(() {
    GalleryLoadExperiment.instance.setMode(GalleryLoadMode.settled);
    GalleryPerf.instance.stop();
  });

  for (final page in ['library', 'album', 'favorites']) {
    final album = page == 'album';
    testWidgets('$page defaults to settled loading without an A/B button', (
      tester,
    ) async {
      final backend = FakeBackend(mediaItems: []);
      final settings = SettingsController(backend);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: LibraryPage(
            backend: backend,
            settings: settings,
            onOpenTransfer: () {},
            albumId: album ? 1 : null,
            albumName: album ? 'Synthetic album' : null,
            albumSystemKey: page == 'favorites' ? 'favorites' : null,
            enableVideoFeatures: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('gallery-loading-ab-toggle'));
      expect(button, findsNothing);
      expect(GalleryLoadExperiment.instance.mode, GalleryLoadMode.settled);
      expect(find.text('A 即时'), findsNothing);
      expect(find.text('B 停稳加载'), findsNothing);
      expect(find.byType(GalleryDragLoadRegion), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
    });
  }

  testWidgets(
    'desktop wheel leaves new metadata deferred until the page settles',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = FakeBackend(
        mediaItems: [
          for (var i = 0; i < 120; i++)
            MediaAsset(
              id: 8000 + i,
              sha256: 'synthetic-wheel-$i',
              originalName: 'sample-$i.jpg',
              storagePath: 'unavailable-$i.jpg',
              kind: MediaKind.image,
              gameName: 'Sample game',
              favorite: false,
              tags: const ['Sample tag'],
            ),
        ],
      );
      final settings = SettingsController(backend);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: LibraryPage(
            backend: backend,
            settings: settings,
            onOpenTransfer: () {},
            enableVideoFeatures: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll =
          tester
                  .widget<CustomScrollView>(find.byType(CustomScrollView))
                  .controller!
              as DesktopGalleryScrollController;
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(800, 450),
          scrollDelta: Offset(0, 1200),
        ),
      );
      expect(
        GalleryLoadExperiment.instance.admission.value,
        GalleryWorkAdmission.paused,
      );
      await tester.pump();
      for (
        var frame = 0;
        frame < 30 && scroll.position.isScrollingNotifier.value;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scroll.position.isScrollingNotifier.value, isFalse);
      await tester.pump(const Duration(milliseconds: 49));
      expect(
        GalleryLoadExperiment.instance.admission.value,
        GalleryWorkAdmission.paused,
      );
      final viewport = tester.getRect(find.byType(CustomScrollView));
      final placeholders = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'media-card-deferred-',
            ),
      );
      final visible = placeholders
          .evaluate()
          .where(
            (element) => tester
                .getRect(find.byWidget(element.widget))
                .overlaps(viewport),
          )
          .toList();
      expect(visible, isNotEmpty);
      final id = (visible.first.widget.key! as ValueKey<String>).value
          .replaceFirst('media-card-deferred-', '');
      final outer = find.byKey(ValueKey(('deferred-card', int.parse(id))));
      final rect = tester.getRect(outer);
      expect(
        find.descendant(of: outer, matching: find.byType(IconButton)),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(tester.getRect(outer), rect);
      expect(
        find.descendant(of: outer, matching: find.byType(IconButton)),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );

  testWidgets(
    'desktop thumb defers real metadata controls and restores them without moving the grid',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = FakeBackend(
        mediaItems: [
          for (var i = 0; i < 80; i++)
            MediaAsset(
              id: 9000 + i,
              sha256: i.toRadixString(16).padLeft(64, '0'),
              originalName: 'synthetic-$i.jpg',
              storagePath: 'unavailable-synthetic-$i.jpg',
              kind: MediaKind.image,
              gameName: 'Game $i',
              favorite: false,
              tags: ['Tag $i'],
            ),
        ],
      );
      final settings = SettingsController(backend);
      GalleryLoadExperiment.instance.setMode(GalleryLoadMode.settled);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            platform: TargetPlatform.windows,
            scrollbarTheme: const ScrollbarThemeData(
              thumbVisibility: WidgetStatePropertyAll(true),
            ),
          ),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: LibraryPage(
            backend: backend,
            settings: settings,
            onOpenTransfer: () {},
            enableVideoFeatures: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final painterFinder = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.foregroundPainter is ScrollbarPainter,
      );
      final paint = tester.widget<CustomPaint>(painterFinder.first);
      final painter = paint.foregroundPainter! as ScrollbarPainter;
      final rect = tester.getRect(painterFinder.first);
      Offset? hit;
      for (var y = 1.0; y < rect.height && hit == null; y += 2) {
        for (var x = rect.width - 1; x > rect.width - 28; x--) {
          if (painter.hitTestOnlyThumbInteractive(
            Offset(x, y),
            PointerDeviceKind.mouse,
          )) {
            hit = rect.topLeft + Offset(x, y);
            break;
          }
        }
      }
      expect(hit, isNotNull);
      final thumb = await tester.startGesture(
        hit!,
        kind: PointerDeviceKind.mouse,
      );
      await thumb.moveBy(const Offset(0, 110));
      await tester.pump();
      expect(
        GalleryLoadExperiment.instance.admission.value,
        GalleryWorkAdmission.paused,
      );
      final placeholders = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'media-card-deferred-',
            ),
      );
      expect(placeholders, findsWidgets);
      final viewport = tester.getRect(find.byType(CustomScrollView));
      final visiblePlaceholders = placeholders
          .evaluate()
          .where(
            (element) => tester
                .getRect(find.byWidget(element.widget))
                .overlaps(viewport),
          )
          .toList();
      expect(visiblePlaceholders, isNotEmpty);
      final key = visiblePlaceholders.first.widget.key!;
      final id = (key as ValueKey<String>).value.replaceFirst(
        'media-card-deferred-',
        '',
      );
      final outer = find.byKey(ValueKey(('deferred-card', int.parse(id))));
      final geometry = tester.getRect(outer);
      expect(
        find.descendant(of: outer, matching: find.byType(IconButton)),
        findsNothing,
      );
      await thumb.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(outer), geometry);
      expect(
        find.descendant(of: outer, matching: find.byType(IconButton)),
        findsWidgets,
      );
      expect(find.byKey(key), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
    },
    skip: !GalleryLoadExperiment.available,
  );

  testWidgets('new image cards do not read disk before settling or release', (
    tester,
  ) async {
    final experiment = GalleryLoadExperiment(enabled: true)
      ..setMode(GalleryLoadMode.settled);
    final drag = GalleryDragLoadController(experiment)
      ..begin()
      ..moved();
    late Directory root;
    final asset = MediaAsset(
      id: 7001,
      sha256: 'd' * 64,
      originalName: 'synthetic.jpg',
      storagePath: 'missing-synthetic.jpg',
      kind: MediaKind.image,
      gameName: '',
      favorite: false,
      tags: const [],
    );
    late ImageThumbnailStore store;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('gallery-drag-image-');
      await File('${root.path}/${asset.sha256}_v4_1024.jpg').writeAsBytes(
        Uint8List.fromList(image.encodeJpg(image.Image(width: 16, height: 9))),
      );
      store = await ImageThumbnailCache.store(cacheRoot: root.path);
    });
    addTearDown(() => root.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: GalleryPreviewLoadScope(
          controller: drag,
          child: ImageThumbnail(asset: asset, cacheRoot: root.path),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 49));
    expect(store.diskCacheReadCount, 0);
    drag.end();
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 100 && !tester.any(find.byType(Image));
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(store.diskCacheReadCount, 1);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    drag.dispose();
  });

  test(
    'image and video background prefetch do not bypass a thumb hold',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gallery-drag-prefetch-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/synthetic.png');
      await source.writeAsBytes(
        image.encodePng(image.Image(width: 16, height: 9)),
      );
      final imageAsset = MediaAsset(
        id: 7101,
        sha256: 'e' * 64,
        originalName: 'synthetic.png',
        storagePath: source.path,
        kind: MediaKind.image,
        gameName: '',
        favorite: false,
        tags: const [],
      );
      final videoAsset = MediaAsset(
        id: 7102,
        sha256: 'f' * 64,
        originalName: 'synthetic.mp4',
        storagePath: 'unavailable-synthetic.mp4',
        kind: MediaKind.video,
        gameName: '',
        favorite: false,
        tags: const [],
      );
      VideoThumbnailCache.configureCacheRoot(root.path);
      final videoRoot = Directory('${root.path}/cache/video_thumbnails');
      await videoRoot.create(recursive: true);
      await File('${videoRoot.path}/${videoAsset.sha256}_v6_1024.jpg')
          .writeAsBytes(image.encodeJpg(image.Image(width: 16, height: 9)));
      await File('${videoRoot.path}/${videoAsset.sha256}.duration')
          .writeAsString('1000');
      final experiment = GalleryLoadExperiment.instance
        ..setMode(GalleryLoadMode.settled);
      final drag = GalleryDragLoadController(experiment)
        ..begin()
        ..moved();
      addTearDown(drag.dispose);
      final store = ImageThumbnailStore('${root.path}/images');
      final imageDrain = store.prefetch([imageAsset]);
      final videoDrain = VideoThumbnailCache.prefetch([
        videoAsset,
      ], onError: (_, _) async {});
      expect(store.cacheDirectoryScanCount, 0);
      expect(store.pendingPrefetchCount, 1);
      expect(VideoThumbnailCache.pendingPrefetchCount, 1);
      drag.end();
      await Future.wait([imageDrain, videoDrain]);
      expect(
        await File('${root.path}/images/${imageAsset.sha256}_v4_1024.jpg')
            .exists(),
        isTrue,
      );
      expect(VideoThumbnailCache.peekCover(videoAsset)?.bytes, isNotNull);
      expect(store.pendingPrefetchCount, 0);
      expect(VideoThumbnailCache.pendingPrefetchCount, 0);
    },
    skip: !GalleryLoadExperiment.available,
  );

  testWidgets(
    'promoting the last first-time prefetch item completes its original drain',
    (tester) async {
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('gallery-drag-drain-'),
      );
      final store = ImageThumbnailStore(
        root!.path,
        generateThumbnail: (_) async => Uint8List.fromList(
          image.encodeJpg(image.Image(width: 16, height: 9)),
        ),
      );
      addTearDown(() => root.delete(recursive: true));
      final experiment = GalleryLoadExperiment.instance
        ..setMode(GalleryLoadMode.settled);
      final drag = GalleryDragLoadController(experiment)
        ..begin()
        ..moved();
      addTearDown(drag.dispose);
      final asset = MediaAsset(
        id: 7110,
        sha256: 'a' * 64,
        originalName: 'synthetic.png',
        storagePath: 'unavailable.png',
        kind: MediaKind.image,
        gameName: '',
        favorite: false,
        tags: const [],
      );
      var drained = false;
      store.prefetch([asset]).then((_) => drained = true);
      expect(store.cacheDirectoryScanCount, 0);
      await tester.pump(const Duration(milliseconds: 100));
      var foregroundDone = false;
      final request = store.request(asset)!;
      request.future.then((bytes) => foregroundDone = bytes != null);
      drag.end();
      for (var attempt = 0; attempt < 100 && !foregroundDone; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(foregroundDone, isTrue);
      expect(drained, isTrue);
      expect(store.pendingPrefetchCount, 0);
      request.cancel();
    },
    skip: !GalleryLoadExperiment.available,
  );
}
