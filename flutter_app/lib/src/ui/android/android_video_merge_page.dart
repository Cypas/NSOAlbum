import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../state/media_edit_controller.dart';
import 'android_back_guard.dart';
import 'android_media_card.dart';
import 'android_media_viewer.dart';
import 'android_page_frame.dart';
import 'android_video_surface.dart';

class AndroidVideoMergePage extends StatefulWidget {
  const AndroidVideoMergePage({
    super.key,
    required this.backend,
    required this.videos,
  });
  final AppBackend backend;
  final List<MediaAsset> videos;
  @override
  State<AndroidVideoMergePage> createState() => _AndroidVideoMergePageState();
}

class _AndroidVideoMergePageState extends State<AndroidVideoMergePage> {
  late final videos = List.of(widget.videos);
  late final editor = MediaEditController(widget.backend);
  GlobalKey<AndroidVideoSurfaceState> preview = GlobalKey();
  bool busy = false;
  Object? error;
  bool get dirty => !listEquals(
    videos.map((item) => item.id).toList(),
    widget.videos.map((item) => item.id).toList(),
  );

  @override
  void dispose() {
    final surface = preview.currentState;
    unawaited(() async {
      try {
        await surface?.release();
      } finally {
        await editor.dispose();
      }
    }());
    super.dispose();
  }

  Future<void> createPreview() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await preview.currentState?.release();
      await editor.preview(videos);
      // A released player cannot be reused when a new preview has the same path.
      preview = GlobalKey();
    } catch (exception) {
      error = exception;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await preview.currentState?.release();
      final result = await editor.merge(videos);
      if (mounted) Navigator.pop(context, result);
    } catch (exception) {
      if (mounted) {
        setState(() {
          busy = false;
          error = exception;
        });
      }
    }
  }

  Future<void> previewSource(MediaAsset source) async {
    try {
      await preview.currentState?.release();
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => AndroidMediaViewer(
            backend: widget.backend,
            items: [source],
            autoPlay: true,
          ),
        ),
      );
      if (mounted) {
        setState(() => preview = GlobalKey());
      }
    } catch (exception) {
      if (mounted) setState(() => error = exception);
    }
  }

  @override
  Widget build(BuildContext context) => AndroidBackGuard(
    busy: busy,
    dirty: dirty,
    child: AndroidPageFrame(
      title: context.l10n.select(zh: '合并视频', en: 'Merge videos'),
      secondary: true,
      child: AndroidPageList(
        children: [
          if (editor.previewPath != null)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: AndroidVideoSurface(
                key: preview,
                path: editor.previewPath!,
                autoPlay: true,
              ),
            ),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: videos.length,
            onReorderItem: (oldIndex, newIndex) async {
              if (busy) return;
              setState(() {
                busy = true;
                videos.insert(newIndex, videos.removeAt(oldIndex));
              });
              try {
                await preview.currentState?.release();
                await editor.discardPreview();
              } catch (exception) {
                error = exception;
              } finally {
                if (mounted) setState(() => busy = false);
              }
            },
            itemBuilder: (context, index) {
              final source = videos[index];
              return Card(
                key: ValueKey(source.id),
                child: Column(
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          AndroidMediaThumbnail(asset: source),
                          Center(
                            child: IconButton.filled(
                              tooltip: context.l10n.select(
                                zh: '预览源视频',
                                en: 'Preview source',
                              ),
                              onPressed: busy
                                  ? null
                                  : () => previewSource(source),
                              icon: const Icon(Icons.play_arrow),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      title: Text(
                        source.originalName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      leading: Text('${index + 1}'),
                      trailing: ReorderableDragStartListener(
                        index: index,
                        enabled: !busy,
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : createPreview,
            icon: const Icon(Icons.play_arrow),
            label: Text(
              context.l10n.select(zh: '预览合并结果', en: 'Preview merged video'),
            ),
          ),
          FilledButton.icon(
            onPressed: busy ? null : save,
            icon: const Icon(Icons.save_outlined),
            label: Text(
              context.l10n.select(zh: '保存合并视频', en: 'Save merged video'),
            ),
          ),
          if (error != null) SelectableText(error.toString()),
        ],
      ),
    ),
  );
}
