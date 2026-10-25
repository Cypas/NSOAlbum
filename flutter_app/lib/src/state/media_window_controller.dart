import '../rust/models.dart';
import 'gallery_page_controller.dart';

/// A viewer owns its pages independently of the gallery route's lifetime.
class MediaWindowController extends GalleryPageController {
  MediaWindowController(
    super.backend, {
    required GalleryQuery scope,
    required GalleryPage initial,
    required int mediaId,
    bool Function(MediaAsset)? filter,
  }) {
    seed(scope, initial, filter: filter);
    retainAround(mediaId);
  }

  Future<void> prefetchAround(int mediaId) async {
    final index = items.indexWhere((item) => item.id == mediaId);
    if (index < 0) return;
    await Future.wait([
      if (index <= 1 && hasBefore) loadPrevious(),
      if (index >= items.length - 2 && hasAfter) loadNext(),
    ]);
  }
}
