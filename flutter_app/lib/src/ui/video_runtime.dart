import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

/// Lazily initializes media_kit only when a video surface or decoder is
/// actually requested. Keeping this out of application startup avoids loading
/// the native video stack while the first Flutter page is still settling.
class VideoRuntime {
  VideoRuntime._();

  static bool _initialized = false;
  static Player? _prewarmedPlayer;
  static Future<void>? _prewarmFuture;
  static final Map<String, _PreparedVideo> _prepared = {};

  static Future<void> openAndPlayWhenReady({
    required Future<void> Function() waitForVideoOutput,
    required Future<void> Function() open,
    required Future<void> Function() play,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await waitForVideoOutput().timeout(timeout);
    await open().timeout(timeout);
    await play().timeout(timeout);
  }

  static Future<void> prepare(String path) {
    if (path.isEmpty) return Future<void>.value();
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return Future<void>.value();
    }
    final existing = _prepared[path];
    if (existing != null) return existing.ready;
    ensureInitialized();
    final player = Player();
    final future = () async {
      try {
        await player.open(Media(path), play: false);
      } catch (_) {
        _prepared.remove(path);
        await player.dispose();
        rethrow;
      }
    }();
    final entry = _PreparedVideo(player, future);
    _prepared[path] = entry;
    return future;
  }

  static void ensureInitialized() {
    if (_initialized) return;
    MediaKit.ensureInitialized();
    _initialized = true;
  }

  /// Initializes the native media stack after the first Flutter frame and
  /// keeps one idle player ready for the first video surface.
  static Future<void> prewarm() {
    final existing = _prewarmFuture;
    if (existing != null) return existing;
    final future = Future<void>(() {
      ensureInitialized();
      _prewarmedPlayer ??= Player();
    });
    _prewarmFuture = future;
    return future;
  }

  static VideoPlayerHandle acquirePlayer(String path) {
    ensureInitialized();
    final prepared = _prepared.remove(path);
    if (prepared != null) {
      return VideoPlayerHandle(prepared.player, prepared.ready);
    }
    final player = _prewarmedPlayer;
    _prewarmedPlayer = null;
    return VideoPlayerHandle(player ?? Player(), null);
  }

  static Future<void> clearPrepared() async {
    final entries = _prepared.values.toList(growable: false);
    _prepared.clear();
    for (final entry in entries) {
      await entry.player.dispose();
    }
  }
}

class _PreparedVideo {
  const _PreparedVideo(this.player, this.ready);

  final Player player;
  final Future<void> ready;
}

class VideoPlayerHandle {
  const VideoPlayerHandle(this.player, this.ready);

  final Player player;
  final Future<void>? ready;
}
