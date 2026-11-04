import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/gallery_perf.dart';
import 'package:squid_album/src/ui/image_thumbnail.dart';
import 'package:squid_album/src/ui/video_preview_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('completed cancelled image work persists its thumbnail without delivering stale bytes', () async {
    final perf = _GenerationObserver()..start();
    addTearDown(perf.stop);
    final root = await Directory.systemTemp.createTemp(
      'gallery-cancel-persist-',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/source.png');
    final original = image.encodePng(
      image.Image(width: 1024, height: 512)
        ..clear(image.ColorRgb8(32, 117, 191)),
    );
    await source.writeAsBytes(original);
    final asset = MediaAsset(
      id: 1,
      sha256: 'b' * 64,
      originalName: 'fixture.png',
      storagePath: source.path,
      kind: MediaKind.image,
      gameName: '',
      favorite: false,
      tags: const [],
    );
    final cacheRoot = '${root.path}/thumbs';
    final store = ImageThumbnailStore(cacheRoot, diagnostics: perf);
    final request = store.request(asset)!;
    await perf.started.future.timeout(const Duration(seconds: 10));
    request.cancel();
    expect(await request.future, isNull);
    expect(
      store.peek(asset),
      isNull,
      reason: 'Cancellation must not attach the completed result to the old consumer or encoded LRU.',
    );

    final cacheFile = File('$cacheRoot/${asset.sha256}_v4_1024.jpg');
    expect(await cacheFile.exists(), isTrue);
    final thumbnail = await cacheFile.readAsBytes();
    expect(image.decodeJpg(thumbnail)!.width, 1024);
    final absentOriginal = MediaAsset(
      id: asset.id,
      sha256: asset.sha256,
      originalName: asset.originalName,
      storagePath: '${root.path}/missing.png',
      kind: MediaKind.image,
      gameName: '',
      favorite: false,
      tags: const [],
    );
    final freshStore = ImageThumbnailStore(cacheRoot, diagnostics: perf);
    expect(await freshStore.ensure(absentOriginal), thumbnail);
    final counters = perf.snapshot()['counters'] as Map;
    expect(counters['imageGenerate'], 1);
    expect(counters['originalRead'], 1);
    expect(counters['imageDiskHit'], 1);
    expect(counters['cancelled'], 1);
    expect(counters['discarded'], 1);
    expect(counters['cachedAfterCancel'], 1);
    expect(await source.readAsBytes(), original);
  });

  test('decoded cover budget grows only for desktops and preserves a larger budget', () {
    final desktop = ImageCache()..maximumSizeBytes = 100 * 1024 * 1024;
    configureGalleryDecodedImageCache(desktop, desktop: true);
    expect(desktop.maximumSizeBytes, 160 * 1024 * 1024);
    final android = ImageCache()..maximumSizeBytes = 100 * 1024 * 1024;
    configureGalleryDecodedImageCache(android, desktop: false);
    expect(android.maximumSizeBytes, 100 * 1024 * 1024);
    final larger = ImageCache()..maximumSizeBytes = 256 * 1024 * 1024;
    configureGalleryDecodedImageCache(larger, desktop: true);
    expect(larger.maximumSizeBytes, 256 * 1024 * 1024);
  });

  test('a late cancelled writer never replaces another request’s published JPEG', () async {
    final perf = GalleryPerf(enabled: true)..start();
    addTearDown(perf.stop);
    final root = await Directory.systemTemp.createTemp('gallery-publish-race-');
    addTearDown(() => root.delete(recursive: true));
    final cacheRoot = '${root.path}/thumbs';
    final asset = MediaAsset(
      id: 1,
      sha256: 'c' * 64,
      originalName: 'fixture.png',
      storagePath: '${root.path}/not-read.png',
      kind: MediaKind.image,
      gameName: '',
      favorite: false,
      tags: const [],
    );
    final firstStarted = Completer<void>(), secondStarted = Completer<void>();
    final firstGate = Completer<Uint8List?>(),
        secondGate = Completer<Uint8List?>();
    final firstJpeg = image.encodeJpg(
      image.Image(width: 32, height: 16)..clear(image.ColorRgb8(200, 30, 40)),
    );
    final secondJpeg = image.encodeJpg(
      image.Image(width: 32, height: 16)..clear(image.ColorRgb8(20, 60, 210)),
    );
    var generations = 0;
    final store = ImageThumbnailStore(
      cacheRoot,
      diagnostics: perf,
      generateThumbnail: (_) {
        switch (generations++) {
          case 0:
            firstStarted.complete();
            return firstGate.future;
          case 1:
            secondStarted.complete();
            return secondGate.future;
          default:
            throw StateError('Unexpected extra generation');
        }
      },
    );
    final first = store.request(asset)!;
    await firstStarted.future.timeout(const Duration(seconds: 10));
    first.cancel();
    final second = store.request(asset)!;
    await secondStarted.future.timeout(const Duration(seconds: 10));
    secondGate.complete(secondJpeg);
    expect(await second.future, secondJpeg);
    final cacheFile = File('$cacheRoot/${asset.sha256}_v4_1024.jpg');
    expect(await cacheFile.readAsBytes(), secondJpeg);

    firstGate.complete(firstJpeg);
    final reader = ImageThumbnailStore(
      cacheRoot,
      diagnostics: perf,
      generateThumbnail: (_) => throw StateError(
        'A valid published JPEG must not expose an original-read gap',
      ),
    ).ensure(asset);
    final results = await Future.wait([first.future, reader]);
    expect(results[0], isNull);
    expect(results[1], secondJpeg);
    expect(await cacheFile.readAsBytes(), secondJpeg);
    expect(
      store.peek(asset),
      same(secondJpeg),
      reason:
          'The cancelled result cannot replace the current encoded LRU entry.',
    );
    expect(generations, 2);
    final counters = perf.snapshot()['counters'] as Map;
    expect(counters['cacheBytes'], secondJpeg.length);
    expect(counters['originalRead'], isNull);
  });

  test(
    'a failed thumbnail publication releases its target for a later retry',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gallery-publish-retry-',
      );
      addTearDown(() => root.delete(recursive: true));
      final cacheRoot = '${root.path}/thumbs';
      final asset = MediaAsset(
        id: 1,
        sha256: 'e' * 64,
        originalName: 'fixture.png',
        storagePath: '${root.path}/not-read.png',
        kind: MediaKind.image,
        gameName: '',
        favorite: false,
        tags: const [],
      );
      final jpeg = image.encodeJpg(image.Image(width: 32, height: 16));
      final obstruction = Directory('$cacheRoot/${asset.sha256}_v4_1024.jpg');
      await obstruction.create(recursive: true);
      final store = ImageThumbnailStore(
        cacheRoot,
        generateThumbnail: (_) async => jpeg,
      );
      await expectLater(
        store.ensure(asset),
        throwsA(isA<FileSystemException>()),
      );
      await obstruction.delete();
      expect(
        await store.ensure(asset).timeout(const Duration(seconds: 10)),
        jpeg,
      );
      expect(await File(obstruction.path).readAsBytes(), jpeg);
    },
  );

  test('cache reports coalescing, cancelled results and byte-budget eviction without keys', () async {
    final perf = GalleryPerf(enabled: true)..start();
    addTearDown(perf.stop);
    final cache = PreviewCache<int>(
      maxEntries: 4,
      maxBytes: 2,
      sizeOf: (_) => 1,
      diagnostics: perf,
    );
    final gate = Completer<int?>();
    final first = cache.request(
      'private-file-and-hash',
      load: (_) => gate.future,
    );
    final shared = cache.request(
      'private-file-and-hash',
      load: (_) => throw StateError('must coalesce'),
    );
    first.cancel();
    shared.cancel();
    gate.complete(1);
    expect(await shared.future, isNull);
    expect(cache.peek('private-file-and-hash'), isNull);
    for (var i = 0; i < 3; i++) {
      expect(await cache.request('key-$i', load: (_) async => i).future, i);
    }
    expect(
      await cache
          .request('key-2', load: (_) => throw StateError('must hit memory'))
          .future,
      2,
    );
    final data = perf.snapshot();
    final counters = data['counters'] as Map;
    expect(counters['coalesced'], 1);
    expect(counters['cancelled'], 1);
    expect(counters['discarded'], 1);
    expect(counters['eviction'], 1);
    expect(counters['memoryHit'], 1);
    expect(data.toString(), isNot(contains('private-file-and-hash')));
    expect((data['timings'] as Map)['queueWait'], isNotNull);
  });

  test(
    'queued cancellation and load errors remain distinct diagnostics',
    () async {
      final perf = GalleryPerf(enabled: true)..start();
      addTearDown(perf.stop);
      final cache = PreviewCache<int>(
        maxEntries: 3,
        maxBytes: 5,
        sizeOf: (_) => 1,
        diagnostics: perf,
      );
      final gate = Completer<int?>();
      final first = cache.request('first', load: (_) => gate.future);
      var queuedRuns = 0;
      final queued = cache.request(
        'cancelled',
        load: (_) async {
          queuedRuns++;
          return 2;
        },
      );
      queued.cancel();
      expect(await queued.future, isNull);
      gate.complete(1);
      expect(await first.future, 1);
      final failed = cache.request(
        'error',
        load: (_) async => throw StateError('private path'),
      );
      await expectLater(failed.future, throwsStateError);
      expect(queuedRuns, 0);
      final counters = perf.snapshot()['counters'] as Map;
      expect(counters['cancelled'], 1);
      expect(counters['failed'], 1);
      expect(perf.snapshot().toString(), isNot(contains('private path')));
    },
  );

  test(
    'background gauges retain real preroll jobs across a capture boundary',
    () async {
      final perf = GalleryPerf(enabled: true);
      addTearDown(perf.stop);
      final cache = PreviewCache<int>(
        maxEntries: 4,
        maxBytes: 4,
        sizeOf: (_) => 1,
        diagnostics: perf,
      );
      final firstGate = Completer<int?>(), secondGate = Completer<int?>();
      final first = cache.request('first', load: (_) => firstGate.future);
      final second = cache.request('second', load: (_) => secondGate.future);
      final cancelled = cache.request('cancelled', load: (_) async => 3);
      perf.start();
      var background = perf.snapshot()['background'] as Map;
      expect(background['cacheActiveAtStart'], 1);
      expect(background['cachePendingAtStart'], 2);
      cancelled.cancel();
      expect(await cancelled.future, isNull);
      background = perf.snapshot()['background'] as Map;
      expect(background['cachePending'], 1);
      firstGate.complete(1);
      expect(await first.future, 1);
      background = perf.snapshot()['background'] as Map;
      expect(background['cacheActive'], 1);
      expect(background['cachePending'], 0);
      expect(background['cacheCarryoverFinished'], 1);
      secondGate.complete(2);
      expect(await second.future, 2);
      background = perf.snapshot()['background'] as Map;
      expect(background['cacheActive'], 0);
      expect(background['cachePending'], 0);
      expect(background['cacheCarryoverFinished'], 2);
      expect(
        perf.snapshot()['counters'],
        isEmpty,
        reason: 'Old work is visible as carryover, not attributed to new per-session cache counts.',
      );
    },
  );

  test(
    'late results from an old capture do not contaminate the next session',
    () async {
      final perf = GalleryPerf(enabled: true)..start();
      addTearDown(perf.stop);
      final cache = PreviewCache<int>(
        maxEntries: 2,
        maxBytes: 1,
        sizeOf: (_) => 1,
        diagnostics: perf,
      );
      cache.seed('seed', 1);
      final gate = Completer<int?>();
      final old = cache.request(
        'old',
        load: (work) async {
          final result = await gate.future;
          work.diagnostics.increment(GalleryMetric.diskBytes, 800);
          return result;
        },
      );
      perf.start();
      gate.complete(2);
      expect(await old.future, 2);
      expect(perf.snapshot()['counters'], isEmpty);
      expect(
        cache.peek('old'),
        2,
        reason: 'Capture boundaries do not change caching behavior.',
      );
    },
  );

  test(
    'image metrics distinguish generation, disk hit and memory hit',
    () async {
      final perf = GalleryPerf.instance..start();
      addTearDown(perf.stop);
      final root = await Directory.systemTemp.createTemp('gallery-perf-cache-');
      addTearDown(() => root.delete(recursive: true));
      final original = File('${root.path}/original.png');
      await original.writeAsBytes(
        image.encodePng(image.Image(width: 64, height: 32)),
      );
      final asset = MediaAsset(
        id: 1,
        sha256: 'd' * 64,
        originalName: 'private-name.png',
        storagePath: original.path,
        kind: MediaKind.image,
        gameName: '',
        favorite: false,
        tags: const [],
      );
      final store = ImageThumbnailStore('${root.path}/thumbs');
      expect(await store.ensure(asset), isNotNull);
      expect(await store.ensure(asset), isNotNull);
      expect(
        await ImageThumbnailStore('${root.path}/thumbs').ensure(asset),
        isNotNull,
      );
      final snapshot = perf.snapshot();
      final counters = snapshot['counters'] as Map;
      expect(counters['imageGenerate'], 1);
      expect(counters['imageDiskHit'], 1);
      expect(counters['memoryHit'], 1);
      expect((snapshot['timings'] as Map)['imageDecode'], isNotNull);
      final timings = snapshot['timings'] as Map;
      expect((timings['cacheStat'] as Map)['count'], greaterThan(0));
      expect((timings['cacheRoot'] as Map)['count'], greaterThan(0));
      expect((timings['cacheCleanup'] as Map)['count'], greaterThan(0));
      expect(snapshot.toString(), isNot(contains(original.path)));
      expect(snapshot.toString(), isNot(contains(asset.sha256)));
    },
    skip: !GalleryPerf.compiled
        ? 'Enable NSO_GALLERY_PERF for cache instrumentation'
        : false,
  );

  testWidgets(
    'placeholder comparison removes a mounted warm cover without changing its slot',
    (tester) async {
      final perf = GalleryPerf.instance..start();
      addTearDown(perf.stop);
      late Directory root;
      final asset = MediaAsset(
        id: 2,
        sha256: 'a' * 64,
        originalName: 'private.png',
        storagePath: 'not-read.png',
        kind: MediaKind.image,
        gameName: '',
        favorite: false,
        tags: const [],
      );
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('gallery-perf-mode-');
        await File('${root.path}/${asset.sha256}_v4_1024.jpg')
            .writeAsBytes(image.encodeJpg(image.Image(width: 32, height: 16)));
        await ImageThumbnailCache.ensure(asset, cacheRoot: root.path);
      });
      addTearDown(() => root.delete(recursive: true));
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              key: const Key('slot'),
              width: 180,
              height: 90,
              child: ImageThumbnail(
                asset: asset,
                cacheRoot: root.path,
                placeholder: const SizedBox.expand(key: Key('placeholder')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      final rect = tester.getRect(find.byKey(const Key('slot')));
      perf.start(mode: GalleryCoverMode.placeholder);
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.byKey(const Key('placeholder')), findsOneWidget);
      expect(tester.getRect(find.byKey(const Key('slot'))), rect);
      perf.start(mode: GalleryCoverMode.encodedWarm);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !GalleryPerf.compiled,
  );
}

class _GenerationObserver extends GalleryPerf {
  _GenerationObserver() : super(enabled: true);
  final started = Completer<void>();
  @override
  void increment(GalleryMetric metric, [int amount = 1]) {
    super.increment(metric, amount);
    if (metric == GalleryMetric.imageGenerate && !started.isCompleted) {
      started.complete();
    }
  }
}
