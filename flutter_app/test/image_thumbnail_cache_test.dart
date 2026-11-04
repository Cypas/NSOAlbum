import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:squid_album/src/rust/device_sync/read_model.dart'
    as device_sync;
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/image_thumbnail.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  test(
    'image thumbnail cache survives source removal and repairs bad bytes',
    () async {
      final root = await Directory.systemTemp.createTemp('image-thumb-cache-');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}${Platform.pathSeparator}source.png');
      final original = image.Image(width: 1600, height: 900)
        ..clear(image.ColorRgb8(28, 103, 188));
      await source.writeAsBytes(image.encodePng(original));
      final bytes = await source.readAsBytes();
      final sha256 = digestToString(bytes);
      final asset = _asset(source.path, sha256);
      final cacheRoot = '${root.path}${Platform.pathSeparator}image_thumbnails';

      final store = ImageThumbnailStore(cacheRoot);
      final first = await store.ensure(asset);
      expect(first, isNotNull);
      expect(first!.sublist(0, 2), [0xff, 0xd8]);
      final cachedFile = File(
        '$cacheRoot${Platform.pathSeparator}${sha256}_v4_1024.jpg',
      );
      expect(await cachedFile.exists(), isTrue);
      final cachedBytes = await cachedFile.readAsBytes();
      final decoded = image.decodeJpg(cachedBytes)!;
      expect(decoded.width, 1024);
      expect(decoded.height, 576);
      expect(_luminanceQuantizers(cachedBytes), [3, 2, 2, 2]);
      expect(await source.readAsBytes(), bytes);

      await source.delete();
      final fromDisk = await ImageThumbnailStore(cacheRoot).ensure(asset);
      expect(fromDisk, cachedBytes);

      await source.writeAsBytes(bytes);
      await cachedFile.writeAsString('not a jpeg');
      final repaired = await ImageThumbnailStore(cacheRoot).ensure(asset);
      expect(repaired, isNotNull);
      expect(repaired!.sublist(0, 2), [0xff, 0xd8]);
      expect(await cachedFile.readAsBytes(), repaired);
    },
  );

  test(
    'small original images are not upscaled for the new thumbnail',
    () async {
      final root = await Directory.systemTemp.createTemp('image-thumb-small-');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/small.png');
      final original = image.encodePng(image.Image(width: 320, height: 180));
      await source.writeAsBytes(original);

      final thumbnail = await ImageThumbnailStore('${root.path}/thumbs')
          .ensure(_asset(source.path, digestToString(original)));

      final decoded = image.decodeJpg(thumbnail!)!;
      expect(decoded.width, 320);
      expect(decoded.height, 180);
      expect(_luminanceQuantizers(thumbnail), [3, 2, 2, 2]);
      expect(await source.readAsBytes(), original);
    },
  );

  test('prefetch generates thumbnails before a card requests them', () async {
    final root = await Directory.systemTemp.createTemp('image-thumb-prefetch-');
    addTearDown(() => root.delete(recursive: true));
    final cacheRoot = '${root.path}${Platform.pathSeparator}image_thumbnails';
    final assets = <MediaAsset>[];
    for (var index = 0; index < 3; index++) {
      final source = File(
        '${root.path}${Platform.pathSeparator}source-$index.png',
      );
      final original = image.Image(width: 640, height: 480)
        ..clear(image.ColorRgb8(index * 40, 103, 188));
      final bytes = image.encodePng(original);
      await source.writeAsBytes(bytes);
      assets.add(_asset(source.path, digestToString(bytes)));
    }

    final store = ImageThumbnailStore(cacheRoot);
    await store.prefetch(assets);

    for (final asset in assets) {
      expect(
        await File(
          '$cacheRoot${Platform.pathSeparator}${asset.sha256}_v4_1024.jpg',
        ).exists(),
        isTrue,
      );
      expect(await store.ensure(asset), isNotNull);
    }
  });

  test(
    '800 warm image covers keep their bytes during return scrolling',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'image-thumb-prefetch-disk-hit-',
      );
      addTearDown(() => root.delete(recursive: true));
      final cacheRoot = '${root.path}${Platform.pathSeparator}image_thumbnails';
      final jpeg = image.encodeJpg(
        image.Image(width: 256, height: 144),
        quality: 70,
      );
      final assets = List.generate(800, (index) {
        final sha = index.toRadixString(16).padLeft(64, '0');
        return _asset(
          '${root.path}${Platform.pathSeparator}unused-$index.png',
          sha,
        );
      });
      for (final asset in assets) {
        await File(
          '$cacheRoot${Platform.pathSeparator}${asset.sha256}_v4_1024.jpg',
        ).create(recursive: true).then((file) => file.writeAsBytes(jpeg));
      }

      final store = ImageThumbnailStore(cacheRoot);
      await store.prefetch(assets);
      expect(store.diskCacheReadCount, 0);
      expect(store.cacheDirectoryScanCount, 1);

      final firstPass = <Uint8List>[];
      for (final asset in assets) {
        firstPass.add((await store.ensure(asset))!);
      }
      expect(store.diskCacheReadCount, assets.length);

      for (var index = assets.length - 1; index >= 0; index--) {
        expect(await store.ensure(assets[index]), same(firstPass[index]));
      }
      expect(
        store.diskCacheReadCount,
        assets.length,
        reason:
            'Scrolling back through a typical gallery should stay in memory.',
      );

      await store.prefetch([assets.first]);
      expect(
        store.diskCacheReadCount,
        assets.length,
        reason:
            'An existing thumbnail must not be queued for background reading.',
      );
      expect(store.cacheDirectoryScanCount, 1);
    },
  );

  test(
    'device-sync cache entries prefetch exact image paths without media models',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'image-thumb-applied-entry-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}${Platform.pathSeparator}applied.png');
      final original = image.Image(width: 640, height: 480)
        ..clear(image.ColorRgb8(28, 103, 188));
      final bytes = Uint8List.fromList(image.encodePng(original));
      await source.writeAsBytes(bytes);
      final sha = digestToString(bytes);
      final cacheRoot = '${root.path}${Platform.pathSeparator}image_thumbnails';

      await ImageThumbnailCache.prefetchAppliedMediaEntries([
        device_sync.AppliedMediaCacheEntry(
          sha256: sha,
          storagePath: source.path,
          kind: MediaKind.image,
        ),
      ], cacheRoot: cacheRoot);

      expect(
        await File('$cacheRoot${Platform.pathSeparator}${sha}_v4_1024.jpg')
            .exists(),
        isTrue,
      );
    },
  );

  test('import prefetch scans every item in the import window regardless of capture sort', () async {
    final root = await Directory.systemTemp.createTemp(
      'image-thumb-import-window-',
    );
    addTearDown(() => root.delete(recursive: true));
    final cacheRoot = '${root.path}${Platform.pathSeparator}image_thumbnails';
    final importedSince = DateTime.now().toUtc().subtract(
      const Duration(minutes: 1),
    );
    final importedAt = importedSince.add(const Duration(seconds: 30));
    final assets = <MediaAsset>[];
    for (var index = 0; index < 61; index++) {
      final sha = index.toRadixString(16).padLeft(64, '0');
      final asset = _asset(
        '${root.path}${Platform.pathSeparator}source-$index.png',
        sha,
        id: index + 1,
        capturedAt: index == 60
            ? DateTime.utc(2000)
            : DateTime.utc(2025, 1, 1).add(Duration(seconds: index)),
        importedAt: importedAt,
      );
      assets.add(asset);
      if (index < 60) {
        await File('$cacheRoot${Platform.pathSeparator}${sha}_v4_1024.jpg')
            .create(recursive: true)
            .then((file) => file.writeAsBytes([0xff, 0xd8, 0x00, 0xff, 0xd9]));
      }
    }
    final source = image.Image(width: 640, height: 480)
      ..clear(image.ColorRgb8(28, 103, 188));
    await File(assets.last.storagePath).writeAsBytes(image.encodePng(source));

    final backend = _RecordingBackend(mediaItems: assets);
    await ImageThumbnailCache.prefetchImportedImages(
      backend,
      BigInt.one,
      importedSince: importedSince,
      cacheRoot: cacheRoot,
    );

    expect(
      await File(
        '$cacheRoot${Platform.pathSeparator}${assets.last.sha256}_v4_1024.jpg',
      ).exists(),
      isTrue,
    );
    expect(backend.pageQueries.length, greaterThan(1));
    expect(
      backend.pageQueries.map((query) => query.importedUntil).toSet().length,
      1,
    );
  });

  test('import prefetch continues beyond 500 pages', () async {
    final root = await Directory.systemTemp.createTemp(
      'image-thumb-many-pages-',
    );
    addTearDown(() => root.delete(recursive: true));
    const pageCount = 501;
    final cacheRoot = '${root.path}${Platform.pathSeparator}image_thumbnails';
    final sha = 'f' * 64;
    final asset = _asset(
      '${root.path}${Platform.pathSeparator}cached.png',
      sha,
    );
    await File('$cacheRoot${Platform.pathSeparator}${sha}_v4_1024.jpg')
        .create(recursive: true)
        .then((file) => file.writeAsBytes([0xff, 0xd8, 0x00, 0xff, 0xd9]));
    final backend = _ManyPagesBackend(asset, pageCount);

    await ImageThumbnailCache.prefetchImportedImages(
      backend,
      BigInt.one,
      importedSince: DateTime.now().toUtc().subtract(
        const Duration(minutes: 1),
      ),
      cacheRoot: cacheRoot,
    );

    expect(backend.pageCalls, pageCount);
  });

  test(
    'background prefetch queue is capped and visible requests stay urgent',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'image-thumb-bounded-prefetch-',
      );
      addTearDown(() => root.delete(recursive: true));
      const queueLimit = 32;
      final cacheRoot = '${root.path}${Platform.pathSeparator}image_thumbnails';
      final assets = List.generate(queueLimit + 100, (index) {
        final sha = index.toRadixString(16).padLeft(64, '0');
        return _asset(
          '${root.path}${Platform.pathSeparator}unused-$index.png',
          sha,
        );
      });

      final store = ImageThumbnailStore(
        cacheRoot,
        prefetchQueueLimit: queueLimit,
      );
      final drain = store.prefetch(assets);
      expect(store.pendingPrefetchCount, lessThanOrEqualTo(queueLimit));
      expect(store.pendingPrefetchHashes, contains(assets.last.sha256));
      expect(store.pendingPrefetchHashes, isNot(contains(assets[2].sha256)));

      final visibleSource = File(
        '${root.path}${Platform.pathSeparator}visible.png',
      );
      final visibleImage = image.Image(width: 640, height: 480)
        ..clear(image.ColorRgb8(28, 103, 188));
      final sourceBytes = image.encodePng(visibleImage);
      await visibleSource.writeAsBytes(sourceBytes);
      final visibleAsset = _asset(
        visibleSource.path,
        digestToString(sourceBytes),
      );
      expect(await store.ensure(visibleAsset), isNotNull);
      await drain;
    },
  );

  test(
    'legacy thumbnail cleanup only removes bounded exact cache names',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'image-thumb-cleanup-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = ImageThumbnailStore(root.path);
      final valid = List.generate(
        3,
        (index) => File(
          '${root.path}${Platform.pathSeparator}${'a' * 63}$index'
          '_v1_512.jpg',
        ),
      );
      for (final file in valid) {
        await file.writeAsBytes(const [1]);
        final sha = file.uri.pathSegments.last.substring(0, 64);
        await File('${root.path}${Platform.pathSeparator}${sha}_v4_1024.jpg')
            .writeAsBytes(const [1]);
      }
      final unknown = File(
        '${root.path}${Platform.pathSeparator}not-owned-v1_512.jpg',
      );
      await unknown.writeAsBytes(const [1]);
      await store.cleanupLegacy(
        maxFiles: 2,
        verifiedHashes: {
          for (final file in valid) file.uri.pathSegments.last.substring(0, 64),
        },
      );
      expect(await Future.wait(valid.take(2).map((file) => file.exists())), [
        false,
        false,
      ]);
      expect(await valid.last.exists(), isTrue);
      expect(await unknown.exists(), isTrue);
    },
  );
}

class _RecordingBackend extends FakeBackend {
  _RecordingBackend({super.mediaItems});

  final List<GalleryQuery> pageQueries = [];

  @override
  Future<GalleryPage> listMediaPage(GalleryPageRequest request) {
    pageQueries.add(request.query);
    return super.listMediaPage(request);
  }
}

class _ManyPagesBackend extends FakeBackend {
  _ManyPagesBackend(this.asset, this.pageCount) : super(mediaItems: [asset]);

  final MediaAsset asset;
  final int pageCount;
  int pageCalls = 0;

  @override
  Future<GalleryPage> listMediaPage(GalleryPageRequest request) async {
    pageCalls++;
    return GalleryPage(
      items: [asset],
      afterCursor: GalleryCursor(
        filterFingerprint: 'many-pages',
        mediaId: pageCalls,
      ),
      hasBefore: pageCalls > 1,
      hasAfter: pageCalls < pageCount,
    );
  }
}

MediaAsset _asset(
  String path,
  String sha256, {
  int id = 1,
  DateTime? capturedAt,
  DateTime? importedAt,
}) => MediaAsset(
  id: id,
  sha256: sha256,
  originalName: 'source.png',
  storagePath: path,
  kind: MediaKind.image,
  capturedAt: capturedAt,
  importedAt: importedAt,
  gameName: 'Game',
  favorite: false,
  tags: const [],
);

String digestToString(Uint8List bytes) => sha256.convert(bytes).toString();

List<int>? _luminanceQuantizers(Uint8List bytes) {
  var offset = 2;
  while (offset + 8 < bytes.length && bytes[offset] == 0xff) {
    final marker = bytes[offset + 1];
    if (marker == 0xda || marker == 0xd9) return null;
    final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    if (length < 2 || offset + length + 2 > bytes.length) return null;
    if (marker == 0xdb && bytes[offset + 4] == 0) {
      return bytes.sublist(offset + 5, offset + 9);
    }
    offset += length + 2;
  }
  return null;
}
