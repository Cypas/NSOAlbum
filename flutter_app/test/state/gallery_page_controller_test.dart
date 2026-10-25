import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/gallery_page_controller.dart';
import 'package:squid_album/src/state/media_window_controller.dart';

import '../home_shell_test.dart' show FakeBackend;

GalleryQuery query({bool favorites = false}) => GalleryQuery(
  kind: GalleryKindFilter.all,
  limit: 2,
  offset: 0,
  favoriteOnly: favorites,
  newestFirst: true,
  gameNames: const [],
);

MediaAsset asset(int id) => MediaAsset(
  id: id,
  sha256: '$id',
  originalName: '$id.jpg',
  storagePath: 'synthetic/$id.jpg',
  kind: MediaKind.image,
  importedAt: DateTime.utc(2026, 1, id),
  gameName: 'Game',
  favorite: false,
  tags: const [],
);

GalleryPage page(List<int> ids, {bool before = false, bool after = false}) =>
    GalleryPage(
      items: ids.map(asset).toList(),
      hasBefore: before,
      hasAfter: after,
      beforeCursor: ids.isEmpty
          ? null
          : GalleryCursor(filterFingerprint: 'query', mediaId: ids.first),
      afterCursor: ids.isEmpty
          ? null
          : GalleryCursor(filterFingerprint: 'query', mediaId: ids.last),
    );

class DeferredPages extends FakeBackend {
  final pending = <Completer<GalleryPage>>[];
  final requests = <GalleryPageRequest>[];
  @override
  Future<GalleryPage> listMediaPage(GalleryPageRequest request) {
    requests.add(request);
    final response = Completer<GalleryPage>();
    pending.add(response);
    return response.future;
  }
}

void main() {
  test(
    'evicted media remain reachable in both directions through 300 items',
    () async {
      final backend = FakeBackend(
        mediaItems: List.generate(300, (index) => asset(index + 1)),
      );
      final scope = query();
      final first = await backend.listMediaPage(
        GalleryPageRequest(
          query: scope,
          direction: GalleryPageDirection.forward,
        ),
      );
      final controller = MediaWindowController(
        backend,
        scope: scope,
        initial: first,
        mediaId: 300,
      );
      addTearDown(controller.dispose);
      for (var id = 300; id >= 1; id--) {
        expect(controller.items.any((item) => item.id == id), isTrue);
        await controller.prefetchAround(id);
        controller.retainAround(id);
        expect(controller.items.length, lessThanOrEqualTo(121));
        final currentIndex = controller.items.indexWhere(
          (item) => item.id == id,
        );
        expect(currentIndex, lessThanOrEqualTo(60));
        expect(
          controller.items.length - currentIndex - 1,
          lessThanOrEqualTo(60),
        );
      }
      expect(controller.items.first.id, 61);
      expect(controller.items.last.id, 1);
      expect(controller.hasAfter, isFalse);
      for (var id = 1; id <= 300; id++) {
        expect(controller.items.any((item) => item.id == id), isTrue);
        await controller.prefetchAround(id);
        controller.retainAround(id);
        expect(controller.items.length, lessThanOrEqualTo(121));
        final currentIndex = controller.items.indexWhere(
          (item) => item.id == id,
        );
        expect(currentIndex, lessThanOrEqualTo(60));
        expect(
          controller.items.length - currentIndex - 1,
          lessThanOrEqualTo(60),
        );
      }
      expect(controller.items.first.id, 300);
      expect(controller.items.last.id, 240);
      expect(controller.hasBefore, isFalse);
      expect(controller.error, isNull);
    },
  );

  test(
    'query game filters stay frozen while a delayed page is in flight',
    () async {
      final backend = DeferredPages();
      final controller = GalleryPageController(backend);
      addTearDown(controller.dispose);
      final games = ['Original game'];
      final scope = GalleryQuery(
        kind: GalleryKindFilter.all,
        limit: 2,
        offset: 0,
        favoriteOnly: false,
        newestFirst: true,
        gameNames: games,
      );
      final pending = controller.reload(scope);
      games[0] = 'Different game';
      expect(backend.requests.single.query.gameNames, ['Original game']);
      backend.pending.single.complete(page([5, 4], after: true));
      await pending;
      final next = controller.loadNext();
      expect(backend.requests.last.query.gameNames, ['Original game']);
      backend.pending.last.complete(page([3, 2]));
      await next;
      expect(controller.items.map((item) => item.id), [5, 4, 3, 2]);
    },
  );

  test('opposite page directions complete independently without dropping either page', () async {
    final backend = DeferredPages();
    final controller = GalleryPageController(backend);
    addTearDown(controller.dispose);
    controller.seed(query(), page([5, 4], before: true, after: true));
    final next = controller.loadNext();
    final previous = controller.loadPrevious();
    expect(backend.requests.length, 2);
    backend.pending[1].complete(page([7, 6]));
    await previous;
    backend.pending[0].complete(page([3, 2]));
    await next;
    expect(controller.items.map((item) => item.id), [7, 6, 5, 4, 3, 2]);
    expect(controller.loadingNext, isFalse);
    expect(controller.loadingPrevious, isFalse);
  });
  test('search scans bounded pages without retaining rejected media', () async {
    final backend = DeferredPages();
    final controller = GalleryPageController(backend);
    addTearDown(controller.dispose);
    final pending = controller.reload(query(), filter: (item) => item.id == 1);
    backend.pending[0].complete(page([4, 3], after: true));
    await Future<void>.delayed(Duration.zero);
    expect(backend.requests.length, 2);
    expect(controller.items, isEmpty);
    backend.pending[1].complete(page([2, 1]));
    await pending;
    expect(controller.items.map((item) => item.id), [1]);
    expect(controller.hasAfter, isFalse);
    expect(controller.hasBefore, isFalse);
  });
  test(
    'repeated scroll coalesces; a failed page retries the unchanged cursor',
    () async {
      final backend = DeferredPages();
      final controller = GalleryPageController(backend);
      addTearDown(controller.dispose);
      final initial = controller.reload(query());
      backend.pending[0].complete(page([5, 4], after: true));
      await initial;
      final next = controller.loadNext();
      final repeated = controller.loadNext();
      expect(backend.requests.length, 2);
      backend.pending[1].completeError(StateError('offline'));
      await Future.wait([next, repeated]);
      expect(controller.items.map((item) => item.id), [5, 4]);
      expect(controller.hasAfter, isTrue);
      expect(controller.error, isNotNull);
      final retry = controller.loadNext();
      expect(backend.requests[2].cursor, backend.requests[1].cursor);
      backend.pending[2].complete(page([4, 3], after: false));
      await retry;
      expect(controller.items.map((item) => item.id), [5, 4, 3]);
      expect(controller.hasAfter, isFalse);
      expect(controller.error, isNull);
    },
  );

  test('old initial and next pages cannot overwrite a new query', () async {
    final backend = DeferredPages();
    final controller = GalleryPageController(backend);
    addTearDown(controller.dispose);
    final initial = controller.reload(query());
    final newer = controller.reload(query(favorites: true));
    backend.pending[1].complete(page([2, 1], after: true));
    await newer;
    backend.pending[0].complete(page([5, 4], after: true));
    await initial;
    expect(controller.items.map((item) => item.id), [2, 1]);
    final next = controller.loadNext();
    final reset = controller.reload(query());
    backend.pending[3].complete(page([5], after: false));
    await reset;
    backend.pending[2].complete(page([99]));
    await next;
    expect(controller.items.map((item) => item.id), [5]);
    expect(controller.loadingNext, isFalse);
  });

  test('window eviction retains current item and restores both directions', () {
    final controller = GalleryPageController(DeferredPages());
    addTearDown(controller.dispose);
    controller.seed(query(), page(List.generate(240, (index) => index + 1)));
    controller.retainAround(121);
    expect(controller.items.length, 121);
    expect(controller.items.first.id, 61);
    expect(controller.items.last.id, 181);
    expect(controller.hasBefore, isTrue);
    expect(controller.hasAfter, isTrue);
    expect(controller.beforeCursor?.mediaId, 61);
    expect(controller.afterCursor?.mediaId, 181);
  });

  test(
    'dispose ignores delayed results; a repeating page is a retryable error',
    () async {
      final backend = DeferredPages();
      final controller = GalleryPageController(backend);
      controller.seed(query(), page([5, 4], after: true));
      final load = controller.loadNext();
      backend.pending[0].complete(page([5, 4], after: true));
      await load;
      expect(controller.error, isNotNull);
      final delayed = controller.loadNext();
      controller.dispose();
      backend.pending[1].complete(page([3, 2]));
      await delayed;
      expect(controller.items.map((item) => item.id), [5, 4]);
    },
  );
}
