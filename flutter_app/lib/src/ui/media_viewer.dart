import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../backend/app_backend.dart';
import '../l10n/app_localizations.dart';
import '../rust/models.dart';
import 'desktop_window_drag_area.dart';
import 'media_metadata_editor.dart';
import 'video_editor.dart';
import 'video_runtime.dart';

Set<int> adjacentVideoIndices(int index, int length) => {
  for (final candidate in [index - 1, index, index + 1])
    if (candidate >= 0 && candidate < length) candidate,
};

class MediaViewer extends StatefulWidget {
  const MediaViewer({
    super.key,
    required this.backend,
    required this.items,
    required this.initialIndex,
    required this.autoPlayVideo,
    required this.compactTagDisplay,
    this.onMetadataChanged,
  });

  final AppBackend backend;
  final List<MediaAsset> items;
  final int initialIndex;
  final bool autoPlayVideo;
  final bool compactTagDisplay;
  final VoidCallback? onMetadataChanged;

  static Future<void> open(
    BuildContext context, {
    required AppBackend backend,
    required List<MediaAsset> items,
    required int initialIndex,
    required bool autoPlayVideo,
    required bool compactTagDisplay,
    VoidCallback? onMetadataChanged,
  }) => showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black87,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, _, _) => Dialog(
      key: const Key('media-viewer-dialog'),
      insetPadding: const EdgeInsets.all(5),
      backgroundColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: MediaQuery.sizeOf(dialogContext).width,
        height: MediaQuery.sizeOf(dialogContext).height,
        child: MediaViewer(
          backend: backend,
          items: items,
          initialIndex: initialIndex,
          autoPlayVideo: autoPlayVideo,
          compactTagDisplay: compactTagDisplay,
          onMetadataChanged: onMetadataChanged,
        ),
      ),
    ),
    transitionBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: ScaleTransition(
        scale: Tween(begin: .985, end: 1.0).animate(animation),
        child: child,
      ),
    ),
  );

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  late final PageController pageController = PageController(
    initialPage: widget.initialIndex,
  );
  final FocusNode keyboardFocus = FocusNode(debugLabel: 'media-viewer');
  final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  final Map<int, GlobalKey<_VideoViewerState>> videoKeys = {};
  late final List<MediaAsset> items = List.of(widget.items);
  late int currentIndex = widget.initialIndex;
  bool immersive = false;

  @override
  void initState() {
    super.initState();
    _preloadAround(currentIndex);
  }

  void _preloadAround(int index) {
    for (final candidate in adjacentVideoIndices(index, items.length)) {
      final item = items[candidate];
      if (item.kind == MediaKind.video) {
        unawaited(VideoRuntime.prepare(item.storagePath));
      }
    }
  }

  @override
  void dispose() {
    unawaited(VideoRuntime.clearPrepared());
    pageController.dispose();
    keyboardFocus.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    if (index < 0 || index >= items.length) return;
    pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    final editingText =
        focusedContext?.widget is EditableText ||
        focusedContext?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (event.logicalKey == LogicalKeyboardKey.space && !editingText) {
      final asset = items[currentIndex];
      if (asset.kind == MediaKind.video) {
        videoKeys[asset.id]?.currentState?.togglePlayback();
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _goTo(currentIndex - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _goTo(currentIndex + 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _editCurrent() async {
    final asset = items[currentIndex];
    final update = await showModalBottomSheet<MediaMetadataUpdate>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 680),
      builder: (_) =>
          MediaMetadataEditor(backend: widget.backend, asset: asset),
    );
    if (update == null || !mounted) return;
    setState(() {
      items[currentIndex] = _copyMediaAsset(
        asset,
        note: update.note,
        tags: update.tags,
      );
    });
    widget.onMetadataChanged?.call();
  }

  Future<void> _editCurrentVideo() async {
    final asset = items[currentIndex];
    if (asset.kind != MediaKind.video) return;
    await videoKeys[asset.id]?.currentState?.pausePlayback();
    if (!mounted) return;
    final result = await VideoEditorPage.open(
      context,
      backend: widget.backend,
      source: asset,
      onMediaCreated: widget.onMetadataChanged,
    );
    if (result == null || !mounted) return;
    var targetIndex = currentIndex;
    setState(() {
      if (result.overwrite) {
        items[currentIndex] = result.asset;
        videoKeys.remove(asset.id);
      } else {
        items.insert(currentIndex + 1, result.asset);
        targetIndex = currentIndex + 1;
        currentIndex = targetIndex;
      }
    });
    if (!result.overwrite) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (pageController.hasClients) pageController.jumpToPage(targetIndex);
      });
    }
    widget.onMetadataChanged?.call();
    messengerKey.currentState?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          result.overwrite
              ? context.l10n.select(
                  zh: '已保存并更新原视频：${result.asset.originalName}',
                  en: 'Updated the original video: ${result.asset.originalName}',
                )
              : context.l10n.select(
                  zh: '已另存并切换到新视频：${result.asset.originalName}',
                  en: 'Saved and opened the new video: ${result.asset.originalName}',
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = items[currentIndex];
    final canGoBack = currentIndex > 0;
    final canGoForward = currentIndex < items.length - 1;
    final horizontalInset = immersive
        ? 12.0
        : MediaQuery.sizeOf(context).width < 700
        ? 16.0
        : 54.0;
    return ScaffoldMessenger(
      key: messengerKey,
      child: Scaffold(
        backgroundColor: const Color(0xff090b10),
        body: Focus(
          autofocus: true,
          focusNode: keyboardFocus,
          onKeyEvent: _handleKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                controller: pageController,
                itemCount: items.length,
                allowImplicitScrolling: true,
                onPageChanged: (index) {
                  setState(() => currentIndex = index);
                  _preloadAround(index);
                },
                itemBuilder: (context, index) {
                  final media = items[index];
                  return Padding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalInset,
                      immersive ? 12 : 48,
                      horizontalInset,
                      immersive ? 12 : 126,
                    ),
                    child: media.kind == MediaKind.video
                        ? _VideoViewer(
                            key: videoKeys.putIfAbsent(
                              media.id,
                              () => GlobalKey<_VideoViewerState>(
                                debugLabel: 'video-viewer-${media.id}',
                              ),
                            ),
                            path: media.storagePath,
                            active: index == currentIndex,
                            autoPlay: widget.autoPlayVideo,
                          )
                        : _ImageViewer(path: media.storagePath),
                  );
                },
              ),
              Positioned(
                top: 0,
                left: 82,
                right: 82,
                height: 44,
                child: DesktopWindowDragArea(
                  key: const Key('media-viewer-window-drag-area'),
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned(
                top: 18,
                left: 18,
                child: SafeArea(
                  child: IconButton.filledTonal(
                    key: const Key('media-viewer-close'),
                    tooltip: context.l10n.select(
                      zh: '关闭预览',
                      en: 'Close preview',
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              ),
              Positioned(
                right: 18,
                bottom: immersive ? 18 : 132,
                child: SafeArea(
                  top: false,
                  child: IconButton.filledTonal(
                    key: const Key('media-viewer-immersive'),
                    tooltip: immersive
                        ? context.l10n.select(
                            zh: '退出应用内沉浸预览',
                            en: 'Exit in-app immersive view',
                          )
                        : context.l10n.select(
                            zh: '应用内沉浸预览',
                            en: 'In-app immersive view',
                          ),
                    onPressed: () => setState(() => immersive = !immersive),
                    icon: Icon(
                      immersive
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                    ),
                  ),
                ),
              ),
              if (canGoBack)
                Positioned(
                  left: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: IconButton.filledTonal(
                      key: const Key('media-viewer-previous'),
                      tooltip: context.l10n.select(
                        zh: '上一项',
                        en: 'Previous item',
                      ),
                      onPressed: () => _goTo(currentIndex - 1),
                      icon: const Icon(Icons.chevron_left_rounded, size: 34),
                    ),
                  ),
                ),
              if (canGoForward)
                Positioned(
                  right: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: IconButton.filledTonal(
                      key: const Key('media-viewer-next'),
                      tooltip: context.l10n.select(zh: '下一项', en: 'Next item'),
                      onPressed: () => _goTo(currentIndex + 1),
                      icon: const Icon(Icons.chevron_right_rounded, size: 34),
                    ),
                  ),
                ),
              if (!immersive)
                Positioned(
                  left: horizontalInset,
                  right: horizontalInset,
                  bottom: 8,
                  child: SafeArea(
                    top: false,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 112),
                      child: Material(
                        color: const Color(0xdd181b24),
                        borderRadius: BorderRadius.circular(20),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      item.originalName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    '${currentIndex + 1} / ${items.length}',
                                    key: const Key('media-viewer-counter'),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  if (item.kind == MediaKind.video) ...[
                                    FilledButton.tonalIcon(
                                      key: const Key('media-viewer-edit-video'),
                                      onPressed: _editCurrentVideo,
                                      icon: const Icon(
                                        Icons.content_cut_rounded,
                                      ),
                                      label: Text(
                                        context.l10n.select(
                                          zh: '剪辑',
                                          en: 'Edit video',
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  FilledButton.tonalIcon(
                                    key: const Key(
                                      'media-viewer-edit-metadata',
                                    ),
                                    onPressed: _editCurrent,
                                    icon: const Icon(Icons.edit_note_rounded),
                                    label: Text(
                                      context.l10n.select(
                                        zh: '编辑标签与备注',
                                        en: 'Edit tags & note',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 7),
                              _ViewerTags(
                                item: item,
                                compact: widget.compactTagDisplay,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                item.note?.isNotEmpty == true
                                    ? item.note!
                                    : context.l10n.select(
                                        zh: '暂无备注',
                                        en: 'No note',
                                      ),
                                key: const Key('media-viewer-note'),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: item.note?.isNotEmpty == true
                                      ? Colors.white70
                                      : Colors.white38,
                                  height: 1.35,
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
      ),
    );
  }
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) => InteractiveViewer(
    minScale: 0.75,
    maxScale: 5,
    child: Center(
      child: Image.file(
        File(path),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _ViewerError(
          icon: Icons.broken_image_outlined,
          message: context.l10n.select(
            zh: '无法读取这张图片',
            en: 'Unable to load this image',
          ),
        ),
      ),
    ),
  );
}

class _ViewerTags extends StatelessWidget {
  const _ViewerTags({required this.item, required this.compact});

  final MediaAsset item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final gameTag = _ViewerTag(
      text: item.gameName.isEmpty
          ? context.l10n.select(zh: '未知游戏', en: 'Unknown game')
          : item.gameName,
      game: true,
    );
    final customTags = item.tags.isEmpty
        ? <Widget>[
            Text(
              context.l10n.select(zh: '暂无自定义标签', en: 'No custom tags'),
              style: const TextStyle(color: Colors.white54),
            ),
          ]
        : item.tags.map<Widget>((tag) => _ViewerTag(text: tag)).toList();

    if (compact) {
      return Wrap(
        key: const Key('media-viewer-compact-tags'),
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [gameTag, ...customTags],
      );
    }
    return Column(
      key: const Key('media-viewer-separated-tags'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [gameTag]),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: customTags,
        ),
      ],
    );
  }
}

class _VideoViewer extends StatefulWidget {
  const _VideoViewer({
    super.key,
    required this.path,
    required this.active,
    required this.autoPlay,
  });

  final String path;
  final bool active;
  final bool autoPlay;

  @override
  State<_VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<_VideoViewer>
    with AutomaticKeepAliveClientMixin {
  late final VideoPlayerHandle _playerHandle = VideoRuntime.acquirePlayer(
    widget.path,
  );
  late final Player player = _playerHandle.player;
  late final VideoController controller = VideoController(player);

  Object? openError;

  @override
  bool get wantKeepAlive => true;

  Future<void> togglePlayback() => player.playOrPause();

  Future<void> pausePlayback() => player.pause();

  @override
  void initState() {
    super.initState();
    (_playerHandle.ready ??
            player.open(
              Media(widget.path),
              play: widget.autoPlay && widget.active,
            ))
        .then((_) {
          if (widget.autoPlay && widget.active) unawaited(player.play());
        })
        .catchError((Object error) {
          if (mounted) setState(() => openError = error);
        });
  }

  @override
  void didUpdateWidget(covariant _VideoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) player.pause();
    if (!oldWidget.active && widget.active && widget.autoPlay) player.play();
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (openError != null) {
      return _ViewerError(
        icon: Icons.videocam_off_outlined,
        message: context.l10n.select(
          zh: '无法播放这个视频',
          en: 'Unable to play this video',
        ),
      );
    }
    const desktopControls = MaterialDesktopVideoControlsThemeData(
      toggleFullscreenOnDoublePress: false,
      bottomButtonBar: [
        MaterialDesktopSkipPreviousButton(),
        MaterialDesktopPlayOrPauseButton(),
        MaterialDesktopSkipNextButton(),
        MaterialDesktopVolumeButton(),
        MaterialDesktopPositionIndicator(),
        Spacer(),
      ],
    );
    const touchControls = MaterialVideoControlsThemeData(
      bottomButtonBar: [MaterialPositionIndicator(), Spacer()],
    );
    return Center(
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: MaterialDesktopVideoControlsTheme(
          normal: desktopControls,
          fullscreen: desktopControls,
          child: MaterialVideoControlsTheme(
            normal: touchControls,
            fullscreen: touchControls,
            child: Video(
              controller: controller,
              controls: AdaptiveVideoControls,
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewerTag extends StatelessWidget {
  const _ViewerTag({required this.text, this.game = false});

  final String text;
  final bool game;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: game ? const Color(0xff4d617e) : const Color(0xff303541),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (game) ...[
          const Icon(
            Icons.sports_esports_rounded,
            size: 15,
            color: Colors.white70,
          ),
          const SizedBox(width: 5),
        ],
        Text(text, style: const TextStyle(color: Colors.white70)),
      ],
    ),
  );
}

MediaAsset _copyMediaAsset(
  MediaAsset value, {
  String? note,
  List<String>? tags,
}) => MediaAsset(
  id: value.id,
  sha256: value.sha256,
  originalName: value.originalName,
  storagePath: value.storagePath,
  kind: value.kind,
  capturedAt: value.capturedAt,
  importedAt: value.importedAt,
  gameTitleId: value.gameTitleId,
  gameName: value.gameName,
  favorite: value.favorite,
  note: note ?? value.note,
  tags: tags ?? value.tags,
);

class _ViewerError extends StatelessWidget {
  const _ViewerError({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 64, color: Colors.white54),
        const SizedBox(height: 14),
        Text(message, style: const TextStyle(color: Colors.white70)),
      ],
    ),
  );
}
