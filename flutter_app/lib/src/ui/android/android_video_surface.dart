import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../video_runtime.dart';
import '../video_preview.dart';
import '../video_viewer_lifecycle.dart';
import 'android_media_swipe_region.dart';
import 'android_video_controls.dart';
import 'android_video_failure_view.dart';
import 'android_video_retirement.dart';

class AndroidVideoSurface extends StatefulWidget {
  const AndroidVideoSurface({
    super.key,
    required this.path,
    required this.cover,
    this.autoPlay = false,
    this.active = true,
    this.prewarm = false,
    this.immersive = false,
    this.hideControls = false,
    this.fillColor = Colors.black,
    this.onReady,
    this.onMediaTap,
    this.onSwipe,
    this.onVerticalSwipe,
  });
  final String path;
  final MediaAsset cover;
  final bool autoPlay;
  final bool active;
  final bool prewarm;
  final bool immersive;
  final bool hideControls;
  final Color fillColor;
  final ValueChanged<Player>? onReady;
  final VoidCallback? onMediaTap;
  final ValueChanged<int>? onSwipe;
  final ValueChanged<int>? onVerticalSwipe;
  @override
  State<AndroidVideoSurface> createState() => AndroidVideoSurfaceState();
}

class AndroidVideoSurfaceState extends State<AndroidVideoSurface> {
  late final Player player;
  late final VideoController controller;
  late final playbackLifecycle = VideoViewerLifecycle(
    initiallyActive: false,
    pause: player.pause,
    play: () async {
      await opening;
      if (mounted && !released && widget.active) await player.play();
    },
    disposePlayer: () async {
      try {
        await opening;
      } catch (_) {
        // Opening failure does not transfer ownership of the native player.
      }
      await retireAndroidVideoOutput(controller.notifier.value, player.dispose);
    },
  );
  Object? error;
  bool get released => playbackLifecycle.disposed;
  bool ready = false;
  late final Future<void> opening;
  @override
  void initState() {
    super.initState();
    VideoRuntime.ensureInitialized();
    player = Player();
    controller = VideoController(player);
    opening = open();
    unawaited(
      opening
          .then((_) async {
            if (!mounted || released) return;
            setState(() => ready = true);
            if (widget.active) {
              await updateActive();
            } else if (widget.prewarm) {
              unawaited(prewarm());
            }
            if (mounted && !released && widget.active) {
              widget.onReady?.call(player);
            }
          })
          .catchError((Object exception) {
            if (mounted) setState(() => error = exception);
            unawaited(release());
          }),
    );
  }

  Future<void> open() async {
    await controller.platform.future.timeout(const Duration(seconds: 15));
    if (released) return;
    await player
        .open(Media(widget.path), play: false)
        .timeout(const Duration(seconds: 15));
  }

  Future<void> prewarm() async {
    try {
      await playbackLifecycle.prewarm((interrupted) async {
        if (!mounted || released || widget.active) return;
        await warmVideoPreview(
          player: player,
          firstFrame: controller.waitUntilFirstFrameRendered,
          interrupted: interrupted,
          requireDecodedOutput: true,
        );
      });
    } catch (_) {
      // Neighbor preparation is optional; the selected page owns playback errors.
    }
  }

  Future<void> updateActive() async {
    try {
      await playbackLifecycle.updateActive(
        widget.active,
        autoPlay: widget.autoPlay,
      );
    } catch (exception) {
      if (mounted && !released) setState(() => error = exception);
    }
  }

  Future<void> pausePlayback() => playbackLifecycle.pause();

  Future<void> _command(Future<void> command) async {
    try {
      await command;
    } catch (exception) {
      if (mounted && !released) {
        setState(() => error = exception);
        unawaited(release());
      }
    }
  }

  @override
  void didUpdateWidget(covariant AndroidVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active == widget.active || released) return;
    unawaited(() async {
      await updateActive();
      if (widget.active && ready) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !released && widget.active && ready) {
            widget.onReady?.call(player);
          }
        });
      }
    }());
  }

  Future<void> release() => playbackLifecycle.dispose();

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
      builder: (context, playing) {
        final showControls = !widget.immersive && !widget.hideControls;
        return VideoPreview(
          controller: controller,
          cover: widget.cover,
          fill: widget.fillColor,
          showLoadingIndicator: false,
          controls: (_) => Stack(
            children: [
              // Siblings, not ancestors of the control bar: its raw pointer
              // listener must not observe scrubbing as a media-page swipe.
              Positioned.fill(
                child: AndroidMediaSwipeRegion(
                  enabled: !released && widget.active,
                  onSwipe: (delta) => widget.onSwipe?.call(delta),
                  onVerticalSwipe: (delta) =>
                      widget.onVerticalSwipe?.call(delta),
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: widget.active ? widget.onMediaTap : null,
                    child: showControls && playing.data != true
                        ? Center(
                            child: IconButton.filledTonal(
                              key: const Key('android-video-center-play'),
                              tooltip: context.l10n.select(
                                zh: '播放',
                                en: 'Play',
                              ),
                              onPressed: !ready || released || !widget.active
                                  ? null
                                  : () => unawaited(
                                      _command(playbackLifecycle.play()),
                                    ),
                              icon: const Icon(Icons.play_arrow, size: 42),
                            ),
                          )
                        : const SizedBox.expand(),
                  ),
                ),
              ),
              if (showControls)
                Positioned(
                  key: const Key('android-video-control-overlay'),
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: StreamBuilder(
                    stream: player.stream.duration,
                    initialData: player.state.duration,
                    builder: (context, duration) => StreamBuilder(
                      stream: player.stream.position,
                      initialData: player.state.position,
                      builder: (context, position) => StreamBuilder(
                        stream: player.stream.volume,
                        initialData: player.state.volume,
                        builder: (context, volume) => AndroidVideoControls(
                          enabled: ready && !released && widget.active,
                          playing: playing.data == true,
                          position: position.data ?? Duration.zero,
                          duration: duration.data ?? Duration.zero,
                          muted: (volume.data ?? 100) == 0,
                          onToggle: () => unawaited(
                            _command(
                              playbackLifecycle.runCommand(player.playOrPause),
                            ),
                          ),
                          onMute: () => unawaited(
                            _command(
                              playbackLifecycle.runCommand(
                                () => player.setVolume(
                                  (volume.data ?? 100) == 0 ? 100 : 0,
                                ),
                              ),
                            ),
                          ),
                          onSeek: (value) => unawaited(
                            _command(
                              playbackLifecycle.runCommand(
                                () => player.seek(value),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
