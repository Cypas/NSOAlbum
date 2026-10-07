import 'package:media_kit/media_kit.dart';

/// Lazily initializes media_kit only when a video surface or decoder is
/// actually requested. Keeping this out of application startup avoids loading
/// the native video stack while the first Flutter page is still settling.
class VideoRuntime {
  VideoRuntime._();

  static bool _initialized = false;

  static void ensureInitialized() {
    if (_initialized) return;
    MediaKit.ensureInitialized();
    _initialized = true;
  }
}
