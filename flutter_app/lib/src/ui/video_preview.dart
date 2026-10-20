import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../l10n/app_localizations.dart';
import '../rust/models.dart';
import 'video_thumbnail.dart';
import 'video_preview_cache.dart';

/// Presentation boundary between an opening texture and its rendered first frame.
class VideoFirstFrameCover extends StatefulWidget {
  const VideoFirstFrameCover({
    super.key,
    required this.identity,
    required this.firstFrame,
    required this.thumbnail,
    required this.child,
    this.error,
  });
  final Object identity;
  final Future<void> firstFrame;
  final Future<VideoThumbnailData> thumbnail;
  final Widget child;
  final Object? error;

  @override
  State<VideoFirstFrameCover> createState() => _VideoFirstFrameCoverState();
}

class _VideoFirstFrameCoverState extends State<VideoFirstFrameCover> {
  int generation = 0;
  bool rendered = false;
  bool failed = false;
  VideoThumbnailData? poster;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(covariant VideoFirstFrameCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) _watch();
  }

  void _watch() {
    final ticket = ++generation;
    rendered = false;
    failed = false;
    poster = null;
    // No timeout here: a paused video can legitimately have no rendered frame.
    // Native/open failures arrive separately, rather than faking readiness.
    unawaited(
      widget.firstFrame.then(
        (_) {
          if (mounted && ticket == generation) setState(() => rendered = true);
        },
        onError: (Object _, StackTrace _) {
          if (mounted && ticket == generation) setState(() => failed = true);
        },
      ),
    );
    unawaited(
      widget.thumbnail.then(
        (data) {
          if (mounted && ticket == generation) setState(() => poster = data);
        },
        onError: (Object _, StackTrace _) {
          // A missing cover must not prevent playback or remove its placeholder.
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = failed || widget.error != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!rendered || error)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                key: const Key('video-first-frame-cover'),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (poster?.bytes case final bytes? when bytes.isNotEmpty)
                      Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        gaplessPlayback: false,
                        cacheWidth: 1280,
                        errorBuilder: (_, _, _) => const Center(
                          child: SizedBox.square(
                            dimension: 28,
                            child: CircularProgressIndicator(
                              key: Key('video-preview-loading'),
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      ),
                    if (error)
                      Center(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              context.l10n.select(
                                zh: '无法播放这个视频',
                                en: 'Unable to play this video',
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      )
                    else if (poster?.bytes?.isNotEmpty != true)
                      Center(
                        child: Semantics(
                          label: context.l10n.select(
                            zh: '正在准备视频',
                            en: 'Preparing video',
                          ),
                          child: const SizedBox.square(
                            dimension: 28,
                            child: CircularProgressIndicator(
                              key: Key('video-preview-loading'),
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        // Keep this slot stable; cover arrival must not reset control state.
        Positioned.fill(child: widget.child),
      ],
    );
  }
}

/// All production video entry points use this texture/cover boundary. It does
/// not own or open a player; each route retains its existing lifecycle.
class VideoPreview extends StatefulWidget {
  const VideoPreview({
    super.key,
    required this.controller,
    required this.cover,
    this.controls = AdaptiveVideoControls,
    this.error,
  });
  final VideoController controller;
  final MediaAsset cover;
  final VideoControlsBuilder? controls;
  final Object? error;

  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<VideoPreview> {
  late PreviewRequest<VideoThumbnailData> request;
  late Future<VideoThumbnailData> thumbnail;
  late Future<void> firstFrame;
  StreamSubscription<String>? errors;
  Object? playbackError;

  Future<VideoThumbnailData> _load() {
    request = VideoThumbnailCache.request(
      widget.cover,
      urgent: true,
      onError: (_, _) async {},
    );
    return request.future.then((data) => data ?? const VideoThumbnailData());
  }

  @override
  void initState() {
    super.initState();
    thumbnail = _load();
    firstFrame = widget.controller.waitUntilFirstFrameRendered;
    _listen();
  }

  void _listen() {
    unawaited(errors?.cancel());
    playbackError = null;
    final controller = widget.controller;
    errors = controller.player.stream.error.listen((value) {
      if (mounted && controller == widget.controller && value.isNotEmpty) {
        setState(() => playbackError = true);
      }
    });
  }

  @override
  void didUpdateWidget(covariant VideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cover.sha256 != widget.cover.sha256) {
      request.cancel();
      thumbnail = _load();
    }
    if (oldWidget.controller != widget.controller) {
      firstFrame = widget.controller.waitUntilFirstFrameRendered;
      _listen();
    }
  }

  @override
  void dispose() {
    unawaited(errors?.cancel());
    request.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Video(
    key: ObjectKey(widget.controller),
    controller: widget.controller,
    fit: BoxFit.contain,
    controls: (state) => VideoFirstFrameCover(
      identity: (widget.controller, widget.cover.sha256),
      firstFrame: firstFrame,
      thumbnail: thumbnail,
      error: widget.error ?? playbackError,
      child: widget.controls?.call(state) ?? const SizedBox.expand(),
    ),
  );
}

/// Adjacent pages can show a cover without allocating a native player.
class VideoPoster extends StatefulWidget {
  const VideoPoster({super.key, required this.asset});
  final MediaAsset asset;
  @override
  State<VideoPoster> createState() => _VideoPosterState();
}

class _VideoPosterState extends State<VideoPoster> {
  // Owned by this short-lived page, never a global never-completing future that
  // retains callbacks from every previously visited neighbor.
  final _pendingFrame = Completer<void>().future;
  late Future<VideoThumbnailData> thumbnail = VideoThumbnailCache.readExisting(
    widget.asset,
  );

  @override
  void didUpdateWidget(covariant VideoPoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.sha256 != widget.asset.sha256) {
      thumbnail = VideoThumbnailCache.readExisting(widget.asset);
    }
  }

  @override
  Widget build(BuildContext context) => VideoFirstFrameCover(
    identity: widget.asset.sha256,
    firstFrame: _pendingFrame,
    thumbnail: thumbnail,
    child: const SizedBox.expand(),
  );
}
