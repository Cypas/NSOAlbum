import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../app_branding.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../state/library_controller.dart';
import '../../state/settings_controller.dart';
import 'android_action_bar.dart';
import 'android_layout.dart';
import 'android_media_card.dart';
import 'android_media_viewer.dart';
import 'android_fluid_scroll_physics.dart';
import 'android_metadata_editor.dart';
import 'android_page_frame.dart';
import 'android_video_merge_page.dart';
import 'android_text_prompt.dart';
import '../device_sync/album_source_label.dart';
import '../font_families.dart';
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
  final searchFocus = FocusNode();
  final scroll = ScrollController();
  final selected = <int>{};
  final selectedAssets = <int, MediaAsset>{};
  List<MediaAsset>? selectedSource;
  final Set<int> favoriteBusy = {};
  final Map<int, bool> favoriteOverrides = {};
  bool selecting = false;
  bool searchExpanded = false;
  bool busy = false;
  bool groupByImportedDate = false;
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

  void toggleSearch() {
    if (searchExpanded) {
      searchFocus.unfocus();
      setState(() => searchExpanded = false);
      return;
    }
    setState(() => searchExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !searchExpanded) return;
      if (mounted && searchExpanded) searchFocus.requestFocus();
    });
  }

  void enterSelection() {
    searchFocus.unfocus();
    setState(() {
      searchExpanded = false;
      selecting = true;
    });
  }

  @override
  void dispose() {
    search.dispose();
    searchFocus.dispose();
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

  MediaAsset _withFavoriteOverride(MediaAsset asset) {
    final favorite = favoriteOverrides[asset.id];
    if (favorite == null || favorite == asset.favorite) return asset;
    return MediaAsset(
      id: asset.id,
      sha256: asset.sha256,
      originalName: asset.originalName,
      storagePath: asset.storagePath,
      kind: asset.kind,
      capturedAt: asset.capturedAt,
      importedAt: asset.importedAt,
      gameTitleId: asset.gameTitleId,
      gameName: asset.gameName,
      favorite: favorite,
      note: asset.note,
      tags: asset.tags,
    );
  }

  Future<void> _toggleFavorite(MediaAsset asset) async {
    if (favoriteBusy.contains(asset.id)) return;
    final next = !asset.favorite;
    setState(() {
      favoriteBusy.add(asset.id);
      favoriteOverrides[asset.id] = next;
    });
    try {
      await backend.setFavorite(asset.id, next);
      if (!mounted) return;
      setState(() => favoriteBusy.remove(asset.id));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        favoriteBusy.remove(asset.id);
        favoriteOverrides.remove(asset.id);
      });
      androidMessage(context, error);
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
        final tags = (replace ? values : {...item.tags, ...values}).toList();
        await backend.replaceTags(item.id, tags);
        if (selected.contains(item.id)) {
          selectedAssets[item.id] = MediaAsset(
            id: item.id,
            sha256: item.sha256,
            originalName: item.originalName,
            storagePath: item.storagePath,
            kind: item.kind,
            capturedAt: item.capturedAt,
            importedAt: item.importedAt,
            gameTitleId: item.gameTitleId,
            gameName: item.gameName,
            favorite: item.favorite,
            note: item.note,
            tags: tags,
          );
        }
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
    var draftGroupByDate = groupByImportedDate;
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
              Card(
                key: const Key('android-filter-game-section'),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.sports_esports_outlined, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              context.l10n.select(
                                zh: '游戏标签筛选',
                                en: 'Game tag filters',
                              ),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          const Spacer(),
                          if (state.gameNames.isNotEmpty)
                            TextButton(
                              onPressed: () =>
                                  update(() => state.gameNames = []),
                              child: Text(
                                context.l10n.select(zh: '清除', en: 'Clear'),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
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
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                key: const Key('android-filter-date-section'),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.date_range_outlined, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              context.l10n.select(
                                zh: '日期筛选',
                                en: 'Date filters',
                              ),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const Key('android-filter-date-button'),
                        icon: const Icon(Icons.date_range),
                        label: Text(
                          context.l10n.select(
                            zh: _captureRangeLabel(state),
                            en: _captureRangeLabel(state, english: true),
                          ),
                        ),
                        onPressed: () async {
                          final selection = await _chooseCaptureRange(
                            context,
                            state,
                          );
                          if (selection == null) return;
                          update(() {
                            state.importedFrom = selection.range?.start;
                            state.importedUntil = selection.range == null
                                ? null
                                : DateTime(
                                    selection.range!.end.year,
                                    selection.range!.end.month,
                                    selection.range!.end.day + 1,
                                  );
                            state.capturedOnThisDay = selection.anniversary;
                          });
                        },
                      ),
                      SwitchListTile(
                        key: const Key('android-filter-group-by-date'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          context.l10n.select(zh: '按日期归类', en: 'Group by date'),
                        ),
                        value: draftGroupByDate,
                        onChanged: (value) =>
                            update(() => draftGroupByDate = value),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                key: const Key('android-filter-other-section'),
                child: Column(
                  children: [
                    SwitchListTile(
                      title: Text(
                        context.l10n.select(zh: '仅收藏', en: 'Favorites only'),
                      ),
                      value: state.favoriteOnly,
                      onChanged: (value) =>
                          update(() => state.favoriteOnly = value),
                    ),
                    SwitchListTile(
                      title: Text(
                        context.l10n.select(zh: '最新优先', en: 'Newest first'),
                      ),
                      value: state.newestFirst,
                      onChanged: (value) =>
                          update(() => state.newestFirst = value),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => update(() {
                  state.kind = GalleryKindFilter.all;
                  state.favoriteOnly = false;
                  state.gameNames = [];
                  state.importedFrom = null;
                  state.importedUntil = null;
                  state.capturedOnThisDay = null;
                  draftGroupByDate = false;
                }),
                child: Text(
                  context.l10n.select(zh: '清除筛选', en: 'Clear filters'),
                ),
              ),
              FilledButton(
                onPressed: () {
                  if (mounted) {
                    setState(() => groupByImportedDate = draftGroupByDate);
                  }
                  Navigator.pop(context);
                },
                child: Text(context.l10n.select(zh: '应用', en: 'Apply')),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) await state.reload();
  }

  Future<GalleryDateFilterSelection?> _chooseCaptureRange(
    BuildContext context,
    LibraryController state,
  ) async {
    return showDialog<GalleryDateFilterSelection>(
      context: context,
      builder: (context) => _AndroidDateFilterDialog(
        initialRange: state.importedFrom == null
            ? null
            : DateTimeRange(
                start: state.importedFrom!,
                end:
                    (state.importedUntil ??
                            state.importedFrom!.add(const Duration(days: 1)))
                        .subtract(const Duration(days: 1)),
              ),
      ),
    );
  }

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

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.controller, widget.settings]),
    builder: (context, _) {
      final state = widget.controller;
      final items = state.visible
          .map(_withFavoriteOverride)
          .where(
            (item) =>
                (!state.favoriteOnly &&
                    widget.album?.systemKey != 'favorites') ||
                item.favorite,
          )
          .toList(growable: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !state.loading) _loadWhenNearEnd();
      });
      // Search and paging replace state.items; retain metadata for selected
      // items outside the current result so bulk actions match the count.
      selectedAssets.removeWhere((id, _) => !selected.contains(id));
      final sourceChanged = !identical(selectedSource, state.items);
      for (final item in state.items) {
        if (selected.contains(item.id) &&
            (sourceChanged || !selectedAssets.containsKey(item.id))) {
          selectedAssets[item.id] = item;
        }
      }
      // Do not overwrite successful local edits with the same pre-edit list
      // when a later item in the batch fails before a backend refresh.
      selectedSource = state.items;
      final chosen = [
        for (final id in selected)
          if (selectedAssets[id] case final item?) _withFavoriteOverride(item),
      ];
      final searchMode = searchExpanded && !selecting;
      final secondary = selecting || searchExpanded || widget.onBack != null;
      final pageTitle = selecting
          ? context.l10n.select(
              zh: '已选择 ${selected.length} 项',
              en: '${selected.length} selected',
            )
          : widget.album?.name ??
                context.l10n.select(zh: appChineseName, en: appEnglishName);
      final searchHeight = math.max(
        48.0,
        MediaQuery.textScalerOf(context).scale(16) * 1.5 + 20,
      );
      final searchField = SizedBox(
        height: searchHeight,
        child: KeyedSubtree(
          key: const Key('android-library-search-input'),
          child: TextField(
            key: const Key('android-library-search'),
            controller: search,
            focusNode: searchFocus,
            style: Theme.of(context).textTheme.bodyLarge,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
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
      );
      final rootBrandTitle = !secondary && widget.album == null;
      return PopScope<Object?>(
        canPop:
            !selecting &&
            !searchExpanded &&
            !busy &&
            MediaQuery.viewInsetsOf(context).bottom == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (MediaQuery.viewInsetsOf(context).bottom > 0) {
            FocusManager.instance.primaryFocus?.unfocus();
            return;
          }
          if (searchExpanded && !selecting) {
            setState(() => searchExpanded = false);
            return;
          }
          if (!didPop && selecting && !busy) {
            setState(() {
              selecting = false;
              selected.clear();
              selectedAssets.clear();
            });
          }
        },
        child: AndroidPageFrame(
          title: pageTitle,
          secondary: secondary,
          toolbarTitle: searchMode
              ? searchField
              : rootBrandTitle
              ? Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pageTitle,
                        key: const Key('android-library-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: appBrandFontFamily,
                          fontFamilyFallback: appBrandFontFallback,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      DecoratedBox(
                        key: const Key('android-library-brand-underline'),
                        decoration: const BoxDecoration(
                          color: Color(0xffffc107),
                          borderRadius: BorderRadius.all(Radius.circular(2)),
                        ),
                        child: const SizedBox(width: 40, height: 3),
                      ),
                    ],
                  ),
                )
              : null,
          toolbarHeight: searchMode ? searchHeight : 48,
          scrollController: scroll,
          scrollToTopTooltip: context.l10n.select(
            zh: '回到顶部',
            en: 'Back to top',
          ),
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
                    selectedAssets.clear();
                    searchExpanded = false;
                  });
                }
              : searchExpanded
              ? () {
                  searchFocus.unfocus();
                  setState(() => searchExpanded = false);
                }
              : widget.onBack == null
              ? null
              : () => Navigator.of(context).maybePop(),
          actions: [
            if (!searchExpanded && !selecting)
              IconButton(
                key: const Key('android-library-search-toggle'),
                tooltip: context.l10n.select(zh: '搜索', en: 'Search'),
                isSelected: state.search.trim().isNotEmpty,
                color: state.search.trim().isNotEmpty
                    ? Theme.of(context).colorScheme.primary
                    : null,
                onPressed: toggleSearch,
                icon: const Icon(Icons.search),
              ),
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
                onPressed: enterSelection,
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
              final rows = _galleryRows(
                items,
                columns: columns,
                grouped: groupByImportedDate,
                english: context.l10n.locale.languageCode == 'en',
              );
              return CustomScrollView(
                controller: scroll,
                physics: const AndroidFluidScrollPhysics(),
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
                      itemCount: rows.length,
                      itemBuilder: (context, row) {
                        final galleryRow = rows[row];
                        if (galleryRow.header != null) {
                          return Padding(
                            padding: EdgeInsets.only(
                              top: row == 0 ? 0 : spacing,
                              bottom: spacing / 2,
                            ),
                            child: Text(
                              galleryRow.header!,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          );
                        }
                        return Padding(
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
                                  child: column >= galleryRow.items.length
                                      ? const SizedBox.shrink()
                                      : Builder(
                                          builder: (context) {
                                            final indexed =
                                                galleryRow.items[column];
                                            final item = indexed.$1;
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
                                                        ? selected.remove(
                                                            item.id,
                                                          )
                                                        : selected.add(item.id);
                                                  });
                                                  return;
                                                }
                                                await Navigator.of(
                                                  context,
                                                ).push(
                                                  _androidMediaViewerRoute(
                                                    (_) => AndroidMediaViewer(
                                                      backend: backend,
                                                      settings:
                                                          widget.settings.value,
                                                      items: items,
                                                      initialIndex: indexed.$2,
                                                      galleryQuery:
                                                          state.galleryQuery,
                                                      initialPage:
                                                          state.pages.snapshot,
                                                      mediaFilter:
                                                          state.pages.accept,
                                                    ),
                                                  ),
                                                );
                                                if (mounted) {
                                                  await state.reload();
                                                }
                                              },
                                              onMenu: () => menu(item),
                                              onFavorite: () =>
                                                  _toggleFavorite(item),
                                            );
                                          },
                                        ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
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

class GalleryDateFilterSelection {
  const GalleryDateFilterSelection.range(this.range) : anniversary = null;
  const GalleryDateFilterSelection.anniversary(this.anniversary) : range = null;

  final DateTimeRange? range;
  final CapturedOnThisDay? anniversary;
}

class _AndroidGalleryRow {
  const _AndroidGalleryRow({this.header, this.items = const []});

  final String? header;
  final List<(MediaAsset, int)> items;
}

List<_AndroidGalleryRow> _galleryRows(
  List<MediaAsset> items, {
  required int columns,
  required bool grouped,
  required bool english,
}) {
  if (!grouped) {
    return [
      for (var offset = 0; offset < items.length; offset += columns)
        _AndroidGalleryRow(
          items: [
            for (
              var index = offset;
              index < math.min(offset + columns, items.length);
              index++
            )
              (items[index], index),
          ],
        ),
    ];
  }
  final rows = <_AndroidGalleryRow>[];
  final today = DateUtils.dateOnly(DateTime.now());
  final yesterday = today.subtract(const Duration(days: 1));
  String? previousKey;
  for (var offset = 0; offset < items.length;) {
    final first = items[offset];
    final date = first.importedAt?.toLocal();
    final key = date == null
        ? 'unknown'
        : '${date.year}-${date.month}-${date.day}';
    if (key != previousKey) {
      final label = date == null
          ? (english ? 'Unknown date' : '日期未知')
          : DateUtils.dateOnly(date) == today
          ? (english ? 'Today' : '今天')
          : DateUtils.dateOnly(date) == yesterday
          ? (english ? 'Yesterday' : '昨天')
          : english
          ? '${date.month}/${date.day}/${date.year}'
          : '${date.month}月${date.day}日';
      rows.add(_AndroidGalleryRow(header: label));
      previousKey = key;
    }
    final groupItems = <(MediaAsset, int)>[];
    while (offset < items.length) {
      final item = items[offset];
      final itemDate = item.importedAt?.toLocal();
      final itemKey = itemDate == null
          ? 'unknown'
          : '${itemDate.year}-${itemDate.month}-${itemDate.day}';
      if (itemKey != key) break;
      groupItems.add((item, offset));
      offset++;
      if (groupItems.length == columns) {
        rows.add(_AndroidGalleryRow(items: List.of(groupItems)));
        groupItems.clear();
      }
    }
    if (groupItems.isNotEmpty) {
      rows.add(_AndroidGalleryRow(items: List.of(groupItems)));
    }
  }
  return rows;
}

class _AndroidDateFilterDialog extends StatefulWidget {
  const _AndroidDateFilterDialog({this.initialRange});

  final DateTimeRange? initialRange;

  @override
  State<_AndroidDateFilterDialog> createState() =>
      _AndroidDateFilterDialogState();
}

class _AndroidDateFilterDialogState extends State<_AndroidDateFilterDialog> {
  late DateTime? start = widget.initialRange?.start;
  late DateTime? end = widget.initialRange?.end;
  bool choosingEnd = false;

  void _chooseDate(DateTime value) {
    final selected = DateUtils.dateOnly(value);
    if (!choosingEnd) {
      setState(() {
        start = selected;
        end = null;
        choosingEnd = true;
      });
      return;
    }
    final anchor = start ?? selected;
    final first = selected.isBefore(anchor) ? selected : anchor;
    final last = selected.isBefore(anchor) ? anchor : selected;
    Navigator.of(context).pop(
      GalleryDateFilterSelection.range(DateTimeRange(start: first, end: last)),
    );
  }

  @override
  Widget build(BuildContext context) => Dialog(
    key: const Key('android-date-filter-dialog'),
    insetPadding: const EdgeInsets.all(24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420, maxHeight: 540),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(
                context.l10n.select(zh: '选择日期范围', en: 'Select date range'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  context.l10n.select(zh: '快捷日期', en: 'Quick ranges'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in _androidQuickRanges(context).entries)
                    OutlinedButton(
                      key: Key('android-filter-${entry.key}'),
                      onPressed: () => Navigator.pop(
                        context,
                        GalleryDateFilterSelection.range(entry.value.$1),
                      ),
                      child: Text(entry.value.$2),
                    ),
                  OutlinedButton(
                    key: const Key('android-filter-anniversary'),
                    onPressed: () {
                      final now = DateTime.now();
                      Navigator.pop(
                        context,
                        GalleryDateFilterSelection.anniversary(
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
              Text(
                choosingEnd
                    ? context.l10n.select(
                        zh: '请选择结束日期',
                        en: 'Choose an end date',
                      )
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
                      value: _formatDialogDate(start),
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
                      value: _formatDialogDate(end),
                      active: choosingEnd,
                    ),
                  ),
                ],
              ),
              const Divider(height: 12),
              SizedBox(
                height: 300,
                child: CalendarDatePicker(
                  key: ValueKey(choosingEnd),
                  initialDate: choosingEnd
                      ? start ?? DateUtils.dateOnly(DateTime.now())
                      : start ?? DateUtils.dateOnly(DateTime.now()),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(DateTime.now().year + 1, 12, 31),
                  onDateChanged: _chooseDate,
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
    ),
  );
}

String _formatDialogDate(DateTime? value) {
  if (value == null) return '—';
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

Map<String, (DateTimeRange, String)> _androidQuickRanges(BuildContext context) {
  final today = DateUtils.dateOnly(DateTime.now());
  final tomorrow = today.add(const Duration(days: 1));
  final monday = today.subtract(Duration(days: today.weekday - 1));
  final nextMonday = monday.add(const Duration(days: 7));
  final previousMonday = monday.subtract(const Duration(days: 7));
  final monthStart = DateTime(today.year, today.month);
  final nextMonth = DateTime(today.year, today.month + 1);
  DateTimeRange inclusive(DateTime start, DateTime exclusive) => DateTimeRange(
    start: start,
    end: exclusive.subtract(const Duration(days: 1)),
  );
  return {
    'today': (
      inclusive(today, tomorrow),
      context.l10n.select(zh: '本日', en: 'Today'),
    ),
    'this-week': (
      inclusive(monday, nextMonday),
      context.l10n.select(zh: '本周', en: 'This week'),
    ),
    'this-month': (
      inclusive(monthStart, nextMonth),
      context.l10n.select(zh: '本月', en: 'This month'),
    ),
    'last-week': (
      inclusive(previousMonday, monday),
      context.l10n.select(zh: '上周', en: 'Last week'),
    ),
  };
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
