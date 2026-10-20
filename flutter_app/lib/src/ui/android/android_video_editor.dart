import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../state/media_edit_controller.dart';
import '../video_runtime.dart';
import '../video_preview.dart';
import 'android_back_guard.dart';
import 'android_page_frame.dart';
import 'android_media_card.dart' show androidDuration;
import 'android_operation_progress.dart';

class AndroidVideoEditor extends StatefulWidget {
  const AndroidVideoEditor({
    super.key,
    required this.backend,
    required this.source,
  });
  final AppBackend backend;
  final MediaAsset source;
  @override
  State<AndroidVideoEditor> createState() => _AndroidVideoEditorState();
}

class _AndroidVideoEditorState extends State<AndroidVideoEditor> {
  late final MediaEditController editor = MediaEditController(widget.backend);
  late final Player player;
  late final VideoController video;
  StreamSubscription<Duration>? durationSubscription;
  StreamSubscription<Duration>? positionSubscription;
  double start = 0;
  double end = 0;
  double duration = 0;
  bool dirty = false;
  bool busy = false;
  bool autoPlay = false;
  Object? error;

  @override
  void initState() {
    super.initState();
    VideoRuntime.ensureInitialized();
    player = Player();
    video = VideoController(player);
    durationSubscription = player.stream.duration.listen((value) {
      if (!mounted) return;
      setState(() {
        duration = value.inMilliseconds.toDouble();
        if (end == 0) end = duration;
      });
    });
    positionSubscription = player.stream.position.listen((position) {
      if (!busy && end > start && position.inMilliseconds >= end) {
        unawaited(player.pause());
        unawaited(player.seek(Duration(milliseconds: start.round())));
      }
    });
    player.open(Media(widget.source.storagePath), play: false).catchError((
      Object exception,
    ) {
      if (mounted) setState(() => error = exception);
    });
  }

  @override
  void dispose() {
    unawaited(durationSubscription?.cancel());
    unawaited(positionSubscription?.cancel());
    unawaited(player.dispose());
    unawaited(editor.dispose());
    super.dispose();
  }

  Future<void> save(bool overwrite) async {
    if (overwrite) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            context.l10n.select(zh: '覆盖原视频？', en: 'Overwrite original?'),
          ),
          content: Text(
            context.l10n.select(
              zh: '原视频将被选区替换，完成后无法恢复。',
              en: 'The selected range replaces the original and cannot be undone.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.select(zh: '覆盖', en: 'Overwrite')),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
    }
    setState(() => busy = true);
    try {
      await player.pause();
      final result = await editor.trim(
        widget.source,
        Duration(milliseconds: start.round()),
        Duration(milliseconds: end.round()),
        overwrite: overwrite,
      );
      if (mounted) Navigator.pop(context, result);
    } catch (exception) {
      if (mounted) {
        androidMessage(context, exception);
        setState(() {
          busy = false;
          error = exception;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AndroidBackGuard(
    busy: busy,
    dirty: dirty,
    child: AndroidPageFrame(
      title: context.l10n.select(zh: '剪辑视频', en: 'Trim video'),
      secondary: true,
      child: AndroidPageList(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: VideoPreview(controller: video, cover: widget.source),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              IconButton(
                tooltip: context.l10n.select(zh: '播放选区', en: 'Play selection'),
                onPressed: busy
                    ? null
                    : () async {
                        await player.seek(
                          Duration(milliseconds: start.round()),
                        );
                        await player.play();
                      },
                icon: const Icon(Icons.play_arrow),
              ),
              IconButton(
                tooltip: context.l10n.select(zh: '暂停', en: 'Pause'),
                onPressed: busy ? null : player.pause,
                icon: const Icon(Icons.pause),
              ),
              Text(
                context.l10n.select(
                  zh: '选区 ${((end - start) / 1000).toStringAsFixed(1)} 秒',
                  en: 'Selection ${((end - start) / 1000).toStringAsFixed(1)} seconds',
                ),
              ),
            ],
          ),
          RangeSlider(
            min: 0,
            max: duration > 0 ? duration : 1,
            values: RangeValues(start, end),
            labels: RangeLabels(
              _trimTimestamp(Duration(milliseconds: start.round())),
              _trimTimestamp(Duration(milliseconds: end.round())),
            ),
            onChanged: busy || duration == 0
                ? null
                : (range) {
                    unawaited(player.pause());
                    setState(() {
                      start = range.start;
                      end = range.end;
                      dirty = true;
                    });
                  },
            onChangeEnd: (range) async {
              await player.seek(Duration(milliseconds: range.start.round()));
              if (autoPlay) await player.play();
            },
          ),
          AndroidTrimTimestamps(
            start: Duration(milliseconds: start.round()),
            end: Duration(milliseconds: end.round()),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              context.l10n.select(
                zh: '调整后自动播放选区',
                en: 'Play selection after adjusting',
              ),
            ),
            value: autoPlay,
            onChanged: busy
                ? null
                : (value) => setState(() => autoPlay = value),
          ),
          if (busy)
            ValueListenableBuilder(
              valueListenable: editor.progress,
              builder: (context, progress, _) =>
                  AndroidOperationProgress(progress: progress),
            ),
          FilledButton.icon(
            onPressed: busy || end - start < 300 ? null : () => save(false),
            icon: busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(
              context.l10n.select(zh: '另存为新视频', en: 'Save as new video'),
            ),
          ),
          OutlinedButton(
            onPressed: busy || end - start < 300 ? null : () => save(true),
            child: Text(
              context.l10n.select(zh: '覆盖原视频', en: 'Overwrite original'),
            ),
          ),
          if (error != null) Text(androidReadableError(context, error!)),
        ],
      ),
    ),
  );
}

String _trimTimestamp(Duration value) =>
    '${androidDuration(value)}.${value.inMilliseconds.remainder(1000).toString().padLeft(3, '0')}';

class AndroidTrimTimestamps extends StatelessWidget {
  const AndroidTrimTimestamps({
    super.key,
    required this.start,
    required this.end,
  });
  final Duration start;
  final Duration end;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 16,
    runSpacing: 4,
    alignment: WrapAlignment.spaceBetween,
    children: [
      Text(
        context.l10n.select(
          zh: '开始 ${_trimTimestamp(start)}',
          en: 'Start ${_trimTimestamp(start)}',
        ),
      ),
      Text(
        context.l10n.select(
          zh: '结束 ${_trimTimestamp(end)}',
          en: 'End ${_trimTimestamp(end)}',
        ),
      ),
    ],
  );
}
