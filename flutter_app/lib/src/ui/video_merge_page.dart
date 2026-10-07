import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../backend/app_backend.dart';
import '../l10n/app_localizations.dart';
import '../rust/models.dart';
import 'desktop_window_drag_area.dart';
import 'video_runtime.dart';
import 'video_thumbnail.dart';

class VideoMergePage extends StatefulWidget {
  const VideoMergePage({
    super.key,
    required this.backend,
    required this.videos,
  });

  final AppBackend backend;
  final List<MediaAsset> videos;

  static Future<MediaAsset?> open(
    BuildContext context, {
    required AppBackend backend,
    required List<MediaAsset> videos,
  }) => showGeneralDialog<MediaAsset>(
    context: context,
    barrierDismissible: false,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black87,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, _, _) => Dialog(
      key: const Key('video-merge-dialog'),
      insetPadding: const EdgeInsets.all(10),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: MediaQuery.sizeOf(dialogContext).width,
        height: MediaQuery.sizeOf(dialogContext).height,
        child: VideoMergePage(backend: backend, videos: videos),
      ),
    ),
    transitionBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: child,
    ),
  );

  @override
  State<VideoMergePage> createState() => _VideoMergePageState();
}

class _VideoMergePageState extends State<VideoMergePage> {
  late final List<MediaAsset> videos = List.of(widget.videos);
  Player? previewPlayer;
  VideoController? previewController;
  String? previewPath;
  bool busy = false;
  Object? previewError;

  @override
  void dispose() {
    final player = previewPlayer;
    final path = previewPath;
    if (player != null) unawaited(player.dispose());
    if (path != null) unawaited(widget.backend.discardTemporaryMedia(path));
    super.dispose();
  }

  Future<void> _invalidatePreview() async {
    final player = previewPlayer;
    final path = previewPath;
    previewPlayer = null;
    previewController = null;
    previewPath = null;
    previewError = null;
    if (player != null) await player.dispose();
    if (path != null) await widget.backend.discardTemporaryMedia(path);
  }

  Future<void> _close() async {
    if (busy) return;
    await _invalidatePreview();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _previewSource(MediaAsset video) async {
    await previewPlayer?.pause();
    if (!mounted) return;
    await _SourceVideoPreview.open(context, video: video);
  }

  Future<String?> _ensurePreview() async {
    if (previewPath != null) return previewPath;
    setState(() {
      busy = true;
      previewError = null;
    });
    try {
      final path = await widget.backend.createMergedVideoPreview(videos);
      VideoRuntime.ensureInitialized();
      final player = Player();
      final controller = VideoController(player);
      await player.open(Media(path), play: false);
      if (!mounted) {
        await player.dispose();
        await widget.backend.discardTemporaryMedia(path);
        return null;
      }
      setState(() {
        previewPath = path;
        previewPlayer = player;
        previewController = controller;
        busy = false;
      });
      return path;
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to create merged video preview',
        error,
        stackTrace,
      );
      if (!mounted) return null;
      setState(() {
        busy = false;
        previewError = error;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.select(
              zh: '合并预览生成失败：$error',
              en: 'Failed to build merged preview: $error',
            ),
          ),
        ),
      );
      return null;
    }
  }

  Future<void> _saveAs() async {
    if (busy) return;
    final path = await _ensurePreview();
    if (path == null || !mounted) return;
    setState(() => busy = true);
    final player = previewPlayer;
    if (player != null) await player.dispose();
    previewPlayer = null;
    previewController = null;
    previewPath = null;
    try {
      final asset = await widget.backend.saveMergedVideo(
        videos,
        preparedPath: path,
      );
      if (!mounted) return;
      Navigator.of(context).pop(asset);
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to merge videos',
        error,
        stackTrace,
      );
      await widget.backend.discardTemporaryMedia(path);
      if (!mounted) return;
      setState(() {
        busy = false;
        previewError = error;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.select(
              zh: '视频合并失败：$error',
              en: 'Video merge failed: $error',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                child: Row(
                  children: [
                    IconButton.filledTonal(
                      key: const Key('video-merge-close'),
                      onPressed: busy ? null : _close,
                      tooltip: context.l10n.select(zh: '关闭', en: 'Close'),
                      icon: const Icon(Icons.close_rounded),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DesktopWindowDragArea(
                        key: const Key('video-merge-window-drag-area'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.l10n.select(
                                zh: '合并视频',
                                en: 'Merge videos',
                              ),
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              context.l10n.select(
                                zh: '${videos.length} 个视频 · 拖拽下方条目调整拼接顺序',
                                en: '${videos.length} videos · Drag the items below to change their order',
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      key: const Key('video-merge-preview'),
                      onPressed: busy ? null : _ensurePreview,
                      icon: const Icon(Icons.play_circle_outline_rounded),
                      label: Text(context.l10n.select(zh: '预览', en: 'Preview')),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      key: const Key('video-merge-save-as'),
                      onPressed: busy ? null : _saveAs,
                      icon: const Icon(Icons.save_as_rounded),
                      label: Text(context.l10n.select(zh: '另存', en: 'Save as')),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildPreview(context)),
              Container(
                height: 250,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: ReorderableListView.builder(
                  key: const Key('video-merge-order-list'),
                  scrollDirection: Axis.horizontal,
                  buildDefaultDragHandles: false,
                  itemCount: videos.length,
                  onReorderItem: (oldIndex, newIndex) {
                    setState(() {
                      final item = videos.removeAt(oldIndex);
                      videos.insert(newIndex, item);
                    });
                    unawaited(
                      _invalidatePreview().then((_) {
                        if (mounted) setState(() {});
                      }),
                    );
                  },
                  itemBuilder: (context, index) {
                    final video = videos[index];
                    return SizedBox(
                      key: ValueKey(video.id),
                      width: 284,
                      child: Card(
                        margin: const EdgeInsets.only(right: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(child: Text('${index + 1}')),
                                  const Spacer(),
                                  ReorderableDragStartListener(
                                    index: index,
                                    child: IconButton(
                                      key: ValueKey(
                                        'video-merge-drag-${video.id}',
                                      ),
                                      tooltip: context.l10n.select(
                                        zh: '拖拽排序',
                                        en: 'Drag to reorder',
                                      ),
                                      onPressed: null,
                                      icon: const Icon(
                                        Icons.drag_indicator_rounded,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Expanded(
                                child: _MergeVideoThumbnail(
                                  video: video,
                                  backend: widget.backend,
                                  onPreview: () => _previewSource(video),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                video.originalName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                video.gameName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          if (busy)
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0x88000000),
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(width: 16),
                          Text(
                            context.l10n.select(
                              zh: '正在处理视频…',
                              en: 'Processing videos…',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _buildPreview(BuildContext context) {
    final controller = previewController;
    if (controller != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Video(
              controller: controller,
              controls: AdaptiveVideoControls,
            ),
          ),
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            previewError == null
                ? Icons.video_collection_outlined
                : Icons.error_outline_rounded,
            size: 58,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            previewError == null
                ? context.l10n.select(
                    zh: '调整顺序后点击“预览”生成拼接结果',
                    en: 'Arrange the videos, then select Preview to build the result',
                  )
                : context.l10n.select(
                    zh: '预览暂不可用，请调整顺序或重试。',
                    en: 'Preview is unavailable. Adjust the order or try again.',
                  ),
          ),
        ],
      ),
    );
  }
}

class _MergeVideoThumbnail extends StatelessWidget {
  const _MergeVideoThumbnail({
    required this.video,
    required this.backend,
    required this.onPreview,
  });

  final MediaAsset video;
  final AppBackend backend;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) => FutureBuilder<VideoThumbnailData>(
    future: VideoThumbnailCache.load(
      video,
      onError: (error, stackTrace) => backend.logError(
        'Failed to generate merge thumbnail for media ${video.id}',
        error,
        stackTrace,
      ),
    ),
    builder: (context, snapshot) {
      final bytes = snapshot.data?.bytes;
      return AspectRatio(
        key: ValueKey('video-merge-thumbnail-${video.id}'),
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (bytes != null && bytes.isNotEmpty)
                Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
              else
                ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Center(
                    child: snapshot.connectionState == ConnectionState.waiting
                        ? const SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.movie_outlined, size: 36),
                  ),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: .5),
                    ],
                  ),
                ),
              ),
              Center(
                child: IconButton.filled(
                  key: ValueKey('video-merge-preview-${video.id}'),
                  tooltip: context.l10n.select(
                    zh: '预览这个视频',
                    en: 'Preview this video',
                  ),
                  onPressed: onPreview,
                  icon: const Icon(Icons.play_arrow_rounded, size: 30),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _SourceVideoPreview extends StatefulWidget {
  const _SourceVideoPreview({required this.video});

  final MediaAsset video;

  static Future<void> open(BuildContext context, {required MediaAsset video}) =>
      showDialog<void>(
        context: context,
        barrierColor: Colors.black87,
        builder: (_) => Dialog(
          key: const Key('video-merge-source-preview'),
          insetPadding: const EdgeInsets.all(24),
          backgroundColor: const Color(0xff090b10),
          child: _SourceVideoPreview(video: video),
        ),
      );

  @override
  State<_SourceVideoPreview> createState() => _SourceVideoPreviewState();
}

class _SourceVideoPreviewState extends State<_SourceVideoPreview> {
  late final Player player = _createPlayer();
  late final VideoController controller = VideoController(player);

  Player _createPlayer() {
    VideoRuntime.ensureInitialized();
    return Player();
  }

  Object? error;

  @override
  void initState() {
    super.initState();
    player.open(Media(widget.video.storagePath), play: true).catchError((
      Object value,
    ) {
      if (mounted) setState(() => error = value);
    });
  }

  @override
  void dispose() {
    unawaited(player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 760),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          child: Row(
            children: [
              Expanded(
                child: DesktopWindowDragArea(
                  key: const Key('video-merge-source-window-drag-area'),
                  child: Text(
                    widget.video.originalName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              IconButton.filledTonal(
                key: const Key('video-merge-source-preview-close'),
                tooltip: context.l10n.select(zh: '关闭预览', en: 'Close preview'),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: error == null
                ? Center(
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Video(
                        controller: controller,
                        controls: AdaptiveVideoControls,
                      ),
                    ),
                  )
                : Center(
                    child: Text(
                      context.l10n.select(
                        zh: '无法预览这个视频：$error',
                        en: 'Unable to preview this video: $error',
                      ),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
          ),
        ),
      ],
    ),
  );
}
