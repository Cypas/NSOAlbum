import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:image/image.dart' as image;
import 'package:path_provider/path_provider.dart';

import '../rust/models.dart';
import 'gallery_perf.dart';
import 'gallery_drag_loading.dart';
import 'video_preview_cache.dart';

const _videoThumbnailVersion = 'v6';
const _videoThumbnailMaxEdge = 1024;
const _videoThumbnailQuality = 92;
const _videoThumbnailPrefetchConcurrency = 1;
const _videoThumbnailPrefetchQueueLimit = 256;

bool get _placeholderCovers =>
    GalleryPerf.instance.enabled &&
    GalleryPerf.instance.coverMode.value == GalleryCoverMode.placeholder;

class VideoThumbnailData {
  const VideoThumbnailData({
    this.bytes,
    this.duration = Duration.zero,
    this.needsUpgrade = false,
  });

  final Uint8List? bytes;
  final Duration duration;
  final bool needsUpgrade;
}

class VideoThumbnailCache {
  static const decodeWidth = _videoThumbnailMaxEdge;
  static final _memory = PreviewCache<VideoThumbnailData>(
    maxEntries: 1024,
    maxBytes: 32 * 1024 * 1024,
    sizeOf: (data) => data.bytes?.length ?? 0,
    maxConcurrent: 2,
    memoryHitMetric: GalleryMetric.videoMemoryHit,
    admission: GalleryLoadExperiment.instance.admission,
  );
  static String? _cacheRootOverride;
  static Future<String>? _cacheRootFlight;
  static final _cachedReads = <String, Future<VideoThumbnailData>>{};
  static String _legacyKey(String sha) => 'legacy:$sha';
  static VideoThumbnailData? _peek(String sha) =>
      _memory.peek(sha) ?? _memory.peek(_legacyKey(sha));
  static final LinkedHashMap<String, ({String sha256, String storagePath})>
  _prefetchQueue =
      LinkedHashMap<String, ({String sha256, String storagePath})>();
  static final Set<String> _prefetchActive = {};
  static Completer<void>? _prefetchDrainCompleter;
  static Future<void> Function(Object, StackTrace)? _prefetchOnError;
  static int _prefetchQueueLimit = _videoThumbnailPrefetchQueueLimit;
  static bool _prefetchAdmissionListening = false;

  @visibleForTesting
  static int get pendingPrefetchCount => _prefetchQueue.length;

  @visibleForTesting
  static List<String> get pendingPrefetchHashes =>
      List.unmodifiable(_prefetchQueue.keys);

  static String thumbnailPath({
    required String cacheRoot,
    required String sha256,
  }) =>
      '$cacheRoot${Platform.pathSeparator}${sha256}_$_videoThumbnailVersion'
      '_$_videoThumbnailMaxEdge.jpg';

  @visibleForTesting
  static Future<Uint8List?> compactBytesForTesting(Uint8List bytes) => compute(
    _compactVideoThumbnail,
    <Object>[bytes, _videoThumbnailMaxEdge, _videoThumbnailQuality],
  );

  /// Cache-only neighbor warming: no FFmpeg jobs or original video reads.
  /// Active file reads are bounded and their callers can stop scheduling more.
  static Future<void> warmCached(MediaAsset asset) async {
    final perf = PreviewPerfScope();
    if (_placeholderCovers) return;
    if (_peek(asset.sha256) != null) return;
    final data = await readExisting(asset, diagnostics: perf);
    // A cover-only warm must not suppress the first real duration probe.
    if (data.bytes?.isNotEmpty == true && data.duration > Duration.zero) {
      _memory.seed(
        data.needsUpgrade ? _legacyKey(asset.sha256) : asset.sha256,
        data,
        diagnostics: perf,
      );
    }
  }

  static Future<VideoThumbnailData> readExisting(
    MediaAsset asset, {
    PreviewPerfScope? diagnostics,
  }) async {
    final perf = diagnostics ?? PreviewPerfScope();
    if (_placeholderCovers) return const VideoThumbnailData();
    if (_peek(asset.sha256) case final cached?) return cached;
    final root = await perf.async(GalleryMetric.cacheRoot, _cacheRoot);
    return readCachedFiles(
      cacheRoot: root,
      sha256: asset.sha256,
      diagnostics: perf,
    );
  }

  /// Test-only seeding entry that mirrors a gallery card warm.
  @visibleForTesting
  static void seedForTest(String sha256, VideoThumbnailData data) =>
      _memory.seed(sha256, data);

  static void configureCacheRoot(String root) {
    _cacheRootOverride =
        '$root${Platform.pathSeparator}cache${Platform.pathSeparator}video_thumbnails';
    _cacheRootFlight = Future.value(_cacheRootOverride);
  }

  static Future<String> _cacheRoot() => _cacheRootFlight ??= PreviewPerfScope()
      .async(GalleryMetric.cacheRoot, () async {
        final override = _cacheRootOverride;
        if (override != null) return override;
        final cache = await getApplicationCacheDirectory();
        return '${cache.path}${Platform.pathSeparator}squid_album'
            '${Platform.pathSeparator}video_thumbnails';
      });

  /// Returns a cached thumbnail without touching disk or starting FFmpeg.
  static VideoThumbnailData? peek(MediaAsset asset) => _peek(asset.sha256);

  /// Memory-only first-frame cover lookup that tolerates incomplete data.
  ///
  /// Gallery cards warm the cache with cover bytes but may not have probed the
  /// duration yet, so [peek] alone can miss entries. Unlike [peek] this still
  /// returns bytes-only data, and it never touches disk or FFmpeg.
  static VideoThumbnailData? peekCover(MediaAsset asset) {
    final cached = _peek(asset.sha256);
    if (cached == null) return null;
    if (cached.bytes?.isNotEmpty != true && cached.duration <= Duration.zero) {
      return null;
    }
    return cached;
  }

  static Future<VideoThumbnailData> readCachedFiles({
    required String cacheRoot,
    required String sha256,
    PreviewPerfScope? diagnostics,
  }) {
    final key = '$cacheRoot${Platform.pathSeparator}$sha256';
    return _cachedReads[key] ??=
        _readCachedFiles(
          cacheRoot: cacheRoot,
          sha256: sha256,
          diagnostics: diagnostics,
        ).whenComplete(() {
          _cachedReads.remove(key);
        });
  }

  static Future<VideoThumbnailData> _readCachedFiles({
    required String cacheRoot,
    required String sha256,
    PreviewPerfScope? diagnostics,
  }) async {
    final perf = diagnostics ?? PreviewPerfScope();
    if (_placeholderCovers) return const VideoThumbnailData();
    final thumbnail = File(thumbnailPath(cacheRoot: cacheRoot, sha256: sha256));
    final durationFile = File(
      '$cacheRoot${Platform.pathSeparator}$sha256.duration',
    );
    Uint8List? bytes;
    var needsUpgrade = false;
    if (await perf.async(GalleryMetric.cacheStat, thumbnail.exists)) {
      final cached = await perf.async(
        GalleryMetric.diskRead,
        thumbnail.readAsBytes,
      );
      perf.increment(GalleryMetric.diskBytes, cached.length);
      if (_isJpeg(cached)) {
        perf.increment(GalleryMetric.videoDiskHit);
        bytes = cached;
      } else {
        // Corrupt disposable bytes must not become the cover or keep a stale
        // failure marker from blocking a subsequent regeneration.
        try {
          await perf.async(GalleryMetric.cacheCleanup, thumbnail.delete);
        } catch (_) {
          // Cache cleanup is best effort; the invalid bytes remain ignored.
        }
        final failedFile = File(
          '$cacheRoot${Platform.pathSeparator}$sha256.failed',
        );
        try {
          if (await perf.async(GalleryMetric.cacheStat, failedFile.exists)) {
            await perf.async(GalleryMetric.cacheCleanup, failedFile.delete);
          }
        } catch (_) {
          // A marker is not needed to read the independently cached duration.
        }
      }
    }
    if (bytes == null) {
      // Reuse the former 1280px poster without reading the original video.
      final legacy = File('$cacheRoot${Platform.pathSeparator}$sha256.jpg');
      if (await perf.async(GalleryMetric.cacheStat, legacy.exists)) {
        final oldBytes = await perf.async(
          GalleryMetric.diskRead,
          legacy.readAsBytes,
        );
        perf.increment(GalleryMetric.diskBytes, oldBytes.length);
        bytes = await perf.async(
          GalleryMetric.videoCompact,
          () => compute(_compactVideoThumbnail, <Object>[
            oldBytes,
            _videoThumbnailMaxEdge,
            _videoThumbnailQuality,
          ]),
        );
        if (bytes != null && bytes.isNotEmpty) {
          await _writeAtomic(thumbnail, bytes, diagnostics: perf);
        }
      }
    }
    for (final suffix in const ['v5_768', 'v4_1024', 'v3_512', 'v2_256']) {
      if (bytes != null) break;
      final legacy = File(
        '$cacheRoot${Platform.pathSeparator}${sha256}_$suffix.jpg',
      );
      if (await perf.async(GalleryMetric.cacheStat, legacy.exists)) {
        final oldBytes = await perf.async(
          GalleryMetric.diskRead,
          legacy.readAsBytes,
        );
        perf.increment(GalleryMetric.diskBytes, oldBytes.length);
        if (_isJpeg(oldBytes)) {
          bytes = oldBytes;
          needsUpgrade = true;
          perf.increment(GalleryMetric.videoDiskHit);
        }
      }
    }
    if (bytes == null) perf.increment(GalleryMetric.diskMiss);
    final duration = await _readDuration(durationFile, perf);
    return VideoThumbnailData(
      bytes: bytes,
      duration: duration,
      needsUpgrade: needsUpgrade,
    );
  }

  /// Adds imported videos to a bounded, best-effort queue.
  ///
  /// Only one background FFmpeg job is admitted at a time. Visible requests
  /// still enter [_memory] as urgent work and may use its second worker.
  static Future<void> prefetch(
    Iterable<MediaAsset> assets, {
    required Future<void> Function(Object error, StackTrace stackTrace) onError,
    int? queueLimit,
  }) => prefetchSources(
    assets
        .where((asset) => asset.kind == MediaKind.video)
        .map((asset) => (sha256: asset.sha256, storagePath: asset.storagePath)),
    onError: onError,
    queueLimit: queueLimit,
  );

  static Future<void> prefetchSources(
    Iterable<({String sha256, String storagePath})> sources, {
    Future<void> Function(Object error, StackTrace stackTrace)? onError,
    int? queueLimit,
  }) {
    if (_placeholderCovers) return Future<void>.value();
    if (queueLimit != null) {
      _prefetchQueueLimit = queueLimit.clamp(
        1,
        _videoThumbnailPrefetchQueueLimit,
      );
    }
    if (onError != null) _prefetchOnError ??= onError;
    for (final source in sources) {
      if (!_validHash(source.sha256) ||
          _memory.peek(source.sha256) != null ||
          _prefetchActive.contains(source.sha256) ||
          _prefetchQueue.containsKey(source.sha256)) {
        GalleryPerf.instance.increment(GalleryMetric.prefetchSkipped);
        continue;
      }
      if (_prefetchQueue.length >= _prefetchQueueLimit) {
        _prefetchQueue.remove(_prefetchQueue.keys.first);
      }
      _prefetchQueue[source.sha256] = source;
      GalleryPerf.instance.increment(GalleryMetric.prefetchQueued);
    }
    if (_prefetchQueue.isEmpty && _prefetchActive.isEmpty) {
      return Future<void>.value();
    }
    GalleryPerf.instance.sample(
      GalleryMetric.prefetchDepth,
      _prefetchQueue.length,
    );
    final drain = _prefetchDrainCompleter ??= Completer<void>();
    _pumpPrefetch();
    return drain.future;
  }

  /// Keeps the existing bounded viewport warmup behavior for gallery pages.
  static void preload(
    Iterable<MediaAsset> assets, {
    required Future<void> Function(Object error, StackTrace stackTrace) onError,
    int limit = 64,
  }) {
    unawaited(
      prefetch(
        assets.where((item) => item.kind == MediaKind.video).take(limit),
        onError: onError,
      ),
    );
  }

  static void _pumpPrefetch() {
    final gate = GalleryLoadExperiment.instance.admission;
    final paused =
        gate.value != GalleryWorkAdmission.all && _prefetchQueue.isNotEmpty;
    if (paused != _prefetchAdmissionListening) {
      _prefetchAdmissionListening = paused;
      if (paused) {
        gate.addListener(_pumpPrefetch);
      } else {
        gate.removeListener(_pumpPrefetch);
      }
    }
    if (paused) return;
    if (_placeholderCovers) {
      _prefetchQueue.clear();
      if (_prefetchActive.isEmpty) {
        final drain = _prefetchDrainCompleter;
        _prefetchDrainCompleter = null;
        if (drain != null && !drain.isCompleted) drain.complete();
      }
      return;
    }
    while (_prefetchActive.length < _videoThumbnailPrefetchConcurrency &&
        _prefetchQueue.isNotEmpty) {
      final sha = _prefetchQueue.keys.first;
      final source = _prefetchQueue.remove(sha)!;
      _prefetchActive.add(sha);
      unawaited(() async {
        final pending = _requestSource(
          source.sha256,
          source.storagePath,
          onError: _prefetchOnError ?? (_, _) async {},
          urgent: false,
        );
        try {
          await pending.future;
        } catch (_) {
          // Thumbnail warming must not affect a completed import or sync.
        } finally {
          pending.cancel();
          _prefetchActive.remove(sha);
          if (_prefetchQueue.isNotEmpty) {
            _pumpPrefetch();
          } else if (_prefetchActive.isEmpty) {
            _prefetchOnError = null;
            final drain = _prefetchDrainCompleter;
            _prefetchDrainCompleter = null;
            if (drain != null && !drain.isCompleted) drain.complete();
          }
        }
      }());
    }
  }

  static bool shouldRetryFailureMarker(String marker) =>
      !marker.trimLeft().startsWith('$_videoThumbnailVersion:');

  static Future<VideoThumbnailData> load(
    MediaAsset asset, {
    required Future<void> Function(Object error, StackTrace stackTrace) onError,
    bool urgent = true,
  }) {
    final pending = request(asset, onError: onError, urgent: urgent);
    return pending.future
        .then((data) => data ?? const VideoThumbnailData())
        .whenComplete(pending.cancel);
  }

  static PreviewRequest<VideoThumbnailData> request(
    MediaAsset asset, {
    required Future<void> Function(Object, StackTrace) onError,
    bool urgent = false,
  }) => _requestSource(
    asset.sha256,
    asset.storagePath,
    onError: onError,
    urgent: urgent,
  );

  static PreviewRequest<VideoThumbnailData> _requestSource(
    String sha256,
    String storagePath, {
    required Future<void> Function(Object, StackTrace) onError,
    required bool urgent,
  }) {
    if (_placeholderCovers) return PreviewRequest(Future.value());
    if (urgent && _prefetchQueue.remove(sha256) != null) {
      _pumpPrefetch();
    }
    final pending = _memory.request(
      sha256,
      urgent: urgent,
      load: (work) async {
        try {
          final data = await _loadOrCreate(sha256, storagePath, work);
          if (data.needsUpgrade) return null;
          return data.bytes?.isNotEmpty == true || data.duration > Duration.zero
              ? data
              : null;
        } catch (error, stack) {
          if (!work.cancelled) {
            work.diagnostics.increment(GalleryMetric.failed);
            try {
              await onError(error, stack);
            } catch (_) {}
          }
          return null;
        }
      },
    );
    var cancelled = false;
    return PreviewRequest(
      pending.future.then(
        (data) => cancelled ? null : data ?? _memory.peek(_legacyKey(sha256)),
      ),
      () {
        cancelled = true;
        pending.cancel();
      },
    );
  }

  static Future<FFmpegSession> _extract(
    List<String> arguments,
    PreviewWork work,
  ) async {
    final done = Completer<FFmpegSession>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      arguments,
      (session) => done.complete(session),
    );
    final id = session.getSessionId();
    // Never call the plugin's global cancel: other editing tasks may be active.
    if (id != null) {
      work.onCancel = () => unawaited(FFmpegKit.cancel(id).catchError((_) {}));
    }
    try {
      return await done.future;
    } finally {
      work.onCancel = null;
    }
  }

  static Future<VideoThumbnailData> _loadOrCreate(
    String sha256,
    String storagePath,
    PreviewWork work,
  ) async {
    final perf = work.diagnostics;
    if (work.cancelled) {
      return const VideoThumbnailData();
    }
    final separator = Platform.pathSeparator;
    final cacheRoot = Directory(
      await perf.async(GalleryMetric.cacheRoot, _cacheRoot),
    );
    final thumbnail = File(
      thumbnailPath(cacheRoot: cacheRoot.path, sha256: sha256),
    );
    final durationFile = File('${cacheRoot.path}$separator$sha256.duration');
    final failedFile = File('${cacheRoot.path}$separator$sha256.failed');
    final cached = await readCachedFiles(
      cacheRoot: cacheRoot.path,
      sha256: sha256,
      diagnostics: perf,
    );
    if (work.cancelled) return cached;
    if (cached.needsUpgrade) {
      _memory.seed(_legacyKey(sha256), cached, diagnostics: perf);
    }
    if (cached.bytes != null &&
        cached.duration > Duration.zero &&
        !cached.needsUpgrade) {
      return cached;
    }
    if (!await perf.async(GalleryMetric.cacheStat, File(storagePath).exists) ||
        work.cancelled) {
      return cached;
    }
    await perf.async(
      GalleryMetric.cacheRoot,
      () => cacheRoot.create(recursive: true),
    );
    if (await perf.async(GalleryMetric.cacheStat, failedFile.exists)) {
      final marker = await perf.async(
        GalleryMetric.diskRead,
        failedFile.readAsString,
      );
      if (!shouldRetryFailureMarker(marker)) {
        // Cache the bytes-only cover so later opens can show it instantly
        // instead of re-probing the file for the same failed result.
        if (cached.bytes?.isNotEmpty == true) {
          _memory.seed(
            cached.needsUpgrade ? _legacyKey(sha256) : sha256,
            cached,
            diagnostics: perf,
          );
        }
        return cached;
      }
      await perf.async(GalleryMetric.cacheCleanup, failedFile.delete);
    }

    try {
      var duration = cached.duration;
      if (duration == Duration.zero) {
        try {
          perf.increment(GalleryMetric.videoProbe);
          final information = await perf.async(
            GalleryMetric.videoProbe,
            () => FFprobeKit.getMediaInformation(storagePath),
          );
          final seconds = double.tryParse(
            information.getMediaInformation()?.getDuration() ?? '',
          );
          if (seconds != null && seconds.isFinite && seconds > 0) {
            duration = Duration(
              microseconds: (seconds * Duration.microsecondsPerSecond).round(),
            );
          }
        } catch (_) {
          // Frame extraction below may still succeed without metadata.
        }
      }
      if (work.cancelled) return cached;
      Uint8List? bytes = cached.needsUpgrade ? null : cached.bytes;
      if (bytes == null || bytes.isEmpty) {
        final positions = _thumbnailPositions(duration);
        for (final position in positions) {
          if (work.cancelled) return cached;
          final candidate = File(
            '${thumbnail.path}.${DateTime.now().microsecondsSinceEpoch}.part.jpg',
          );
          try {
            perf.increment(GalleryMetric.videoExtract);
            final session = await perf.async(
              GalleryMetric.videoExtract,
              () => _extract([
                '-hide_banner',
                '-loglevel',
                'error',
                '-y',
                '-ss',
                _ffmpegTime(position),
                '-i',
                storagePath,
                '-frames:v',
                '1',
                '-vf',
                'scale=$_videoThumbnailMaxEdge:$_videoThumbnailMaxEdge:force_original_aspect_ratio=decrease',
                '-q:v',
                '2',
                candidate.path,
              ], work),
            );
            if (work.cancelled) return cached;
            final returnCode = await session.getReturnCode();
            if (ReturnCode.isSuccess(returnCode) &&
                await perf.async(GalleryMetric.cacheStat, candidate.exists)) {
              final extracted = await perf.async(
                GalleryMetric.diskRead,
                candidate.readAsBytes,
              );
              perf.increment(GalleryMetric.diskBytes, extracted.length);
              final next = await perf.async(
                GalleryMetric.videoCompact,
                () => compute(_compactVideoThumbnail, <Object>[
                  extracted,
                  _videoThumbnailMaxEdge,
                  _videoThumbnailQuality,
                ], debugLabel: 'video-thumbnail-compact'),
              );
              if (next?.isNotEmpty == true) {
                bytes = next;
                break;
              }
            }
          } finally {
            if (await perf.async(GalleryMetric.cacheStat, candidate.exists)) {
              await perf.async(GalleryMetric.cacheCleanup, candidate.delete);
            }
          }
        }
      }
      if (work.cancelled) return cached;
      if (bytes != null && bytes.isNotEmpty) {
        await _writeAtomic(thumbnail, bytes, diagnostics: perf);
        if (await perf.async(GalleryMetric.cacheStat, failedFile.exists)) {
          await perf.async(GalleryMetric.cacheCleanup, failedFile.delete);
        }
      } else {
        await _writeAtomic(
          failedFile,
          Uint8List.fromList(
            '$_videoThumbnailVersion:ffmpeg:${DateTime.now().toUtc().toIso8601String()}'
                .codeUnits,
          ),
          diagnostics: perf,
        );
      }
      if (duration > Duration.zero) {
        await _writeAtomic(
          durationFile,
          Uint8List.fromList('${duration.inMilliseconds}'.codeUnits),
          diagnostics: perf,
        );
      }
      if (bytes == null && cached.bytes != null) return cached;
      final cover = VideoThumbnailData(bytes: bytes, duration: duration);
      if (cover.bytes?.isNotEmpty == true) {
        _memory.seed(sha256, cover, diagnostics: perf);
      }
      return cover;
    } catch (error) {
      if (work.cancelled) return cached;
      await _writeAtomic(
        failedFile,
        Uint8List.fromList('$_videoThumbnailVersion:ffmpeg:failed'.codeUnits),
        diagnostics: perf,
      );
      if (cached.bytes != null) return cached;
      rethrow;
    }
  }

  static String _ffmpegTime(Duration value) =>
      (value.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(
        6,
      );

  static List<Duration> _thumbnailPositions(Duration duration) {
    final candidates = <Duration>[
      Duration.zero,
      const Duration(milliseconds: 120),
      const Duration(milliseconds: 500),
      const Duration(seconds: 1),
      if (duration > const Duration(seconds: 3))
        Duration(milliseconds: duration.inMilliseconds ~/ 4),
    ];
    return candidates
        .where((value) => duration == Duration.zero || value < duration)
        .toSet()
        .toList();
  }

  static Future<Duration> _readDuration(
    File file,
    PreviewPerfScope perf,
  ) async {
    if (!await perf.async(GalleryMetric.cacheStat, file.exists)) {
      return Duration.zero;
    }
    final text = await perf.async(GalleryMetric.diskRead, file.readAsString);
    perf.increment(GalleryMetric.diskBytes, text.length);
    final milliseconds = int.tryParse(text.trim());
    return Duration(milliseconds: milliseconds ?? 0);
  }

  static Future<void> _writeAtomic(
    File target,
    Uint8List bytes, {
    PreviewPerfScope? diagnostics,
  }) async {
    final perf = diagnostics ?? PreviewPerfScope();
    await perf.async(GalleryMetric.cacheWrite, () async {
      final part = File('${target.path}.part');
      if (await perf.async(GalleryMetric.cacheStat, part.exists)) {
        await perf.async(GalleryMetric.cacheCleanup, part.delete);
      }
      await part.writeAsBytes(bytes, flush: true);
      if (await perf.async(GalleryMetric.cacheStat, target.exists)) {
        await perf.async(GalleryMetric.cacheCleanup, target.delete);
      }
      await part.rename(target.path);
    });
    perf.increment(GalleryMetric.cacheBytes, bytes.length);
  }
}

Uint8List? _compactVideoThumbnail(List<Object> arguments) {
  final source = image.decodeImage(arguments[0] as Uint8List);
  if (source == null) return null;
  final maxEdge = arguments[1] as int;
  final quality = arguments[2] as int;
  final upright = image.bakeOrientation(source);
  final longEdge = math.max(upright.width, upright.height);
  final resized = longEdge <= maxEdge
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
        );
  return Uint8List.fromList(image.encodeJpg(resized, quality: quality));
}

bool _validHash(String value) =>
    value.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(value);

bool _isJpeg(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0xff &&
    bytes[1] == 0xd8 &&
    bytes[bytes.length - 2] == 0xff &&
    bytes[bytes.length - 1] == 0xd9;
