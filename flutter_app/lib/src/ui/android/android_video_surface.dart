import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../video_runtime.dart';
import '../video_preview.dart';
import 'android_media_swipe_region.dart';
import 'android_video_controls.dart';
import 'android_video_failure_view.dart';

class AndroidVideoSurface extends StatefulWidget {
  const AndroidVideoSurface({
    super.key,
    required this.path,
    required this.cover,
    this.autoPlay = false,
    this.onReady,
    this.onSwipe,
  });
  final String path;
  final MediaAsset cover;
  final bool autoPlay;
  final ValueChanged<Player>? onReady;
  final ValueChanged<int>? onSwipe;
  @override
  State<AndroidVideoSurface> createState() => AndroidVideoSurfaceState();
}

class AndroidVideoSurfaceState extends State<AndroidVideoSurface> {
  late final Player player;
  late final VideoController controller;
  Object? error;
  bool released = false;
  Future<void>? releasing;
  @override
  void initState() {
    super.initState();
    VideoRuntime.ensureInitialized();
    player = Player();
    controller = VideoController(player);
    unawaited(open());
  }

  Future<void> open() async {
    try {
      await controller.platform.future.timeout(const Duration(seconds: 15));
      if (released) return;
      await player
          .open(Media(widget.path), play: false)
          .timeout(const Duration(seconds: 15));
      if (released) return;
      if (widget.autoPlay) {
        await player.play();
      }
      if (!released) widget.onReady?.call(player);
    } catch (exception) {
      await release();
      if (mounted) setState(() => error = exception);
    }
  }

  Future<void> release() {
    if (releasing != null) return releasing!;
    released = true;
    return releasing = () async {
      try {
        await player.pause();
      } finally {
        await player.dispose();
      }
    }();
  }

  @override
  void dispose() {
    unawaited(release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return AndroidVideoFailureView(onSwipe: widget.onSwipe);
    }
    return StreamBuilder(
      stream: player.stream.playing,
      initialData: player.state.playing,
      builder: (context, playing) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: AndroidMediaSwipeRegion(
              enabled: !released,
              onSwipe: (delta) => widget.onSwipe?.call(delta),
              child: VideoPreview(
                controller: controller,
                cover: widget.cover,
                controls: (_) => Stack(
                  children: [
                    if (playing.data != true)
                      Center(
                        child: IconButton.filledTonal(
                          key: const Key('android-video-center-play'),
                          tooltip: context.l10n.select(zh: '播放', en: 'Play'),
                          onPressed: released ? null : player.play,
                          icon: const Icon(Icons.play_arrow, size: 42),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          StreamBuilder(
            stream: player.stream.duration,
            initialData: player.state.duration,
            builder: (context, duration) => StreamBuilder(
              stream: player.stream.position,
              initialData: player.state.position,
              builder: (context, position) => StreamBuilder(
                stream: player.stream.volume,
                initialData: player.state.volume,
                builder: (context, volume) => AndroidVideoControls(
                  enabled: !released,
                  playing: playing.data == true,
                  position: position.data ?? Duration.zero,
                  duration: duration.data ?? Duration.zero,
                  muted: (volume.data ?? 100) == 0,
                  onToggle: () => unawaited(player.playOrPause()),
                  onMute: () => unawaited(
                    player.setVolume((volume.data ?? 100) == 0 ? 100 : 0),
                  ),
                  onSeek: (value) => unawaited(player.seek(value)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
