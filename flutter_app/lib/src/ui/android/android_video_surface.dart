import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../video_runtime.dart';

class AndroidVideoSurface extends StatefulWidget {
  const AndroidVideoSurface({
    super.key,
    required this.path,
    this.autoPlay = false,
    this.onReady,
  });
  final String path;
  final bool autoPlay;
  final ValueChanged<Player>? onReady;
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
        await controller.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 15),
        );
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
    return releasing = player.dispose();
  }

  @override
  void dispose() {
    unawaited(release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => error != null
      ? Center(child: SelectableText(error.toString()))
      : Video(controller: controller);
}
