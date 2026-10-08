import 'package:flutter/material.dart';

import '../backend/app_backend.dart';
import '../l10n/app_localizations.dart';
import '../rust/models.dart';
import '../search/search_normalizer.dart';
import 'font_families.dart';

class MediaMetadataUpdate {
  const MediaMetadataUpdate({required this.note, required this.tags});

  final String note;
  final List<String> tags;
}

class MediaMetadataEditor extends StatefulWidget {
  const MediaMetadataEditor({
    super.key,
    required this.backend,
    required this.asset,
  });

  final AppBackend backend;
  final MediaAsset asset;

  @override
  State<MediaMetadataEditor> createState() => _MediaMetadataEditorState();
}

class _MediaMetadataEditorState extends State<MediaMetadataEditor> {
  late final TextEditingController note = TextEditingController(
    text: widget.asset.note,
  );
  final TextEditingController newTag = TextEditingController();
  late final Set<String> selectedTags = widget.asset.tags.toSet();
  List<String> availableTags = const [];
  bool saving = false;

  @override
  void initState() {
    super.initState();
    newTag.addListener(_onNewTagChanged);
    widget.backend.listTags().then((tags) {
      if (mounted) setState(() => availableTags = tags);
    });
  }

  @override
  void dispose() {
    note.dispose();
    newTag
      ..removeListener(_onNewTagChanged)
      ..dispose();
    super.dispose();
  }

  void _onNewTagChanged() {
    final value = newTag.value;
    if (!mounted || (value.composing.isValid && !value.composing.isCollapsed)) {
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        4,
        24,
        28 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.asset.originalName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),
            if (widget.backend.settings.compactTagDisplay) ...[
              Text(
                context.l10n.select(zh: '标签', en: 'Tags'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                key: const Key('media-metadata-compact-tags'),
                spacing: 8,
                runSpacing: 8,
                children: [_gameTag(context), ..._customTagChips],
              ),
            ] else ...[
              Text(
                context.l10n.select(zh: '游戏标签', en: 'Game tag'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              _gameTag(context),
              const SizedBox(height: 18),
              Text(
                context.l10n.select(zh: '自定义标签', en: 'Custom tags'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                key: const Key('media-metadata-separated-tags'),
                spacing: 8,
                runSpacing: 8,
                children: _customTagChips,
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              key: const Key('media-metadata-new-tag'),
              controller: newTag,
              decoration: InputDecoration(
                labelText: context.l10n.select(zh: '新增标签', en: 'Add tag'),
                hintText: context.l10n.select(
                  zh: '输入后按回车或点击添加',
                  en: 'Press Enter or use the add button',
                ),
                suffixIcon: IconButton(
                  key: const Key('media-metadata-add-tag'),
                  tooltip: context.l10n.select(zh: '添加标签', en: 'Add tag'),
                  onPressed: () => _addTag(newTag.text),
                  icon: const Icon(Icons.add_rounded),
                ),
                border: const OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: _addTag,
            ),
            const SizedBox(height: 18),
            Text(
              context.l10n.select(zh: '备注', en: 'Note'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('media-metadata-note'),
              controller: note,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(
                hintText: context.l10n.select(
                  zh: '为这个媒体添加备注',
                  en: 'Add a note for this media item',
                ),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            SelectableText(
              context.l10n.select(
                zh: '文件路径：${widget.asset.storagePath}\n创建时间：${widget.asset.capturedAt?.toLocal() ?? '未知'}\n内容哈希：${widget.asset.sha256}',
                en: 'File path: ${widget.asset.storagePath}\nCreated at: ${widget.asset.capturedAt?.toLocal() ?? 'Unknown'}\nContent hash: ${widget.asset.sha256}',
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('save-media-metadata'),
                onPressed: saving ? null : _save,
                icon: saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(
                  context.l10n.select(zh: '保存标签与备注', en: 'Save tags and note'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  void _addTag(String value) {
    final tag = value.trim();
    if (tag.isEmpty) return;
    final normalized = normalizeSearchText(tag);
    final existing = availableTags.cast<String?>().firstWhere(
      (candidate) => normalizeSearchText(candidate!) == normalized,
      orElse: () => null,
    );
    final selected = existing ?? tag;
    setState(() {
      selectedTags.add(selected);
      if (existing == null) availableTags = [...availableTags, selected];
      newTag.clear();
    });
  }

  Widget _gameTag(BuildContext context) => Chip(
    avatar: const Icon(Icons.sports_esports_rounded, size: 18),
    label: Text(
      widget.asset.gameName.isEmpty
          ? context.l10n.select(zh: '未知游戏', en: 'Unknown game')
          : widget.asset.gameName,
    ),
  );

  List<Widget> get _customTagChips => _visibleTags.map((tag) {
    return FilterChip(
      label: Text(tag),
      labelStyle: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFamily: appFontFamily,
        fontFamilyFallback: appFontFallback,
      ),
      selected: selectedTags.contains(tag),
      onSelected: (selected) => setState(() {
        if (selected) {
          selectedTags.add(tag);
        } else {
          selectedTags.remove(tag);
        }
      }),
    );
  }).toList();

  List<String> get _visibleTags {
    final query = normalizeSearchText(newTag.text.trim());
    if (query.isEmpty) return availableTags;
    return availableTags
        .where(
          (tag) =>
              selectedTags.contains(tag) ||
              normalizeSearchText(tag).contains(query),
        )
        .toList();
  }

  Future<void> _save() async {
    _takePendingTag();
    setState(() => saving = true);
    final nextNote = note.text.trim();
    final nextTags = selectedTags.toList()..sort();
    try {
      await widget.backend.setNote(widget.asset.id, nextNote);
      await widget.backend.replaceTags(widget.asset.id, nextTags);
      if (mounted) {
        Navigator.pop(
          context,
          MediaMetadataUpdate(note: nextNote, tags: nextTags),
        );
      }
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to save media details',
        error,
        stackTrace,
      );
      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 12),
          showCloseIcon: true,
          content: Text(
            context.l10n.select(
              zh: '保存失败：$error',
              en: 'Failed to save: $error',
            ),
          ),
        ),
      );
    }
  }

  void _takePendingTag() {
    final tag = newTag.text.trim();
    if (tag.isEmpty) return;
    final normalized = normalizeSearchText(tag);
    final existing = availableTags.cast<String?>().firstWhere(
      (candidate) => normalizeSearchText(candidate!) == normalized,
      orElse: () => null,
    );
    final selected = existing ?? tag;
    selectedTags.add(selected);
    if (existing == null) availableTags = [...availableTags, selected];
    newTag.clear();
  }
}
