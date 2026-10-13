import 'package:flutter/foundation.dart';

import '../backend/app_backend.dart';
import '../rust/models.dart';
import '../search/search_normalizer.dart';

class LibraryController extends ChangeNotifier {
  LibraryController(this.backend, {this.albumId});
  final AppBackend backend;
  final int? albumId;
  GalleryKindFilter kind = GalleryKindFilter.all;
  bool favoriteOnly = false;
  bool newestFirst = true;
  List<String> gameNames = [];
  DateTime? capturedFrom;
  DateTime? capturedUntil;
  String search = '';
  List<MediaAsset> items = [];
  Object? error;
  bool loading = false;
  bool disposed = false;
  int revision = 0;

  List<MediaAsset> get visible => items
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

  Future<void> reload() async {
    if (disposed) return;
    final request = ++revision;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await query(
        backend,
        kind: kind,
        favoriteOnly: favoriteOnly,
        albumId: albumId,
        newestFirst: newestFirst,
        gameNames: gameNames,
        capturedFrom: capturedFrom,
        capturedUntil: capturedUntil,
      );
      if (disposed || request != revision) return;
      items = result;
    } catch (exception) {
      if (!disposed && request == revision) error = exception;
    } finally {
      if (!disposed && request == revision) {
        loading = false;
        notifyListeners();
      }
    }
  }

  static Future<List<MediaAsset>> query(
    AppBackend backend, {
    GalleryKindFilter kind = GalleryKindFilter.all,
    bool favoriteOnly = false,
    int? albumId,
    bool newestFirst = true,
    List<String> gameNames = const [],
    DateTime? capturedFrom,
    DateTime? capturedUntil,
    int limit = 500,
  }) => backend
      .listMedia(
        kind: kind,
        favoriteOnly: favoriteOnly,
        albumId: albumId,
        newestFirst: newestFirst,
        gameNames: gameNames,
        capturedFrom: capturedFrom,
        capturedUntil: capturedUntil,
        limit: limit,
      )
      .timeout(const Duration(seconds: 25));

  void searchFor(String value) {
    search = value;
    if (!disposed) notifyListeners();
  }

  Future<void> favorite(MediaAsset item) async {
    await backend.setFavorite(item.id, !item.favorite);
    if (!disposed) await reload();
  }

  @override
  void dispose() {
    disposed = true;
    revision++;
    super.dispose();
  }
}
