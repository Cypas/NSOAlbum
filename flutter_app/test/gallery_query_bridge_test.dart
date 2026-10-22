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
    'generated gallery bridge filters historical days before paging',
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

        GalleryQuery query({int offset = 0, bool favoriteOnly = false}) =>
            GalleryQuery(
              kind: GalleryKindFilter.all,
              limit: 1,
              offset: offset,
              favoriteOnly: favoriteOnly,
              newestFirst: true,
              gameNames: const [],
              capturedOnThisDay: CapturedOnThisDay(
                month: 2,
                day: 29,
                beforeYear: 2028,
                utcOffsetSeconds: DateTime(
                  2024,
                  2,
                  29,
                  12,
                ).timeZoneOffset.inSeconds,
              ),
            );

        final first = (await native.listMedia(query: query())).single;
        final second = (await native.listMedia(query: query(offset: 1))).single;
        expect(first.capturedAt!.toLocal().year, 2024);
        expect(second.capturedAt!.toLocal().year, 2020);
        expect(await native.listMedia(query: query(offset: 2)), isEmpty);
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
