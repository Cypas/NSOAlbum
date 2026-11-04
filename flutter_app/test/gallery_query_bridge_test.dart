import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/rust/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];

  test(
    'generated gallery bridge pages capture order and filters import dates',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      final root = await Directory.systemTemp.createTemp(
        'nsoalbum-gallery-bridge-',
      );
      try {
        await native.initCore(libraryRoot: root.path);
        final files = <String>[];
        for (final (index, name) in [
          '2020022912000000.jpg',
          '2024022912000000.jpg',
          '2024030112000000.jpg',
          '2028022912000000.jpg',
        ].indexed) {
          final file = File('${root.path}/$name');
          await file.writeAsBytes([0xff, 0xd8, index, 0xff, 0xd9]);
          files.add(file.path);
        }
        final imported = await native.importLocalFiles(paths: files);
        expect(imported.imported, BigInt.from(4));
        expect(imported.failed, BigInt.zero);

        GalleryQuery query({
          int offset = 0,
          bool favoriteOnly = false,
          DateTime? importedFrom,
          DateTime? importedUntil,
          DateTime? capturedFrom,
          DateTime? capturedUntil,
          CapturedOnThisDay? anniversary,
        }) => GalleryQuery(
          kind: GalleryKindFilter.all,
          limit: 1,
          offset: offset,
          favoriteOnly: favoriteOnly,
          newestFirst: true,
          gameNames: const [],
          importedFrom: importedFrom,
          importedUntil: importedUntil,
          capturedFrom: capturedFrom,
          capturedUntil: capturedUntil,
          capturedOnThisDay: anniversary,
        );

        final first = (await native.listMedia(query: query())).single;
        final second = (await native.listMedia(query: query(offset: 1))).single;
        expect(first.capturedAt!.toLocal().year, 2028);
        expect(second.capturedAt!.toLocal().month, 3);
        expect(await native.listMedia(query: query(offset: 4)), isEmpty);
        final captureDay = await native.listMedia(
          query: query(
            capturedFrom: DateTime(2024, 2, 29).toUtc(),
            capturedUntil: DateTime(2024, 3, 1).toUtc(),
          ),
        );
        expect(captureDay.single.capturedAt!.toLocal().year, 2024);
        expect(captureDay.single.capturedAt!.toLocal().day, 29);

        // These newly imported files have historical capture dates, but their
        // local creation/import time is recent. Do not use capture metadata
        // to fabricate historical import dates in this native roundtrip.
        final yesterday = DateTime.now().toUtc().subtract(
          const Duration(days: 1),
        );
        expect(
          await native.listMedia(query: query(importedUntil: yesterday)),
          isEmpty,
        );
        expect(
          (await native.listMedia(query: query(importedFrom: yesterday)))
              .single
              .id,
          first.id,
        );
        final importedDay = first.importedAt!.toLocal();
        expect(
          await native.listMedia(
            query: query(
              anniversary: CapturedOnThisDay(
                month: importedDay.month,
                day: importedDay.day,
                beforeYear: importedDay.year,
                utcOffsetSeconds: importedDay.timeZoneOffset.inSeconds,
              ),
            ),
          ),
          isEmpty,
        );

        final firstPage = await native.listMediaPage(
          request: GalleryPageRequest(
            query: query(),
            direction: GalleryPageDirection.forward,
          ),
        );
        expect(firstPage.items.single.id, first.id);
        expect(firstPage.hasBefore, isFalse);
        expect(firstPage.hasAfter, isTrue);
        final secondPage = await native.listMediaPage(
          request: GalleryPageRequest(
            query: query(),
            direction: GalleryPageDirection.forward,
            cursor: firstPage.afterCursor,
          ),
        );
        expect(secondPage.items.single.id, second.id);
        final previousPage = await native.listMediaPage(
          request: GalleryPageRequest(
            query: query(),
            direction: GalleryPageDirection.backward,
            cursor: secondPage.beforeCursor,
          ),
        );
        expect(previousPage.items.single.id, first.id);
        await expectLater(
          native.listMediaPage(
            request: GalleryPageRequest(
              query: query(favoriteOnly: true),
              direction: GalleryPageDirection.forward,
              cursor: firstPage.afterCursor,
            ),
          ),
          throwsA(
            contains('gallery cursor does not match the current filters'),
          ),
        );
        final counts = await native.listGameMediaCounts();
        expect(
          counts.fold(BigInt.zero, (total, game) => total + game.imageCount),
          BigInt.from(4),
        );
        expect(
          counts.fold(BigInt.zero, (total, game) => total + game.videoCount),
          BigInt.zero,
        );
        final album = await native.createAlbum(
          name: 'Synthetic page scope',
          description: '',
          smart: false,
        );
        await native.addMediaToAlbum(albumId: album, mediaId: second.id);
        final albumCounts = await native.listGameMediaCounts(albumId: album);
        expect(albumCounts.single.imageCount, BigInt.one);
        final details = await native.mediaDetails(mediaId: second.id);
        expect(details.media.id, second.id);
        expect(details.importedAt, second.importedAt);
        expect(details.sources, isNotEmpty);
        expect(
          await native.listMedia(query: query(favoriteOnly: true)),
          isEmpty,
        );
        await native.setFavorite(mediaId: second.id, favorite: true);
        expect(
          (await native.listMedia(query: query(favoriteOnly: true))).single.id,
          second.id,
        );
      } finally {
        RustLib.dispose();
        // The process-wide core can retain the synthetic SQLite handle until
        // process exit. Preserve this fixture instead of racing native teardown.
        debugPrintSynchronously(
          'Retained synthetic gallery fixture: ${root.path}',
        );
      }
    },
    skip: library == null
        ? 'Requires NSOALBUM_DEVICE_SYNC_TEST_LIBRARY pointing to the current Debug core; synthetic data only'
        : false,
  );
}
