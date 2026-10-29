import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../l10n/app_localizations.dart';
import '../rust/models.dart';
import 'video_thumbnail.dart';
import 'video_preview_cache.dart';

/// Shared desktop control bar for all desktop video surfaces.
///
/// The in-app immersive action is intentionally separate from media_kit's
/// system fullscreen action. Both buttons live in the same auto-hiding bar,
/// while the callbacks only change presentation and never replace the player.
MaterialDesktopVideoControlsThemeData appDesktopVideoControlsThemeData({
  required VoidCallback onToggleImmersive,
  required bool immersive,
  String immersiveTooltip = 'In-app fullscreen',
  String systemFullscreenTooltip = 'Fullscreen',
  Key? immersiveKey,
  Key? systemFullscreenKey,
}) => MaterialDesktopVideoControlsThemeData(
  toggleFullscreenOnDoublePress: false,
  bufferingIndicatorBuilder: (_) => const SizedBox.shrink(),
  bottomButtonBar: [
    const MaterialDesktopSkipPreviousButton(),
    const MaterialDesktopPlayOrPauseButton(),
    const MaterialDesktopSkipNextButton(),
    const MaterialDesktopVolumeButton(),
    const MaterialDesktopPositionIndicator(),
    const Spacer(),
    Tooltip(
      message: immersiveTooltip,
      child: MaterialDesktopCustomButton(
        key: immersiveKey,
        onPressed: onToggleImmersive,
        iconSize: 18,
        icon: Icon(
          immersive ? Icons.fit_screen_rounded : Icons.open_in_full_rounded,
        ),
      ),
    ),
    Tooltip(
      message: systemFullscreenTooltip,
      child: MaterialDesktopFullscreenButton(key: systemFullscreenKey),
    ),
  ],
);

/// Presentation boundary between an opening texture and its rendered first frame.
class VideoFirstFrameCover extends StatefulWidget {
  const VideoFirstFrameCover({
    super.key,
    required this.identity,
    required this.firstFrame,
    required this.thumbnail,
    required this.child,
    this.initialThumbnail,
    this.playbackErrors,
    this.decoderReady,
    this.decoderInitiallyReady = true,
    this.error,
    this.showLoadingIndicator = true,
  });
  final Object identity;
  final Future<void> firstFrame;
  final Future<VideoThumbnailData> thumbnail;
  final Widget child;
  final VideoThumbnailData? initialThumbnail;
  final Stream<String>? playbackErrors;
  final Stream<bool>? decoderReady;
  final bool decoderInitiallyReady;
  final Object? error;
  final bool showLoadingIndicator;

  @override
  State<VideoFirstFrameCover> createState() => _VideoFirstFrameCoverState();
}

class _VideoFirstFrameCoverState extends State<VideoFirstFrameCover> {
  static const _coverFadeDuration = Duration(milliseconds: 120);

  int generation = 0;
  bool rendered = false;
  bool decoded = false;
  bool failed = false;
  bool coverVisible = true;
  bool fading = false;
  String? playbackError;
  StreamSubscription<String>? errors;
  StreamSubscription<bool>? decoder;
  VideoThumbnailData? poster;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(covariant VideoFirstFrameCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _watch();
    } else if (oldWidget.initialThumbnail != widget.initialThumbnail) {
      poster = widget.initialThumbnail;
    }
  }

  void _watch() {
    final ticket = ++generation;
    rendered = false;
    decoded = widget.decoderInitiallyReady;
    failed = false;
    coverVisible = true;
    fading = false;
    playbackError = null;
    poster = widget.initialThumbnail;
    unawaited(errors?.cancel());
    unawaited(decoder?.cancel());
    decoder = widget.decoderReady?.listen((ready) {
      if (mounted && ticket == generation && ready) {
        setState(() {
          decoded = true;
          playbackError = null;
        });
        _maybeFadeCover(ticket);
      }
    });
    errors = widget.playbackErrors?.listen((value) {
      if (mounted && ticket == generation && value.isNotEmpty) {
        // Android hardware probing can report this after software fallback has
        // already produced decoded output and a frame. Do not cover that frame
        // again; all other errors and unproven decoder states remain visible.
        if (widget.decoderReady != null &&
            rendered &&
            decoded &&
            !failed &&
            value.trim() == 'Could not open codec.') {
          return;
        }
        setState(() {
          fading = false;
          coverVisible = true;
          playbackError = value;
        });
      }
    });
    // No timeout here: a paused video can legitimately have no rendered frame.
    // Native/open failures arrive separately, rather than faking readiness.
    unawaited(
      widget.firstFrame.then(
        (_) {
          if (mounted && ticket == generation) {
            setState(() {
              rendered = true;
              // A real decoded frame proves recovery from an opening decoder
              // failure (for example a hardware-to-software fallback).
              if (decoded) playbackError = null;
            });
            _maybeFadeCover(ticket);
          }
        },
        onError: (Object _, StackTrace _) {
          if (mounted && ticket == generation) {
            setState(() {
              fading = false;
              coverVisible = true;
              failed = true;
            });
          }
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

  void _maybeFadeCover(int ticket) {
    if (!mounted ||
        ticket != generation ||
        fading ||
        !coverVisible ||
        !rendered ||
        !decoded ||
        failed ||
        playbackError != null ||
        widget.error != null) {
      return;
    }
    setState(() => fading = true);
  }

  @override
  void dispose() {
    unawaited(errors?.cancel());
    unawaited(decoder?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = failed || playbackError != null || widget.error != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (coverVisible || error)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: fading && !error ? 0 : 1,
                duration: _coverFadeDuration,
                onEnd: () {
                  if (!mounted || !fading) return;
                  setState(() {
                    fading = false;
                    coverVisible = false;
                  });
                },
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
                          errorBuilder: (_, _, _) => Center(
                            child: widget.showLoadingIndicator
                                ? const SizedBox.square(
                                    dimension: 28,
                                    child: CircularProgressIndicator(
                                      key: Key('video-preview-loading'),
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.movie_outlined,
                                    key: Key('video-preview-placeholder'),
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
                            child: widget.showLoadingIndicator
                                ? const SizedBox.square(
                                    dimension: 28,
                                    child: CircularProgressIndicator(
                                      key: Key('video-preview-loading'),
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.movie_outlined,
                                    key: Key('video-preview-placeholder'),
                                  ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        // The preceding cover is conditional. Key this slot so its removal
        // cannot recycle that Positioned and remount the playback controls.
        Positioned.fill(
          key: const ValueKey('video-preview-controls-slot'),
          child: widget.child,
        ),
      ],
    );
  }
}

bool hasDecodedVideo(VideoParams params) =>
    params.pixelformat?.isNotEmpty == true &&
    (params.w ?? 0) > 0 &&
    (params.h ?? 0) > 0;

Future<void> warmVideoPreview({
  required Player player,
  required Future<void> firstFrame,
  required Future<void> interrupted,
  required bool requireDecodedOutput,
}) async {
  final volume = player.state.volume;
  final decoded = Completer<void>();
  StreamSubscription<VideoParams>? parameters;
  if (requireDecodedOutput) {
    parameters = player.stream.videoParams.listen((value) {
      if (!decoded.isCompleted && hasDecodedVideo(value)) decoded.complete();
    });
    if (hasDecodedVideo(player.state.videoParams)) decoded.complete();
  } else {
    decoded.complete();
  }
  final prepared = Future.any<void>([
    Future.wait([firstFrame, decoded.future]).then((_) {}),
    interrupted,
  ]);
  // The native play command may finish after an early frame failure.
  unawaited(prepared.catchError((Object _, StackTrace _) {}));
  try {
    await player.setVolume(0);
    await player.play();
    await prepared.timeout(const Duration(seconds: 2));
  } finally {
    await parameters?.cancel();
    try {
      await player.pause();
    } finally {
      await player.setVolume(volume);
    }
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
    this.initialThumbnail,
    this.error,
    this.showLoadingIndicator = true,
    this.fill = const Color(0xFF000000),
  });
  final VideoController controller;
  final MediaAsset cover;
  final VideoControlsBuilder? controls;
  final VideoThumbnailData? initialThumbnail;
  final Object? error;
  final bool showLoadingIndicator;
  final Color fill;

  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<VideoPreview> {
  late PreviewRequest<VideoThumbnailData> request;
  late Future<VideoThumbnailData> thumbnail;
  late Future<void> firstFrame;
  late Stream<bool>? decoderReady;
  VideoThumbnailData? initialThumbnail;

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
    initialThumbnail = _initialThumbnail();
    thumbnail = _load();
    firstFrame = widget.controller.waitUntilFirstFrameRendered;
    _watchDecoder();
  }

  VideoThumbnailData? _initialThumbnail() =>
      widget.initialThumbnail ?? VideoThumbnailCache.peek(widget.cover);

  void _watchDecoder() {
    decoderReady = Platform.isAndroid
        ? widget.controller.player.stream.videoParams.map(hasDecodedVideo)
        : null;
  }

  @override
  void didUpdateWidget(covariant VideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cover.sha256 != widget.cover.sha256 ||
        oldWidget.initialThumbnail != widget.initialThumbnail) {
      initialThumbnail = _initialThumbnail();
    }
    if (oldWidget.cover.sha256 != widget.cover.sha256) {
      request.cancel();
      thumbnail = _load();
    }
    if (oldWidget.controller != widget.controller) {
      firstFrame = widget.controller.waitUntilFirstFrameRendered;
      _watchDecoder();
    }
  }

  @override
  void dispose() {
    request.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Video(
    key: ObjectKey(widget.controller),
    controller: widget.controller,
    fill: widget.fill,
    fit: BoxFit.contain,
    controls: (state) => VideoFirstFrameCover(
      identity: (widget.controller, widget.cover.sha256),
      firstFrame: firstFrame,
      thumbnail: thumbnail,
      initialThumbnail: initialThumbnail,
      error: widget.error,
      playbackErrors: widget.controller.player.stream.error,
      decoderReady: decoderReady,
      decoderInitiallyReady:
          !Platform.isAndroid ||
          hasDecodedVideo(widget.controller.player.state.videoParams),
      showLoadingIndicator: widget.showLoadingIndicator,
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
    showLoadingIndicator: false,
    child: const SizedBox.expand(),
  );
}
