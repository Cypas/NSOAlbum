import 'dart:async';

import 'package:flutter/foundation.dart';

import '../backend/app_backend.dart';
import '../rust/models.dart';
import '../search/search_normalizer.dart';
import 'gallery_page_controller.dart';

class LibraryController extends ChangeNotifier {
  LibraryController(this.backend, {this.albumId})
    : pages = GalleryPageController(backend) {
    pages.addListener(_pageChanged);
  }
  final AppBackend backend;
  final GalleryPageController pages;
  final int? albumId;
  GalleryKindFilter kind = GalleryKindFilter.all;
  bool favoriteOnly = false;
  bool newestFirst = true;
  List<String> gameNames = [];
  DateTime? importedFrom;
  DateTime? importedUntil;
  DateTime? capturedFrom;
  DateTime? capturedUntil;
  CapturedOnThisDay? capturedOnThisDay;
  String search = '';
  List<MediaAsset> items = [];
  Object? get error => pages.error;
  bool get loading => pages.loading;
  bool get loadingMore => pages.loadingNext;
  bool get hasAfter => pages.hasAfter;
  bool get hasBefore => pages.hasBefore;
  bool disposed = false;
  int revision = 0;
  List<MediaAsset>? _visibleSource;
  String? _visibleSearch;
  List<MediaAsset> _visibleCache = [];

  bool get hasFilters =>
      kind != GalleryKindFilter.all ||
      favoriteOnly ||
      gameNames.isNotEmpty ||
      importedFrom != null ||
      importedUntil != null ||
      capturedFrom != null ||
      capturedUntil != null ||
      capturedOnThisDay != null;

  List<MediaAsset> get visible {
    if (identical(_visibleSource, items) && _visibleSearch == search) {
      return _visibleCache;
    }
    _visibleSource = items;
    _visibleSearch = search;
    return _visibleCache = items
        .where(
          (item) => normalizedTextContains(
            [
              item.originalName,
              item.gameName,
              item.note ?? '',
              ...item.tags,
            ].join(' '),
            search,
          ),
        )
        .toList(growable: false);
  }

  Future<void> reload() async {
    if (disposed) return;
    revision++;
    final term = search;
    await pages.reload(
      galleryQuery,
      filter: term.trim().isEmpty
          ? null
          : (item) => normalizedTextContains(
              [
                item.originalName,
                item.gameName,
                item.note ?? '',
                ...item.tags,
              ].join(' '),
              term,
            ),
    );
  }

  void _pageChanged() {
    if (disposed) return;
    items = pages.items;
    notifyListeners();
  }

  GalleryQuery get galleryQuery => GalleryQuery(
    kind: kind,
    limit: 60,
    offset: 0,
    favoriteOnly: favoriteOnly,
    albumId: albumId,
    newestFirst: newestFirst,
    gameNames: List.unmodifiable(gameNames),
    importedFrom: importedFrom,
    importedUntil: importedUntil,
    capturedFrom: capturedFrom,
    capturedUntil: capturedUntil,
    capturedOnThisDay: capturedOnThisDay,
  );

  Future<void> loadNextPage() => pages.loadNext();

  static Future<List<MediaAsset>> query(
    AppBackend backend, {
    GalleryKindFilter kind = GalleryKindFilter.all,
    bool favoriteOnly = false,
    int? albumId,
    bool newestFirst = true,
    List<String> gameNames = const [],
    DateTime? importedFrom,
    DateTime? importedUntil,
    DateTime? capturedFrom,
    DateTime? capturedUntil,
    CapturedOnThisDay? capturedOnThisDay,
    int limit = 500,
  }) => backend
      .listMedia(
        kind: kind,
        favoriteOnly: favoriteOnly,
        albumId: albumId,
        newestFirst: newestFirst,
        gameNames: gameNames,
        importedFrom: importedFrom,
        importedUntil: importedUntil,
        capturedFrom: capturedFrom,
        capturedUntil: capturedUntil,
        capturedOnThisDay: capturedOnThisDay,
        limit: limit,
      )
      .timeout(const Duration(seconds: 25));

  void searchFor(String value) {
    if (search == value) return;
    search = value;
    if (!disposed) unawaited(reload());
  }

  Future<void> favorite(MediaAsset item) async {
    await backend.setFavorite(item.id, !item.favorite);
    if (!disposed) await reload();
  }

  @override
  void dispose() {
    disposed = true;
    revision++;
    pages.removeListener(_pageChanged);
    pages.dispose();
    super.dispose();
  }
}
