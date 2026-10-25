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
import '../../platform/android_media_share.dart';

PageRoute<void> _androidMediaViewerRoute(WidgetBuilder builder) =>
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, _, _) => builder(context),
      transitionsBuilder: (context, animation, _, child) => FadeTransition(
        key: const Key('android-detail-route-fade'),
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        child: child,
      ),
    );

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
  final scroll = ScrollController();
  final selected = <int>{};
  bool selecting = false;
  bool busy = false;
  AppBackend get backend => widget.controller.backend;

  @override
  void initState() {
    super.initState();
    search.text = widget.controller.search;
    unawaited(widget.controller.reload());
    scroll.addListener(_loadWhenNearEnd);
  }

  void _loadWhenNearEnd() {
    if (!scroll.hasClients ||
        scroll.position.extentAfter > 640 ||
        widget.controller.loadingMore ||
        widget.controller.error != null) {
      return;
    }
    unawaited(widget.controller.loadNextPage());
  }

  void applySearch() {
    FocusManager.instance.primaryFocus?.unfocus();
    widget.controller.searchFor(search.text);
  }

  @override
  void dispose() {
    search.dispose();
    scroll.dispose();
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
        isError: false,
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
            isError: result.failed > BigInt.zero,
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
      label: context.l10n.select(zh: '分享', en: 'Share'),
      icon: Icons.share_outlined,
      onPressed: busy || items.isEmpty
          ? null
          : () => showAndroidMediaShareSheet(context, items),
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
    final games = state.albumId == null
        ? await backend.listGameTags()
        : (await backend.listGameMediaCounts(albumId: state.albumId))
              .map(
                (game) => GameTagSummary(
                  name: game.gameName,
                  imageCount: game.imageCount,
                  videoCount: game.videoCount,
                  selectionCount: game.selectionCount,
                ),
              )
              .toList(growable: false);
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
                  context.l10n.select(
                    zh: _captureRangeLabel(state),
                    en: _captureRangeLabel(state, english: true),
                  ),
                ),
                onPressed: () async {
                  final range = await _chooseCaptureRange(context, state);
                  if (range != null) {
                    update(() {
                      state.importedFrom = range.from;
                      state.importedUntil = range.until;
                      state.capturedOnThisDay = range.anniversary;
                    });
                  }
                },
              ),
              TextButton(
                onPressed: () => update(() {
                  state.kind = GalleryKindFilter.all;
                  state.favoriteOnly = false;
                  state.gameNames = [];
                  state.importedFrom = null;
                  state.importedUntil = null;
                  state.capturedOnThisDay = null;
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

  Future<_CaptureDateSelection?> _chooseCaptureRange(
    BuildContext context,
    LibraryController state,
  ) async {
    return showDialog<_CaptureDateSelection>(
      context: context,
      builder: (context) => Dialog(
        key: const Key('android-date-range-dialog'),
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.select(zh: '选择时间范围', en: 'Choose date range'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (state.importedFrom != null ||
                    state.importedUntil != null ||
                    state.capturedOnThisDay != null)
                  Text(
                    context.l10n.select(
                      zh: '当前：${_formatDateRange(state)}',
                      en: 'Current: ${_formatDateRange(state, english: true)}',
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  context.l10n.select(zh: '快速时间范围', en: 'Quick date ranges'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in _quickRanges(context).entries)
                      OutlinedButton(
                        key: Key('android-filter-${entry.key}'),
                        onPressed: () => Navigator.pop(
                          context,
                          _CaptureDateSelection.range(
                            entry.value.$1,
                            entry.value.$2,
                          ),
                        ),
                        child: Text(entry.value.$3),
                      ),
                    OutlinedButton(
                      key: const Key('android-filter-anniversary'),
                      onPressed: () {
                        final now = DateTime.now();
                        Navigator.pop(
                          context,
                          _CaptureDateSelection.anniversary(
                            CapturedOnThisDay(
                              month: now.month,
                              day: now.day,
                              beforeYear: now.year,
                              utcOffsetSeconds: now.timeZoneOffset.inSeconds,
                            ),
                          ),
                        );
                      },
                      child: Text(
                        context.l10n.select(
                          zh: '那年今日',
                          en: 'This date in history',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: Text(
                    context.l10n.select(zh: '自定义日期范围', en: 'Custom date range'),
                  ),
                  onPressed: () async {
                    final range = await showDialog<DateTimeRange>(
                      context: context,
                      builder: (_) => _AndroidCustomDateRangeDialog(
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      ),
                    );
                    if (!context.mounted || range == null) return;
                    Navigator.pop(
                      context,
                      _CaptureDateSelection.range(
                        _dayStart(range.start),
                        DateTime(
                          range.end.year,
                          range.end.month,
                          range.end.day + 1,
                        ),
                      ),
                    );
                  },
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  DateTime _dayStart(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  String _formatDate(DateTime value, {bool english = false}) => english
      ? '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}'
      : '${value.year}/${value.month}/${value.day}';

  String _formatDateRange(LibraryController state, {bool english = false}) {
    final anniversary = state.capturedOnThisDay;
    if (anniversary != null) {
      return english
          ? 'On this day · ${anniversary.month}/${anniversary.day} in previous years'
          : '那年今日 · 往年 ${anniversary.month}/${anniversary.day}';
    }
    final from = state.importedFrom;
    final until = state.importedUntil;
    if (from == null && until == null) {
      return context.l10n.select(zh: '不限', en: 'Any date');
    }
    final end = until?.subtract(const Duration(days: 1));
    return [
      if (from != null) _formatDate(from, english: english),
      if (end != null) _formatDate(end, english: english),
    ].join(english ? ' to ' : ' 至 ');
  }

  String _captureRangeLabel(LibraryController state, {bool english = false}) {
    if (state.importedFrom == null &&
        state.importedUntil == null &&
        state.capturedOnThisDay == null) {
      return context.l10n.select(zh: '创建日期', en: 'Creation dates');
    }
    return _formatDateRange(state, english: english);
  }

  Map<String, (DateTime, DateTime, String)> _quickRanges(BuildContext context) {
    final now = DateTime.now();
    final today = _dayStart(now);
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final monday = DateTime(
      today.year,
      today.month,
      today.day - today.weekday + 1,
    );
    final nextMonday = DateTime(monday.year, monday.month, monday.day + 7);
    final previousMonday = DateTime(monday.year, monday.month, monday.day - 7);
    final monthStart = DateTime(today.year, today.month);
    final nextMonth = DateTime(today.year, today.month + 1);
    return {
      'today': (today, tomorrow, context.l10n.select(zh: '本日', en: 'Today')),
      'this-week': (
        monday,
        nextMonday,
        context.l10n.select(zh: '本周', en: 'This week'),
      ),
      'this-month': (
        monthStart,
        nextMonth,
        context.l10n.select(zh: '本月', en: 'This month'),
      ),
      'last-week': (
        previousMonday,
        monday,
        context.l10n.select(zh: '上周', en: 'Last week'),
      ),
    };
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.controller, widget.settings]),
    builder: (context, _) {
      final state = widget.controller;
      final items = state.visible;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !state.loading) _loadWhenNearEnd();
      });
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
              MergeSemantics(
                child: Semantics(
                  selected: state.hasFilters,
                  child: IconButton(
                    key: const Key('android-library-filter'),
                    tooltip: context.l10n.select(zh: '筛选', en: 'Filter'),
                    onPressed: filters,
                    icon: Icon(
                      Icons.filter_list,
                      color: state.hasFilters
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                ),
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
                controller: scroll,
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
                          KeyedSubtree(
                            key: const Key('android-library-search-input'),
                            child: TextField(
                              key: const Key('android-library-search'),
                              controller: search,
                              textInputAction: TextInputAction.search,
                              decoration: InputDecoration(
                                prefixIcon: const Icon(Icons.search),
                                hintText: context.l10n.select(
                                  zh: '搜索游戏、标签、备注',
                                  en: 'Search games, tags, notes',
                                ),
                                suffixIcon: search.text.isEmpty
                                    ? null
                                    : IconButton(
                                        tooltip: context.l10n.select(
                                          zh: '清除搜索',
                                          en: 'Clear search',
                                        ),
                                        onPressed: () {
                                          search.clear();
                                          applySearch();
                                          setState(() {});
                                        },
                                        icon: const Icon(Icons.clear),
                                      ),
                              ),
                              onChanged: (_) => setState(() {}),
                              onSubmitted: (_) => applySearch(),
                            ),
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
                          if (state.hasFilters)
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
                                                _androidMediaViewerRoute(
                                                  (_) => AndroidMediaViewer(
                                                    backend: backend,
                                                    settings:
                                                        widget.settings.value,
                                                    items: items,
                                                    initialIndex:
                                                        row * columns + column,
                                                    galleryQuery:
                                                        state.galleryQuery,
                                                    initialPage:
                                                        state.pages.snapshot,
                                                    mediaFilter:
                                                        state.pages.accept,
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
                  if (state.loadingMore)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: LinearProgressIndicator(),
                      ),
                    ),
                  if (!state.loading && state.error != null && state.hasAfter)
                    SliverToBoxAdapter(
                      child: TextButton.icon(
                        onPressed: state.loadNextPage,
                        icon: const Icon(Icons.refresh),
                        label: Text(
                          context.l10n.select(
                            zh: '加载失败，重试',
                            en: 'Loading failed. Retry',
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

class _CaptureDateSelection {
  const _CaptureDateSelection.range(this.from, this.until) : anniversary = null;
  const _CaptureDateSelection.anniversary(this.anniversary)
    : from = null,
      until = null;

  final DateTime? from;
  final DateTime? until;
  final CapturedOnThisDay? anniversary;
}

class _AndroidCustomDateRangeDialog extends StatefulWidget {
  const _AndroidCustomDateRangeDialog({
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_AndroidCustomDateRangeDialog> createState() =>
      _AndroidCustomDateRangeDialogState();
}

class _AndroidCustomDateRangeDialogState
    extends State<_AndroidCustomDateRangeDialog> {
  late DateTime start = DateUtils.dateOnly(DateTime.now());
  DateTime? end;
  bool choosingEnd = false;

  String _date(DateTime? value) {
    if (value == null) return '—';
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

  void _choose(DateTime value) {
    final selected = DateUtils.dateOnly(value);
    if (!choosingEnd) {
      setState(() {
        start = selected;
        end = null;
        choosingEnd = true;
      });
      return;
    }
    final first = selected.isBefore(start) ? selected : start;
    final last = selected.isBefore(start) ? start : selected;
    Navigator.of(context).pop(DateTimeRange(start: first, end: last));
  }

  @override
  Widget build(BuildContext context) => Dialog(
    key: const Key('android-custom-date-range-dialog'),
    insetPadding: const EdgeInsets.all(24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420, maxHeight: 540),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              context.l10n.select(zh: '选择创建时间', en: 'Select creation dates'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              choosingEnd
                  ? context.l10n.select(zh: '请选择结束日期', en: 'Choose an end date')
                  : context.l10n.select(
                      zh: '请先选择开始日期',
                      en: 'Choose a start date first',
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _DateRangeStep(
                    label: context.l10n.select(zh: '开始日期', en: 'Start date'),
                    value: _date(start),
                    active: !choosingEnd,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward_rounded, size: 18),
                ),
                Expanded(
                  child: _DateRangeStep(
                    label: context.l10n.select(zh: '结束日期', en: 'End date'),
                    value: _date(end),
                    active: choosingEnd,
                  ),
                ),
              ],
            ),
            const Divider(height: 12),
            Expanded(
              child: CalendarDatePicker(
                key: ValueKey(choosingEnd),
                initialDate: choosingEnd ? start : DateUtils.dateOnly(start),
                firstDate: widget.firstDate,
                lastDate: widget.lastDate,
                onDateChanged: _choose,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DateRangeStep extends StatelessWidget {
  const _DateRangeStep({
    required this.label,
    required this.value,
    required this.active,
  });

  final String label;
  final String value;
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: active
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(
        color: active
            ? Theme.of(context).colorScheme.primary
            : Colors.transparent,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(value, style: Theme.of(context).textTheme.labelMedium),
      ],
    ),
  );
}
