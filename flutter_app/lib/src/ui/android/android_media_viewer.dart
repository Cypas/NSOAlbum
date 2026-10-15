import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../rust/settings.dart';
import '../../state/media_edit_controller.dart';
import '../display_time.dart';
import 'android_back_guard.dart';
import 'android_metadata_editor.dart';
import 'android_page_frame.dart';
import 'android_video_editor.dart';
import 'android_video_surface.dart';
import 'android_tag.dart';

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
  Player? player;
  bool busy = false;
  final tagInput = TextEditingController();
  final noteInput = TextEditingController();
  bool addingTag = false;
  bool editingNote = false;
  bool get dirty =>
      editingNote || (addingTag && tagInput.text.trim().isNotEmpty);

  @override
  void dispose() {
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
    if (busy || !addingTag) return;
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
      if (next.length != item.tags.length) {
        await widget.backend.replaceTags(item.id, next);
      }
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
    if (busy) return;
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

  void navigate(int next) {
    player?.pause();
    setState(() {
      index = next;
      player = null;
    });
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
    if (player == null) return;
    setState(() => busy = true);
    try {
      final bytes = await player!.screenshot(format: 'image/jpeg');
      if (bytes == null || bytes.isEmpty) {
        throw StateError('Unable to capture this frame.');
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
        );
      }
    } catch (error) {
      if (mounted) androidMessage(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = items[index];
    final settings = widget.settings ?? widget.backend.settings;
    return AndroidBackGuard(
      busy: busy,
      dirty: dirty,
      child: AndroidPageFrame(
        title: item.originalName,
        secondary: true,
        actions: [
          IconButton(
            tooltip: context.l10n.select(
              zh: '编辑标签与备注',
              en: 'Edit tags and note',
            ),
            onPressed: busy ? null : edit,
            icon: const Icon(Icons.edit_note),
          ),
          if (item.kind == MediaKind.video)
            PopupMenuButton<String>(
              tooltip: context.l10n.select(zh: '更多', en: 'More'),
              enabled: !busy,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'trim',
                  child: Text(
                    context.l10n.select(zh: '剪辑视频', en: 'Trim video'),
                  ),
                ),
                PopupMenuItem(
                  value: 'frame',
                  child: Text(
                    context.l10n.select(zh: '截取帧图', en: 'Capture frame'),
                  ),
                ),
              ],
              onSelected: (value) async {
                if (value == 'frame') {
                  await frame();
                  return;
                }
                await player?.pause();
                if (!context.mounted) return;
                final result = await Navigator.of(context).push<MediaAsset>(
                  MaterialPageRoute(
                    builder: (_) => AndroidVideoEditor(
                      backend: widget.backend,
                      source: item,
                    ),
                  ),
                );
                if (result != null && mounted && result.id == item.id) {
                  setState(() {
                    items[index] = result;
                    player = null;
                  });
                }
              },
            ),
        ],
        child: AndroidPageList(
          children: [
            SizedBox(
              height: (MediaQuery.sizeOf(context).height * .36).clamp(150, 360),
              child: ClipRect(
                child: item.kind == MediaKind.image
                    ? InteractiveViewer(
                        minScale: 0.75,
                        maxScale: 5,
                        child: Center(
                          child: Image.file(
                            File(item.storagePath),
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      )
                    : Stack(
                        children: [
                          Positioned.fill(
                            child: AndroidVideoSurface(
                              key: ValueKey('${item.sha256}-$index'),
                              path: item.storagePath,
                              autoPlay:
                                  widget.autoPlay ?? settings.autoPlayVideo,
                              onReady: (value) => player = value,
                            ),
                          ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: IconButton.filledTonal(
                              key: const Key('android-capture-frame'),
                              tooltip: context.l10n.select(
                                zh: '截取帧图',
                                en: 'Capture frame',
                              ),
                              onPressed: busy ? null : frame,
                              icon: const Icon(Icons.screenshot),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            SelectableText(
              item.originalName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              context.l10n.select(zh: '游戏标签', en: 'Game tag'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Wrap(children: [AndroidTag(label: item.gameName, game: true)]),
            Text(
              context.l10n.select(zh: '自定义标签', en: 'Custom tags'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in item.tags) AndroidTag(label: tag),
                if (!addingTag)
                  ActionChip(
                    key: const Key('android-inline-add-tag'),
                    label: const Icon(Icons.add, size: 20),
                    tooltip: context.l10n.select(zh: '新增标签', en: 'Add tag'),
                    onPressed: busy
                        ? null
                        : () => setState(() => addingTag = true),
                  ),
              ],
            ),
            if (addingTag)
              Focus(
                onFocusChange: (focused) {
                  if (!focused && addingTag && !busy) unawaited(addTag());
                },
                child: TextField(
                  key: const Key('android-inline-tag-input'),
                  controller: tagInput,
                  autofocus: true,
                  enabled: !busy,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: context.l10n.select(zh: '新标签', en: 'New tag'),
                  ),
                  onSubmitted: (_) => addTag(),
                  onTapOutside: (_) {
                    FocusManager.instance.primaryFocus?.unfocus();
                  },
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.select(zh: '备注', en: 'Note'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (!editingNote)
                  IconButton(
                    key: const Key('android-inline-edit-note'),
                    tooltip: context.l10n.select(zh: '编辑备注', en: 'Edit note'),
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            noteInput.text = item.note ?? '';
                            editingNote = true;
                          }),
                    icon: const Icon(Icons.edit_outlined),
                  ),
              ],
            ),
            if (editingNote) ...[
              TextField(
                key: const Key('android-inline-note-input'),
                controller: noteInput,
                minLines: 2,
                maxLines: 5,
                enabled: !busy,
                decoration: InputDecoration(
                  labelText: context.l10n.select(zh: '备注', en: 'Note'),
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    key: const Key('android-inline-save-note'),
                    onPressed: busy ? null : saveNote,
                    child: Text(context.l10n.select(zh: '保存', en: 'Save')),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() => editingNote = false),
                    child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
                  ),
                ],
              ),
            ] else
              SelectableText(
                item.note ?? context.l10n.select(zh: '暂无备注', en: 'No note'),
              ),
            if (item.capturedAt != null)
              Text(
                context.l10n.select(
                  zh: '拍摄/创建时间：${formatUserDateTime(item.capturedAt!)}',
                  en: 'Captured/created: ${formatUserDateTime(item.capturedAt!)}',
                ),
              ),
            Text(
              context.l10n.select(
                zh: '导入时间：${formatUserDateTime(item.importedAt)}',
                en: 'Imported: ${formatUserDateTime(item.importedAt)}',
              ),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton(
                  tooltip: context.l10n.select(zh: '上一个', en: 'Previous'),
                  onPressed: busy || dirty || index == 0
                      ? null
                      : () => navigate(index - 1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('${index + 1} / ${items.length}'),
                IconButton(
                  tooltip: context.l10n.select(zh: '下一个', en: 'Next'),
                  onPressed: busy || dirty || index + 1 == items.length
                      ? null
                      : () => navigate(index + 1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
