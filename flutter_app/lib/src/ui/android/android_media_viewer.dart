import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
import 'android_media_card.dart';
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

enum AndroidViewerMoreAction { copyToAlbum, moveToAlbum, captureFrame }

List<AndroidViewerMoreAction> androidViewerMoreActionsFor(MediaKind kind) => [
  AndroidViewerMoreAction.copyToAlbum,
  AndroidViewerMoreAction.moveToAlbum,
  if (kind == MediaKind.video) AndroidViewerMoreAction.captureFrame,
];

ImageProvider<Object> androidDetailImageProvider(
  BuildContext context,
  String path,
) {
  const decodeAllowance = 1.5;
  final viewport = MediaQuery.sizeOf(context);
  final pixelRatio = MediaQuery.devicePixelRatioOf(context);
  return ResizeImage(
    FileImage(File(path)),
    width: (viewport.width * pixelRatio * decodeAllowance).round(),
    height: (viewport.height * pixelRatio * decodeAllowance).round(),
    policy: ResizeImagePolicy.fit,
  );
}

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
    super.key,
    required this.item,
    required this.busy,
    required this.onFavorite,
    required this.onEdit,
    required this.onTrim,
    required this.onShare,
    required this.onMore,
  });
  final MediaAsset item;
  final bool busy;
  final VoidCallback onFavorite;
  final VoidCallback onEdit;
  final VoidCallback? onTrim;
  final VoidCallback onShare;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      top: false,
      child: Container(
        height: 64,
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 3),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Theme.of(context).colorScheme.shadow
                  .withValues(alpha: .12),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            _AndroidDockAction(
              key: const Key('android-detail-favorite'),
              label: context.l10n.select(zh: '收藏', en: 'Favorite'),
              icon: item.favorite ? Icons.favorite : Icons.favorite_border,
              color: item.favorite ? Colors.redAccent : null,
              enabled: !busy,
              onPressed: onFavorite,
            ),
            _AndroidDockAction(
              key: const Key('android-detail-edit'),
              label: context.l10n.select(zh: '编辑', en: 'Edit'),
              icon: Icons.edit_outlined,
              enabled: !busy,
              onPressed: onEdit,
            ),
            if (item.kind == MediaKind.video)
              _AndroidDockAction(
                key: const Key('android-detail-trim'),
                label: context.l10n.select(zh: '剪辑', en: 'Trim'),
                icon: Icons.content_cut,
                enabled: !busy,
                onPressed: onTrim,
              ),
            _AndroidDockAction(
              key: const Key('android-detail-share'),
              label: context.l10n.select(zh: '分享', en: 'Share'),
              icon: Icons.share_outlined,
              enabled: !busy,
              onPressed: onShare,
            ),
            _AndroidDockAction(
              key: const Key('android-detail-more'),
              label: context.l10n.select(zh: '更多', en: 'More'),
              icon: Icons.more_horiz,
              enabled: !busy,
              onPressed: onMore,
            ),
          ],
        ),
      ),
    ),
  );
}

class _AndroidDockAction extends StatelessWidget {
  const _AndroidDockAction({
    super.key,
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onPressed,
    this.color,
  });
  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Semantics(
      button: true,
      label: label,
      enabled: enabled,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 19, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontSize: 9,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AndroidMediaFilmstrip extends StatelessWidget {
  const _AndroidMediaFilmstrip({
    required this.items,
    required this.currentIndex,
    required this.onSelected,
  });
  final List<MediaAsset> items;
  final int currentIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const Key('android-detail-filmstrip'),
    height: 56,
    child: ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      scrollDirection: Axis.horizontal,
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final item = items[index];
        return InkWell(
          onTap: () => onSelected(index),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 64,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: index == currentIndex
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AndroidMediaThumbnail(asset: item),
            ),
          ),
        );
      },
    ),
  );
}

class _AndroidViewerMoreMenu extends StatelessWidget {
  const _AndroidViewerMoreMenu({
    required this.item,
    required this.busy,
    required this.onAction,
  });

  final MediaAsset item;
  final bool busy;
  final ValueChanged<AndroidViewerMoreAction> onAction;

  String _label(BuildContext context, AndroidViewerMoreAction action) =>
      switch (action) {
        AndroidViewerMoreAction.copyToAlbum => context.l10n.select(
          zh: '复制到相册',
          en: 'Copy to album',
        ),
        AndroidViewerMoreAction.moveToAlbum => context.l10n.select(
          zh: '移动到相册',
          en: 'Move to album',
        ),
        AndroidViewerMoreAction.captureFrame => context.l10n.select(
          zh: '截取当前帧',
          en: 'Capture current frame',
        ),
      };

  IconData _icon(AndroidViewerMoreAction action) => switch (action) {
    AndroidViewerMoreAction.copyToAlbum =>
      Icons.control_point_duplicate_outlined,
    AndroidViewerMoreAction.moveToAlbum => Icons.drive_file_move_outlined,
    AndroidViewerMoreAction.captureFrame => Icons.screenshot,
  };

  double _width(BuildContext context, List<AndroidViewerMoreAction> actions) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final scaler = MediaQuery.textScalerOf(context);
    var widest = 0.0;
    for (final action in actions) {
      final painter = TextPainter(
        text: TextSpan(text: _label(context, action), style: style),
        maxLines: 2,
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout(maxWidth: 160);
      widest = math.max(widest, painter.width);
    }
    return (widest + 68).clamp(184.0, 232.0);
  }

  @override
  Widget build(BuildContext context) {
    final actions = androidViewerMoreActionsFor(item.kind);
    return SizedBox(
      key: const Key('android-detail-more-menu'),
      width: _width(context, actions),
      child: Material(
        elevation: 8,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final action in actions)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: InkWell(
                    key: ValueKey('android-detail-more-${action.name}'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: busy ? null : () => onAction(action),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          Icon(_icon(action), size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _label(context, action),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
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

class _AndroidMediaViewerState extends State<AndroidMediaViewer>
    with SingleTickerProviderStateMixin {
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
  bool detailsOpen = false, immersiveMedia = false, moreOpen = false;
  bool captureFeedback = false;
  bool preserveImmersivePadding = false;
  int systemUiRequest = 0;
  EdgeInsets immersiveSystemPadding = EdgeInsets.zero;
  Uint8List? capturedFrame;
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
        androidDetailImageProvider(context, item.storagePath),
        context,
        onError: (_, _) {},
      );
    }
  }

  @override
  void dispose() {
    if (immersiveMedia) {
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
    bool? favorite,
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
    favorite: favorite ?? item.favorite,
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

  Future<void> toggleFavorite() async {
    if (busy || switching) return;
    final item = items[index];
    final next = !item.favorite;
    setState(() => busy = true);
    try {
      await widget.backend.setFavorite(item.id, next);
      if (mounted) {
        setState(() => items[index] = withMetadata(item, favorite: next));
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
        moreOpen = false;
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
    if (immersiveMedia) await _setImmersive(false);
    if (!mounted || detailsOpen) return;
    final id = items[index].id;
    setState(() => moreOpen = false);
    try {
      final details = await widget.backend.loadMediaDetails(id);
      if (!mounted || items[index].id != id) return;
      setState(() {
        currentDetails = details;
        detailsOpen = true;
        controlsVisible = true;
      });
    } catch (error) {
      if (mounted && items[index].id == id) {
        // The local media record still contains the user-facing metadata.
        // Keep the details surface usable when the optional detail lookup
        // cannot read a path or native media property.
        setState(() {
          currentDetails = null;
          detailsOpen = true;
          controlsVisible = true;
        });
      }
    }
  }

  void closeDetails() {
    if (mounted) setState(() => detailsOpen = false);
  }

  Future<void> _setImmersive(bool value) async {
    if (!mounted || detailsOpen || immersiveMedia == value) {
      return;
    }
    final request = ++systemUiRequest;
    if (value) {
      final padding = preserveImmersivePadding
          ? immersiveSystemPadding
          : MediaQuery.paddingOf(context);
      setState(() {
        immersiveSystemPadding = padding;
        preserveImmersivePadding = true;
        immersiveMedia = true;
        moreOpen = false;
        controlsVisible = true;
      });
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      return;
    }
    setState(() {
      immersiveMedia = false;
      controlsVisible = true;
    });
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted && request == systemUiRequest) {
      setState(() => preserveImmersivePadding = false);
    }
  }

  Future<void> toggleImmersive() => _setImmersive(!immersiveMedia);

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

  void toggleMoreActions() {
    if (busy || switching || detailsOpen || immersiveMedia) return;
    setState(() => moreOpen = !moreOpen);
  }

  void closeMoreActions() {
    if (moreOpen && mounted) setState(() => moreOpen = false);
  }

  Future<void> runMoreAction(AndroidViewerMoreAction action) async {
    closeMoreActions();
    switch (action) {
      case AndroidViewerMoreAction.copyToAlbum:
        await albumAction(move: false);
      case AndroidViewerMoreAction.moveToAlbum:
        await albumAction(move: true);
      case AndroidViewerMoreAction.captureFrame:
        await frame();
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
        setState(() {
          capturedFrame = bytes;
          captureFeedback = true;
        });
        androidMessage(
          context,
          context.l10n.select(zh: '帧图已保存', en: 'Frame saved'),
          isError: false,
        );
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 900), () {
            if (mounted) setState(() => captureFeedback = false);
          }),
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
      label: immersiveMedia
          ? context.l10n.select(zh: '显示操作栏', en: 'Show controls')
          : context.l10n.select(zh: '隐藏操作栏', en: 'Hide controls'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: dirty || detailsOpen
            ? null
            : moreOpen
            ? closeMoreActions
            : toggleImmersive,
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
              image: androidDetailImageProvider(context, item.storagePath),
              fit: BoxFit.contain,
              gaplessPlayback: true,
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
    final canvasColor = immersiveMedia
        ? Colors.black
        : Theme.of(context).colorScheme.surface;
    return ColoredBox(
      key: ValueKey(('android-media-page', item.id, item.sha256)),
      color: canvasColor,
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
                immersive: immersiveMedia,
                hideControls: detailsOpen,
                fillColor: canvasColor,
                onMediaTap: item.id == items[index].id && !detailsOpen
                    ? (moreOpen ? closeMoreActions : toggleImmersive)
                    : null,
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
    final mediaQuery = MediaQuery.of(context);
    final canvasColor = immersiveMedia
        ? Colors.black
        : Theme.of(context).colorScheme.surface;
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
        backgroundColor: canvasColor,
        body: MediaQuery(
          data: mediaQuery.copyWith(
            padding: immersiveMedia || preserveImmersivePadding
                ? immersiveSystemPadding
                : mediaQuery.padding,
          ),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
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
                    if (!immersiveMedia && (controlsVisible || detailsOpen))
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: Material(
                          key: const Key('android-detail-overlay'),
                          color: Theme.of(context).colorScheme.surface
                              .withValues(alpha: .85),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: moreOpen ? closeMoreActions : null,
                            child: Row(
                              children: [
                                Builder(
                                  builder: (context) => IconButton(
                                    key: const Key('android-page-back'),
                                    tooltip: context.l10n.select(
                                      zh: '返回',
                                      en: 'Back',
                                    ),
                                    onPressed: moreOpen
                                        ? closeMoreActions
                                        : () => AndroidBackGuard.back(context),
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
                                  onPressed: moreOpen
                                      ? closeMoreActions
                                      : detailsOpen
                                      ? closeDetails
                                      : openDetails,
                                  icon: Icon(
                                    detailsOpen
                                        ? Icons.expand_more
                                        : Icons.subject_outlined,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
                if (detailsOpen) {
                  return AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    child: Column(
                      children: [
                        Expanded(flex: 39, child: media),
                        Expanded(
                          flex: 61,
                          child: NotificationListener<ScrollNotification>(
                            onNotification: (notification) {
                              if (notification is OverscrollNotification &&
                                  notification.dragDetails != null &&
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
                    ),
                  );
                }
                final normalContent = AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: Column(
                    children: [
                      Expanded(
                        child: Transform.translate(
                          offset: const Offset(0, -12),
                          child: media,
                        ),
                      ),
                      if (controlsVisible)
                        Visibility(
                          key: const Key('android-detail-filmstrip-visibility'),
                          visible: !immersiveMedia,
                          maintainState: true,
                          maintainAnimation: true,
                          maintainSize: true,
                          child: _AndroidMediaFilmstrip(
                            items: items,
                            currentIndex: index,
                            onSelected: (next) {
                              if (immersiveMedia) return;
                              if (moreOpen) {
                                closeMoreActions();
                                return;
                              }
                              if (next != index) {
                                unawaited(navigate(next - index));
                              }
                            },
                          ),
                        ),
                      if (controlsVisible)
                        Visibility(
                          key: const Key(
                            'android-detail-action-dock-visibility',
                          ),
                          visible: !immersiveMedia,
                          maintainState: true,
                          maintainAnimation: true,
                          maintainSize: true,
                          child: _AndroidViewerActionBar(
                            key: const Key('android-detail-action-dock'),
                            item: item,
                            busy: blocked,
                            onFavorite: moreOpen
                                ? closeMoreActions
                                : toggleFavorite,
                            onEdit: moreOpen ? closeMoreActions : edit,
                            onTrim: item.kind == MediaKind.video
                                ? (moreOpen ? closeMoreActions : trim)
                                : null,
                            onShare: moreOpen
                                ? closeMoreActions
                                : () => showAndroidMediaShareSheet(context, [
                                    item,
                                  ]),
                            onMore: toggleMoreActions,
                          ),
                        ),
                      if (captureFeedback && capturedFrame != null)
                        Visibility(
                          visible: !immersiveMedia,
                          maintainState: true,
                          maintainAnimation: true,
                          maintainSize: true,
                          child: SizedBox(
                            key: const Key('android-detail-capture-feedback'),
                            height: 56,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 14),
                                child: Material(
                                  elevation: 6,
                                  borderRadius: BorderRadius.circular(8),
                                  clipBehavior: Clip.antiAlias,
                                  child: Image.memory(
                                    capturedFrame!,
                                    width: 80,
                                    height: 56,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
                final preview = immersiveMedia
                    ? ColoredBox(
                        key: const Key('android-detail-immersive'),
                        color: Colors.black,
                        child: normalContent,
                      )
                    : normalContent;
                final actionBarReserve =
                    67.0 + MediaQuery.paddingOf(context).bottom;
                const filmstripReserve = 64.0;
                return Stack(
                  key: const Key('android-detail-preview-slot'),
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(child: preview),
                    if (moreOpen)
                      Positioned(
                        right: 12,
                        bottom: actionBarReserve + filmstripReserve,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: constraints.maxHeight * .42,
                          ),
                          child: _AndroidViewerMoreMenu(
                            item: item,
                            busy: blocked,
                            onAction: (action) =>
                                unawaited(runMoreAction(action)),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
