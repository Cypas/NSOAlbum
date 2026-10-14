import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../state/transfer_controller.dart';
import 'android_back_guard.dart';
import 'android_page_frame.dart';

class AndroidCustomImportPage extends StatefulWidget {
  const AndroidCustomImportPage({super.key, required this.controller});
  final TransferController controller;
  @override
  State<AndroidCustomImportPage> createState() =>
      _AndroidCustomImportPageState();
}

class _AndroidCustomImportPageState extends State<AndroidCustomImportPage> {
  late final TextEditingController game = TextEditingController(
    text: widget.controller.gameName,
  );
  @override
  void dispose() {
    game.dispose();
    super.dispose();
  }

  Future<void> choose({bool directory = false}) async {
    try {
      if (directory) {
        final path = await FilePicker.getDirectoryPath();
        if (path != null) widget.controller.addPaths([path]);
      } else {
        final files = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'mp4', 'mov'],
        );
        widget.controller.addPaths(
          files.map((file) => file.path).whereType<String>(),
        );
      }
    } catch (error) {
      if (mounted) androidMessage(context, error);
    }
  }

  Future<void> importSelected() async {
    final success = await widget.controller.importSelected();
    if (!success && mounted && widget.controller.error != null) {
      androidMessage(context, widget.controller.error!);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final state = widget.controller;
      return AndroidBackGuard(
        busy: state.busy,
        child: AndroidPageFrame(
          title: context.l10n.select(zh: '自定义导入', en: 'Custom Import'),
          secondary: true,
          child: AndroidPageList(
            children: [
              Text(
                context.l10n.select(
                  zh: '选择图片、视频或目录，并为本次导入统一指定游戏标签。',
                  en: 'Choose media or a folder and assign one game tag for this import.',
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: state.busy ? null : () => choose(),
                    icon: const Icon(Icons.file_open_outlined),
                    label: Text(
                      context.l10n.select(zh: '选择文件', en: 'Choose files'),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: state.busy
                        ? null
                        : () => choose(directory: true),
                    icon: const Icon(Icons.folder_open),
                    label: Text(
                      context.l10n.select(zh: '选择目录', en: 'Choose folder'),
                    ),
                  ),
                ],
              ),
              for (final path in state.paths)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _SelectedMediaPreview(path: path),
                  title: Text(
                    p.basename(path),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: context.l10n.select(zh: '移除', en: 'Remove'),
                    onPressed: state.busy ? null : () => state.removePath(path),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ),
              TextField(
                controller: game,
                enabled: !state.busy,
                decoration: InputDecoration(
                  labelText: context.l10n.select(zh: '游戏标签', en: 'Game tag'),
                ),
                onChanged: (value) {
                  state.gameName = value;
                  state.publish();
                },
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in state.games)
                    ActionChip(
                      label: Text(item.name),
                      onPressed: state.busy
                          ? null
                          : () {
                              game.text = item.name;
                              state.gameName = item.name;
                              state.publish();
                            },
                    ),
                ],
              ),
              FilledButton.icon(
                onPressed:
                    state.busy ||
                        state.paths.isEmpty ||
                        game.text.trim().isEmpty
                    ? null
                    : importSelected,
                icon: state.busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
                label: Text(
                  context.l10n.select(
                    zh: state.busy ? '正在导入…' : '开始导入',
                    en: state.busy ? 'Importing…' : 'Start import',
                  ),
                ),
              ),
              if (state.importProgress case final progress?) ...[
                Text(_progressLabel(context, progress)),
                LinearProgressIndicator(value: progress.value),
              ],
              if (state.importSummary case final result?)
                Text(
                  context.l10n.select(
                    zh: '导入 ${result.imported} · 重复 ${result.duplicates} · 失败 ${result.failed}',
                    en: 'Imported ${result.imported} · Duplicates ${result.duplicates} · Failed ${result.failed}',
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

String _progressLabel(BuildContext context, OperationProgressValue progress) {
  if (progress.phase == 'discovering') {
    return context.l10n.select(zh: '正在扫描可导入媒体…', en: 'Scanning for media…');
  }
  if (progress.total case final int total when total > 0) {
    return context.l10n.select(
      zh: '正在导入 ${progress.processed} / $total',
      en: 'Importing ${progress.processed} / $total',
    );
  }
  return context.l10n.select(zh: '正在导入…', en: 'Importing…');
}

class _SelectedMediaPreview extends StatelessWidget {
  const _SelectedMediaPreview({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final extension = p.extension(path).toLowerCase();
    if (const {'.jpg', '.jpeg', '.png', '.webp'}.contains(extension)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(path),
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const SizedBox.square(
            dimension: 48,
            child: Icon(Icons.image_outlined),
          ),
        ),
      );
    }
    return SizedBox.square(
      dimension: 48,
      child: Icon(
        const {'.mp4', '.mov'}.contains(extension)
            ? Icons.movie_outlined
            : Icons.folder_outlined,
      ),
    );
  }
}
