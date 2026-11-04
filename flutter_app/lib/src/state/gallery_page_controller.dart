import 'dart:async';

import 'package:flutter/foundation.dart';

import '../backend/app_backend.dart';
import '../rust/models.dart';
import '../ui/gallery_perf.dart';

/// Owns one query snapshot. Late pages can never enter a newer query/window.
class GalleryPageController extends ChangeNotifier {
  GalleryPageController(this.backend);

  final AppBackend backend;
  GalleryQuery? query;
  bool Function(MediaAsset)? accept;
  List<MediaAsset> items = const [];
  GalleryCursor? beforeCursor, afterCursor;
  bool hasBefore = false, hasAfter = false;
  bool loading = false, loadingNext = false, loadingPrevious = false;
  int? totalMatching;
  bool countingTotal = false;
  Object? error;
  int _generation = 0;
  bool _disposed = false;
  Future<void>? _next, _previous;

  void seed(
    GalleryQuery scope,
    GalleryPage page, {
    bool Function(MediaAsset)? filter,
  }) {
    _generation++;
    query = _snapshot(scope);
    accept = filter;
    items = List.of(page.items);
    beforeCursor = page.beforeCursor;
    afterCursor = page.afterCursor;
    hasBefore = page.hasBefore;
    hasAfter = page.hasAfter;
    totalMatching = null;
    countingTotal = false;
    loading = loadingNext = loadingPrevious = false;
    _next = _previous = null;
    error = null;
  }

  Future<void> reload(
    GalleryQuery scope, {
    bool Function(MediaAsset)? filter,
  }) async {
    final generation = ++_generation;
    final frozen = _snapshot(scope);
    query = frozen;
    accept = filter;
    items = const [];
    beforeCursor = afterCursor = null;
    hasBefore = hasAfter = false;
    totalMatching = null;
    countingTotal = false;
    loadingNext = loadingPrevious = false;
    _next = _previous = null;
    loading = true;
    error = null;
    _notify();
    try {
      final page = await _fetch(
        GalleryPageRequest(
          query: frozen,
          direction: GalleryPageDirection.forward,
        ),
        filter,
        generation,
      );
      if (_disposed || generation != _generation) return;
      items = _unique(page.items);
      beforeCursor = page.beforeCursor;
      afterCursor = page.afterCursor;
      hasBefore = page.hasBefore;
      hasAfter = page.hasAfter;
    } catch (failure) {
      if (!_disposed && generation == _generation) error = failure;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        _notify();
        unawaited(_countMatching(frozen, generation));
      }
    }
  }

  Future<void> _countMatching(GalleryQuery scope, int generation) async {
    if (_disposed ||
        generation != _generation ||
        countingTotal ||
        accept != null ||
        backend is! MediaCountBackend) {
      return;
    }
    countingTotal = true;
    _notify();
    try {
      final count = await (backend as MediaCountBackend).countMedia(scope);
      if (!_disposed && generation == _generation) {
        totalMatching = count.toInt();
      }
    } catch (_) {
      // The indicator remains on the loaded-page count if counting is
      // unavailable in a compatibility backend.
    } finally {
      if (!_disposed && generation == _generation) {
        countingTotal = false;
        _notify();
      }
    }
  }

  Future<void> loadNext() {
    if (_next != null) return _next!;
    if (_disposed || loading || !hasAfter || afterCursor == null) {
      return Future.value();
    }
    return _next = _load(GalleryPageDirection.forward);
  }

  Future<void> loadPrevious() {
    if (_previous != null) return _previous!;
    if (_disposed || loading || !hasBefore || beforeCursor == null) {
      return Future.value();
    }
    return _previous = _load(GalleryPageDirection.backward);
  }

  /// Loads every media item matching the current query and optional search
  /// filter. This does not replace or extend the visible paging window.
  Future<List<MediaAsset>> loadAllMatching({
    bool Function(MediaAsset)? filter,
  }) async {
    final scope = query;
    if (_disposed) return const [];
    if (scope == null) return _unique(List.of(items));
    final generation = _generation;
    final effectiveFilter = filter ?? accept;
    final leading = <MediaAsset>[];
    final trailing = <MediaAsset>[];

    Future<void> walk({
      required GalleryPageDirection direction,
      required GalleryCursor? initialCursor,
      required bool initialHasMore,
      required List<MediaAsset> target,
    }) async {
      var cursor = initialCursor;
      var hasMore = initialHasMore;
      while (hasMore) {
        if (cursor == null) {
          throw StateError('The media page set cannot advance');
        }
        final page = await backend
            .listMediaPage(
              GalleryPageRequest(
                query: scope,
                cursor: cursor,
                direction: direction,
              ),
            )
            .timeout(const Duration(seconds: 25));
        if (_disposed || generation != _generation) return;
        final nextCursor = direction == GalleryPageDirection.forward
            ? page.afterCursor
            : page.beforeCursor;
        if (page.hasAfter &&
            direction == GalleryPageDirection.forward &&
            (page.items.isEmpty || nextCursor == cursor)) {
          throw StateError('The media page did not advance');
        }
        if (page.hasBefore &&
            direction == GalleryPageDirection.backward &&
            (page.items.isEmpty || nextCursor == cursor)) {
          throw StateError('The media page did not advance');
        }
        target.addAll(
          effectiveFilter == null
              ? page.items
              : page.items.where(effectiveFilter),
        );
        cursor = nextCursor;
        hasMore = direction == GalleryPageDirection.forward
            ? page.hasAfter
            : page.hasBefore;
      }
    }

    await walk(
      direction: GalleryPageDirection.forward,
      initialCursor: afterCursor,
      initialHasMore: hasAfter,
      target: trailing,
    );
    if (_disposed || generation != _generation) return const [];
    await walk(
      direction: GalleryPageDirection.backward,
      initialCursor: beforeCursor,
      initialHasMore: hasBefore,
      target: leading,
    );
    if (_disposed || generation != _generation) return const [];
    return _unique([
      ...leading,
      ...items.where(
        (item) => effectiveFilter == null || effectiveFilter(item),
      ),
      ...trailing,
    ]);
  }

  Future<void> _load(GalleryPageDirection direction) async {
    final generation = _generation;
    final forward = direction == GalleryPageDirection.forward;
    final cursor = forward ? afterCursor : beforeCursor;
    if (forward) {
      loadingNext = true;
    } else {
      loadingPrevious = true;
    }
    error = null;
    _notify();
    try {
      final page = await _fetch(
        GalleryPageRequest(query: query!, cursor: cursor, direction: direction),
        accept,
        generation,
      );
      if (_disposed || generation != _generation) return;
      final nextCursor = forward ? page.afterCursor : page.beforeCursor;
      final hasMore = forward ? page.hasAfter : page.hasBefore;
      if (hasMore && (page.items.isEmpty || nextCursor == cursor)) {
        throw StateError('The media page did not advance');
      }
      items = _unique(
        forward ? [...items, ...page.items] : [...page.items, ...items],
      );
      if (forward) {
        afterCursor = nextCursor ?? afterCursor;
        hasAfter = page.hasAfter;
      } else {
        beforeCursor = nextCursor ?? beforeCursor;
        hasBefore = page.hasBefore;
      }
    } catch (failure) {
      if (!_disposed && generation == _generation) error = failure;
    } finally {
      if (!_disposed && generation == _generation) {
        if (forward) {
          loadingNext = false;
          _next = null;
        } else {
          loadingPrevious = false;
          _previous = null;
        }
        _notify();
      }
    }
  }

  // Chinese/traditional/phonetic search keeps the existing Dart matcher.
  // Scan SQL pages without retaining rejected assets. A rare/no-match query
  // therefore never materializes the complete library in memory.
  Future<GalleryPage> _fetch(
    GalleryPageRequest request,
    bool Function(MediaAsset)? filter,
    int generation,
  ) async {
    var current = request;
    while (true) {
      final page = await GalleryPerf.instance.async(
        GalleryMetric.pageWait,
        () =>
            backend.listMediaPage(current).timeout(const Duration(seconds: 25)),
      );
      if (filter == null || _disposed || generation != _generation) return page;
      final matches = GalleryPerf.instance.sync(
        GalleryMetric.filter,
        () => page.items.where(filter).toList(),
      );
      final forward = current.direction == GalleryPageDirection.forward;
      final more = forward ? page.hasAfter : page.hasBefore;
      final cursor = forward ? page.afterCursor : page.beforeCursor;
      if (matches.isNotEmpty || !more) {
        return GalleryPage(
          items: matches,
          beforeCursor: page.beforeCursor,
          afterCursor: page.afterCursor,
          hasBefore: request.cursor == null && forward ? false : page.hasBefore,
          hasAfter: page.hasAfter,
        );
      }
      if (page.items.isEmpty || cursor == null || cursor == current.cursor) {
        throw StateError('The media search page did not advance');
      }
      current = GalleryPageRequest(
        query: current.query,
        cursor: cursor,
        direction: current.direction,
      );
    }
  }

  /// The viewer keeps the current item plus at most one page on either side.
  /// Evicted items remain reachable through fresh cursors at the new edges.
  void retainAround(int mediaId, {int radius = 60}) {
    final index = items.indexWhere((item) => item.id == mediaId);
    if (index < 0) return;
    final start = (index - radius).clamp(0, items.length);
    final end = (index + radius + 1).clamp(0, items.length);
    if (start == 0 && end == items.length) return;
    final fingerprint =
        beforeCursor?.filterFingerprint ?? afterCursor?.filterFingerprint;
    if (fingerprint == null) return;
    hasBefore = hasBefore || start > 0;
    hasAfter = hasAfter || end < items.length;
    items = items.sublist(start, end);
    GalleryCursor cursor(MediaAsset item) => GalleryCursor(
      filterFingerprint: fingerprint,
      effectiveSortTime: (item.capturedAt ?? item.importedAt)
          ?.microsecondsSinceEpoch
          .toString(),
      mediaId: item.id,
    );
    beforeCursor = cursor(items.first);
    afterCursor = cursor(items.last);
  }

  GalleryPage get snapshot => GalleryPage(
    items: List.of(items),
    beforeCursor: beforeCursor,
    afterCursor: afterCursor,
    hasBefore: hasBefore,
    hasAfter: hasAfter,
  );

  List<MediaAsset> _unique(List<MediaAsset> values) {
    final ids = <int>{};
    return values.where((item) => ids.add(item.id)).toList();
  }

  GalleryQuery _snapshot(GalleryQuery scope) => GalleryQuery(
    kind: scope.kind,
    limit: scope.limit,
    offset: 0,
    favoriteOnly: scope.favoriteOnly,
    albumId: scope.albumId,
    newestFirst: scope.newestFirst,
    gameNames: List.unmodifiable(scope.gameNames),
    importedFrom: scope.importedFrom,
    importedUntil: scope.importedUntil,
    capturedFrom: scope.capturedFrom,
    capturedUntil: scope.capturedUntil,
    capturedOnThisDay: scope.capturedOnThisDay,
  );

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
