import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

void main() {
  test(
    'video cover cache retains an 800 item gallery for return scrolling',
    () {
      final bytes = Uint8List.fromList(
        image.encodeJpg(image.Image(width: 16, height: 9), quality: 70),
      );
      final assets = List.generate(
        800,
        (index) => _videoAsset(index, 'return-scroll-video-$index'),
      );
      for (final asset in assets) {
        VideoThumbnailCache.seedForTest(
          asset.sha256,
          VideoThumbnailData(
            bytes: bytes,
            duration: const Duration(seconds: 10),
          ),
        );
      }

      expect(VideoThumbnailCache.peek(assets.first)?.bytes, same(bytes));
      expect(VideoThumbnailCache.peek(assets.last)?.bytes, same(bytes));
    },
  );

  test(
    'complete disk cover loads before checking the original video',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'video-cover-offline-',
      );
      addTearDown(() => root.delete(recursive: true));
      VideoThumbnailCache.configureCacheRoot(root.path);
      final cacheRoot = '${root.path}/cache/video_thumbnails';
      await Directory(cacheRoot).create(recursive: true);
      final asset = _videoAsset(9001, 'd' * 64);
      final bytes = Uint8List.fromList(
        image.encodeJpg(image.Image(width: 16, height: 9), quality: 70),
      );
      await File(
        VideoThumbnailCache.thumbnailPath(
          cacheRoot: cacheRoot,
          sha256: asset.sha256,
        ),
      ).writeAsBytes(bytes);
      await File('$cacheRoot/${asset.sha256}.duration').writeAsString('14000');

      final result = await VideoThumbnailCache.load(
        asset,
        onError: (_, _) async {},
      );

      expect(result.bytes, bytes);
      expect(result.duration, const Duration(seconds: 14));
    },
  );

  test('reads cached duration even when thumbnail extraction failed', () async {
    final directory = await Directory.systemTemp.createTemp('squid-thumb-');
    addTearDown(() => directory.delete(recursive: true));
    const sha = 'abc123';
    await File('${directory.path}/$sha.duration').writeAsString('29000');
    await File('${directory.path}/$sha.failed').writeAsString('failed');

    final result = await VideoThumbnailCache.readCachedFiles(
      cacheRoot: directory.path,
      sha256: sha,
    );

    expect(result.duration, const Duration(seconds: 29));
    expect(result.bytes, isNull);
  });

  test('reads cached thumbnail and duration independently from disk', () async {
    final directory = await Directory.systemTemp.createTemp('squid-thumb-');
    addTearDown(() => directory.delete(recursive: true));
    const sha = 'def456';
    final bytes = Uint8List.fromList(
      image.encodeJpg(image.Image(width: 4, height: 4), quality: 70),
    );
    await File(
      VideoThumbnailCache.thumbnailPath(cacheRoot: directory.path, sha256: sha),
    ).writeAsBytes(bytes);
    await File('${directory.path}/$sha.duration').writeAsString('14000');

    final result = await VideoThumbnailCache.readCachedFiles(
      cacheRoot: directory.path,
      sha256: sha,
    );

    expect(result.duration, const Duration(seconds: 14));
    expect(result.bytes, bytes);
  });

  test(
    'ignores a corrupt cached JPEG instead of reusing it as a cover',
    () async {
      final directory = await Directory.systemTemp.createTemp('squid-thumb-');
      addTearDown(() => directory.delete(recursive: true));
      const sha = 'broken123';
      final thumbnail = File(
        VideoThumbnailCache.thumbnailPath(
          cacheRoot: directory.path,
          sha256: sha,
        ),
      );
      await thumbnail.writeAsBytes(const [1, 2, 3]);
      await File('${directory.path}/$sha.duration').writeAsString('14000');

      final result = await VideoThumbnailCache.readCachedFiles(
        cacheRoot: directory.path,
        sha256: sha,
      );

      expect(result.duration, const Duration(seconds: 14));
      expect(result.bytes, isNull);
    },
  );

  test(
    'legacy timestamp failure markers are retried after extractor changes',
    () {
      expect(
        VideoThumbnailCache.shouldRetryFailureMarker('2026-10-05T16:02:04Z'),
        isTrue,
      );
      expect(
        VideoThumbnailCache.shouldRetryFailureMarker(
          'v2:ffmpeg:decoder failed',
        ),
        isTrue,
      );
      expect(
        VideoThumbnailCache.shouldRetryFailureMarker(
          'v3:ffmpeg:decoder failed',
        ),
        isTrue,
      );
      expect(
        VideoThumbnailCache.shouldRetryFailureMarker(
          'v4:ffmpeg:decoder failed',
        ),
        isTrue,
      );
      expect(
        VideoThumbnailCache.shouldRetryFailureMarker(
          'v6:ffmpeg:decoder failed',
        ),
        isFalse,
      );
    },
  );

  test('video thumbnail preserves 1024px detail with quality 92', () async {
    final source = image.Image(width: 1920, height: 1080);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        source.setPixelRgb(x, y, x % 256, y % 256, (x + y) % 256);
      }
    }
    final input = Uint8List.fromList(image.encodePng(source));

    final bytes = await VideoThumbnailCache.compactBytesForTesting(input);

    expect(bytes, isNotNull);
    final decoded = image.decodeJpg(bytes!)!;
    expect(decoded.width, 1024);
    expect(decoded.height, 576);
    expect(_luminanceQuantizers(bytes), [3, 2, 2, 2]);
    expect(bytes.length, lessThan(384 * 1024));
  });

  test('new video cache wins without overwriting the old cover', () async {
    final root = await Directory.systemTemp.createTemp('video-cover-quality-');
    addTearDown(() => root.delete(recursive: true));
    final sha = 'b' * 64;
    final oldBytes = image.encodeJpg(image.Image(width: 256, height: 144));
    final middleBytes = image.encodeJpg(image.Image(width: 512, height: 288));
    final previousBytes = image.encodeJpg(
      image.Image(width: 1024, height: 576),
    );
    final newBytes = image.encodeJpg(image.Image(width: 1024, height: 576));
    final oldFile = File('${root.path}/${sha}_v2_256.jpg');
    final middleFile = File('${root.path}/${sha}_v3_512.jpg');
    await oldFile.writeAsBytes(oldBytes);
    await middleFile.writeAsBytes(middleBytes);
    final previousFile = File('${root.path}/${sha}_v4_1024.jpg');
    await previousFile.writeAsBytes(previousBytes);
    await File('${root.path}/${sha}_v6_1024.jpg').writeAsBytes(newBytes);
    await File('${root.path}/$sha.duration').writeAsString('14000');

    final cover = await VideoThumbnailCache.readCachedFiles(
      cacheRoot: root.path,
      sha256: sha,
    );

    expect(cover.bytes, newBytes);
    expect(cover.duration, const Duration(seconds: 14));
    expect(cover.needsUpgrade, isFalse);
    expect(await oldFile.readAsBytes(), oldBytes);
    expect(await middleFile.readAsBytes(), middleBytes);
    expect(await previousFile.readAsBytes(), previousBytes);
  });

  test(
    'previous v4 cover remains readable while the original is offline',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'video-cover-offline-v4-',
      );
      addTearDown(() => root.delete(recursive: true));
      VideoThumbnailCache.configureCacheRoot(root.path);
      final directory = Directory('${root.path}/cache/video_thumbnails');
      await directory.create(recursive: true);
      final asset = _videoAsset(9904, 'a' * 64);
      final previousBytes = image.encodeJpg(
        image.Image(width: 1024, height: 576),
      );
      final previousFile = File(
        '${directory.path}/${asset.sha256}_v4_1024.jpg',
      );
      await previousFile.writeAsBytes(previousBytes);
      await File('${directory.path}/${asset.sha256}.duration')
          .writeAsString('14000');

      final cover = await VideoThumbnailCache.load(
        asset,
        onError: (_, _) async {},
      );

      expect(cover.bytes, previousBytes);
      expect(cover.needsUpgrade, isTrue);
      expect(await previousFile.readAsBytes(), previousBytes);
      expect(
        await File('${directory.path}/${asset.sha256}_v6_1024.jpg').exists(),
        isFalse,
      );
    },
  );

  test(
    'offline v3 cover is retained and not passed off as a current cover',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'video-cover-offline-v3-',
      );
      addTearDown(() => root.delete(recursive: true));
      VideoThumbnailCache.configureCacheRoot(root.path);
      final directory = Directory('${root.path}/cache/video_thumbnails');
      await directory.create(recursive: true);
      final asset = _videoAsset(9903, 'f' * 64);
      final oldBytes = image.encodeJpg(image.Image(width: 256, height: 144));
      final middleBytes = image.encodeJpg(image.Image(width: 512, height: 288));
      final oldFile = File('${directory.path}/${asset.sha256}_v2_256.jpg');
      final middleFile = File('${directory.path}/${asset.sha256}_v3_512.jpg');
      await oldFile.writeAsBytes(oldBytes);
      await middleFile.writeAsBytes(middleBytes);
      await File('${directory.path}/${asset.sha256}.duration')
          .writeAsString('14000');

      await VideoThumbnailCache.warmCached(asset);
      expect(VideoThumbnailCache.peekCover(asset)?.bytes, middleBytes);
      final cover = await VideoThumbnailCache.load(
        asset,
        onError: (_, _) async {},
      );

      expect(cover.bytes, middleBytes);
      expect(cover.needsUpgrade, isTrue);
      expect(cover.duration, const Duration(seconds: 14));
      expect(image.decodeJpg(cover.bytes!)!.width, 512);
      expect(await middleFile.readAsBytes(), middleBytes);
      expect(await oldFile.readAsBytes(), oldBytes);
      expect(
        await File('${directory.path}/${asset.sha256}_v6_1024.jpg').exists(),
        isFalse,
      );
    },
  );

  test('an offline video keeps its old cover without upscaling it', () async {
    final root = await Directory.systemTemp.createTemp(
      'video-cover-offline-v2-',
    );
    addTearDown(() => root.delete(recursive: true));
    VideoThumbnailCache.configureCacheRoot(root.path);
    final directory = Directory('${root.path}/cache/video_thumbnails');
    await directory.create(recursive: true);
    final asset = _videoAsset(9902, 'e' * 64);
    final oldBytes = image.encodeJpg(image.Image(width: 256, height: 144));
    final oldFile = File('${directory.path}/${asset.sha256}_v2_256.jpg');
    await oldFile.writeAsBytes(oldBytes);
    await File('${directory.path}/${asset.sha256}.duration')
        .writeAsString('14000');

    await VideoThumbnailCache.warmCached(asset);
    expect(VideoThumbnailCache.peekCover(asset)?.bytes, oldBytes);
    final cover = await VideoThumbnailCache.load(
      asset,
      onError: (_, _) async {},
    );

    expect(cover.bytes, oldBytes);
    expect(image.decodeJpg(cover.bytes!)!.width, 256);
    expect(await oldFile.readAsBytes(), oldBytes);
    expect(
      await File('${directory.path}/${asset.sha256}_v6_1024.jpg').exists(),
      isFalse,
      reason:
          'A resized low-resolution JPEG must not masquerade as new detail.',
    );
  });

  test(
    'video prefetch queue is bounded and visible request is not starved',
    () async {
      const limit = 32;
      final assets = List.generate(
        limit + 40,
        (index) =>
            _videoAsset(index + 1, index.toRadixString(16).padLeft(64, '0')),
      );

      final drain = VideoThumbnailCache.prefetch(
        assets,
        onError: (_, _) async {},
        queueLimit: limit,
      );
      expect(
        VideoThumbnailCache.pendingPrefetchCount,
        lessThanOrEqualTo(limit),
      );
      expect(
        VideoThumbnailCache.pendingPrefetchHashes,
        contains(assets.last.sha256),
      );

      final visible = VideoThumbnailCache.request(
        assets.last,
        onError: (_, _) async {},
        urgent: true,
      );
      expect(await visible.future, isNull);
      visible.cancel();
      await drain;
      expect(VideoThumbnailCache.pendingPrefetchCount, 0);
    },
  );
}

List<int>? _luminanceQuantizers(Uint8List bytes) {
  var offset = 2;
  while (offset + 4 < bytes.length && bytes[offset] == 0xff) {
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

MediaAsset _videoAsset(int id, String sha256) => MediaAsset(
  id: id,
  sha256: sha256,
  originalName: 'video.mp4',
  storagePath: 'missing-$id.mp4',
  kind: MediaKind.video,
  gameName: 'Game',
  favorite: false,
  tags: const [],
);
