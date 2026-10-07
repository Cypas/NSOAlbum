import 'package:media_kit/media_kit.dart';

/// Lazily initializes media_kit only when a video surface or decoder is
/// actually requested. Keeping this out of application startup avoids loading
/// the native video stack while the first Flutter page is still settling.
class VideoRuntime {
  VideoRuntime._();

  static bool _initialized = false;
  static Player? _prewarmedPlayer;
  static Future<void>? _prewarmFuture;

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

  static Player acquirePlayer() {
    ensureInitialized();
    final player = _prewarmedPlayer;
    _prewarmedPlayer = null;
    return player ?? Player();
  }
}
