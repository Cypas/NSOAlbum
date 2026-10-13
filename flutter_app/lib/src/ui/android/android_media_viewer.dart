import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../rust/settings.dart';
import '../../state/media_edit_controller.dart';
import 'android_back_guard.dart';
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
  Player? player;
  bool busy = false;

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
      await MediaEditController(widget.backend).frame(items[index], bytes);
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
        child: Column(
          children: [
            Expanded(
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
                  : AndroidVideoSurface(
                      key: ValueKey('${item.sha256}-$index'),
                      path: item.storagePath,
                      autoPlay: widget.autoPlay ?? settings.autoPlayVideo,
                      onReady: (value) => player = value,
                    ),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton(
                  tooltip: context.l10n.select(zh: '上一个', en: 'Previous'),
                  onPressed: busy || index == 0
                      ? null
                      : () => navigate(index - 1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('${index + 1} / ${items.length}'),
                IconButton(
                  tooltip: context.l10n.select(zh: '下一个', en: 'Next'),
                  onPressed: busy || index + 1 == items.length
                      ? null
                      : () => navigate(index + 1),
                  icon: const Icon(Icons.chevron_right),
                ),
                TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    useSafeArea: true,
                    isScrollControlled: true,
                    builder: (context) => SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SelectableText(item.originalName),
                          const SizedBox(height: 12),
                          Text(context.l10n.select(zh: '游戏标签', en: 'Game tag')),
                          SelectableText(item.gameName),
                          const SizedBox(height: 12),
                          Text(
                            context.l10n.select(zh: '自定义标签', en: 'Custom tags'),
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final tag in item.tags)
                                Chip(label: Text(tag)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SelectableText(item.note ?? ''),
                          TextButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              edit();
                            },
                            icon: const Icon(Icons.edit_note),
                            label: Text(
                              context.l10n.select(
                                zh: '编辑标签与备注',
                                en: 'Edit tags and note',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  child: Text(context.l10n.select(zh: '详情', en: 'Details')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
