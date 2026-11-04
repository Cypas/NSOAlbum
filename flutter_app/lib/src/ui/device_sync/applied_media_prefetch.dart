import '../../backend/device_sync/service_contract.dart';
import '../../rust/device_sync/read_model.dart';
import '../image_thumbnail.dart';

typedef AppliedMediaPageLoader =
    Future<AppliedMediaCachePage> Function(BigInt offset);
typedef AppliedMediaPagePrefetch =
    Future<void> Function(List<AppliedMediaCacheEntry> entries);

/// Streams completed receive pages into the thumbnail caches without keeping
/// the entire applied library in memory.
Future<void> prefetchAppliedMediaPages({
  required AppliedMediaPageLoader loadPage,
  required AppliedMediaPagePrefetch prefetchPage,
}) async {
  var offset = BigInt.zero;
  while (true) {
    final page = await loadPage(offset);
    if (page.items.length > 60) {
      throw FormatException(
        'Applied media page exceeded its bounded size',
        page.items.length,
      );
    }
    if (page.items.isNotEmpty) {
      await prefetchPage(page.items);
    }

    final nextOffset = page.nextOffset;
    if (nextOffset == null) return;
    if (nextOffset <= offset) {
      throw FormatException(
        'Applied media page cursor did not advance',
        nextOffset,
      );
    }
    offset = nextOffset;
  }
}

Future<void> warmAppliedMediaCache(DeviceSyncSessionController session) =>
    prefetchAppliedMediaPages(
      loadPage: (offset) => session.appliedMediaPage(offset: offset),
      prefetchPage: ImageThumbnailCache.prefetchAppliedMediaEntries,
    );
