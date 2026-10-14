import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../search/search_normalizer.dart';
import 'android_back_guard.dart';
import 'android_page_frame.dart';

class AndroidMetadataEditor extends StatefulWidget {
  const AndroidMetadataEditor({
    super.key,
    required this.backend,
    required this.asset,
  });
  final AppBackend backend;
  final MediaAsset asset;
  @override
  State<AndroidMetadataEditor> createState() => _AndroidMetadataEditorState();
}

class _AndroidMetadataEditorState extends State<AndroidMetadataEditor> {
  late final note = TextEditingController(text: widget.asset.note ?? '');
  final newTag = TextEditingController();
  late final selected = widget.asset.tags.toSet();
  List<String> available = [];
  bool busy = false;
  Object? error;

  bool get dirty =>
      note.text != (widget.asset.note ?? '') ||
      selected.length != widget.asset.tags.length ||
      !selected.containsAll(widget.asset.tags);

  @override
  void initState() {
    super.initState();
    note.addListener(changed);
    widget.backend
        .listTags()
        .then((tags) {
          if (mounted) {
            setState(() => available = {...tags, ...selected}.toList());
          }
        })
        .catchError((Object exception) {
          if (mounted) setState(() => error = exception);
        });
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    note.dispose();
    newTag.dispose();
    super.dispose();
  }

  void add() {
    final name = newTag.text.trim();
    if (name.isEmpty) return;
    final existing = available
        .where((tag) => normalizeSearchText(tag) == normalizeSearchText(name))
        .firstOrNull;
    setState(() {
      selected.add(existing ?? name);
      available = {...available, existing ?? name}.toList();
      newTag.clear();
    });
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.backend.setNote(widget.asset.id, note.text);
      await widget.backend.replaceTags(widget.asset.id, selected.toList());
      if (mounted) Navigator.pop(context, true);
    } catch (exception) {
      if (mounted) {
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
      title: context.l10n.select(zh: '标签与备注', en: 'Tags & Note'),
      secondary: true,
      child: AndroidPageList(
        children: [
          SelectableText(widget.asset.originalName),
          Text(context.l10n.select(zh: '游戏标签', en: 'Game tag')),
          Text(widget.asset.gameName),
          Text(context.l10n.select(zh: '自定义标签', en: 'Custom tags')),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in available)
                FilterChip(
                  label: Text(tag),
                  selected: selected.contains(tag),
                  onSelected: busy
                      ? null
                      : (value) => setState(() {
                          value ? selected.add(tag) : selected.remove(tag);
                        }),
                ),
            ],
          ),
          TextField(
            controller: newTag,
            enabled: !busy,
            decoration: InputDecoration(
              labelText: context.l10n.select(zh: '新增标签', en: 'Add tag'),
              suffixIcon: IconButton(
                tooltip: context.l10n.select(zh: '添加', en: 'Add'),
                onPressed: busy ? null : add,
                icon: const Icon(Icons.add),
              ),
            ),
            onSubmitted: (_) => add(),
          ),
          TextField(
            key: const Key('android-metadata-note'),
            controller: note,
            minLines: 3,
            maxLines: null,
            enabled: !busy,
            decoration: InputDecoration(
              labelText: context.l10n.select(zh: '备注', en: 'Note'),
            ),
          ),
          FilledButton.icon(
            onPressed: busy ? null : save,
            icon: const Icon(Icons.save_outlined),
            label: Text(context.l10n.select(zh: '保存', en: 'Save')),
          ),
          SelectableText(widget.asset.storagePath),
          if (error != null) Text(androidReadableError(context, error!)),
        ],
      ),
    ),
  );
}
