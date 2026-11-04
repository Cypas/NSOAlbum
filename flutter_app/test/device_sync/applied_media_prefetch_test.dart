import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/models.dart' as models;
import 'package:squid_album/src/rust/device_sync/read_model.dart';
import 'package:squid_album/src/ui/device_sync/applied_media_prefetch.dart';

void main() {
  test('prefetches applied media in bounded forward pages', () async {
    final requestedOffsets = <BigInt>[];
    final prefetchedPageSizes = <int>[];

    await prefetchAppliedMediaPages(
      loadPage: (offset) async {
        requestedOffsets.add(offset);
        if (offset == BigInt.zero) {
          return AppliedMediaCachePage(
            items: List.generate(60, _entry),
            nextOffset: BigInt.from(60),
          );
        }
        return AppliedMediaCachePage(items: List.generate(2, _entry));
      },
      prefetchPage: (entries) async {
        prefetchedPageSizes.add(entries.length);
      },
    );

    expect(requestedOffsets, [BigInt.zero, BigInt.from(60)]);
    expect(prefetchedPageSizes, [60, 2]);
  });

  test('stops rather than looping when a page cursor does not advance', () async {
    final requestedOffsets = <BigInt>[];

    await expectLater(
      prefetchAppliedMediaPages(
        loadPage: (offset) async {
          requestedOffsets.add(offset);
          return AppliedMediaCachePage(
            items: const [],
            nextOffset: offset,
          );
        },
        prefetchPage: (_) async {},
      ),
      throwsFormatException,
    );

    expect(requestedOffsets, [BigInt.zero]);
  });

  test('continues after a sparse page when its bounded cursor advances', () async {
    final prefetched = <int>[];

    await prefetchAppliedMediaPages(
      loadPage: (offset) async {
        if (offset == BigInt.zero) {
          return AppliedMediaCachePage(
            items: const [],
            nextOffset: BigInt.from(60),
          );
        }
        return AppliedMediaCachePage(items: [_entry(7)]);
      },
      prefetchPage: (entries) async => prefetched.add(entries.length),
    );

    expect(prefetched, [1]);
  });
}

AppliedMediaCacheEntry _entry(int index) => AppliedMediaCacheEntry(
  sha256: index.toRadixString(16).padLeft(64, '0'),
  storagePath: 'synthetic-$index.jpg',
  kind: models.MediaKind.image,
);
