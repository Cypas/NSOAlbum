import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../backend/app_backend.dart';
import '../rust/device_sync/read_model.dart' as device_sync;
import '../rust/models.dart';
import 'gallery_perf.dart';
import 'gallery_drag_loading.dart';
import 'video_thumbnail.dart';
import 'video_preview_cache.dart';

const _thumbnailVersion = 'v4';
const _thumbnailMaxEdge = 1024;
const _thumbnailQuality = 92;
final _thumbnailCacheFilePattern = RegExp(
  '^([0-9a-fA-F]{64})_$_thumbnailVersion'
  '_$_thumbnailMaxEdge[.]jpg\$',
);

bool get _placeholderCovers =>
    GalleryPerf.instance.enabled &&
    GalleryPerf.instance.coverMode.value == GalleryCoverMode.placeholder;

/// Desktop grids show more decoded covers at once and on the return path.
/// Keep Android's existing budget and never reduce a previously enlarged cache.
void configureGalleryDecodedImageCache(
  ImageCache cache, {
  required bool desktop,
}) {
  const desktopBudget = 160 * 1024 * 1024;
  if (desktop && cache.maximumSizeBytes < desktopBudget) {
    cache.maximumSizeBytes = desktopBudget;
  }
}

/// Persistent, content-addressed thumbnails for library cards.
///
/// Original media remain the source of truth. The app cache is disposable and
/// can be rebuilt safely when the operating system clears it.
class ImageThumbnailCache {
  ImageThumbnailCache._();

  static String? _cacheRootOverride;
  static String? _resolvedCacheRoot;
  static final Map<String, ImageThumbnailStore> _stores = {};
  static Future<String>? _cacheRootFlight;

  static void configureCacheRoot(String root) {
    _cacheRootOverride =
        '$root${Platform.pathSeparator}cache${Platform.pathSeparator}image_thumbnails';
    _stores.clear();
    _resolvedCacheRoot = _cacheRootOverride;
    _cacheRootFlight = Future<String>.value(_cacheRootOverride);
  }

  static Future<String> _cacheRoot() => _cacheRootFlight ??= PreviewPerfScope()
      .async(GalleryMetric.cacheRoot, () async {
        final override = _cacheRootOverride;
        if (override != null) return override;
        final cacheDirectory = await getApplicationCacheDirectory();
        return _resolvedCacheRoot =
            '${cacheDirectory.path}'
            '${Platform.pathSeparator}squid_album'
            '${Platform.pathSeparator}image_thumbnails';
      });

  static Future<ImageThumbnailStore> store({String? cacheRoot}) async {
    final root = cacheRoot ?? await _cacheRoot();
    return _stores.putIfAbsent(root, () => ImageThumbnailStore(root));
  }

  /// Uses only an existing store; returning cards never wait for a cache hit.
  static Uint8List? peek(MediaAsset asset, {String? cacheRoot}) {
    final root = cacheRoot ?? _cacheRootOverride ?? _resolvedCacheRoot;
    return root == null ? null : _stores[root]?.peek(asset);
  }

  static Future<Uint8List?> ensure(
    MediaAsset asset, {
    String? cacheRoot,
  }) async => (await store(cacheRoot: cacheRoot)).ensure(asset);

  static Future<PreviewRequest<Uint8List>?> request(
    MediaAsset asset, {
    String? cacheRoot,
    bool urgent = true,
  }) async {
    if (_placeholderCovers) return null;
    return (await store(cacheRoot: cacheRoot)).request(asset, urgent: urgent);
  }

  static Future<void> prefetch(
    Iterable<MediaAsset> assets, {
    String? cacheRoot,
  }) async {
    if (_placeholderCovers) return;
    await prefetchAppliedMediaSources(
      assets.map(
        (asset) => (
          sha256: asset.sha256,
          storagePath: asset.storagePath,
          kind: asset.kind,
        ),
      ),
      cacheRoot: cacheRoot,
    );
  }

  /// Warms exact media returned by a successful device-sync apply page.
  ///
  /// The page is bounded by Rust; do not accumulate the entire sync result in
  /// memory here. Paths are consumed only by the cache layer and never logged.
  static Future<void> prefetchAppliedMediaEntries(
    List<device_sync.AppliedMediaCacheEntry> entries, {
    String? cacheRoot,
  }) => prefetchAppliedMediaSources(
    entries.map(
      (entry) => (
        sha256: entry.sha256,
        storagePath: entry.storagePath,
        kind: entry.kind,
      ),
    ),
    cacheRoot: cacheRoot,
  );

  static Future<void> prefetchAppliedMediaSources(
    Iterable<({String sha256, String storagePath, MediaKind kind})> sources, {
    String? cacheRoot,
  }) async {
    if (_placeholderCovers) return;
    final images = <({String sha256, String storagePath})>[];
    final videos = <({String sha256, String storagePath})>[];
    for (final source in sources) {
      switch (source.kind) {
        case MediaKind.image:
          images.add((sha256: source.sha256, storagePath: source.storagePath));
          break;
        case MediaKind.video:
          videos.add((sha256: source.sha256, storagePath: source.storagePath));
          break;
      }
    }
    await Future.wait([
      if (images.isNotEmpty)
        store(cacheRoot: cacheRoot)
            .then((store) => store.prefetchSources(images)),
      if (videos.isNotEmpty) VideoThumbnailCache.prefetchSources(videos),
    ]);
  }

  static Future<void> prefetchImportedImages(
    AppBackend backend,
    BigInt importedCount, {
    required DateTime importedSince,
    String? cacheRoot,
  }) async {
    if (_placeholderCovers || importedCount <= BigInt.zero) return;
    try {
      final importedUntil = DateTime.now().toUtc().add(
        const Duration(seconds: 1),
      );
      GalleryCursor? cursor;
      while (true) {
        final query = GalleryQuery(
          kind: GalleryKindFilter.all,
          limit: 60,
          offset: 0,
          favoriteOnly: false,
          newestFirst: true,
          gameNames: const [],
          importedFrom: importedSince.toUtc(),
          importedUntil: importedUntil,
        );
        final page = await backend.listMediaPage(
          GalleryPageRequest(
            query: query,
            cursor: cursor,
            direction: GalleryPageDirection.forward,
          ),
        );
        if (page.items.isEmpty) break;
        await prefetch(page.items, cacheRoot: cacheRoot);
        if (!page.hasAfter || page.afterCursor == null) break;
        if (page.afterCursor == cursor ||
            page.afterCursor?.mediaId == cursor?.mediaId) {
          break;
        }
        cursor = page.afterCursor;
      }
    } catch (_) {
      // Cache warming is optional; a failed query must not affect imports.
    }
  }
}

class ImageThumbnailStore {
  ImageThumbnailStore(
    this.cacheRoot, {
    this.prefetchQueueLimit = 256,
    GalleryPerf? diagnostics,
    Future<Uint8List?> Function(String storagePath)? generateThumbnail,
  }) : _diagnostics = diagnostics ?? GalleryPerf.instance,
       _thumbnailGenerator = generateThumbnail,
       assert(prefetchQueueLimit > 0);

  static const _prefetchConcurrency = 2;
  // Keep a typical large gallery warm when the user scrolls back.
  static const _memoryCacheMaxEntries = 1024;
  static final Map<String, Future<void>> _publicationGates = {};

  final String cacheRoot;
  final int prefetchQueueLimit;
  final GalleryPerf _diagnostics;
  final Future<Uint8List?> Function(String storagePath)? _thumbnailGenerator;
  late final PreviewCache<Uint8List> _memory = PreviewCache<Uint8List>(
    maxEntries: _memoryCacheMaxEntries,
    maxBytes: 32 * 1024 * 1024,
    sizeOf: (bytes) => bytes.length,
    maxConcurrent: 2,
    memoryHitMetric: GalleryMetric.imageMemoryHit,
    diagnostics: _diagnostics,
    admission: GalleryLoadExperiment.instance.admission,
  );
  final LinkedHashMap<String, ({String sha256, String storagePath})>
  _prefetchQueue =
      LinkedHashMap<String, ({String sha256, String storagePath})>();
  final Set<String> _prefetchActive = {};
  Completer<void>? _prefetchDrainCompleter;
  final Set<String> _diskCacheHashes = {};
  final Set<String> _legacyCheckedHashes = {};
  Future<void>? _diskCacheIndexFlight;
  Future<void>? _rootReady;
  bool _diskCacheIndexLoaded = false;
  int _diskCacheReadCount = 0;
  int _cacheDirectoryScanCount = 0;
  bool _prefetchAdmissionListening = false;

  @visibleForTesting
  int get pendingPrefetchCount => _prefetchQueue.length;

  @visibleForTesting
  List<String> get pendingPrefetchHashes =>
      List.unmodifiable(_prefetchQueue.keys);

  @visibleForTesting
  int get diskCacheReadCount => _diskCacheReadCount;

  @visibleForTesting
  int get cacheDirectoryScanCount => _cacheDirectoryScanCount;

  Future<void> _ensureDiskCacheIndex() {
    if (_diskCacheIndexLoaded) return Future<void>.value();
    final perf = PreviewPerfScope(_diagnostics);
    return _diskCacheIndexFlight ??= perf
        .async(GalleryMetric.diskIndex, () async {
          final root = Directory(cacheRoot);
          final hashes = <String>{};
          try {
            if (await perf.async(GalleryMetric.cacheStat, root.exists)) {
              _cacheDirectoryScanCount++;
              await for (final entity in root.list(followLinks: false)) {
                if (entity is! File) continue;
                final name = entity.uri.pathSegments.last;
                final match = _thumbnailCacheFilePattern.firstMatch(name);
                if (match != null) {
                  hashes.add(match.group(1)!.toLowerCase());
                }
              }
            }
          } catch (_) {
            // A failed index only disables the optimization; visible reads still
            // validate and repair their own cache files.
          }
          _diskCacheHashes.addAll(hashes);
          _diskCacheIndexLoaded = true;
        })
        .whenComplete(() => _diskCacheIndexFlight = null);
  }

  Future<void> cleanupLegacy({
    int maxFiles = 16,
    required Set<String> verifiedHashes,
    PreviewPerfScope? diagnostics,
  }) {
    final perf = diagnostics ?? PreviewPerfScope(_diagnostics);
    return perf.async(GalleryMetric.cacheCleanup, () async {
      var removed = 0;
      for (final value in verifiedHashes) {
        if (removed >= maxFiles) break;
        if (!_validHash(value)) continue;
        final sha = value.toLowerCase();
        if (!_legacyCheckedHashes.add(sha)) continue;
        final current = File(_cachePath(sha));
        final legacy = File(
          '$cacheRoot${Platform.pathSeparator}${sha}_v1_512.jpg',
        );
        try {
          if (await perf.async(GalleryMetric.cacheStat, current.exists) &&
              await perf.async(GalleryMetric.cacheStat, legacy.exists)) {
            await legacy.delete();
            removed++;
          }
        } catch (_) {
          _legacyCheckedHashes.remove(sha);
        }
      }
    });
  }

  String _cachePath(String sha256) =>
      '$cacheRoot${Platform.pathSeparator}$sha256'
      '_${_thumbnailVersion}_$_thumbnailMaxEdge.jpg';

  Uint8List? peek(MediaAsset asset) =>
      asset.kind == MediaKind.image ? _memory.peek(asset.sha256) : null;

  PreviewRequest<Uint8List>? request(MediaAsset asset, {bool urgent = true}) {
    if (_placeholderCovers ||
        asset.kind != MediaKind.image ||
        !_validHash(asset.sha256)) {
      return null;
    }
    return _requestSource(asset.sha256, asset.storagePath, urgent: urgent);
  }

  PreviewRequest<Uint8List>? _requestSource(
    String sha256,
    String storagePath, {
    required bool urgent,
  }) {
    if (urgent && _prefetchQueue.remove(sha256) != null) {
      _schedulePrefetch();
    }
    return _memory.request(
      sha256,
      load: (work) => _loadOrCreate(sha256, storagePath, work),
      urgent: urgent,
    );
  }

  Future<Uint8List?> ensure(MediaAsset asset) {
    final pending = request(asset);
    if (pending == null) return Future.value();
    return pending.future.whenComplete(pending.cancel);
  }

  /// Queues newly imported images without doing decoding on the UI isolate.
  /// Visible card requests are promoted ahead of this bounded background work.
  Future<void> prefetch(Iterable<MediaAsset> assets) => prefetchSources(
    assets
        .where((asset) => asset.kind == MediaKind.image)
        .map((asset) => (sha256: asset.sha256, storagePath: asset.storagePath)),
  );

  Future<void> prefetchSources(
    Iterable<({String sha256, String storagePath})> sources,
  ) {
    if (_placeholderCovers) return Future<void>.value();
    for (final source in sources) {
      if (!_validHash(source.sha256) ||
          _memory.peek(source.sha256) != null ||
          _diskCacheHashes.contains(source.sha256.toLowerCase()) ||
          _prefetchActive.contains(source.sha256) ||
          _prefetchQueue.containsKey(source.sha256)) {
        _diagnostics.increment(GalleryMetric.prefetchSkipped);
        continue;
      }
      if (_prefetchQueue.length >= prefetchQueueLimit) {
        _prefetchQueue.remove(_prefetchQueue.keys.first);
      }
      _prefetchQueue.putIfAbsent(source.sha256, () => source);
      _diagnostics.increment(GalleryMetric.prefetchQueued);
    }
    if (_prefetchQueue.isEmpty && _prefetchActive.isEmpty) {
      return Future<void>.value();
    }
    _diagnostics.sample(GalleryMetric.prefetchDepth, _prefetchQueue.length);
    final drain = _prefetchDrainCompleter ??= Completer<void>();
    _schedulePrefetch();
    return drain.future;
  }

  void _schedulePrefetch() {
    final gate = GalleryLoadExperiment.instance.admission;
    final paused =
        gate.value != GalleryWorkAdmission.all && _prefetchQueue.isNotEmpty;
    if (paused != _prefetchAdmissionListening) {
      _prefetchAdmissionListening = paused;
      if (paused) {
        gate.addListener(_schedulePrefetch);
      } else {
        gate.removeListener(_schedulePrefetch);
      }
    }
    if (paused) return;
    if (_prefetchQueue.isEmpty) {
      _completePrefetchIfIdle();
      return;
    }
    final diagnostics = PreviewPerfScope(_diagnostics);
    if (_diskCacheIndexLoaded) {
      _removeDiskCachedPrefetchItems(diagnostics);
      _pumpPrefetch();
      _completePrefetchIfIdle();
    } else if (_prefetchQueue.isNotEmpty) {
      unawaited(_ensureDiskCacheIndex().then((_) => _schedulePrefetch()));
    }
  }

  void _removeDiskCachedPrefetchItems(PreviewPerfScope diagnostics) {
    final previous = _prefetchQueue.length;
    _prefetchQueue.removeWhere(
      (sha, _) => _diskCacheHashes.contains(sha.toLowerCase()),
    );
    diagnostics.increment(
      GalleryMetric.prefetchSkipped,
      previous - _prefetchQueue.length,
    );
  }

  void _completePrefetchIfIdle() {
    if (_prefetchQueue.isNotEmpty || _prefetchActive.isNotEmpty) return;
    final drain = _prefetchDrainCompleter;
    _prefetchDrainCompleter = null;
    if (drain != null && !drain.isCompleted) drain.complete();
  }

  Future<void> _ensureCacheDirectory() {
    final existing = _rootReady;
    if (existing != null) return existing;
    late final Future<void> creating;
    creating = Directory(cacheRoot).create(recursive: true).then<void>((_) {});
    _rootReady = creating;
    return creating.catchError((Object error, StackTrace stack) {
      if (identical(_rootReady, creating)) _rootReady = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  void _pumpPrefetch() {
    if (GalleryLoadExperiment.instance.admission.value !=
        GalleryWorkAdmission.all) {
      if (_prefetchQueue.isNotEmpty) _schedulePrefetch();
      return;
    }
    if (_placeholderCovers) {
      _prefetchQueue.clear();
      _completePrefetchIfIdle();
      return;
    }
    if (!_diskCacheIndexLoaded) return;
    while (_prefetchActive.length < _prefetchConcurrency &&
        _prefetchQueue.isNotEmpty) {
      final sha = _prefetchQueue.keys.first;
      final source = _prefetchQueue.remove(sha)!;
      _prefetchActive.add(sha);
      unawaited(() async {
        final pending = _requestSource(
          source.sha256,
          source.storagePath,
          urgent: false,
        );
        try {
          await pending?.future;
        } catch (_) {
          // A missing or unsupported source must not block other imports.
        } finally {
          pending?.cancel();
          _prefetchActive.remove(sha);
          if (_prefetchQueue.isNotEmpty) {
            _schedulePrefetch();
          } else if (_prefetchActive.isEmpty) {
            _completePrefetchIfIdle();
          }
        }
      }());
    }
  }

  Future<Uint8List?> _loadOrCreate(
    String sha256,
    String storagePath,
    PreviewWork work,
  ) async {
    final perf = work.diagnostics;
    await perf.async(GalleryMetric.cacheRoot, _ensureCacheDirectory);
    final target = File(_cachePath(sha256));
    if (work.cancelled) return null;

    if (await perf.async(GalleryMetric.cacheStat, target.exists)) {
      _diskCacheHashes.add(sha256.toLowerCase());
      _diskCacheReadCount++;
      final cached = await perf.async(
        GalleryMetric.diskRead,
        target.readAsBytes,
      );
      perf.increment(GalleryMetric.diskBytes, cached.length);
      if (_isJpeg(cached)) {
        perf.increment(GalleryMetric.imageDiskHit);
        await cleanupLegacy(
          maxFiles: 1,
          verifiedHashes: {sha256},
          diagnostics: perf,
        );
        return cached;
      }
      // Repair is published under the shared target gate below. Do not delete
      // here: another store may have replaced the bytes we just found corrupt.
      _diskCacheHashes.remove(sha256.toLowerCase());
    }
    if (work.cancelled) return null;
    perf
      ..increment(GalleryMetric.diskMiss)
      ..increment(GalleryMetric.imageGenerate);

    final generator = _thumbnailGenerator;
    final generated = await perf.async(
      GalleryMetric.imageGenerate,
      () => generator == null
          ? compute(_generateImageThumbnail, <Object>[
              storagePath,
              _thumbnailMaxEdge,
              _thumbnailQuality,
              perf.current,
            ], debugLabel: 'image-thumbnail')
          : generator(storagePath)
                .then((bytes) => _GeneratedImageThumbnail(bytes, const {}, 0)),
    );
    if (perf.current) {
      for (final entry in generated.timings.entries) {
        perf.sample(entry.key, entry.value);
      }
      if (generated.originalBytes > 0) {
        perf
          ..increment(GalleryMetric.originalRead)
          ..increment(GalleryMetric.originalBytes, generated.originalBytes);
      }
    }
    final bytes = generated.bytes;
    if (bytes == null || bytes.isEmpty) return null;
    if (!_isJpeg(bytes)) {
      throw const FormatException('Generated image thumbnail is not JPEG');
    }

    // The original read/compute has already finished. Keep this valid derived
    // result on disk even if its last scrolling consumer left meanwhile; a new
    // consumer can reuse it without decoding the original again. PreviewCache
    // still returns null and refuses LRU retention for the cancelled request.
    final published = await _publishThumbnail(target, bytes, perf);
    if (published) {
      perf.increment(GalleryMetric.cacheBytes, bytes.length);
      if (work.cancelled) {
        perf.increment(GalleryMetric.cachedAfterCancel);
      }
    }
    _diskCacheHashes.add(sha256.toLowerCase());
    await cleanupLegacy(
      maxFiles: 1,
      verifiedHashes: {sha256},
      diagnostics: perf,
    );
    return bytes;
  }

  Future<bool> _publishThumbnail(
    File target,
    Uint8List bytes,
    PreviewPerfScope perf,
  ) async {
    final absolute = p.normalize(p.absolute(target.path));
    final key = Platform.isWindows ? absolute.toLowerCase() : absolute;
    final previous = _publicationGates[key];
    final gate = Completer<void>();
    _publicationGates[key] = gate.future;
    try {
      return await perf.async(GalleryMetric.cacheWrite, () async {
        if (previous != null) await previous;
        if (await perf.async(GalleryMetric.cacheStat, target.exists)) {
          final existing = await perf.async(
            GalleryMetric.diskRead,
            target.readAsBytes,
          );
          perf.increment(GalleryMetric.diskBytes, existing.length);
          // A late cancelled computation must not remove a newer valid cover.
          if (_isJpeg(existing)) return false;
        }
        final temporary = File(
          '${target.path}.${DateTime.now().microsecondsSinceEpoch}.part',
        );
        try {
          await temporary.writeAsBytes(bytes, flush: true);
          // Same-directory rename publishes complete bytes. A corrupt cache
          // can be replaced, but an already-valid target is never removed.
          await temporary.rename(target.path);
          return true;
        } finally {
          if (await perf.async(GalleryMetric.cacheStat, temporary.exists)) {
            await perf.async(GalleryMetric.cacheCleanup, temporary.delete);
          }
        }
      });
    } finally {
      gate.complete();
      if (identical(_publicationGates[key], gate.future)) {
        _publicationGates.remove(key);
      }
    }
  }
}

class _GeneratedImageThumbnail {
  const _GeneratedImageThumbnail(this.bytes, this.timings, this.originalBytes);
  final Uint8List? bytes;
  final Map<GalleryMetric, int> timings;
  final int originalBytes;
}

Future<_GeneratedImageThumbnail> _generateImageThumbnail(
  List<Object> arguments,
) async {
  final source = File(arguments[0] as String);
  final maxEdge = arguments[1] as int;
  final quality = arguments[2] as int;
  final recording = arguments[3] as bool;
  final timings = <GalleryMetric, int>{};
  T timed<T>(GalleryMetric metric, T Function() work) {
    if (!recording) return work();
    final watch = Stopwatch()..start();
    try {
      return work();
    } finally {
      timings[metric] = watch.elapsedMicroseconds;
    }
  }

  final statWatch = recording ? (Stopwatch()..start()) : null;
  final exists = await source.exists();
  if (statWatch != null) {
    timings[GalleryMetric.cacheStat] = statWatch.elapsedMicroseconds;
  }
  if (!exists) return _GeneratedImageThumbnail(null, timings, 0);
  final readWatch = recording ? (Stopwatch()..start()) : null;
  final original = await source.readAsBytes();
  if (readWatch != null) {
    timings[GalleryMetric.originalRead] = readWatch.elapsedMicroseconds;
  }
  final decoded = timed(
    GalleryMetric.imageDecode,
    () => image.decodeImage(original),
  );
  if (decoded == null) {
    return _GeneratedImageThumbnail(null, timings, original.length);
  }
  final upright = timed(
    GalleryMetric.imageOrient,
    () => image.bakeOrientation(decoded),
  );
  final longEdge = math.max(upright.width, upright.height);
  final resized = timed(
    GalleryMetric.imageResize,
    () => longEdge <= maxEdge
        ? upright
        : upright.width >= upright.height
        ? image.copyResize(
            upright,
            width: maxEdge,
            interpolation: image.Interpolation.average,
          )
        : image.copyResize(
            upright,
            height: maxEdge,
            interpolation: image.Interpolation.average,
          ),
  );
  final encoded = timed(
    GalleryMetric.imageEncode,
    () => Uint8List.fromList(image.encodeJpg(resized, quality: quality)),
  );
  return _GeneratedImageThumbnail(encoded, timings, original.length);
}

bool _validHash(String value) =>
    value.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(value);

bool _isJpeg(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0xff &&
    bytes[1] == 0xd8 &&
    bytes[bytes.length - 2] == 0xff &&
    bytes[bytes.length - 1] == 0xd9;

class ImageThumbnail extends StatefulWidget {
  const ImageThumbnail({
    super.key,
    required this.asset,
    this.fit = BoxFit.cover,
    this.placeholder = const SizedBox.expand(),
    this.cacheRoot,
  });

  final MediaAsset asset;
  final BoxFit fit;
  final Widget placeholder;
  final String? cacheRoot;

  @override
  State<ImageThumbnail> createState() => _ImageThumbnailState();
}

class _ImageThumbnailState extends State<ImageThumbnail> {
  PreviewRequest<Uint8List>? request;
  Future<Uint8List?>? bytes;
  Uint8List? initialBytes;
  int _generation = 0;
  GalleryDragLoadController? _drag;
  bool _initialized = false;
  bool _waitingForDrag = false;
  int? _resumeTicket;

  @override
  void initState() {
    super.initState();
    if (GalleryPerf.instance.enabled) {
      GalleryPerf.instance.coverMode.addListener(_coverModeChanged);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _drag = GalleryPreviewLoadScope.maybeOf(context);
    if (!_initialized || (_waitingForDrag && _drag?.defer != true)) {
      _initialized = true;
      _load();
    }
  }

  void _coverModeChanged() {
    if (mounted) setState(_load);
  }

  @override
  void didUpdateWidget(ImageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.sha256 != widget.asset.sha256 ||
        oldWidget.asset.kind != widget.asset.kind ||
        oldWidget.asset.storagePath != widget.asset.storagePath ||
        oldWidget.cacheRoot != widget.cacheRoot) {
      _load();
    }
  }

  void _load() {
    _resumeTicket = GalleryPerf.instance.previewTicket(
      thumbActive: _drag?.held == true && _drag?.hasMoved == true,
      resumed: _waitingForDrag,
    );
    final generation = ++_generation;
    request?.cancel();
    request = null;
    bytes = null;
    initialBytes = ImageThumbnailCache.peek(
      widget.asset,
      cacheRoot: widget.cacheRoot,
    );
    _waitingForDrag = _drag?.defer == true;
    if (_waitingForDrag) {
      GalleryPerf.instance.increment(GalleryMetric.dragDeferred);
      return;
    }
    if (_placeholderCovers) {
      initialBytes = null;
      return;
    }
    if (widget.asset.kind != MediaKind.image) return;
    unawaited(() async {
      try {
        final next = await ImageThumbnailCache.request(
          widget.asset,
          cacheRoot: widget.cacheRoot,
          urgent: true,
        );
        if (!mounted || generation != _generation) {
          next?.cancel();
          return;
        }
        setState(() {
          request = next;
          bytes = next?.future;
        });
      } catch (_) {
        if (mounted && generation == _generation) {
          setState(() => bytes = Future.value());
        }
      }
    }());
  }

  @override
  void dispose() {
    if (GalleryPerf.instance.enabled) {
      GalleryPerf.instance.coverMode.removeListener(_coverModeChanged);
    }
    request?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_placeholderCovers) return widget.placeholder;
    return FutureBuilder<Uint8List?>(
      key: ValueKey((
        widget.asset.sha256,
        widget.asset.kind,
        widget.asset.storagePath,
        widget.cacheRoot,
      )),
      future: bytes,
      initialData: initialBytes,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null || data.isEmpty) return widget.placeholder;
        return galleryPerfImageMemory(
          data,
          fit: widget.fit,
          cacheWidth: _thumbnailMaxEdge,
          resumeTicket: _resumeTicket,
          placeholder: widget.placeholder,
        );
      },
    );
  }
}
