import 'package:media_kit_video/media_kit_video.dart';
// media_kit_video 2.0.1 exposes no public output-retirement fence. Keep this
// version-specific integration here rather than modifying the plugin/cache.
// ignore: implementation_imports
import 'package:media_kit_video/src/video_controller/android_video_controller/android_video_controller.dart';

Future<void> retireAndroidVideoOutput(
  PlatformVideoController? output,
  Future<void> Function() disposePlayer,
) async {
  if (output is! AndroidVideoController) {
    await disposePlayer();
    return;
  }
  // Its native Resize handler can enqueue an asynchronous seek even while the
  // Flutter surface is being removed. Stop producers, drain already admitted
  // output work, then run the normal Player-owned plugin cleanup exactly once.
  output.wid.removeListener(output.widListener);
  await output.videoParamsSubscription?.cancel();
  await output.lock.synchronized(disposePlayer);
}
