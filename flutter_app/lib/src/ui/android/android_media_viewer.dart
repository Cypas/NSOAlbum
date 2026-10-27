import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../rust/settings.dart';
import '../../state/media_edit_controller.dart';
import '../../state/media_window_controller.dart';
import '../../platform/android_media_share.dart';
import '../../platform/android_media_clipboard.dart';
import 'android_media_album_actions.dart';
import '../video_preview_prefetch.dart';
import '../video_thumbnail.dart';
import '../video_preview.dart';
import 'android_back_guard.dart';
import 'android_media_information.dart';
import 'android_media_swipe_region.dart';
import 'android_metadata_editor.dart';
import 'android_page_frame.dart';
import 'android_video_editor.dart';
import 'android_video_surface.dart';

class AndroidMediaViewer extends StatefulWidget {
  const AndroidMediaViewer({
    super.key,
    required this.backend,
    required this.items,
    this.settings,
    this.initialIndex = 0,
    this.autoPlay,
    this.galleryQuery,
    this.initialPage,
    this.mediaFilter,
    this.sourceAlbum,
  });
  final AppBackend backend;
  final List<MediaAsset> items;
  final AppSettings? settings;
  final int initialIndex;
  final bool? autoPlay;
  final GalleryQuery? galleryQuery;
  final GalleryPage? initialPage;
  final bool Function(MediaAsset)? mediaFilter;
  final AlbumSummary? sourceAlbum;
  @override
  State<AndroidMediaViewer> createState() => _AndroidMediaViewerState();
}

class _AndroidViewerActionBar extends StatelessWidget {
  const _AndroidViewerActionBar({
    required this.item,
    required this.busy,
    required this.onTrim,
    required this.onShare,
    required this.onImmersive,
  });
  final MediaAsset item;
  final bool busy;
  final VoidCallback? onTrim;
  final VoidCallback onShare;
  final VoidCallback? onImmersive;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      top: false,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (item.kind == MediaKind.video)
            TextButton.icon(
              onPressed: busy ? null : onTrim,
              icon: const Icon(Icons.content_cut),
              label: Text(context.l10n.select(zh: '剪辑', en: 'Trim')),
            ),
          TextButton.icon(
            onPressed: busy ? null : onShare,
            icon: const Icon(Icons.share_outlined),
            label: Text(context.l10n.select(zh: '分享', en: 'Share')),
          ),
          if (onImmersive != null)
            IconButton(
              tooltip: context.l10n.select(
                zh: '应用内全屏',
                en: 'In-app fullscreen',
              ),
              onPressed: busy ? null : onImmersive,
              icon: const Icon(Icons.fit_screen_outlined),
            ),
        ],
      ),
    ),
  );
}

class _AndroidMediaViewerState extends State<AndroidMediaViewer>
    with SingleTickerProviderStateMixin {
  static const _imageZoomDecodeAllowance = 1.5;
  late List<MediaAsset> items = List.of(widget.items);
  late int index = widget.initialIndex;
  late PageController pages;
  late final AnimationController pageFade;
  late final Animation<double> pageOpacity;
  MediaWindowController? window;
  bool extendingWindow = false;
  Future<void>? windowRequest;
  final videoPages = <(int, String), GlobalKey<AndroidVideoSurfaceState>>{};
  GlobalKey<AndroidVideoSurfaceState> videoKey(MediaAsset asset) =>
      videoPages.putIfAbsent((asset.id, asset.sha256), GlobalKey.new);
  GlobalKey<AndroidVideoSurfaceState> get video => videoKey(items[index]);
  final transform = TransformationController();
  late final prefetch = MediaPreviewPrefetch(warm: _warm);
  Player? player;
  bool busy = false, switching = false, controlsVisible = true;
  int navigationGeneration = 0;
  final tagInput = TextEditingController();
  final noteInput = TextEditingController();
  bool addingTag = false, editingNote = false;
  bool detailsOpen = false, immersiveVideo = false;
  MediaDetails? currentDetails;
  bool get dirty =>
      editingNote || (addingTag && tagInput.text.trim().isNotEmpty);

  @override
  void initState() {
    super.initState();
    pageFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
    pageOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 1, end: 0), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: 0, end: 1), weight: 1),
    ]).animate(CurvedAnimation(parent: pageFade, curve: Curves.easeInOutCubic));
    if (widget.galleryQuery case final scope?) {
      final currentId = items[index].id;
      window = MediaWindowController(
        widget.backend,
        scope: scope,
        initial:
            widget.initialPage ??
            GalleryPage(items: items, hasBefore: false, hasAfter: false),
        mediaId: currentId,
        filter: widget.mediaFilter,
      );
      items = List.of(window!.items);
      index = items.indexWhere((item) => item.id == currentId);
    }
    pages = PageController(initialPage: index);
    transform.addListener(_zoomChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        prefetch.around(items, index);
        unawaited(_extendWindow());
      }
    });
  }

  void _zoomChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _warm(MediaAsset item) async {
    if (item.kind == MediaKind.video) {
      await VideoThumbnailCache.warmCached(item);
    } else if (mounted) {
      await precacheImage(
        _imageProvider(item.storagePath),
        context,
        onError: (_, _) {},
      );
    }
  }

  ImageProvider<Object> _imageProvider(String path) {
    final viewport = MediaQuery.sizeOf(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return ResizeImage(
      FileImage(File(path)),
      width: (viewport.width * pixelRatio * _imageZoomDecodeAllowance).round(),
      height: (viewport.height * pixelRatio * _imageZoomDecodeAllowance)
          .round(),
      policy: ResizeImagePolicy.fit,
    );
  }

  @override
  void dispose() {
    if (immersiveVideo) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    prefetch.dispose();
    window?.dispose();
    pages.dispose();
    pageFade.dispose();
    // The surface owns its player; do not dispose that player twice here.
    transform.removeListener(_zoomChanged);
    transform.dispose();
    tagInput.dispose();
    noteInput.dispose();
    super.dispose();
  }

  MediaAsset withMetadata(
    MediaAsset item, {
    List<String>? tags,
    String? note,
  }) => MediaAsset(
    id: item.id,
    sha256: item.sha256,
    originalName: item.originalName,
    storagePath: item.storagePath,
    kind: item.kind,
    capturedAt: item.capturedAt,
    importedAt: item.importedAt,
    gameTitleId: item.gameTitleId,
    gameName: item.gameName,
    favorite: item.favorite,
    note: note ?? item.note,
    tags: tags ?? item.tags,
  );

  Future<void> addTag() async {
    if (busy || switching || !addingTag) return;
    final value = tagInput.text.trim();
    if (value.isEmpty) {
      setState(() => addingTag = false);
      return;
    }
    final item = items[index];
    final duplicate = item.tags.any(
      (tag) => tag.trim().toLowerCase() == value.toLowerCase(),
    );
    final next = duplicate ? item.tags : [...item.tags, value];
    setState(() => busy = true);
    try {
      if (!duplicate) await widget.backend.replaceTags(item.id, next);
      if (!mounted) return;
      setState(() {
        items[index] = withMetadata(item, tags: next);
        tagInput.clear();
        addingTag = false;
      });
    } catch (error) {
      if (mounted) androidMessage(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> saveNote() async {
    if (busy || switching) return;
    final item = items[index];
    final value = noteInput.text;
    setState(() => busy = true);
    try {
      await widget.backend.setNote(item.id, value);
      if (mounted) {
        setState(() {
          items[index] = withMetadata(item, note: value);
          editingNote = false;
        });
      }
    } catch (error) {
      if (mounted) androidMessage(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> navigate(int delta) async {
    var next = index + delta;
    if (next < 0 || next >= items.length) {
      await _extendWindow();
      if (!mounted) return;
      next = index + delta;
    }
    if (!pages.hasClients) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !pages.hasClients) return;
    }
    if (busy || switching || next < 0 || next >= items.length) return;
    navigationGeneration++;
    setState(() => switching = true);
    var pageFadeStarted = false;
    try {
      if (dirty && !await confirmAndroidDiscard(context)) return;
      if (!mounted) return;
      final retained = {
        for (final position in [next - 1, next, next + 1])
          if (position >= 0 && position < items.length)
            (items[position].id, items[position].sha256),
      };
      setState(() {
        player = null;
        index = next;
        controlsVisible = true;
        addingTag = false;
        editingNote = false;
        tagInput.clear();
        noteInput.clear();
        transform.value = Matrix4.identity();
      });
      prefetch.around(items, index);
      final pageTransition = pages.animateToPage(
        next,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      pageFadeStarted = true;
      final fadeIn = pageFade.forward(from: 0);
      final retirements = <Future<void>>[];
      for (final key in videoPages.keys.toList(growable: false)) {
        if (retained.contains(key)) continue;
        final surface = videoPages.remove(key)?.currentState;
        if (surface != null) retirements.add(surface.release());
      }
      unawaited(_extendWindow());
      await Future.wait([pageTransition, fadeIn, ...retirements]);
    } catch (error) {
      if (mounted) androidMessage(context, error);
    } finally {
      if (mounted) {
        if (pageFadeStarted && pageFade.status != AnimationStatus.completed) {
          await pageFade.forward();
        }
        if (mounted) setState(() => switching = false);
        if (mounted && detailsOpen) unawaited(openDetails());
      }
    }
  }

  Future<void> _extendWindow() =>
      windowRequest ??= _fetchWindow().whenComplete(() => windowRequest = null);

  Future<void> _fetchWindow() async {
    final currentWindow = window;
    if (currentWindow == null || extendingWindow || !mounted) return;
    extendingWindow = true;
    try {
      await currentWindow.prefetchAround(items[index].id);
      if (!mounted) return;
      if (currentWindow.error != null) setState(() {});
      final currentId = items[index].id;
      final center = currentWindow.items.indexWhere(
        (item) => item.id == currentId,
      );
      if (center < 0) return;
      final local = {for (final item in items) item.id: item};
      final next = currentWindow.items
          .sublist(
            (center - 60).clamp(0, currentWindow.items.length),
            (center + 61).clamp(0, currentWindow.items.length),
          )
          .map((item) => local[item.id] ?? item)
          .toList();
      final anchor = next.indexWhere((item) => item.id == currentId);
      if (anchor < 0 ||
          (next.length == items.length &&
              next.first.id == items.first.id &&
              next.last.id == items.last.id)) {
        currentWindow.retainAround(currentId);
        setState(() {});
        return;
      }
      final generation = navigationGeneration;
      final retained = {for (final asset in next) (asset.id, asset.sha256)};
      for (final key in videoPages.keys.toList()) {
        if (!retained.contains(key)) {
          await videoPages.remove(key)?.currentState?.release();
        }
      }
      if (!mounted || generation != navigationGeneration) return;
      currentWindow.retainAround(currentId);
      final old = pages;
      final reanchor = anchor != index;
      setState(() {
        items = List.of(next);
        index = anchor;
        if (reanchor) pages = PageController(initialPage: anchor);
      });
      if (reanchor) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    } catch (failure) {
      if (mounted) setState(() => currentWindow.error = failure);
    } finally {
      extendingWindow = false;
    }
  }

  Future<void> edit() async {
    if (busy || switching) return;
    final generation = ++navigationGeneration;
    final item = items[index];
    await video.currentState?.pausePlayback();
    if (!mounted ||
        generation != navigationGeneration ||
        dirty ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            AndroidMetadataEditor(backend: widget.backend, asset: item),
      ),
    );
    if (result != true || !mounted || generation != navigationGeneration) {
      return;
    }
    final fresh = await widget.backend.loadMediaDetails(item.id);
    if (mounted && generation == navigationGeneration) {
      setState(() {
        items = items
            .map((old) => old.id == item.id ? fresh.media : old)
            .toList();
        currentDetails = fresh;
      });
    }
  }

  Future<void> openDetails() async {
    if (busy || switching) return;
    final id = items[index].id;
    try {
      final details = await widget.backend.loadMediaDetails(id);
      if (!mounted || items[index].id != id) return;
      setState(() {
        currentDetails = details;
        detailsOpen = true;
        controlsVisible = true;
      });
    } catch (error) {
      if (mounted) androidMessage(context, error);
    }
  }

  void closeDetails() {
    if (mounted) setState(() => detailsOpen = false);
  }

  Future<void> toggleImmersive() async {
    if (items[index].kind != MediaKind.video) return;
    final next = !immersiveVideo;
    setState(() => immersiveVideo = next);
    await SystemChrome.setEnabledSystemUIMode(
      next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  Future<void> copyToClipboard() async {
    if (items[index].kind != MediaKind.image || busy) return;
    setState(() => busy = true);
    try {
      await const AndroidMediaClipboard().copyFile(items[index].storagePath);
      if (mounted) {
        androidMessage(
          context,
          context.l10n.select(zh: '已复制到剪贴板', en: 'Copied to clipboard'),
          isError: false,
        );
      }
    } catch (error) {
      if (mounted) androidMessage(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> albumAction({required bool move}) async {
    if (busy || switching) return;
    setState(() => busy = true);
    try {
      await showAndroidMediaAlbumAction(
        context,
        backend: widget.backend,
        item: items[index],
        sourceAlbum: widget.sourceAlbum,
        move: move,
      );
    } catch (error) {
      if (mounted) androidMessage(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> frame() async {
    final current = player;
    if (current == null || busy || switching) return;
    setState(() => busy = true);
    try {
      final bytes = await current.screenshot(format: 'image/jpeg');
      if (bytes == null || bytes.isEmpty) {
        throw StateError('Frame capture unavailable');
      }
      final editor = MediaEditController(widget.backend);
      try {
        await editor.frame(items[index], bytes);
      } finally {
        await editor.dispose();
      }
      if (mounted) {
        androidMessage(
          context,
          context.l10n.select(zh: '帧图已保存', en: 'Frame saved'),
          isError: false,
        );
      }
    } catch (error) {
      if (mounted) androidMessage(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> trim() async {
    if (busy || switching) return;
    final generation = ++navigationGeneration;
    final item = items[index];
    final sourceVideo = video;
    await sourceVideo.currentState?.pausePlayback();
    if (!mounted ||
        generation != navigationGeneration ||
        dirty ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final result = await Navigator.of(context).push<MediaAsset>(
      MaterialPageRoute(
        builder: (_) =>
            AndroidVideoEditor(backend: widget.backend, source: item),
      ),
    );
    if (result == null ||
        !mounted ||
        generation != navigationGeneration ||
        result.id != item.id) {
      return;
    }
    await sourceVideo.currentState?.release();
    if (mounted && generation == navigationGeneration) {
      setState(() {
        videoPages.remove((item.id, item.sha256));
        items[index] = result;
        player = null;
      });
    }
  }

  void beginNote() => setState(() {
    noteInput.text = items[index].note ?? '';
    editingNote = true;
  });

  Widget _picture(MediaAsset item) => AndroidMediaSwipeRegion(
    enabled: !busy && !switching && transform.value.getMaxScaleOnAxis() <= 1.01,
    onSwipe: (delta) => unawaited(navigate(delta)),
    onVerticalSwipe: (delta) {
      if (delta > 0 && !detailsOpen) unawaited(openDetails());
      if (delta < 0 && detailsOpen) closeDetails();
    },
    child: Semantics(
      button: true,
      label: controlsVisible
          ? context.l10n.select(zh: '隐藏操作栏', en: 'Hide controls')
          : context.l10n.select(zh: '显示操作栏', en: 'Show controls'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: dirty
            ? null
            : () => setState(() => controlsVisible = !controlsVisible),
        child: InteractiveViewer(
          key: ValueKey(item.sha256),
          transformationController: item.id == items[index].id
              ? transform
              : null,
          minScale: .75,
          maxScale: 5,
          child: Center(
            child: Image(
              key: ValueKey(('android-detail-image', item.sha256)),
              image: _imageProvider(item.storagePath),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Semantics(
                label: context.l10n.select(
                  zh: '无法读取这张图片',
                  en: 'Unable to load this image',
                ),
                child: const Icon(Icons.broken_image_outlined, size: 36),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _media(MediaAsset item) {
    final settings = widget.settings ?? widget.backend.settings;
    return ColoredBox(
      key: ValueKey(('android-media-page', item.id, item.sha256)),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: item.kind == MediaKind.image
          ? _picture(item)
          : KeyedSubtree(
              key: ValueKey((item.id, item.sha256)),
              child: AndroidVideoSurface(
                key: videoKey(item),
                path: item.storagePath,
                cover: item,
                active: item.id == items[index].id,
                prewarm: item.id != items[index].id,
                autoPlay: widget.autoPlay ?? settings.autoPlayVideo,
                immersive: immersiveVideo,
                onReady: (value) {
                  if (mounted && item.id == items[index].id) {
                    setState(() => player = value);
                  }
                },
                onSwipe: (delta) => unawaited(navigate(delta)),
                onVerticalSwipe: (delta) {
                  if (delta > 0 && !detailsOpen) unawaited(openDetails());
                  if (delta < 0 && detailsOpen) closeDetails();
                },
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = items[index];
    final blocked = busy || switching;
    final info = AndroidMediaInformation(
      key: ValueKey('information-${item.id}'),
      item: item,
      busy: blocked,
      addingTag: addingTag,
      editingNote: editingNote,
      tagInput: tagInput,
      noteInput: noteInput,
      onAddTag: addTag,
      onBeginTag: () => setState(() => addingTag = true),
      onEditNote: beginNote,
      onSaveNote: saveNote,
      onCancelNote: () => setState(() => editingNote = false),
      sizeBytes: currentDetails?.sizeBytes,
    );
    return AndroidBackGuard(
      busy: blocked,
      dirty: dirty,
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showInfo = !detailsOpen && (controlsVisible || dirty);
              final media = Stack(
                fit: StackFit.expand,
                children: [
                  FadeTransition(
                    key: const Key('android-detail-page-fade'),
                    opacity: pageOpacity,
                    child: PageView.builder(
                      key: const Key('android-detail-media'),
                      controller: pages,
                      physics: const NeverScrollableScrollPhysics(),
                      allowImplicitScrolling: true,
                      itemCount: items.length,
                      itemBuilder: (context, page) {
                        final asset = items[page];
                        if ((page - index).abs() > 1 &&
                            asset.kind == MediaKind.video) {
                          return VideoPoster(asset: asset);
                        }
                        return _media(asset);
                      },
                    ),
                  ),
                  if (!immersiveVideo && (controlsVisible || detailsOpen))
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Material(
                        key: const Key('android-detail-overlay'),
                        color: Theme.of(context).colorScheme.surface
                            .withValues(alpha: .85),
                        child: Row(
                          children: [
                            Builder(
                              builder: (context) => IconButton(
                                key: const Key('android-page-back'),
                                tooltip: context.l10n.select(
                                  zh: '返回',
                                  en: 'Back',
                                ),
                                onPressed: () => AndroidBackGuard.back(context),
                                icon: const Icon(Icons.arrow_back),
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              key: const Key('android-detail-toggle'),
                              tooltip: context.l10n.select(
                                zh: detailsOpen ? '返回媒体预览' : '查看媒体详情',
                                en: detailsOpen
                                    ? 'Back to media preview'
                                    : 'View media details',
                              ),
                              onPressed: detailsOpen
                                  ? closeDetails
                                  : openDetails,
                              icon: Icon(
                                detailsOpen
                                    ? Icons.expand_more
                                    : Icons.subject_outlined,
                              ),
                            ),
                            if (!detailsOpen)
                              PopupMenuButton<String>(
                                tooltip: context.l10n.select(
                                  zh: '更多',
                                  en: 'More',
                                ),
                                enabled: !blocked && !dirty,
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'details',
                                    child: Text(
                                      context.l10n.select(
                                        zh: '查看媒体详情',
                                        en: 'View media details',
                                      ),
                                    ),
                                  ),
                                  if (item.kind == MediaKind.image)
                                    PopupMenuItem(
                                      value: 'clipboard',
                                      child: Text(
                                        context.l10n.select(
                                          zh: '复制到剪贴板',
                                          en: 'Copy to clipboard',
                                        ),
                                      ),
                                    ),
                                  PopupMenuItem(
                                    value: 'copy-album',
                                    child: Text(
                                      context.l10n.select(
                                        zh: '复制到相册',
                                        en: 'Copy to album',
                                      ),
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'move-album',
                                    child: Text(
                                      context.l10n.select(
                                        zh: '移动到相册',
                                        en: 'Move to album',
                                      ),
                                    ),
                                  ),
                                  if (item.kind == MediaKind.video)
                                    PopupMenuItem(
                                      value: 'capture',
                                      child: Text(
                                        context.l10n.select(
                                          zh: '截取当前帧',
                                          en: 'Capture current frame',
                                        ),
                                      ),
                                    ),
                                  if (window?.error != null)
                                    PopupMenuItem(
                                      value: 'retry-window',
                                      child: Text(
                                        context.l10n.select(
                                          zh: '重试加载相邻媒体',
                                          en: 'Retry adjacent media',
                                        ),
                                      ),
                                    ),
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Text(
                                      context.l10n.select(
                                        zh: '编辑标签与备注',
                                        en: 'Edit tags and note',
                                      ),
                                    ),
                                  ),
                                  if (item.kind == MediaKind.video)
                                    PopupMenuItem(
                                      value: 'trim',
                                      child: Text(
                                        context.l10n.select(
                                          zh: '剪辑视频',
                                          en: 'Trim video',
                                        ),
                                      ),
                                    ),
                                ],
                                onSelected: (value) {
                                  switch (value) {
                                    case 'details':
                                      openDetails();
                                    case 'clipboard':
                                      copyToClipboard();
                                    case 'copy-album':
                                      albumAction(move: false);
                                    case 'move-album':
                                      albumAction(move: true);
                                    case 'capture':
                                      frame();
                                    case 'retry-window':
                                      _extendWindow();
                                    case 'edit':
                                      edit();
                                    default:
                                      trim();
                                  }
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
              if (immersiveVideo) {
                return ColoredBox(color: Colors.black, child: media);
              }
              if (detailsOpen) {
                return Column(
                  children: [
                    Expanded(flex: 39, child: media),
                    Expanded(
                      flex: 61,
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (notification) {
                          if (notification is OverscrollNotification &&
                              notification.metrics.pixels <=
                                  notification.metrics.minScrollExtent &&
                              notification.overscroll < 0) {
                            closeDetails();
                          }
                          return false;
                        },
                        child: info,
                      ),
                    ),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(child: media),
                  if (showInfo)
                    SizedBox(
                      height: constraints.maxHeight * (editingNote ? .52 : .38),
                      child: info,
                    ),
                  if (controlsVisible)
                    _AndroidViewerActionBar(
                      item: item,
                      busy: blocked,
                      onTrim: item.kind == MediaKind.video ? trim : null,
                      onShare: () =>
                          showAndroidMediaShareSheet(context, [item]),
                      onImmersive: item.kind == MediaKind.video
                          ? toggleImmersive
                          : null,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
