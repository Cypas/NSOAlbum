import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:path_provider/path_provider.dart';

import '../rust/models.dart';

class VideoThumbnailData {
  const VideoThumbnailData({this.bytes, this.duration = Duration.zero});

  final Uint8List? bytes;
  final Duration duration;
}

class VideoThumbnailCache {
  static final Map<String, Future<VideoThumbnailData>> _cache = {};
  static Future<void> _queue = Future.value();

  static Future<VideoThumbnailData> readCachedFiles({
    required String cacheRoot,
    required String sha256,
  }) async {
    final thumbnail = File('$cacheRoot${Platform.pathSeparator}$sha256.jpg');
    final durationFile = File(
      '$cacheRoot${Platform.pathSeparator}$sha256.duration',
    );
    final bytes = await thumbnail.exists()
        ? await thumbnail.readAsBytes()
        : null;
    final duration = await _readDuration(durationFile);
    return VideoThumbnailData(bytes: bytes, duration: duration);
  }

  static void preload(
    Iterable<MediaAsset> assets, {
    required Future<void> Function(Object error, StackTrace stackTrace) onError,
    int limit = 64,
  }) {
    for (final asset
        in assets.where((item) => item.kind == MediaKind.video).take(limit)) {
      unawaited(load(asset, onError: onError));
    }
  }

  static bool shouldRetryFailureMarker(String marker) =>
      !marker.trimLeft().startsWith('v2:');

  static Future<VideoThumbnailData> load(
    MediaAsset asset, {
    required Future<void> Function(Object error, StackTrace stackTrace) onError,
  }) {
    final key = asset.sha256;
    final existing = _cache[key];
    if (existing != null) return existing;
    if (_cache.length >= 80) _cache.remove(_cache.keys.first);
    return _cache.putIfAbsent(key, () {
      final completer = Completer<VideoThumbnailData>();
      _queue = _queue.catchError((_) {}).then((_) async {
        try {
          final data = await _loadOrCreate(asset);
          if (data.bytes == null || data.bytes!.isEmpty) {
            _cache.remove(key);
          }
          completer.complete(data);
        } catch (error, stackTrace) {
          _cache.remove(key);
          try {
            await onError(error, stackTrace);
          } catch (_) {
            // Logging must not block the remaining thumbnail queue.
          }
          completer.complete(const VideoThumbnailData());
        }
      });
      return completer.future;
    });
  }

  static Future<VideoThumbnailData> _loadOrCreate(MediaAsset asset) async {
    if (!File(asset.storagePath).existsSync()) {
      return const VideoThumbnailData();
    }
    final separator = Platform.pathSeparator;
    final cacheRoot = Directory(
      '${(await getApplicationCacheDirectory()).path}'
      '${separator}squid_album${separator}video_thumbnails',
    );
    await cacheRoot.create(recursive: true);
    final thumbnail = File('${cacheRoot.path}$separator${asset.sha256}.jpg');
    final durationFile = File(
      '${cacheRoot.path}$separator${asset.sha256}.duration',
    );
    final failedFile = File(
      '${cacheRoot.path}$separator${asset.sha256}.failed',
    );
    final cached = await readCachedFiles(
      cacheRoot: cacheRoot.path,
      sha256: asset.sha256,
    );
    if (cached.bytes != null && cached.duration > Duration.zero) {
      return cached;
    }
    if (await failedFile.exists()) {
      final marker = await failedFile.readAsString();
      if (!shouldRetryFailureMarker(marker)) {
        return cached;
      }
      await failedFile.delete();
    }

    try {
      var duration = cached.duration;
      if (duration == Duration.zero) {
        try {
          final information = await FFprobeKit.getMediaInformation(
            asset.storagePath,
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
      Uint8List? bytes = cached.bytes;
      if (bytes == null || bytes.isEmpty) {
        final positions = _thumbnailPositions(duration);
        for (final position in positions) {
          final candidate = File(
            '${thumbnail.path}.${DateTime.now().microsecondsSinceEpoch}.part.jpg',
          );
          try {
            final session = await FFmpegKit.executeWithArguments([
              '-hide_banner',
              '-loglevel',
              'error',
              '-y',
              '-ss',
              _ffmpegTime(position),
              '-i',
              asset.storagePath,
              '-frames:v',
              '1',
              '-q:v',
              '3',
              candidate.path,
            ]);
            final returnCode = await session.getReturnCode();
            if (ReturnCode.isSuccess(returnCode) && await candidate.exists()) {
              final next = await candidate.readAsBytes();
              if (next.isNotEmpty) {
                bytes = next;
                break;
              }
            }
          } finally {
            if (await candidate.exists()) await candidate.delete();
          }
        }
      }
      if (bytes != null && bytes.isNotEmpty) {
        await _writeAtomic(thumbnail, bytes);
        if (await failedFile.exists()) await failedFile.delete();
      } else if (cached.bytes == null) {
        await _writeAtomic(
          failedFile,
          Uint8List.fromList(
            'v2:ffmpeg:${DateTime.now().toUtc().toIso8601String()}'.codeUnits,
          ),
        );
      }
      if (duration > Duration.zero) {
        await _writeAtomic(
          durationFile,
          Uint8List.fromList('${duration.inMilliseconds}'.codeUnits),
        );
      }
      return VideoThumbnailData(bytes: bytes, duration: duration);
    } catch (error) {
      await _writeAtomic(
        failedFile,
        Uint8List.fromList('v2:ffmpeg:$error'.codeUnits),
      );
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

  static Future<Duration> _readDuration(File file) async {
    if (!await file.exists()) return Duration.zero;
    final milliseconds = int.tryParse((await file.readAsString()).trim());
    return Duration(milliseconds: milliseconds ?? 0);
  }

  static Future<void> _writeAtomic(File target, Uint8List bytes) async {
    final part = File('${target.path}.part');
    if (await part.exists()) await part.delete();
    await part.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
  }
}
