import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import 'android_back_guard.dart';
import 'android_page_frame.dart';
import 'android_text_prompt.dart';
import 'android_tag_merge_page.dart';

class AndroidTagManagementPage extends StatefulWidget {
  const AndroidTagManagementPage({super.key, required this.backend});

  final AppBackend backend;

  @override
  State<AndroidTagManagementPage> createState() =>
      _AndroidTagManagementPageState();
}

class _AndroidTagManagementPageState extends State<AndroidTagManagementPage> {
  late Future<List<TagUsageSummary>> tags = widget.backend.listTagUsage();
  late Future<List<GameTagSummary>> games = widget.backend.listGameTags();
  bool busy = false;

  void reload() {
    setState(() {
      tags = widget.backend.listTagUsage();
      games = widget.backend.listGameTags();
    });
  }

  Future<void> addTag() async {
    final name = await androidTextPrompt(
      context,
      title: context.l10n.select(zh: '新增标签', en: 'Add tag'),
    );
    if (name == null || name.isEmpty || !mounted) return;
    await perform(() => widget.backend.createTag(name));
  }

  Future<void> perform(Future<Object?> Function() action) async {
    if (busy || !mounted) return;
    setState(() => busy = true);
    try {
      await action();
      if (mounted) reload();
    } catch (error) {
      if (mounted) androidMessage(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> rename(TagUsageSummary tag) async {
    final value = await androidTextPrompt(
      context,
      title: context.l10n.select(zh: '重命名标签', en: 'Rename tag'),
      initialValue: tag.name,
    );
    if (value == null || value.isEmpty || value == tag.name || !mounted) return;
    await perform(() => widget.backend.renameTag(tag.id, value));
  }

  Future<void> replaceGame(GameTagSummary tag) async {
    final value = await androidTextPrompt(
      context,
      title: context.l10n.select(
        zh: '替换游戏标签显示名',
        en: 'Replace game tag display name',
      ),
      initialValue: tag.name,
    );
    if (value == null || value.isEmpty || value == tag.name || !mounted) return;
    await perform(() => widget.backend.renameGameTag(tag.name, value));
  }

  Future<void> delete(TagUsageSummary tag) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.select(zh: '删除标签？', en: 'Delete tag?')),
        content: Text(
          context.l10n.select(
            zh: '将从媒体移除“${tag.name}”，不会删除媒体原件。',
            en: 'Removes “${tag.name}” from media without deleting original files.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.select(zh: '删除', en: 'Delete')),
          ),
        ],
      ),
    );
    if (approved == true && mounted) {
      await perform(() => widget.backend.deleteTag(tag.id));
    }
  }

  Future<void> merge(bool gameTags) async {
    try {
      final tagValues = gameTags ? <TagUsageSummary>[] : await tags;
      final gameValues = gameTags ? await games : <GameTagSummary>[];
      if (!mounted) return;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => AndroidTagMergePage(
            backend: widget.backend,
            tags: tagValues,
            games: gameValues,
            gameTags: gameTags,
          ),
        ),
      );
      if (mounted) reload();
    } catch (error) {
      if (mounted) androidMessage(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => AndroidBackGuard(
    busy: busy,
    child: AndroidPageFrame(
      title: context.l10n.select(zh: '标签管理', en: 'Tag management'),
      secondary: true,
      actions: [
        PopupMenuButton<bool>(
          tooltip: context.l10n.select(zh: '更多操作', en: 'More actions'),
          enabled: !busy,
          onSelected: merge,
          itemBuilder: (_) => [
            PopupMenuItem(
              value: false,
              child: Text(
                context.l10n.select(zh: '合并自定义标签', en: 'Merge custom tags'),
              ),
            ),
            PopupMenuItem(
              value: true,
              child: Text(
                context.l10n.select(zh: '合并游戏标签', en: 'Merge game tags'),
              ),
            ),
          ],
        ),
        IconButton(
          tooltip: context.l10n.select(zh: '新增标签', en: 'Add tag'),
          onPressed: busy ? null : addTag,
          icon: const Icon(Icons.add),
        ),
      ],
      child: FutureBuilder<List<TagUsageSummary>>(
        future: tags,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: SelectableText(snapshot.error.toString()));
          }
          final values = snapshot.data;
          if (values == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return AndroidPageList(
            children: [
              Text(context.l10n.select(zh: '自定义标签', en: 'Custom tags')),
              if (values.isEmpty)
                Text(
                  context.l10n.select(
                    zh: '还没有自定义标签。',
                    en: 'No custom tags yet.',
                  ),
                ),
              for (final tag in values)
                Card(
                  child: ListTile(
                    title: Text(tag.name),
                    subtitle: Text(
                      context.l10n.select(
                        zh: '${tag.imageCount} 张图片 · ${tag.videoCount} 个视频',
                        en: '${tag.imageCount} photos · ${tag.videoCount} videos',
                      ),
                    ),
                    trailing: PopupMenuButton<String>(
                      key: ValueKey('android-tag-actions-${tag.id}'),
                      enabled: !busy,
                      tooltip: context.l10n.select(zh: '更多', en: 'More'),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'rename',
                          child: Text(
                            context.l10n.select(zh: '重命名', en: 'Rename'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(
                            context.l10n.select(zh: '删除', en: 'Delete'),
                          ),
                        ),
                      ],
                      onSelected: (action) =>
                          action == 'rename' ? rename(tag) : delete(tag),
                    ),
                  ),
                ),
              Text(context.l10n.select(zh: '游戏标签', en: 'Game tags')),
              FutureBuilder<List<GameTagSummary>>(
                future: games,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return SelectableText(snapshot.error.toString());
                  }
                  return Column(
                    children: [
                      for (final tag in snapshot.data ?? <GameTagSummary>[])
                        Card(
                          child: ListTile(
                            title: Text(tag.name),
                            subtitle: Text(
                              context.l10n.select(
                                zh: '${tag.imageCount} 张图片 · ${tag.videoCount} 个视频',
                                en: '${tag.imageCount} photos · ${tag.videoCount} videos',
                              ),
                            ),
                            trailing: IconButton(
                              key: ValueKey('android-game-replace-${tag.name}'),
                              tooltip: context.l10n.select(
                                zh: '替换显示名',
                                en: 'Replace display name',
                              ),
                              onPressed: busy ? null : () => replaceGame(tag),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    ),
  );
}
