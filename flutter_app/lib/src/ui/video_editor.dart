import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../backend/app_backend.dart';
import '../l10n/app_localizations.dart';
import '../rust/models.dart';
import 'desktop_window_drag_area.dart';
import 'video_runtime.dart';
import 'font_families.dart';

class VideoEditorResult {
  const VideoEditorResult({required this.asset, required this.overwrite});

  final MediaAsset asset;
  final bool overwrite;
}

class VideoEditorPage extends StatefulWidget {
  const VideoEditorPage({
    super.key,
    required this.backend,
    required this.source,
    this.onMediaCreated,
  });

  final AppBackend backend;
  final MediaAsset source;
  final VoidCallback? onMediaCreated;

  static Future<VideoEditorResult?> open(
    BuildContext context, {
    required AppBackend backend,
    required MediaAsset source,
    VoidCallback? onMediaCreated,
  }) => showGeneralDialog<VideoEditorResult>(
    context: context,
    barrierDismissible: false,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black87,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, _, _) => Padding(
      padding: const EdgeInsets.all(4),
      child: Material(
        key: const Key('video-editor-dialog'),
        color: const Color(0xff090b10),
        child: SizedBox.expand(
          child: VideoEditorPage(
            backend: backend,
            source: source,
            onMediaCreated: onMediaCreated,
          ),
        ),
      ),
    ),
    transitionBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: child,
    ),
  );

  @override
  State<VideoEditorPage> createState() => _VideoEditorPageState();
}

class _VideoEditorPageState extends State<VideoEditorPage> {
  late final Player player = _createPlayer();
  late final VideoController controller = VideoController(player);

  Player _createPlayer() {
    VideoRuntime.ensureInitialized();
    return Player();
  }

  StreamSubscription<Duration>? durationSubscription;
  StreamSubscription<Duration>? positionSubscription;
  StreamSubscription<bool>? playingSubscription;
  final FocusNode keyboardFocus = FocusNode(debugLabel: 'video-editor');
  Duration duration = Duration.zero;
  Duration position = Duration.zero;
  Duration selectionStart = Duration.zero;
  Duration selectionEnd = Duration.zero;
  double timelineZoom = 1;
  bool busy = false;
  bool playing = false;
  bool autoPlayAfterSelectionChange = false;
  bool restartAtSelectionStart = true;
  int seekSequence = 0;
  DateTime ignorePositionsUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Duration pendingSeekTarget = Duration.zero;
  Object? openError;

  @override
  void initState() {
    super.initState();
    durationSubscription = player.stream.duration.listen((value) {
      if (!mounted || value <= Duration.zero) return;
      setState(() {
        duration = value;
        if (selectionEnd <= Duration.zero || selectionEnd > value) {
          selectionEnd = value;
        }
      });
    });
    positionSubscription = player.stream.position.listen((value) {
      if (!mounted) return;
      if (DateTime.now().isBefore(ignorePositionsUntil) &&
          (value - pendingSeekTarget).abs() >
              const Duration(milliseconds: 500)) {
        return;
      }
      if (selectionEnd > selectionStart && value >= selectionEnd) {
        unawaited(player.pause());
        restartAtSelectionStart = true;
        unawaited(_seekTo(selectionStart));
        return;
      }
      setState(() => position = value);
    });
    playingSubscription = player.stream.playing.listen((value) {
      if (mounted) setState(() => playing = value);
    });
    player.open(Media(widget.source.storagePath), play: false).catchError((
      Object error,
    ) {
      if (mounted) setState(() => openError = error);
    });
  }

  @override
  void dispose() {
    durationSubscription?.cancel();
    positionSubscription?.cancel();
    playingSubscription?.cancel();
    keyboardFocus.dispose();
    player.dispose();
    super.dispose();
  }

  Future<void> _seekTo(Duration value) async {
    if (duration <= Duration.zero) return;
    final target = value < selectionStart
        ? selectionStart
        : value > selectionEnd
        ? selectionEnd
        : value;
    final sequence = ++seekSequence;
    pendingSeekTarget = target;
    ignorePositionsUntil = DateTime.now().add(
      const Duration(milliseconds: 450),
    );
    if (mounted) setState(() => position = target);
    await player.seek(target);
    if (sequence != seekSequence) return;
    ignorePositionsUntil = DateTime.now().add(
      const Duration(milliseconds: 120),
    );
  }

  Future<void> _toggleSelectionPlayback() async {
    if (player.state.playing) {
      await player.pause();
      return;
    }
    if (restartAtSelectionStart ||
        position < selectionStart ||
        position >= selectionEnd) {
      await _seekTo(selectionStart);
    }
    restartAtSelectionStart = false;
    await player.play();
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    final editingText =
        focusedContext?.widget is EditableText ||
        focusedContext?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (editingText) return KeyEventResult.ignored;
    unawaited(_toggleSelectionPlayback());
    return KeyEventResult.handled;
  }

  void _updateSelection(RangeValues range) {
    unawaited(player.pause());
    final start = Duration(milliseconds: range.start.round());
    final end = Duration(milliseconds: range.end.round());
    setState(() {
      selectionStart = start;
      selectionEnd = end;
      restartAtSelectionStart = true;
    });
  }

  Future<void> _finishSelectionChange(RangeValues range) async {
    _updateSelection(range);
    await player.pause();
    await _seekTo(selectionStart);
    if (autoPlayAfterSelectionChange) {
      restartAtSelectionStart = false;
      await player.play();
    }
  }

  Future<void> _save({required bool overwrite}) async {
    if (busy ||
        selectionEnd - selectionStart < const Duration(milliseconds: 300)) {
      return;
    }
    if (overwrite) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            context.l10n.select(zh: '覆盖原视频？', en: 'Overwrite original video?'),
          ),
          content: Text(
            context.l10n.select(
              zh: '保存会使用当前选区替换原视频。此操作完成后无法恢复，是否继续？',
              en: 'Saving replaces the original video with the selected range. This cannot be undone. Continue?',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              key: const Key('confirm-overwrite-video'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.select(zh: '继续覆盖', en: 'Overwrite')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => busy = true);
    await player.pause();
    try {
      final asset = await widget.backend.trimVideo(
        widget.source,
        selectionStart,
        selectionEnd,
        overwrite: overwrite,
      );
      if (!mounted) return;
      Navigator.of(context)
          .pop(VideoEditorResult(asset: asset, overwrite: overwrite));
    } catch (error, stackTrace) {
      await widget.backend.logError('Failed to trim video', error, stackTrace);
      if (!mounted) return;
      setState(() => busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.select(
              zh: '视频剪辑失败：$error',
              en: 'Video editing failed: $error',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _captureFrame() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      var bytes = await player.screenshot(format: 'image/png');
      var extension = 'png';
      if (bytes == null) {
        bytes = await player.screenshot(format: 'image/jpeg');
        extension = 'jpg';
      }
      if (bytes == null) throw StateError('The current frame is not available');
      await widget.backend.saveVideoFrame(widget.source, bytes, extension);
      widget.onMediaCreated?.call();
      if (!mounted) return;
      setState(() => busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.select(
              zh: '当前画面已保存为新的图片。',
              en: 'The current frame was saved as a new image.',
            ),
          ),
        ),
      );
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to save current video frame',
        error,
        stackTrace,
      );
      if (!mounted) return;
      setState(() => busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.select(
              zh: '截取当前画面失败：$error',
              en: 'Failed to capture the current frame: $error',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    focusNode: keyboardFocus,
    onKeyEvent: _handleKey,
    child: Scaffold(
      backgroundColor: const Color(0xff090b10),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildToolbar(context),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                    child: openError == null
                        ? Center(
                            child: AspectRatio(
                              aspectRatio: 16 / 9,
                              child: Video(
                                controller: controller,
                                controls: NoVideoControls,
                              ),
                            ),
                          )
                        : Center(
                            child: Text(
                              context.l10n.select(
                                zh: '无法打开这个视频：$openError',
                                en: 'Unable to open this video: $openError',
                              ),
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                  ),
                ),
                _buildTimelinePanel(context),
              ],
            ),
            if (busy)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x99000000),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _buildToolbar(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    child: Row(
      children: [
        IconButton.filledTonal(
          key: const Key('video-editor-close'),
          tooltip: context.l10n.select(zh: '关闭剪辑', en: 'Close editor'),
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: DesktopWindowDragArea(
            key: const Key('video-editor-window-drag-area'),
            child: Text(
              widget.source.originalName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        OutlinedButton.icon(
          key: const Key('video-editor-capture-frame'),
          onPressed: busy || openError != null ? null : _captureFrame,
          icon: const Icon(Icons.photo_camera_outlined),
          label: Text(context.l10n.select(zh: '截取当前画面', en: 'Capture frame')),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          key: const Key('video-editor-save-as'),
          onPressed: busy || duration <= Duration.zero
              ? null
              : () => _save(overwrite: false),
          icon: const Icon(Icons.save_as_rounded),
          label: Text(context.l10n.select(zh: '另存', en: 'Save as')),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          key: const Key('video-editor-save'),
          onPressed: busy || duration <= Duration.zero
              ? null
              : () => _save(overwrite: true),
          icon: const Icon(Icons.save_rounded),
          label: Text(context.l10n.select(zh: '保存', en: 'Save')),
        ),
      ],
    ),
  );

  Widget _buildTimelinePanel(BuildContext context) => Material(
    color: const Color(0xff151923),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton.filled(
                key: const Key('video-editor-play-selection'),
                tooltip: context.l10n.select(
                  zh: '预览选区',
                  en: 'Preview selection',
                ),
                onPressed: duration <= Duration.zero
                    ? null
                    : _toggleSelectionPlayback,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${_formatDuration(selectionStart)} – ${_formatDuration(selectionEnd)}',
                key: const Key('video-editor-selection-label'),
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(width: 12),
              Container(
                key: const Key('video-editor-selection-duration'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: .18),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  context.l10n.select(
                    zh: '选区 ${_formatSelectionSeconds(selectionEnd - selectionStart)} 秒',
                    en: '${_formatSelectionSeconds(selectionEnd - selectionStart)} seconds selected',
                  ),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilterChip(
                key: const Key('video-editor-auto-play-selection'),
                labelStyle: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontFamily: appFontFamily,
                  fontFamilyFallback: appFontFallback,
                ),
                selected: autoPlayAfterSelectionChange,
                onSelected: (value) =>
                    setState(() => autoPlayAfterSelectionChange = value),
                avatar: Icon(
                  autoPlayAfterSelectionChange
                      ? Icons.play_circle_fill_rounded
                      : Icons.play_circle_outline_rounded,
                  size: 18,
                ),
                label: Text(
                  context.l10n.select(
                    zh: '调整后自动播放选区',
                    en: 'Auto-play after adjusting',
                  ),
                ),
              ),
              const Spacer(),
              const Icon(Icons.mouse_rounded, size: 18, color: Colors.white54),
              const SizedBox(width: 6),
              Text(
                context.l10n.select(
                  zh: '滚轮缩放时间轴 · ${timelineZoom.toStringAsFixed(1)}×',
                  en: 'Scroll to zoom timeline · ${timelineZoom.toStringAsFixed(1)}×',
                ),
                style: const TextStyle(color: Colors.white54),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 126,
            child: VideoTimeline(
              duration: duration,
              position: position,
              selectionStart: selectionStart,
              selectionEnd: selectionEnd,
              zoom: timelineZoom,
              playing: playing,
              onZoomChanged: (value) => setState(() => timelineZoom = value),
              onSeek: _seekTo,
              onSelectionChanged: _updateSelection,
              onSelectionChangeEnd: (range) =>
                  unawaited(_finishSelectionChange(range)),
            ),
          ),
        ],
      ),
    ),
  );
}

class VideoTimeline extends StatefulWidget {
  const VideoTimeline({
    super.key,
    required this.duration,
    required this.position,
    required this.selectionStart,
    required this.selectionEnd,
    required this.zoom,
    required this.playing,
    required this.onZoomChanged,
    required this.onSelectionChanged,
    required this.onSelectionChangeEnd,
    required this.onSeek,
  });

  final Duration duration;
  final Duration position;
  final Duration selectionStart;
  final Duration selectionEnd;
  final double zoom;
  final bool playing;
  final ValueChanged<double> onZoomChanged;
  final ValueChanged<RangeValues> onSelectionChanged;
  final ValueChanged<RangeValues> onSelectionChangeEnd;
  final ValueChanged<Duration> onSeek;

  @override
  State<VideoTimeline> createState() => _VideoTimelineState();
}

class _VideoTimelineState extends State<VideoTimeline> {
  final ScrollController scrollController = ScrollController();
  final GlobalKey timelineContentKey = GlobalKey();
  double viewportWidth = 0;
  double contentWidth = 0;
  bool manualScroll = false;
  double? zoomAnchorFraction;
  double? zoomAnchorViewportX;
  bool? draggingStartHandle;
  double dragGrabOffset = 0;
  RangeValues? dragRange;

  @override
  void didUpdateWidget(covariant VideoTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.playing && widget.playing) manualScroll = false;
    if (oldWidget.zoom != widget.zoom && zoomAnchorFraction != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreZoomAnchor());
    }
    if (oldWidget.position != widget.position ||
        oldWidget.playing != widget.playing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _followPlayhead());
    }
  }

  void _restoreZoomAnchor() {
    if (!mounted || !scrollController.hasClients) return;
    final fraction = zoomAnchorFraction;
    final viewportX = zoomAnchorViewportX;
    zoomAnchorFraction = null;
    zoomAnchorViewportX = null;
    if (fraction == null || viewportX == null) return;
    final target = (contentWidth * fraction - viewportX).clamp(
      0.0,
      scrollController.position.maxScrollExtent,
    );
    scrollController.jumpTo(target);
  }

  void _followPlayhead() {
    if (!mounted ||
        !widget.playing ||
        manualScroll ||
        !scrollController.hasClients ||
        viewportWidth <= 0) {
      return;
    }
    final durationMs = math.max(1, widget.duration.inMilliseconds);
    final x =
        contentWidth *
        widget.position.inMilliseconds.clamp(0, durationMs) /
        durationMs;
    final relativeX = x - scrollController.offset;
    double? target;
    if (relativeX > viewportWidth * .75) {
      target = x - viewportWidth * .60;
    } else if (relativeX < viewportWidth * .08) {
      target = x - viewportWidth * .40;
    }
    if (target == null) return;
    final bounded = target.clamp(
      0.0,
      scrollController.position.maxScrollExtent,
    );
    if ((bounded - scrollController.offset).abs() < 2) return;
    unawaited(
      scrollController.animateTo(
        bounded,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _beginHandleDrag({
    required bool startHandle,
    required Offset globalPosition,
    required double handleX,
  }) {
    final renderBox =
        timelineContentKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    draggingStartHandle = startHandle;
    dragGrabOffset = renderBox.globalToLocal(globalPosition).dx - handleX;
    dragRange = RangeValues(
      widget.selectionStart.inMilliseconds.toDouble(),
      widget.selectionEnd.inMilliseconds.toDouble(),
    );
  }

  void _updateHandleDrag(Offset globalPosition, int durationMs) {
    final startHandle = draggingStartHandle;
    final renderBox =
        timelineContentKey.currentContext?.findRenderObject() as RenderBox?;
    if (startHandle == null || renderBox == null || contentWidth <= 0) return;
    final localX = renderBox.globalToLocal(globalPosition).dx - dragGrabOffset;
    final targetMs =
        localX.clamp(0.0, contentWidth) / contentWidth * durationMs;
    const minimumSelectionMs = 100.0;
    final current =
        dragRange ??
        RangeValues(
          widget.selectionStart.inMilliseconds.toDouble(),
          widget.selectionEnd.inMilliseconds.toDouble(),
        );
    final RangeValues next;
    if (startHandle) {
      next = RangeValues(
        targetMs.clamp(0.0, current.end - minimumSelectionMs),
        current.end,
      );
    } else {
      next = RangeValues(
        current.start,
        targetMs.clamp(
          current.start + minimumSelectionMs,
          durationMs.toDouble(),
        ),
      );
    }
    dragRange = next;
    widget.onSelectionChanged(next);
  }

  void _endHandleDrag() {
    final range =
        dragRange ??
        RangeValues(
          widget.selectionStart.inMilliseconds.toDouble(),
          widget.selectionEnd.inMilliseconds.toDouble(),
        );
    draggingStartHandle = null;
    dragRange = null;
    widget.onSelectionChangeEnd(range);
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final durationMs = math.max(1, widget.duration.inMilliseconds);
      viewportWidth = constraints.maxWidth;
      contentWidth = math.max(
        constraints.maxWidth,
        constraints.maxWidth * widget.zoom,
      );
      final startMs = widget.selectionStart.inMilliseconds
          .clamp(0, durationMs)
          .toDouble();
      final endMs = widget.selectionEnd.inMilliseconds
          .clamp(startMs.round(), durationMs)
          .toDouble();
      final startX = contentWidth * startMs / durationMs;
      final endX = contentWidth * endMs / durationMs;
      return Listener(
        key: const Key('video-editor-timeline'),
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent) return;
          final delta = event.scrollDelta.dy == 0
              ? event.scrollDelta.dx
              : event.scrollDelta.dy;
          final next = (widget.zoom * (delta < 0 ? 1.2 : 1 / 1.2)).clamp(
            1.0,
            8.0,
          );
          final viewportX = event.localPosition.dx.clamp(
            0.0,
            constraints.maxWidth,
          );
          zoomAnchorFraction =
              (scrollController.hasClients
                  ? scrollController.offset + viewportX
                  : viewportX) /
              contentWidth;
          zoomAnchorViewportX = viewportX;
          widget.onZoomChanged(next);
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification &&
                notification.dragDetails != null) {
              manualScroll = true;
            }
            return false;
          },
          child: ScrollbarTheme(
            data: ScrollbarThemeData(
              thumbColor: WidgetStatePropertyAll(
                Theme.of(context).colorScheme.primary,
              ),
              trackColor: WidgetStatePropertyAll(
                Theme.of(context).colorScheme.primaryContainer
                    .withValues(alpha: .65),
              ),
              trackBorderColor: WidgetStatePropertyAll(
                Theme.of(context).colorScheme.primary.withValues(alpha: .35),
              ),
              thickness: const WidgetStatePropertyAll(10),
              radius: const Radius.circular(999),
            ),
            child: Scrollbar(
              key: const Key('video-editor-horizontal-scrollbar'),
              controller: scrollController,
              thumbVisibility: widget.zoom > 1,
              trackVisibility: widget.zoom > 1,
              interactive: true,
              child: SingleChildScrollView(
                controller: scrollController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: contentWidth,
                  child: KeyedSubtree(
                    key: const Key('video-editor-range'),
                    child: Stack(
                      key: timelineContentKey,
                      fit: StackFit.expand,
                      children: [
                        CustomPaint(
                          painter: _TimelinePainter(
                            duration: widget.duration,
                            position: widget.position,
                            selectionStart: widget.selectionStart,
                            selectionEnd: widget.selectionEnd,
                            zoom: widget.zoom,
                            primary: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTapDown: (details) {
                            final milliseconds =
                                (details.localPosition.dx /
                                        contentWidth *
                                        durationMs)
                                    .round();
                            widget.onSeek(Duration(milliseconds: milliseconds));
                          },
                        ),
                        _TimelineHandle(
                          key: const Key('video-editor-start-handle'),
                          x: startX,
                          width: contentWidth,
                          label: _formatDuration(widget.selectionStart),
                          color: Theme.of(context).colorScheme.secondary,
                          onDragStart: (position) => _beginHandleDrag(
                            startHandle: true,
                            globalPosition: position,
                            handleX: startX,
                          ),
                          onDragUpdate: (position) =>
                              _updateHandleDrag(position, durationMs),
                          onDragEnd: _endHandleDrag,
                        ),
                        _TimelineHandle(
                          key: const Key('video-editor-end-handle'),
                          x: endX,
                          width: contentWidth,
                          label: _formatDuration(widget.selectionEnd),
                          color: Theme.of(context).colorScheme.secondary,
                          onDragStart: (position) => _beginHandleDrag(
                            startHandle: false,
                            globalPosition: position,
                            handleX: endX,
                          ),
                          onDragUpdate: (position) =>
                              _updateHandleDrag(position, durationMs),
                          onDragEnd: _endHandleDrag,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _TimelineHandle extends StatelessWidget {
  const _TimelineHandle({
    super.key,
    required this.x,
    required this.width,
    required this.label,
    required this.color,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final double x;
  final double width;
  final String label;
  final Color color;
  final ValueChanged<Offset> onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    const handleWidth = 64.0;
    final left = (x - handleWidth / 2).clamp(0.0, width - handleWidth);
    final lineOffset = x - left;
    return Positioned(
      left: left,
      top: 0,
      bottom: 14,
      width: handleWidth,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (details) => onDragStart(details.globalPosition),
        onHorizontalDragUpdate: (details) =>
            onDragUpdate(details.globalPosition),
        onHorizontalDragEnd: (_) => onDragEnd(),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 2,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
            Positioned(
              left: lineOffset - 5,
              top: 23,
              bottom: 2,
              child: Container(
                width: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: Colors.white70),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  const _TimelinePainter({
    required this.duration,
    required this.position,
    required this.selectionStart,
    required this.selectionEnd,
    required this.zoom,
    required this.primary,
  });

  final Duration duration;
  final Duration position;
  final Duration selectionStart;
  final Duration selectionEnd;
  final double zoom;
  final Color primary;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xff222936);
    final tick = Paint()..color = const Color(0x66ffffff);
    final minorTick = Paint()..color = const Color(0x22ffffff);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      background,
    );
    final durationMs = math.max(1, duration.inMilliseconds);
    final startX =
        size.width *
        selectionStart.inMilliseconds.clamp(0, durationMs) /
        durationMs;
    final endX =
        size.width *
        selectionEnd.inMilliseconds.clamp(0, durationMs) /
        durationMs;
    final positionX =
        size.width * position.inMilliseconds.clamp(0, durationMs) / durationMs;
    final selectionRect = Rect.fromLTRB(startX, 22, endX, size.height - 14);
    canvas.drawRect(
      selectionRect,
      Paint()..color = primary.withValues(alpha: .22),
    );
    canvas.drawRect(
      Rect.fromLTRB(
        startX,
        22,
        positionX.clamp(startX, endX),
        size.height - 14,
      ),
      Paint()..color = primary.withValues(alpha: .38),
    );

    final divisions = (24 * zoom).round().clamp(24, 160);
    for (var index = 0; index <= divisions; index += 1) {
      final x = size.width * index / divisions;
      final major = index % 6 == 0;
      canvas.drawLine(
        Offset(x, major ? 34 : 41),
        Offset(x, major ? 55 : 51),
        major ? tick : minorTick,
      );
      final barHeight = 12 + (index * 17 % 34).toDouble();
      canvas.drawLine(
        Offset(x, size.height - 18),
        Offset(x, size.height - 18 - barHeight),
        minorTick,
      );
    }
    final playhead = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(positionX, 18),
      Offset(positionX, size.height - 14),
      playhead,
    );
    canvas.drawPath(
      Path()
        ..moveTo(positionX - 6, 17)
        ..lineTo(positionX + 6, 17)
        ..lineTo(positionX, 24)
        ..close(),
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter oldDelegate) =>
      oldDelegate.duration != duration ||
      oldDelegate.position != position ||
      oldDelegate.selectionStart != selectionStart ||
      oldDelegate.selectionEnd != selectionEnd ||
      oldDelegate.zoom != zoom ||
      oldDelegate.primary != primary;
}

String _formatDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  final milliseconds = value.inMilliseconds
      .remainder(1000)
      .toString()
      .padLeft(3, '0');
  return hours > 0
      ? '$hours:$minutes:$seconds.$milliseconds'
      : '$minutes:$seconds.$milliseconds';
}

String _formatSelectionSeconds(Duration value) {
  final seconds = value.inMilliseconds / 1000;
  return seconds >= 100
      ? seconds.toStringAsFixed(1)
      : seconds.toStringAsFixed(2);
}
