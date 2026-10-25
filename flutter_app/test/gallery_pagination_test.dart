import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/media_viewer.dart';

import 'home_shell_test.dart' show FakeBackend;
import 'layout_viewport.dart';

MediaAsset media(int id) => MediaAsset(
  id: id,
  sha256: 'synthetic-$id',
  originalName: 'capture-$id.png',
  storagePath: 'missing-synthetic-$id.png',
  kind: MediaKind.image,
  importedAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: id)),
  gameName: 'Game',
  favorite: false,
  tags: const [],
);

class PagedBackend extends FakeBackend {
  PagedBackend()
    : super(mediaItems: List.generate(180, (index) => media(index + 1)));
  final requests = <GalleryPageRequest>[];
  Completer<void>? nextGate;
  @override
  Future<GalleryPage> listMediaPage(GalleryPageRequest request) async {
    requests.add(request);
    if (request.cursor != null) await nextGate?.future;
    return super.listMediaPage(request);
  }
}

void main() {
  testWidgets(
    'desktop reads one page and only builds visible cards; append keeps scroll offset',
    (tester) async {
      await useLayoutTestViewport(tester, const Size(1000, 800));
      final backend = PagedBackend();
      await tester.pumpWidget(SquidAlbumApp(backend: backend));
      await tester.pumpAndSettle();
      expect(backend.requests.length, 1);
      expect(backend.requests.single.query.limit, 60);
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid).first);
      expect(grid.delegate.estimatedChildCount, 60);
      expect(find.byKey(const ValueKey('media-card-121')), findsNothing);
      expect(find.byKey(const ValueKey('media-card-180')), findsOneWidget);
      backend.nextGate = Completer<void>();
      final scroll = find.byType(CustomScrollView).first;
      await tester.drag(scroll, const Offset(0, -4000));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(backend.requests.length, 2);
      final controller = tester.widget<CustomScrollView>(scroll).controller!;
      final position = controller.offset;
      await tester.drag(scroll, const Offset(0, -100));
      await tester.pump(const Duration(seconds: 1));
      expect(backend.requests.length, 2);
      final beforeAppend = controller.offset;
      backend.nextGate!.complete();
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(beforeAppend, .01));
      expect(controller.offset, greaterThanOrEqualTo(position));
      expect(
        tester
            .widget<SliverGrid>(find.byType(SliverGrid).first)
            .delegate
            .estimatedChildCount,
        120,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop viewer crosses page boundaries without changing the current media on prefetch',
    (tester) async {
      final backend = PagedBackend();
      final request = GalleryPageRequest(
        query: GalleryQuery(
          kind: GalleryKindFilter.all,
          limit: 2,
          offset: 0,
          favoriteOnly: false,
          newestFirst: true,
          gameNames: const [],
        ),
        direction: GalleryPageDirection.forward,
      );
      final initial = await backend.listMediaPage(request);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaViewer(
            backend: backend,
            items: initial.items,
            initialIndex: 1,
            autoPlayVideo: false,
            compactTagDisplay: true,
            galleryQuery: request.query,
            initialPage: initial,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('capture-179.png'), findsOneWidget);
      expect(find.byKey(const Key('media-viewer-counter')), findsNothing);
      for (final id in [178, 177, 176, 175]) {
        await tester.tap(find.byKey(const Key('media-viewer-next')));
        await tester.pumpAndSettle();
        expect(find.text('capture-$id.png'), findsOneWidget);
      }
      for (final id in [176, 177, 178, 179, 180]) {
        await tester.tap(find.byKey(const Key('media-viewer-previous')));
        await tester.pumpAndSettle();
        expect(find.text('capture-$id.png'), findsOneWidget);
      }
      expect(find.byKey(const Key('media-viewer-previous')), findsNothing);
      expect(backend.requests.length, greaterThanOrEqualTo(4));
      expect(
        backend.requests.every((request) => request.query.limit == 2),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing a viewer drops its delayed adjacent page', (
    tester,
  ) async {
    final backend = PagedBackend();
    final scope = GalleryQuery(
      kind: GalleryKindFilter.all,
      limit: 2,
      offset: 0,
      favoriteOnly: false,
      newestFirst: true,
      gameNames: const [],
    );
    final first = await backend.listMediaPage(
      GalleryPageRequest(query: scope, direction: GalleryPageDirection.forward),
    );
    backend.nextGate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaViewer(
          backend: backend,
          items: first.items,
          initialIndex: 1,
          autoPlayVideo: false,
          compactTagDisplay: true,
          galleryQuery: scope,
          initialPage: first,
        ),
      ),
    );
    await tester.pump();
    expect(backend.requests.length, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    backend.nextGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
