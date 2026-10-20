import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../rust/settings.dart';
import '../../state/media_edit_controller.dart';
import '../video_preview_prefetch.dart';
import '../video_thumbnail.dart';
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
  });
  final AppBackend backend;
  final List<MediaAsset> items;
  final AppSettings? settings;
  final int initialIndex;
  final bool? autoPlay;
  @override
  State<AndroidMediaViewer> createState() => _AndroidMediaViewerState();
}

class _AndroidMediaViewerState extends State<AndroidMediaViewer> {
  late List<MediaAsset> items = List.of(widget.items);
  late int index = widget.initialIndex;
  GlobalKey<AndroidVideoSurfaceState> video = GlobalKey();
  final transform = TransformationController();
  late final prefetch = MediaPreviewPrefetch(warm: _warm);
  Player? player;
  bool busy = false, switching = false, controlsVisible = true;
  final tagInput = TextEditingController();
  final noteInput = TextEditingController();
  bool addingTag = false, editingNote = false;
  bool get dirty =>
      editingNote || (addingTag && tagInput.text.trim().isNotEmpty);

  @override
  void initState() {
    super.initState();
    transform.addListener(_zoomChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) prefetch.around(items, index);
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
        mediaPreviewImage(item.storagePath),
        context,
        onError: (_, _) {},
      );
    }
  }

  @override
  void dispose() {
    prefetch.dispose();
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
    final next = index + delta;
    if (busy || switching || next < 0 || next >= items.length) return;
    setState(() => switching = true);
    try {
      if (dirty && !await confirmAndroidDiscard(context)) return;
      if (!mounted) return;
      await video.currentState?.release();
      if (!mounted) return;
      setState(() {
        player = null;
        video = GlobalKey();
        index = next;
        controlsVisible = true;
        addingTag = false;
        editingNote = false;
        tagInput.clear();
        noteInput.clear();
        transform.value = Matrix4.identity();
      });
      prefetch.around(items, index);
    } catch (error) {
      if (mounted) androidMessage(context, error);
    } finally {
      if (mounted) setState(() => switching = false);
    }
  }

  Future<void> edit() async {
    await player?.pause();
    if (!mounted) return;
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            AndroidMetadataEditor(backend: widget.backend, asset: items[index]),
      ),
    );
    if (result != true || !mounted) return;
    final fresh = await widget.backend.listMedia(limit: 100000);
    if (mounted) {
      setState(() {
        items = items
            .map(
              (old) =>
                  fresh.where((item) => item.id == old.id).firstOrNull ?? old,
            )
            .toList();
      });
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
    await player?.pause();
    if (!mounted) return;
    final item = items[index];
    final result = await Navigator.of(context).push<MediaAsset>(
      MaterialPageRoute(
        builder: (_) =>
            AndroidVideoEditor(backend: widget.backend, source: item),
      ),
    );
    if (result == null || !mounted || result.id != item.id) return;
    await video.currentState?.release();
    if (mounted) {
      setState(() {
        items[index] = result;
        player = null;
        video = GlobalKey();
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
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (!dirty) setState(() => controlsVisible = !controlsVisible);
      },
      child: InteractiveViewer(
        key: ValueKey(item.sha256),
        transformationController: transform,
        minScale: .75,
        maxScale: 5,
        child: Center(
          child: Image.file(
            File(item.storagePath),
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
  );

  Widget _media(MediaAsset item) {
    final settings = widget.settings ?? widget.backend.settings;
    return ColoredBox(
      key: const Key('android-detail-media'),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: item.kind == MediaKind.image
          ? _picture(item)
          : KeyedSubtree(
              key: ValueKey((item.sha256, index)),
              child: AndroidVideoSurface(
                key: video,
                path: item.storagePath,
                cover: item,
                autoPlay: widget.autoPlay ?? settings.autoPlayVideo,
                onReady: (value) {
                  if (mounted) setState(() => player = value);
                },
                onSwipe: (delta) => unawaited(navigate(delta)),
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
    );
    return AndroidBackGuard(
      busy: blocked,
      dirty: dirty,
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showInfo = controlsVisible || dirty;
              final landscape =
                  constraints.maxWidth > constraints.maxHeight * 1.2;
              final media = Stack(
                fit: StackFit.expand,
                children: [
                  _media(item),
                  if (controlsVisible)
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
                            Expanded(
                              child: Semantics(
                                label: context.l10n.select(
                                  zh: '第 ${index + 1} 项，共 ${items.length} 项',
                                  en: 'Item ${index + 1} of ${items.length}',
                                ),
                                child: ExcludeSemantics(
                                  child: Text(
                                    '${index + 1} / ${items.length}',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                            if (item.kind == MediaKind.video)
                              IconButton(
                                key: const Key('android-capture-frame'),
                                tooltip: context.l10n.select(
                                  zh: '截取帧图',
                                  en: 'Capture frame',
                                ),
                                onPressed: blocked || player == null
                                    ? null
                                    : frame,
                                icon: const Icon(Icons.screenshot, size: 20),
                              ),
                            PopupMenuButton<String>(
                              tooltip: context.l10n.select(
                                zh: '更多',
                                en: 'More',
                              ),
                              enabled: !blocked && !dirty,
                              itemBuilder: (_) => [
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
                              onSelected: (value) =>
                                  value == 'edit' ? edit() : trim(),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
              if (!showInfo) return media;
              if (landscape) {
                return Row(
                  children: [
                    Expanded(flex: 3, child: media),
                    Expanded(flex: 2, child: info),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(child: media),
                  SizedBox(
                    height: constraints.maxHeight * (editingNote ? .52 : .38),
                    child: info,
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
