import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

void main() {
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
    final bytes = Uint8List.fromList([1, 2, 3]);
    await File('${directory.path}/$sha.jpg').writeAsBytes(bytes);
    await File('${directory.path}/$sha.duration').writeAsString('14000');

    final result = await VideoThumbnailCache.readCachedFiles(
      cacheRoot: directory.path,
      sha256: sha,
    );

    expect(result.duration, const Duration(seconds: 14));
    expect(result.bytes, bytes);
  });

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
        isFalse,
      );
    },
  );
}
