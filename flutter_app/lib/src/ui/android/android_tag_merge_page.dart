import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import 'android_back_guard.dart';
import 'android_page_frame.dart';

class AndroidTagMergePage extends StatefulWidget {
  const AndroidTagMergePage({
    super.key,
    required this.backend,
    this.tags = const [],
    this.games = const [],
    required this.gameTags,
  });
  final AppBackend backend;
  final List<TagUsageSummary> tags;
  final List<GameTagSummary> games;
  final bool gameTags;

  @override
  State<AndroidTagMergePage> createState() => _AndroidTagMergePageState();
}

class _AndroidTagMergePageState extends State<AndroidTagMergePage> {
  final target = TextEditingController();
  final selected = <String>{};
  bool busy = false;
  Object? error;

  @override
  void initState() {
    super.initState();
    target.addListener(changed);
  }

  void changed() => setState(() {});

  @override
  void dispose() {
    target.dispose();
    super.dispose();
  }

  Future<void> merge() async {
    final targetName = target.text.trim();
    if (selected.length < 2 || targetName.isEmpty || busy) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.select(zh: '合并标签？', en: 'Merge tags?')),
        content: Text(
          context.l10n.select(
            zh: '${selected.join('、')} → $targetName\n媒体标签和相册规则将同步更新，原件保持不变。',
            en: '${selected.join(', ')} → $targetName\nMedia tags and album rules are updated; original files are unchanged.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.select(zh: '确认合并', en: 'Confirm merge')),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (widget.gameTags) {
        await widget.backend.mergeGameTags(selected.toList(), targetName);
      } else {
        await widget.backend.mergeTags(
          widget.tags
              .where((tag) => selected.contains(tag.name))
              .map((tag) => tag.id)
              .toList(),
          targetName,
        );
      }
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
    dirty: selected.isNotEmpty || target.text.isNotEmpty,
    child: AndroidPageFrame(
      title: context.l10n.select(
        zh: widget.gameTags ? '合并游戏标签' : '合并自定义标签',
        en: widget.gameTags ? 'Merge game tags' : 'Merge custom tags',
      ),
      secondary: true,
      child: AndroidPageList(
        children: [
          for (final name
              in widget.gameTags
                  ? widget.games.map((tag) => tag.name)
                  : widget.tags.map((tag) => tag.name))
            CheckboxListTile(
              title: Text(name),
              value: selected.contains(name),
              onChanged: busy
                  ? null
                  : (value) => setState(() {
                      value == true
                          ? selected.add(name)
                          : selected.remove(name);
                    }),
            ),
          TextField(
            key: const Key('android-merge-tag-name'),
            controller: target,
            enabled: !busy,
            decoration: InputDecoration(
              labelText: context.l10n.select(zh: '合并后的名称', en: 'Merged name'),
            ),
          ),
          FilledButton.icon(
            onPressed: busy || selected.length < 2 || target.text.trim().isEmpty
                ? null
                : merge,
            icon: const Icon(Icons.merge),
            label: Text(context.l10n.select(zh: '合并', en: 'Merge')),
          ),
          if (error != null) Text(androidReadableError(context, error!)),
        ],
      ),
    ),
  );
}
