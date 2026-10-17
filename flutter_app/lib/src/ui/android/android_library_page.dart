import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../state/library_controller.dart';
import '../../state/settings_controller.dart';
import 'android_action_bar.dart';
import 'android_layout.dart';
import 'android_media_card.dart';
import 'android_media_viewer.dart';
import 'android_metadata_editor.dart';
import 'android_page_frame.dart';
import 'android_video_merge_page.dart';
import 'android_text_prompt.dart';
import '../device_sync/album_source_label.dart';

class AndroidLibraryPage extends StatefulWidget {
  const AndroidLibraryPage({
    super.key,
    required this.controller,
    required this.settings,
    this.album,
    this.onBack,
  });
  final LibraryController controller;
  final SettingsController settings;
  final AlbumSummary? album;
  final VoidCallback? onBack;
  @override
  State<AndroidLibraryPage> createState() => _AndroidLibraryPageState();
}

class _AndroidLibraryPageState extends State<AndroidLibraryPage> {
  final search = TextEditingController();
  final selected = <int>{};
  Timer? debounce;
  bool selecting = false;
  bool busy = false;
  AppBackend get backend => widget.controller.backend;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.reload());
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await operation();
      if (mounted) await widget.controller.reload();
    } catch (error) {
      if (mounted) androidMessage(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.select(zh: '继续', en: 'Continue')),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> delete(List<MediaAsset> items) async {
    final album = widget.album;
    final approved = await confirm(
      context.l10n.select(
        zh: album == null ? '永久删除媒体？' : '移出相册？',
        en: album == null ? 'Permanently delete media?' : 'Remove from album?',
      ),
      context.l10n.select(
        zh: album == null ? '媒体原件将被永久删除，无法恢复。' : '移出后，如媒体不属于其他相册，原件也会被删除。',
        en: album == null
            ? 'Original files will be permanently deleted.'
            : 'Files with no remaining albums will also be deleted.',
      ),
    );
    if (!approved || !mounted) return;
    await run(() async {
      for (final item in items) {
        if (album == null) {
          await backend.deleteMedia(item.id);
        } else {
          await backend.removeMediaFromAlbum(album.id, item.id);
        }
      }
      selected.removeAll(items.map((item) => item.id));
    });
  }

  Future<void> copyToAlbum(List<MediaAsset> items, {bool move = false}) async {
    final albums = (await backend.listAlbums())
        .where(
          (album) =>
              album.albumType == 'manual' &&
              (!move || album.id != widget.album?.id),
        )
        .toList();
    if (!mounted) return;
    final target = await showDialog<AlbumSummary>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(
          context.l10n.select(
            zh: move ? '移动到普通相册' : '复制到普通相册',
            en: move ? 'Move to regular album' : 'Copy to regular album',
          ),
        ),
        children: [
          if (albums.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                context.l10n.select(
                  zh: '请先创建普通相册。',
                  en: 'Create a regular album first.',
                ),
              ),
            ),
          for (final album in albums)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, album),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(album.name),
                  AlbumSourceLabel(
                    name: album.sourceDeviceName,
                    systemKey: album.systemKey,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    await run(() async {
      for (final item in items) {
        await backend.addMediaToAlbum(target.id, item.id);
        if (move && widget.album?.albumType == 'manual') {
          await backend.removeMediaFromAlbum(widget.album!.id, item.id);
        }
      }
    });
    if (mounted && move && widget.album?.albumType != 'manual') {
      androidMessage(
        context,
        context.l10n.select(
          zh: '已复制到相册；当前列表没有可移出的普通相册。',
          en: 'Copied to the album; this view has no regular source album.',
        ),
      );
    }
  }

  Future<void> export(List<MediaAsset> items) async {
    final template = await androidTextPrompt(
      context,
      title: context.l10n.select(zh: '导出命名', en: 'Export naming'),
      initialValue: '{game}_{date}_{time}',
      confirmLabel: context.l10n.select(zh: '选择目录', en: 'Choose folder'),
    );
    if (template == null) return;
    try {
      final path = await FilePicker.getDirectoryPath();
      if (path == null || !mounted) return;
      await run(() async {
        final result = await backend.exportMedia(
          items.map((item) => item.id).toList(),
          path,
          template,
        );
        if (mounted) {
          androidMessage(
            context,
            context.l10n.select(
              zh: '已导出 ${result.exported} · 失败 ${result.failed}',
              en: 'Exported ${result.exported} · Failed ${result.failed}',
            ),
          );
        }
      });
    } catch (error) {
      if (mounted) androidMessage(context, error);
    }
  }

  Future<void> tags(List<MediaAsset> items, {required bool replace}) async {
    final value = await androidTextPrompt(
      context,
      title: context.l10n.select(
        zh: replace ? '覆盖标签' : '新增标签',
        en: replace ? 'Replace tags' : 'Add tags',
      ),
      hint: context.l10n.select(
        zh: '用逗号分隔多个标签',
        en: 'Separate tags with commas',
      ),
    );
    if (value == null || !mounted) return;
    final values = value
        .split(RegExp('[,，]'))
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet();
    await run(() async {
      for (final item in items) {
        await backend.replaceTags(
          item.id,
          (replace ? values : {...item.tags, ...values}).toList(),
        );
      }
    });
  }

  List<AndroidAction> actions(List<MediaAsset> items) => [
    AndroidAction(
      label: context.l10n.select(zh: '复制到相册', en: 'Copy to album'),
      icon: Icons.copy,
      onPressed: busy || items.isEmpty ? null : () => copyToAlbum(items),
    ),
    AndroidAction(
      label: context.l10n.select(zh: '移动到相册', en: 'Move to album'),
      icon: Icons.drive_file_move_outline,
      onPressed: busy || items.isEmpty
          ? null
          : () => copyToAlbum(items, move: true),
    ),
    AndroidAction(
      label: context.l10n.select(zh: '收藏', en: 'Favorite'),
      icon: Icons.favorite_border,
      onPressed: busy || items.isEmpty
          ? null
          : () => run(() async {
              for (final item in items) {
                await backend.setFavorite(item.id, true);
              }
            }),
    ),
    AndroidAction(
      label: context.l10n.select(zh: '新增标签', en: 'Add tags'),
      icon: Icons.label_outline,
      onPressed: busy || items.isEmpty
          ? null
          : () => tags(items, replace: false),
    ),
    AndroidAction(
      label: context.l10n.select(zh: '覆盖标签', en: 'Replace tags'),
      icon: Icons.label,
      onPressed: busy || items.isEmpty
          ? null
          : () => tags(items, replace: true),
    ),
    AndroidAction(
      label: context.l10n.select(zh: '导出', en: 'Export'),
      icon: Icons.file_download_outlined,
      onPressed: busy || items.isEmpty ? null : () => export(items),
    ),
    AndroidAction(
      label: context.l10n.select(zh: '合并视频', en: 'Merge videos'),
      icon: Icons.video_library_outlined,
      onPressed:
          busy ||
              items.length < 2 ||
              items.any((item) => item.kind != MediaKind.video)
          ? null
          : () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      AndroidVideoMergePage(backend: backend, videos: items),
                ),
              );
              if (mounted) await widget.controller.reload();
            },
    ),
    AndroidAction(
      label: context.l10n.select(zh: '删除', en: 'Delete'),
      icon: Icons.delete_outline,
      onPressed: busy || items.isEmpty ? null : () => delete(items),
    ),
  ];

  Future<void> menu(MediaAsset asset) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(asset.originalName),
              onTap: () async {
                Navigator.pop(context);
                await Navigator.of(this.context).push(
                  MaterialPageRoute<bool>(
                    builder: (_) =>
                        AndroidMetadataEditor(backend: backend, asset: asset),
                  ),
                );
                if (mounted) await widget.controller.reload();
              },
            ),
            for (final action in actions([asset]))
              ListTile(
                leading: Icon(action.icon),
                title: Text(action.label),
                enabled: action.onPressed != null,
                onTap: action.onPressed == null
                    ? null
                    : () {
                        Navigator.pop(context);
                        action.onPressed!();
                      },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> filters() async {
    final state = widget.controller;
    final games = await backend.listGameTags();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: Text(
                  context.l10n.select(zh: '仅收藏', en: 'Favorites only'),
                ),
                value: state.favoriteOnly,
                onChanged: (value) => update(() => state.favoriteOnly = value),
              ),
              SwitchListTile(
                title: Text(
                  context.l10n.select(zh: '最新优先', en: 'Newest first'),
                ),
                value: state.newestFirst,
                onChanged: (value) => update(() => state.newestFirst = value),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final game in games)
                    FilterChip(
                      label: Text(game.name),
                      selected: state.gameNames.contains(game.name),
                      onSelected: (value) => update(() {
                        state.gameNames = value
                            ? {...state.gameNames, game.name}.toList()
                            : state.gameNames
                                  .where((name) => name != game.name)
                                  .toList();
                      }),
                    ),
                ],
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.date_range),
                label: Text(
                  context.l10n.select(zh: '拍摄日期', en: 'Capture dates'),
                ),
                onPressed: () async {
                  final range = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (range != null) {
                    state.capturedFrom = range.start;
                    state.capturedUntil = range.end.add(
                      const Duration(days: 1),
                    );
                  }
                },
              ),
              TextButton(
                onPressed: () => update(() {
                  state.favoriteOnly = false;
                  state.gameNames = [];
                  state.capturedFrom = null;
                  state.capturedUntil = null;
                }),
                child: Text(
                  context.l10n.select(zh: '清除筛选', en: 'Clear filters'),
                ),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.l10n.select(zh: '应用', en: 'Apply')),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) await state.reload();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.controller, widget.settings]),
    builder: (context, _) {
      final state = widget.controller;
      final items = state.visible;
      final chosen = state.items
          .where((item) => selected.contains(item.id))
          .toList();
      return PopScope<Object?>(
        canPop:
            !selecting && !busy && MediaQuery.viewInsetsOf(context).bottom == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (MediaQuery.viewInsetsOf(context).bottom > 0) {
            FocusManager.instance.primaryFocus?.unfocus();
            return;
          }
          if (!didPop && selecting && !busy) {
            setState(() {
              selecting = false;
              selected.clear();
            });
          }
        },
        child: AndroidPageFrame(
          title: selecting
              ? context.l10n.select(
                  zh: '已选择 ${selected.length} 项',
                  en: '${selected.length} selected',
                )
              : widget.album?.name ??
                    context.l10n.select(zh: '图库', en: 'Library'),
          secondary: selecting || widget.onBack != null,
          onBack: selecting
              ? () {
                  if (busy) return;
                  if (MediaQuery.viewInsetsOf(context).bottom > 0) {
                    FocusManager.instance.primaryFocus?.unfocus();
                    return;
                  }
                  setState(() {
                    selecting = false;
                    selected.clear();
                  });
                }
              : widget.onBack == null
              ? null
              : () => Navigator.of(context).maybePop(),
          actions: [
            if (!selecting) ...[
              IconButton(
                tooltip: context.l10n.select(zh: '筛选', en: 'Filter'),
                onPressed: filters,
                icon: const Icon(Icons.filter_list),
              ),
              IconButton(
                key: const Key('android-select-media'),
                tooltip: context.l10n.select(zh: '批量选择', en: 'Select'),
                onPressed: () => setState(() => selecting = true),
                icon: const Icon(Icons.checklist),
              ),
            ] else
              AndroidActionMenu(
                label: context.l10n.select(zh: '更多操作', en: 'More actions'),
                actions: [
                  AndroidAction(
                    label: context.l10n.select(zh: '全选', en: 'Select all'),
                    icon: Icons.select_all,
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            selected.addAll(items.map((item) => item.id));
                          }),
                  ),
                  AndroidAction(
                    label: context.l10n.select(
                      zh: '反选',
                      en: 'Invert selection',
                    ),
                    icon: Icons.flip,
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            for (final item in items) {
                              if (!selected.remove(item.id)) {
                                selected.add(item.id);
                              }
                            }
                          }),
                  ),
                  ...actions(chosen),
                ],
              ),
          ],
          child: LayoutBuilder(
            builder: (context, constraints) {
              final padding = androidPagePadding(constraints.maxWidth);
              final spacing = androidCardSpacing(constraints.maxWidth);
              final columns = androidGalleryColumns(
                width: constraints.maxWidth - 2 * padding,
                preferredColumns: widget.settings.value.galleryColumns,
                textScaler: MediaQuery.textScalerOf(context),
                spacing: spacing,
              );
              return CustomScrollView(
                key: PageStorageKey(
                  'android-library-${widget.album?.id ?? 'all'}',
                ),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.all(padding),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        children: [
                          if (widget.album case final album?
                              when album.systemKey != 'favorites') ...[
                            Align(
                              alignment: Alignment.centerLeft,
                              child: AlbumSourceLabel(
                                name: album.sourceDeviceName,
                                systemKey: album.systemKey,
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          TextField(
                            key: const Key('android-library-search'),
                            controller: search,
                            decoration: InputDecoration(
                              prefixIcon: const Icon(Icons.search),
                              hintText: context.l10n.select(
                                zh: '搜索游戏、标签、备注',
                                en: 'Search games, tags, notes',
                              ),
                            ),
                            onChanged: (value) {
                              debounce?.cancel();
                              if (search.value.composing.isValid &&
                                  !search.value.composing.isCollapsed) {
                                return;
                              }
                              debounce = Timer(
                                const Duration(milliseconds: 600),
                                () => state.searchFor(value),
                              );
                            },
                            onSubmitted: state.searchFor,
                          ),
                          const SizedBox(height: 8),
                          SegmentedButton<GalleryKindFilter>(
                            key: const Key('android-kind-filter'),
                            showSelectedIcon: false,
                            style: ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              minimumSize: const WidgetStatePropertyAll(
                                Size(0, 32),
                              ),
                              padding: const WidgetStatePropertyAll(
                                EdgeInsets.symmetric(horizontal: 12),
                              ),
                            ),
                            selected: {state.kind},
                            onSelectionChanged: (values) {
                              state.kind = values.single;
                              state.reload();
                            },
                            segments: [
                              for (final entry in {
                                GalleryKindFilter.all: context.l10n.select(
                                  zh: '全部',
                                  en: 'All',
                                ),
                                GalleryKindFilter.image: context.l10n.select(
                                  zh: '图片',
                                  en: 'Photos',
                                ),
                                GalleryKindFilter.video: context.l10n.select(
                                  zh: '视频',
                                  en: 'Videos',
                                ),
                              }.entries)
                                ButtonSegment(
                                  value: entry.key,
                                  label: Text(entry.value),
                                ),
                            ],
                          ),
                          if (state.favoriteOnly ||
                              state.gameNames.isNotEmpty ||
                              state.capturedFrom != null)
                            Text(
                              context.l10n.select(
                                zh: '已应用筛选',
                                en: 'Filters applied',
                              ),
                            ),
                          if (state.loading) const LinearProgressIndicator(),
                          if (state.error != null)
                            Text(androidReadableError(context, state.error!)),
                          if (!state.loading && items.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                context.l10n.select(
                                  zh: '当前条件下没有媒体',
                                  en: 'No matching media',
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(padding, 0, padding, padding),
                    sliver: SliverList.builder(
                      itemCount: (items.length / columns).ceil(),
                      itemBuilder: (context, row) => Padding(
                        padding: EdgeInsets.only(bottom: spacing),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (
                              var column = 0;
                              column < columns;
                              column++
                            ) ...[
                              if (column > 0) SizedBox(width: spacing),
                              Expanded(
                                child: row * columns + column >= items.length
                                    ? const SizedBox.shrink()
                                    : Builder(
                                        builder: (context) {
                                          final item =
                                              items[row * columns + column];
                                          return AndroidMediaCard(
                                            key: ValueKey(
                                              'android-media-${item.id}',
                                            ),
                                            asset: item,
                                            settings: widget.settings.value,
                                            selecting: selecting,
                                            selected: selected.contains(
                                              item.id,
                                            ),
                                            onOpen: () async {
                                              if (selecting) {
                                                setState(() {
                                                  selected.contains(item.id)
                                                      ? selected.remove(item.id)
                                                      : selected.add(item.id);
                                                });
                                                return;
                                              }
                                              await Navigator.of(context).push(
                                                MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      AndroidMediaViewer(
                                                        backend: backend,
                                                        settings: widget
                                                            .settings
                                                            .value,
                                                        items: items,
                                                        initialIndex:
                                                            row * columns +
                                                            column,
                                                      ),
                                                ),
                                              );
                                              if (mounted) await state.reload();
                                            },
                                            onMenu: () => menu(item),
                                            onFavorite: () =>
                                                run(() => state.favorite(item)),
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}
