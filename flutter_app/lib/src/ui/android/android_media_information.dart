import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../display_time.dart';
import 'android_tag.dart';

/// Android-only compact metadata. Text editing remains owned by the viewer.
class AndroidMediaInformation extends StatelessWidget {
  const AndroidMediaInformation({
    super.key,
    required this.item,
    required this.busy,
    required this.addingTag,
    required this.editingNote,
    required this.tagInput,
    required this.noteInput,
    required this.onAddTag,
    required this.onBeginTag,
    required this.onEditNote,
    required this.onSaveNote,
    required this.onCancelNote,
  });
  final MediaAsset item;
  final bool busy, addingTag, editingNote;
  final TextEditingController tagInput, noteInput;
  final Future<void> Function() onAddTag, onSaveNote;
  final VoidCallback onBeginTag, onEditNote, onCancelNote;

  @override
  Widget build(BuildContext context) {
    final unknown = context.l10n.select(zh: '未知', en: 'Unknown');
    final noteEmpty = item.note?.isNotEmpty != true;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        key: const Key('android-detail-information'),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.originalName,
              key: const Key('android-detail-filename'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Semantics(
              label: context.l10n.select(zh: '游戏标签', en: 'Game tag'),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [AndroidTag(label: item.gameName, game: true)],
              ),
            ),
            const SizedBox(height: 5),
            Semantics(
              label: context.l10n.select(zh: '自定义标签', en: 'Custom tags'),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final tag in item.tags) AndroidTag(label: tag),
                  if (!addingTag)
                    IconButton(
                      key: const Key('android-inline-add-tag'),
                      tooltip: context.l10n.select(zh: '新增标签', en: 'Add tag'),
                      onPressed: busy ? null : onBeginTag,
                      // Small visual, accessible touch target.
                      iconSize: 16,
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .secondaryContainer,
                        padding: const EdgeInsets.all(4),
                        minimumSize: const Size.square(32),
                      ),
                      icon: const Icon(Icons.add),
                    ),
                ],
              ),
            ),
            if (addingTag)
              Focus(
                onFocusChange: (focused) {
                  if (!focused && !busy) unawaited(onAddTag());
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
                  onSubmitted: (_) => onAddTag(),
                  onTapOutside: (_) =>
                      FocusManager.instance.primaryFocus?.unfocus(),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.select(zh: '备注', en: 'Note'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (!editingNote)
                  IconButton(
                    key: const Key('android-inline-edit-note'),
                    tooltip: context.l10n.select(zh: '编辑备注', en: 'Edit note'),
                    onPressed: busy ? null : onEditNote,
                    iconSize: 18,
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
                    onPressed: busy ? null : onSaveNote,
                    child: Text(context.l10n.select(zh: '保存', en: 'Save')),
                  ),
                  TextButton(
                    onPressed: busy ? null : onCancelNote,
                    child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
                  ),
                ],
              ),
            ] else if (noteEmpty)
              TextButton(
                onPressed: busy ? null : onEditNote,
                child: Text(context.l10n.select(zh: '添加备注', en: 'Add note')),
              )
            else
              SelectableText(item.note!),
            const SizedBox(height: 8),
            _TimeRow(
              key: const Key('android-detail-captured'),
              icon: Icons.photo_camera_outlined,
              label: context.l10n.select(zh: '拍摄/创建时间', en: 'Captured/created'),
              value: item.capturedAt == null
                  ? unknown
                  : formatUserDateTime(item.capturedAt!),
            ),
            const SizedBox(height: 5),
            _TimeRow(
              key: const Key('android-detail-imported'),
              icon: Icons.file_download_outlined,
              label: context.l10n.select(zh: '导入时间', en: 'Imported'),
              value: item.importedAt == null
                  ? unknown
                  : formatUserDateTime(item.importedAt!),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  const _TimeRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label, value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 2, right: 8),
        child: ExcludeSemantics(
          child: Icon(
            icon,
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      Expanded(
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '$label\n'),
              TextSpan(text: value),
            ],
          ),
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    ],
  );
}
