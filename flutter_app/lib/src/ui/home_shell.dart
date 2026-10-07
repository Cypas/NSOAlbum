import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_version.dart';
import '../backend/app_backend.dart';
import '../l10n/app_localizations.dart';
import '../platform/windows_mtp_import.dart';
import '../release_update.dart';
import '../rust/models.dart';
import '../rust/settings.dart';
import '../search/search_normalizer.dart';
import '../state/settings_controller.dart';
import '../state/sync_controller.dart';
import '../startup/startup_diagnostics.dart';
import 'media_metadata_editor.dart';
import 'media_viewer.dart';
import 'app_image_viewer.dart';
import 'video_merge_page.dart';
import 'video_thumbnail.dart';
import 'active_page_host.dart';

Future<void> showLatestReleaseUpdate(
  BuildContext context, {
  required bool automatic,
  required Future<void> Function(File installer) onInstall,
  required Future<void> Function(Object error, StackTrace stackTrace) onError,
}) async {
  final service = ReleaseUpdateService();
  try {
    if (automatic && !await service.isAutomaticCheckDue()) return;
    final currentVersion = await loadApplicationVersion();
    final release = await service.checkForUpdate(currentVersion);
    if (automatic) await service.recordAutomaticCheck();
    if (!context.mounted) return;
    if (release == null) {
      if (!automatic) {
        ScaffoldMessenger.of(context).showSnackBar(
          _messageSnackBar(
            context.l10n.select(
              zh: '当前已是最新版本。',
              en: 'You are using the latest version.',
            ),
          ),
        );
      }
      return;
    }

    final download = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.select(zh: '发现新版本', en: 'Update available')),
        content: Text(
          context.l10n.select(
            zh: '发现 Fresh Album ${release.version}。需要下载经过 SHA-256 校验的安装包吗？安装前还会再次确认。',
            en: 'Fresh Album ${release.version} is available. Download the installer and verify its SHA-256? You will confirm again before installation.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.select(zh: '稍后', en: 'Later')),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.download_rounded),
            label: Text(context.l10n.select(zh: '下载更新', en: 'Download')),
          ),
        ],
      ),
    );
    if (download != true || !context.mounted) return;

    final installer = await showDialog<File>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) =>
          _InstallerDownloadDialog(service: service, release: release),
    );
    if (installer == null || !context.mounted) return;
    final install = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.select(zh: '安装更新', en: 'Install update')),
        content: Text(
          context.l10n.select(
            zh: '安装包已通过 SHA-256 校验。现在退出鱿型相册并启动安装程序吗？',
            en: 'The installer passed SHA-256 verification. Exit Fresh Album and launch the installer now?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              context.l10n.select(zh: '安装并退出', en: 'Install and exit'),
            ),
          ),
        ],
      ),
    );
    if (install == true) await onInstall(installer);
  } catch (error, stackTrace) {
    await onError(error, stackTrace);
    if (!automatic && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '检查或下载更新失败：$error',
            en: 'Update check or download failed: $error',
          ),
          error: true,
        ),
      );
    }
  } finally {
    await service.close();
  }
}

class _InstallerDownloadDialog extends StatefulWidget {
  const _InstallerDownloadDialog({
    required this.service,
    required this.release,
  });

  final ReleaseUpdateService service;
  final StableRelease release;

  @override
  State<_InstallerDownloadDialog> createState() =>
      _InstallerDownloadDialogState();
}

class _InstallerDownloadDialogState extends State<_InstallerDownloadDialog> {
  final cancellation = UpdateCancellation();
  int received = 0;
  int? total;
  Object? error;
  bool downloading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_download());
  }

  Future<void> _download() async {
    setState(() {
      downloading = true;
      error = null;
      received = 0;
      total = null;
    });
    try {
      final file = await widget.service.downloadInstaller(
        widget.release,
        cancellation: cancellation,
        onProgress: (nextReceived, nextTotal) {
          if (!mounted) return;
          setState(() {
            received = nextReceived;
            total = nextTotal;
          });
        },
      );
      if (mounted) Navigator.pop(context, file);
    } on UpdateCancelled {
      if (mounted) Navigator.pop(context);
    } catch (exception) {
      if (mounted) {
        setState(() {
          downloading = false;
          error = exception;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.select(zh: '正在下载更新', en: 'Downloading update')),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: total == null || total == 0
                ? null
                : (received / total!).clamp(0, 1),
          ),
          const SizedBox(height: 12),
          Text(
            error?.toString() ??
                (total == null
                    ? context.l10n.select(
                        zh: '正在连接下载源…',
                        en: 'Connecting to download sources…',
                      )
                    : '${(received / (1024 * 1024)).toStringAsFixed(1)} / '
                          '${(total! / (1024 * 1024)).toStringAsFixed(1)} MB'),
          ),
        ],
      ),
    ),
    actions: [
      if (error != null)
        TextButton(
          onPressed: _download,
          child: Text(context.l10n.select(zh: '重试', en: 'Retry')),
        ),
      TextButton(
        onPressed: () {
          cancellation.cancel();
          if (!downloading) Navigator.pop(context);
        },
        child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
      ),
    ],
  );
}

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.backend,
    required this.settings,
    this.syncController,
    this.onNintendoAccountChanged,
    this.enableVideoFeatures = true,
    this.enableMtpDetection = true,
    this.startupDiagnostics,
    this.onCheckForUpdates,
    this.onInstallUpdate,
  });

  final AppBackend backend;
  final SettingsController settings;
  final SyncController? syncController;
  final Future<void> Function()? onNintendoAccountChanged;
  final bool enableVideoFeatures;
  final bool enableMtpDetection;
  final StartupDiagnostics? startupDiagnostics;
  final Future<void> Function()? onCheckForUpdates;
  final Future<void> Function(File installer)? onInstallUpdate;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;
  bool railExtended = false;
  int albumPageRevision = 0;
  AlbumSummary? openedAlbum;
  final libraryKey = GlobalKey<_LibraryPageState>();
  late final SyncController sync;
  late final bool ownsSyncController;
  SyncState? _lastSyncState;
  String? _syncFailureMessage;

  @override
  void initState() {
    super.initState();
    ownsSyncController = widget.syncController == null;
    sync = widget.syncController ?? SyncController(widget.backend);
    _lastSyncState = sync.state;
    sync.addListener(_handleSyncStateChanged);
  }

  void _handleSyncStateChanged() {
    final next = sync.state;
    if (next == SyncState.running && mounted) {
      setState(() => _syncFailureMessage = null);
    }
    if (next == SyncState.completed && _lastSyncState != SyncState.completed) {
      unawaited(libraryKey.currentState?._reloadAndPreload());
      if (mounted) setState(() => albumPageRevision += 1);
    }
    if (next == SyncState.failed && _lastSyncState != SyncState.failed) {
      final failure = sync.error;
      if (failure != null && mounted) {
        setState(
          () => _syncFailureMessage = context.l10n.select(
            zh: 'Nintendo 同步失败：$failure',
            en: 'Nintendo synchronization failed: $failure',
          ),
        );
      }
    }
    _lastSyncState = next;
  }

  List<NavigationDestination> _destinations(BuildContext context) => [
    NavigationDestination(
      icon: const Icon(Icons.photo_library_outlined),
      selectedIcon: const Icon(Icons.photo_library_rounded),
      label: context.l10n.select(zh: '图库', en: 'Library'),
    ),
    NavigationDestination(
      icon: const Icon(Icons.photo_album_outlined),
      selectedIcon: const Icon(Icons.photo_album_rounded),
      label: context.l10n.select(zh: '相册', en: 'Albums'),
    ),
    NavigationDestination(
      icon: const Icon(Icons.cloud_sync_outlined),
      selectedIcon: const Icon(Icons.cloud_sync_rounded),
      label: context.l10n.select(zh: '导入与同步', en: 'Sync & Import'),
    ),
    NavigationDestination(
      icon: const Icon(Icons.settings_outlined),
      selectedIcon: const Icon(Icons.settings_rounded),
      label: context.l10n.select(zh: '设置', en: 'Settings'),
    ),
  ];

  @override
  void dispose() {
    sync.removeListener(_handleSyncStateChanged);
    if (ownsSyncController) sync.dispose();
    super.dispose();
  }

  void _selectDestination(int value) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      index = value;
      if (value == 1) {
        openedAlbum = null;
        albumPageRevision += 1;
      }
    });
  }

  void _openAlbum(AlbumSummary album) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      index = 1;
      openedAlbum = album;
    });
  }

  void _handleTagsChanged() {
    libraryKey.currentState?._reload();
    setState(() => albumPageRevision += 1);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final destinations = _destinations(context);
    final album = openedAlbum;
    final pages = [
      LibraryPage(
        key: libraryKey,
        backend: widget.backend,
        settings: widget.settings,
        enableVideoFeatures: widget.enableVideoFeatures,
        startupDiagnostics: widget.startupDiagnostics,
        onOpenTransfer: () => _selectDestination(2),
      ),
      if (album == null)
        AlbumsPage(
          key: ValueKey('albums-$albumPageRevision'),
          backend: widget.backend,
          onOpenAlbum: _openAlbum,
          enableVideoFeatures: widget.enableVideoFeatures,
        )
      else
        LibraryPage(
          key: ValueKey('album-library-${album.id}'),
          backend: widget.backend,
          settings: widget.settings,
          albumId: album.id,
          albumName: _albumDisplayName(context, album),
          albumDescription: album.description,
          albumType: album.albumType,
          albumSystemKey: album.systemKey,
          showTransferAction: false,
          onOpenTransfer: () {},
          enableVideoFeatures: widget.enableVideoFeatures,
          startupDiagnostics: widget.startupDiagnostics,
          onBack: () {
            FocusManager.instance.primaryFocus?.unfocus();
            setState(() => openedAlbum = null);
          },
        ),
      TransferPage(
        backend: widget.backend,
        sync: sync,
        settings: widget.settings,
        enableVideoFeatures: widget.enableVideoFeatures,
        enableMtpDetection: widget.enableMtpDetection,
        onImportComplete: () => libraryKey.currentState?._reload(),
        onNintendoAccountChanged: widget.onNintendoAccountChanged,
      ),
      SettingsPage(
        controller: widget.settings,
        backend: widget.backend,
        onTagsChanged: _handleTagsChanged,
        onCheckForUpdates: widget.onCheckForUpdates,
      ),
    ];
    final content = ActivePageHost(index: index, children: pages);
    final contentBody = wide
        ? Row(
            children: [
              TweenAnimationBuilder<double>(
                key: const Key('desktop-sidebar'),
                tween: Tween(end: railExtended ? 1 : 0),
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeInOutCubicEmphasized,
                builder: (context, expansion, _) => SizedBox(
                  width: 72 + 148 * expansion,
                  child: _DesktopSidebar(
                    destinations: destinations,
                    selectedIndex: index,
                    expansion: expansion,
                    expanded: railExtended,
                    onDestinationSelected: _selectDestination,
                    onToggle: () =>
                        setState(() => railExtended = !railExtended),
                  ),
                ),
              ),
              Expanded(child: content),
            ],
          )
        : content;

    return Scaffold(
      body: Column(
        children: [
          if (_syncFailureMessage != null)
            MaterialBanner(
              content: Text(_syncFailureMessage!),
              leading: const Icon(Icons.error_outline_rounded),
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              contentTextStyle: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _syncFailureMessage = null),
                  child: Text(context.l10n.select(zh: '关闭', en: 'Dismiss')),
                ),
              ],
            ),
          Expanded(child: contentBody),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: _selectDestination,
              destinations: destinations,
            ),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  static const iconSlotWidth = 50.0;

  const _DesktopSidebar({
    required this.destinations,
    required this.selectedIndex,
    required this.expansion,
    required this.expanded,
    required this.onDestinationSelected,
    required this.onToggle,
  });

  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final double expansion;
  final bool expanded;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          right: BorderSide(color: scheme.outlineVariant.withValues(alpha: .7)),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
          child: Column(
            children: [
              const SizedBox(height: 4),
              ...List.generate(destinations.length, (index) {
                final destination = destinations[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _SidebarDestination(
                    key: ValueKey('sidebar-destination-$index'),
                    icon: index == selectedIndex
                        ? (destination.selectedIcon ?? destination.icon)
                        : destination.icon,
                    label: destination.label,
                    selected: index == selectedIndex,
                    expansion: expansion,
                    onTap: () => onDestinationSelected(index),
                  ),
                );
              }),
              const Spacer(),
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: iconSlotWidth,
                  child: IconButton(
                    tooltip: expanded
                        ? context.l10n.select(
                            zh: '收起侧边栏',
                            en: 'Collapse sidebar',
                          )
                        : context.l10n.select(
                            zh: '展开侧边栏',
                            en: 'Expand sidebar',
                          ),
                    onPressed: onToggle,
                    style: IconButton.styleFrom(
                      foregroundColor: scheme.onSurfaceVariant,
                      hoverColor: scheme.primaryContainer,
                    ),
                    icon: AnimatedRotation(
                      turns: expanded ? .5 : 0,
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeInOutCubicEmphasized,
                      child: const Icon(
                        Icons.keyboard_double_arrow_right_rounded,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarDestination extends StatelessWidget {
  const _SidebarDestination({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.expansion,
    required this.onTap,
  });

  final Widget icon;
  final String label;
  final bool selected;
  final double expansion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;
    return Tooltip(
      message: expansion < .4 ? label : '',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: .18)
                : Colors.transparent,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(15),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            hoverColor: scheme.primaryContainer.withValues(alpha: .55),
            child: SizedBox(
              height: 50,
              child: Row(
                children: [
                  SizedBox(
                    width: _DesktopSidebar.iconSlotWidth,
                    child: IconTheme(
                      data: IconThemeData(color: foreground),
                      child: icon,
                    ),
                  ),
                  _SidebarAnimatedText(
                    key: ValueKey('sidebar-label-$label'),
                    text: label,
                    expansion: expansion,
                    color: foreground,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarAnimatedText extends StatelessWidget {
  const _SidebarAnimatedText({
    super.key,
    required this.text,
    required this.expansion,
    required this.color,
  });

  final String text;
  final double expansion;
  final Color color;
  @override
  Widget build(BuildContext context) => ClipRect(
    child: SizedBox(
      width: 110 * expansion,
      child: Opacity(
        opacity: Curves.easeIn.transform(expansion),
        child: Transform.translate(
          offset: Offset(-8 * (1 - expansion), 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
              style: TextStyle(
                fontFamily: 'SmileySans',
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({
    required this.title,
    this.subtitle,
    required this.child,
    this.leading,
    this.action,
    this.fixedHeader = false,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? leading;
  final Widget? action;
  final bool fixedHeader;

  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 6, 24, 4),
    child: Row(
      key: const Key('page-header'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (leading != null) ...[
          Padding(padding: const EdgeInsets.only(right: 10), child: leading),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                title,
                key: const Key('page-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (action != null)
          ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: 120,
              maxWidth: 620,
              minHeight: 40,
              maxHeight: 40,
            ),
            child: ClipRect(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Align(alignment: Alignment.centerRight, child: action),
              ),
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final content = CustomScrollView(
      slivers: [
        SliverPersistentHeader(
          pinned: fixedHeader,
          delegate: _PageHeaderDelegate(child: _header(context), extent: 72),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          sliver: SliverToBoxAdapter(child: child),
        ),
      ],
    );
    return SafeArea(child: content);
  }
}

class _PageHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _PageHeaderDelegate({required this.child, required this.extent});

  final Widget child;
  final double extent;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Material(
    color: Theme.of(context).colorScheme.surface,
    elevation: overlapsContent ? 2 : 0,
    child: SizedBox(height: extent, child: child),
  );

  @override
  bool shouldRebuild(covariant _PageHeaderDelegate oldDelegate) =>
      oldDelegate.extent != extent || oldDelegate.child != child;
}

enum _BatchMediaAction {
  copyToAlbum,
  moveToAlbum,
  favorite,
  addTags,
  replaceTags,
  export,
  mergeVideos,
  delete,
}

enum _SingleMediaAction { copyToAlbum, moveToAlbum, delete }

class _MediaExportOptions {
  const _MediaExportOptions({
    required this.directory,
    required this.nameFormat,
  });

  final String directory;
  final String nameFormat;
}

class _MediaExportDialog extends StatefulWidget {
  const _MediaExportDialog();

  @override
  State<_MediaExportDialog> createState() => _MediaExportDialogState();
}

class _MediaExportDialogState extends State<_MediaExportDialog> {
  final TextEditingController directoryController = TextEditingController();
  final TextEditingController nameFormat = TextEditingController(
    text: '{相册内名称}',
  );
  static const placeholders = ['{相册内名称}', '{游戏名}', '{年月日}', '{标签}', '{备注}'];

  @override
  void dispose() {
    directoryController.dispose();
    nameFormat.dispose();
    super.dispose();
  }

  void _insertPlaceholder(String placeholder) {
    final value = nameFormat.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start.clamp(0, value.text.length);
    final end = selection.end.clamp(0, value.text.length);
    final next = value.text.replaceRange(start, end, placeholder);
    nameFormat.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + placeholder.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.select(zh: '导出所选媒体', en: 'Export selected media')),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('media-export-directory'),
              controller: directoryController,
              decoration: InputDecoration(
                labelText: context.l10n.select(
                  zh: '导出路径',
                  en: 'Export directory',
                ),
                hintText: context.l10n.select(
                  zh: '请选择导出目录',
                  en: 'Choose an export directory',
                ),
                suffixIcon: IconButton(
                  key: const Key('choose-media-export-directory'),
                  tooltip: context.l10n.select(
                    zh: '选择目录',
                    en: 'Choose directory',
                  ),
                  onPressed: () async {
                    final selected = await FilePicker.getDirectoryPath(
                      dialogTitle: context.l10n.select(
                        zh: '选择媒体导出目录',
                        en: 'Choose media export directory',
                      ),
                    );
                    if (selected != null && mounted) {
                      setState(() => directoryController.text = selected);
                    }
                  },
                  icon: const Icon(Icons.folder_open_rounded),
                ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 18),
            TextField(
              key: const Key('media-export-name-format'),
              controller: nameFormat,
              decoration: InputDecoration(
                labelText: context.l10n.select(
                  zh: '导出名称格式',
                  en: 'Export name format',
                ),
                helperText: context.l10n.select(
                  zh: '扩展名会自动保留；重名文件会自动追加序号。',
                  en: 'The extension is preserved; duplicate names receive a number.',
                ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.select(zh: '点击插入参数', en: 'Insert a parameter'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: placeholders
                  .map(
                    (placeholder) => ActionChip(
                      key: ValueKey('export-placeholder-$placeholder'),
                      label: Text(placeholder),
                      onPressed: () => _insertPlaceholder(placeholder),
                    ),
                  )
                  .toList(growable: false),
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.select(
                zh: '多个标签会使用“-”连接。',
                en: 'Multiple tags are joined with “-”.',
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
      ),
      FilledButton.icon(
        key: const Key('confirm-media-export'),
        onPressed:
            directoryController.text.trim().isEmpty ||
                nameFormat.text.trim().isEmpty
            ? null
            : () => Navigator.pop(
                context,
                _MediaExportOptions(
                  directory: directoryController.text.trim(),
                  nameFormat: nameFormat.text.trim(),
                ),
              ),
        icon: const Icon(Icons.save_alt_rounded),
        label: Text(context.l10n.select(zh: '开始导出', en: 'Export')),
      ),
    ],
  );
}

class _BatchActionLabel extends StatelessWidget {
  const _BatchActionLabel({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 10),
      Text(text, style: TextStyle(color: color)),
    ],
  );
}

class _GameTagFilters extends StatefulWidget {
  const _GameTagFilters({
    required this.games,
    required this.selected,
    required this.onChanged,
    required this.onClear,
  });

  final List<GameTagSummary> games;
  final Set<String> selected;
  final void Function(String game, bool selected) onChanged;
  final VoidCallback onClear;

  @override
  State<_GameTagFilters> createState() => _GameTagFiltersState();
}

class _GameTagFiltersState extends State<_GameTagFilters> {
  static const collapsedLimit = 6;
  bool expanded = false;

  List<GameTagSummary> get visibleGames {
    if (expanded || widget.games.length <= collapsedLimit) return widget.games;
    final visible = widget.games.take(collapsedLimit).toList();
    for (final game in widget.games) {
      if (widget.selected.contains(game.name) &&
          !visible.any((item) => item.name == game.name)) {
        visible.add(game);
      }
    }
    return visible;
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sports_esports_rounded, size: 19),
              const SizedBox(width: 8),
              Text(
                context.l10n.select(
                  zh: '游戏标签（可多选）',
                  en: 'Game tags (multi-select)',
                ),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (widget.selected.isNotEmpty)
                TextButton(
                  onPressed: widget.onClear,
                  child: Text(context.l10n.select(zh: '清除', en: 'Clear')),
                ),
            ],
          ),
          const SizedBox(height: 8),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: visibleGames.map((game) {
                final total = game.imageCount + game.videoCount;
                return Tooltip(
                  message: expanded
                      ? context.l10n.select(
                          zh: '${game.imageCount} 张图片 · ${game.videoCount} 个视频',
                          en: '${game.imageCount} photos · ${game.videoCount} videos',
                        )
                      : '',
                  child: FilterChip(
                    key: ValueKey('game-filter-${game.name}'),
                    labelStyle: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'SmileySans',
                    ),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(game.name),
                        if (expanded) ...[
                          const SizedBox(width: 6),
                          Text(
                            context.l10n.select(
                              zh: '共 $total 项',
                              en: '$total total',
                            ),
                            key: ValueKey('game-filter-count-${game.name}'),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ],
                    ),
                    selected: widget.selected.contains(game.name),
                    onSelected: (enabled) =>
                        widget.onChanged(game.name, enabled),
                  ),
                );
              }).toList(),
            ),
          ),
          if (widget.games.length > collapsedLimit) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              key: const Key('toggle-all-game-tags'),
              onPressed: () => setState(() => expanded = !expanded),
              icon: AnimatedRotation(
                turns: expanded ? .5 : 0,
                duration: const Duration(milliseconds: 220),
                child: const Icon(Icons.expand_more_rounded),
              ),
              label: Text(
                expanded
                    ? context.l10n.select(zh: '收起', en: 'Show less')
                    : context.l10n.select(
                        zh: '展开全部（${widget.games.length}）',
                        en: 'Show all (${widget.games.length})',
                      ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

String _shortDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

class _CreationDateRangeDialog extends StatefulWidget {
  const _CreationDateRangeDialog({
    required this.firstDate,
    required this.lastDate,
    this.initialRange,
  });

  final DateTime firstDate;
  final DateTime lastDate;
  final DateTimeRange? initialRange;

  @override
  State<_CreationDateRangeDialog> createState() =>
      _CreationDateRangeDialogState();
}

class _CreationDateRangeDialogState extends State<_CreationDateRangeDialog> {
  DateTime? start;
  DateTime? end;
  bool selectingEnd = false;

  @override
  void initState() {
    super.initState();
    start = widget.initialRange?.start;
    end = widget.initialRange?.end;
  }

  @override
  Widget build(BuildContext context) {
    final availableHeight = MediaQuery.sizeOf(context).height - 48;
    final dialogHeight = availableHeight.clamp(360.0, 560.0).toDouble();
    final initialDate = _boundedDate(start ?? DateTime.now());
    return Dialog(
      key: const Key('creation-date-range-dialog'),
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 420,
        height: dialogHeight,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 10, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.select(
                            zh: '选择创建时间',
                            en: 'Select creation dates',
                          ),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          selectingEnd
                              ? context.l10n.select(
                                  zh: '请选择结束日期，选定后将自动筛选',
                                  en: 'Choose an end date to apply the filter',
                                )
                              : context.l10n.select(
                                  zh: '请先选择开始日期',
                                  en: 'Choose a start date first',
                                ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.select(zh: '取消', en: 'Cancel'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: _dateStep(
                      context,
                      key: const Key('creation-date-start'),
                      label: context.l10n.select(zh: '开始日期', en: 'Start date'),
                      value: start,
                      active: !selectingEnd,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Icon(Icons.arrow_forward_rounded, size: 18),
                  ),
                  Expanded(
                    child: _dateStep(
                      context,
                      key: const Key('creation-date-end'),
                      label: context.l10n.select(zh: '结束日期', en: 'End date'),
                      value: end,
                      active: selectingEnd,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: CalendarDatePicker(
                key: ValueKey(
                  selectingEnd
                      ? 'creation-date-calendar-end'
                      : 'creation-date-calendar-start',
                ),
                initialDate: initialDate,
                firstDate: widget.firstDate,
                lastDate: widget.lastDate,
                onDateChanged: _selectDate,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateStep(
    BuildContext context, {
    required Key key,
    required String label,
    required DateTime? value,
    required bool active,
  }) => Container(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
        const SizedBox(height: 2),
        Text(
          value == null ? '—' : _shortDate(value),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );

  void _selectDate(DateTime value) {
    final selected = DateUtils.dateOnly(value);
    if (!selectingEnd) {
      setState(() {
        start = selected;
        end = null;
        selectingEnd = true;
      });
      return;
    }
    final selectedStart = start ?? selected;
    Navigator.pop(
      context,
      selected.isBefore(selectedStart)
          ? DateTimeRange(start: selected, end: selectedStart)
          : DateTimeRange(start: selectedStart, end: selected),
    );
  }

  DateTime _boundedDate(DateTime value) {
    if (value.isBefore(widget.firstDate)) return widget.firstDate;
    if (value.isAfter(widget.lastDate)) return widget.lastDate;
    return value;
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.backend,
    required this.settings,
    required this.onOpenTransfer,
    this.albumId,
    this.albumName,
    this.albumDescription,
    this.albumType,
    this.albumSystemKey,
    this.showTransferAction = true,
    this.onBack,
    this.enableVideoFeatures = true,
    this.startupDiagnostics,
  });

  final AppBackend backend;
  final SettingsController settings;
  final VoidCallback onOpenTransfer;
  final int? albumId;
  final String? albumName;
  final String? albumDescription;
  final String? albumType;
  final String? albumSystemKey;
  final bool showTransferAction;
  final VoidCallback? onBack;
  final bool enableVideoFeatures;
  final StartupDiagnostics? startupDiagnostics;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  GalleryKindFilter kind = GalleryKindFilter.all;
  bool favoritesOnly = false;
  bool newestFirst = true;
  bool selecting = false;
  final Set<int> selectedMediaIds = {};
  final Set<int> favoriteBusy = {};
  final Map<int, bool> favoriteOverrides = {};
  final Set<String> _preloadedImagePaths = {};
  final TextEditingController searchController = TextEditingController();
  Timer? searchDebounce;
  String search = '';
  DateTimeRange? capturedRange;
  final Set<String> selectedGameTags = {};
  List<MediaAsset> latestMedia = const [];
  List<MediaAsset>? cachedMedia;
  int loadGeneration = 0;
  bool batchBusy = false;
  bool startupGalleryQueryLogged = false;
  List<int> visibleMediaIds = const [];
  bool _selectionPointerActive = false;
  bool _suppressNextSelectionTap = false;
  int? _selectionAnchorId;
  bool _selectionTargetValue = false;
  final Set<int> _selectionDragVisited = {};
  Timer? _selectionAutoScrollTimer;
  double _selectionAutoScrollVelocity = 0;
  late Future<List<MediaAsset>> media = _load();
  late Future<List<GameTagSummary>> gameTags = _loadGameTags();

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_handleSettingsChanged);
    searchController.addListener(_onSearchControllerChanged);
  }

  void _handleSettingsChanged() {
    if (mounted) setState(() {});
  }

  Future<List<GameTagSummary>> _loadGameTags() async {
    if (widget.albumId == null) return widget.backend.listGameTags();
    final results = await Future.wait([
      widget.backend.listGameTags(),
      widget.backend.listMedia(albumId: widget.albumId, limit: 100000),
    ]);
    final global = results[0] as List<GameTagSummary>;
    final albumMedia = results[1] as List<MediaAsset>;
    final counts = <String, (int, int)>{};
    for (final item in albumMedia) {
      final current = counts[item.gameName] ?? (0, 0);
      counts[item.gameName] = item.kind == MediaKind.image
          ? (current.$1 + 1, current.$2)
          : (current.$1, current.$2 + 1);
    }
    final usage = {for (final item in global) item.name: item.selectionCount};
    final values = counts.entries
        .map(
          (entry) => GameTagSummary(
            name: entry.key,
            imageCount: BigInt.from(entry.value.$1),
            videoCount: BigInt.from(entry.value.$2),
            selectionCount: usage[entry.key] ?? BigInt.zero,
          ),
        )
        .toList(growable: false);
    values.sort((left, right) {
      final byUsage = right.selectionCount.compareTo(left.selectionCount);
      if (byUsage != 0) return byUsage;
      return (right.imageCount + right.videoCount).compareTo(
        left.imageCount + left.videoCount,
      );
    });
    return values;
  }

  Future<List<MediaAsset>> _load() async {
    final generation = ++loadGeneration;
    late final List<MediaAsset> items;
    try {
      items = await widget.backend
          .listMedia(
            kind: kind,
            favoriteOnly: favoritesOnly,
            albumId: widget.albumId,
            newestFirst: newestFirst,
            gameNames: selectedGameTags.toList(growable: false),
            capturedFrom: capturedRange == null
                ? null
                : DateUtils.dateOnly(capturedRange!.start).toUtc(),
            capturedUntil: capturedRange == null
                ? null
                : DateUtils.dateOnly(capturedRange!.end)
                      .add(const Duration(days: 1))
                      .toUtc(),
            limit: 500,
          )
          .timeout(const Duration(seconds: 25));
    } catch (error, stackTrace) {
      if (!startupGalleryQueryLogged) {
        startupGalleryQueryLogged = true;
        await (widget.startupDiagnostics?.failure(
              'first-gallery-query',
              error,
              stackTrace,
            ) ??
            Future<void>.value());
      }
      rethrow;
    }
    if (!startupGalleryQueryLogged) {
      startupGalleryQueryLogged = true;
      unawaited(
        widget.startupDiagnostics?.phase('first-gallery-query-complete') ??
            Future<void>.value(),
      );
    }
    if (generation == loadGeneration) cachedMedia = items;
    return items;
  }

  void _reload() => setState(() {
    media = _load();
    gameTags = _loadGameTags();
  });

  Future<void> _reloadAndPreload() async {
    _reload();
    try {
      final latest = await media;
      if (mounted) _preloadVideoThumbnails(latest);
    } catch (_) {
      // The normal gallery FutureBuilder owns the visible error state.
    }
  }

  Future<void> _setGameTag(String game, bool enabled) async {
    setState(() {
      if (enabled) {
        selectedGameTags.add(game);
      } else {
        selectedGameTags.remove(game);
      }
      media = _load();
    });
    if (!enabled) return;
    try {
      await widget.backend.recordGameTagSelection(game);
      if (mounted) setState(() => gameTags = _loadGameTags());
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to record game tag selection for $game',
        error,
        stackTrace,
      );
    }
  }

  @override
  void dispose() {
    widget.settings.removeListener(_handleSettingsChanged);
    searchDebounce?.cancel();
    _selectionAutoScrollTimer?.cancel();
    searchController
      ..removeListener(_onSearchControllerChanged)
      ..dispose();
    super.dispose();
  }

  void _onSearchControllerChanged() =>
      _queueSearchUpdate(searchController.text);

  void _queueSearchUpdate(String _) {
    searchDebounce?.cancel();
    final value = searchController.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    searchDebounce = Timer(const Duration(milliseconds: 600), _commitSearch);
  }

  void _commitSearch() {
    searchDebounce?.cancel();
    final value = searchController.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    final submitted = value.text.trim();
    if (submitted == search || !mounted) return;
    setState(() => search = submitted);
  }

  void _setKind(GalleryKindFilter value) => setState(() {
    kind = value;
    selectedMediaIds.clear();
    media = _load();
  });

  void _toggleSelecting() => setState(() {
    selecting = !selecting;
    if (!selecting) selectedMediaIds.clear();
  });

  void _toggleSelected(int mediaId) => setState(() {
    selecting = true;
    if (!selectedMediaIds.add(mediaId)) selectedMediaIds.remove(mediaId);
  });

  void _selectAllVisibleMedia() {
    if (batchBusy || visibleMediaIds.isEmpty) return;
    setState(() {
      selecting = true;
      selectedMediaIds.addAll(visibleMediaIds);
    });
  }

  void _invertVisibleMediaSelection() {
    if (batchBusy || visibleMediaIds.isEmpty) return;
    setState(() {
      selecting = true;
      for (final id in visibleMediaIds) {
        if (!selectedMediaIds.add(id)) selectedMediaIds.remove(id);
      }
    });
  }

  void _handleSelectionTap(int mediaId) {
    if (_suppressNextSelectionTap) {
      _suppressNextSelectionTap = false;
      return;
    }
    _toggleSelected(mediaId);
  }

  void _beginSelectionPointer(int mediaId, Offset globalPosition) {
    if (!selecting || batchBusy) return;
    _selectionPointerActive = true;
    _selectionAnchorId = mediaId;
    _selectionTargetValue = !selectedMediaIds.contains(mediaId);
    _selectionDragVisited
      ..clear()
      ..add(mediaId);
    _suppressNextSelectionTap = false;
    _updateSelectionAutoScroll(globalPosition);
  }

  void _enterSelectionPointer(int mediaId, Offset globalPosition) {
    if (!_selectionPointerActive ||
        _selectionAnchorId == null ||
        _selectionDragVisited.contains(mediaId)) {
      _updateSelectionAutoScroll(globalPosition);
      return;
    }
    _suppressNextSelectionTap = true;
    _selectionDragVisited.add(mediaId);
    final anchor = _selectionAnchorId!;
    setState(() {
      if (_selectionTargetValue) {
        selectedMediaIds
          ..add(anchor)
          ..add(mediaId);
      } else {
        selectedMediaIds
          ..remove(anchor)
          ..remove(mediaId);
      }
    });
    _updateSelectionAutoScroll(globalPosition);
  }

  void _updateSelectionAutoScroll(Offset globalPosition) {
    if (!_selectionPointerActive) return;
    final height = MediaQuery.sizeOf(context).height;
    const edge = 72.0;
    final topEdge = 120.0;
    final bottomEdge = height - 24;
    if (globalPosition.dy < topEdge + edge) {
      final distance = (topEdge + edge - globalPosition.dy).clamp(0, edge);
      _selectionAutoScrollVelocity = -2.0 - distance / 16;
    } else if (globalPosition.dy > bottomEdge - edge) {
      final distance = (globalPosition.dy - (bottomEdge - edge)).clamp(0, edge);
      _selectionAutoScrollVelocity = 2.0 + distance / 16;
    } else {
      _selectionAutoScrollVelocity = 0;
    }
    if (_selectionAutoScrollVelocity == 0) {
      _selectionAutoScrollTimer?.cancel();
      _selectionAutoScrollTimer = null;
      return;
    }
    if (_selectionAutoScrollTimer != null) return;
    _selectionAutoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) {
        final scrollable = Scrollable.maybeOf(context);
        if (!_selectionPointerActive || scrollable == null) return;
        final position = scrollable.position;
        final next = (position.pixels + _selectionAutoScrollVelocity).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if (next != position.pixels) position.jumpTo(next);
      },
    );
  }

  void _endSelectionPointer() {
    _selectionPointerActive = false;
    _selectionAnchorId = null;
    _selectionDragVisited.clear();
    _selectionAutoScrollTimer?.cancel();
    _selectionAutoScrollTimer = null;
    _selectionAutoScrollVelocity = 0;
  }

  Future<void> _selectCapturedRange() async {
    final now = DateTime.now();
    final selected = await showDialog<DateTimeRange>(
      context: context,
      builder: (context) => _CreationDateRangeDialog(
        firstDate: DateTime(2000),
        lastDate: DateTime(now.year + 1, 12, 31),
        initialRange: capturedRange,
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        capturedRange = selected;
        media = _load();
      });
    }
  }

  Future<void> _runBatchAction(_BatchMediaAction action) async {
    if (selectedMediaIds.isEmpty || batchBusy) return;
    switch (action) {
      case _BatchMediaAction.copyToAlbum:
        await _batchAlbum(copy: true);
        return;
      case _BatchMediaAction.moveToAlbum:
        await _batchAlbum(copy: false);
        return;
      case _BatchMediaAction.favorite:
        await _runBatchMutation(
          () async {
            for (final id in selectedMediaIds) {
              await widget.backend.setFavorite(id, true);
              favoriteOverrides[id] = true;
            }
          },
          context.l10n.select(
            zh: '已收藏 ${selectedMediaIds.length} 项媒体。',
            en: '${selectedMediaIds.length} item(s) favorited.',
          ),
        );
        return;
      case _BatchMediaAction.addTags:
        await _batchTags(replace: false);
        return;
      case _BatchMediaAction.replaceTags:
        await _batchTags(replace: true);
        return;
      case _BatchMediaAction.export:
        await _batchExport();
        return;
      case _BatchMediaAction.mergeVideos:
        await _batchMergeVideos();
        return;
      case _BatchMediaAction.delete:
        await _deleteSelectedMedia();
        return;
    }
  }

  Future<void> _batchMergeVideos() async {
    if (!widget.enableVideoFeatures) {
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '安全模式已禁用视频处理。请正常启动软件后重试。',
            en: 'Video processing is disabled in safe mode. Restart normally to try again.',
          ),
          error: true,
        ),
      );
      return;
    }
    final videos = latestMedia
        .where(
          (asset) =>
              selectedMediaIds.contains(asset.id) &&
              asset.kind == MediaKind.video,
        )
        .toList(growable: false);
    if (videos.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '合并视频至少需要选择两个视频；所选图片会自动忽略。',
            en: 'Select at least two videos to merge. Selected images are ignored.',
          ),
          error: true,
        ),
      );
      return;
    }
    final result = await VideoMergePage.open(
      context,
      backend: widget.backend,
      videos: videos,
    );
    if (result == null || !mounted) return;
    setState(() {
      selecting = false;
      selectedMediaIds.clear();
      media = _load();
      gameTags = _loadGameTags();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      _messageSnackBar(
        context.l10n.select(
          zh: '已将 ${videos.length} 个视频合并并另存为“${result.originalName}”。',
          en: 'Merged ${videos.length} videos and saved “${result.originalName}”.',
        ),
      ),
    );
  }

  Future<void> _batchExport() async {
    final options = await _showMediaExportDialog();
    if (options == null || !mounted) return;
    final ids = selectedMediaIds.toList(growable: false);
    setState(() => batchBusy = true);
    try {
      final summary = await widget.backend.exportMedia(
        ids,
        options.directory,
        options.nameFormat,
      );
      for (final error in summary.errors) {
        await widget.backend.logError(
          'Failed to export media ${error.mediaId} (${error.name})',
          error.message,
        );
      }
      if (!mounted) return;
      setState(() {
        batchBusy = false;
        selecting = false;
        selectedMediaIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '已导出 ${summary.exported}/${summary.total} 项到 ${options.directory}${summary.failed > BigInt.zero ? '，${summary.failed} 项失败' : ''}。',
            en: 'Exported ${summary.exported}/${summary.total} item(s) to ${options.directory}${summary.failed > BigInt.zero ? '; ${summary.failed} failed' : ''}.',
          ),
          error: summary.failed > BigInt.zero,
          action: SnackBarAction(
            label: context.l10n.select(zh: '打开目录', en: 'Open folder'),
            onPressed: () => unawaited(_openExportDirectory(options.directory)),
          ),
        ),
      );
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to export selected media',
        error,
        stackTrace,
      );
      if (!mounted) return;
      setState(() => batchBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '媒体导出失败：$error',
            en: 'Failed to export media: $error',
          ),
          error: true,
        ),
      );
    }
  }

  Future<void> _openExportDirectory(String directory) async {
    try {
      await widget.backend.openDirectory(directory);
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to open export directory',
        error,
        stackTrace,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '无法打开导出目录：$error',
            en: 'Unable to open export folder: $error',
          ),
          error: true,
        ),
      );
    }
  }

  Future<_MediaExportOptions?> _showMediaExportDialog() async {
    return showDialog<_MediaExportOptions>(
      context: context,
      builder: (_) => const _MediaExportDialog(),
    );
  }

  Future<void> _batchAlbum({
    required bool copy,
    Iterable<int>? mediaIds,
  }) async {
    final ids = (mediaIds ?? selectedMediaIds).toSet();
    if (ids.isEmpty) return;
    final albums = (await widget.backend.listAlbums())
        .where((album) => album.albumType == 'manual')
        .where((album) => copy || album.id != widget.albumId)
        .toList(growable: false);
    if (!mounted) return;
    if (albums.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '请先创建一本普通相册。',
            en: 'Create a regular album first.',
          ),
        ),
      );
      return;
    }
    final target = await showDialog<AlbumSummary>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(
          context.l10n.select(
            zh: copy ? '复制到普通相册' : '移动到普通相册',
            en: copy ? 'Copy to regular album' : 'Move to regular album',
          ),
        ),
        children: albums
            .map(
              (album) => SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, album),
                child: ListTile(
                  leading: const Icon(Icons.photo_album_outlined),
                  title: Text(album.name),
                  subtitle: Text(
                    context.l10n.select(
                      zh: '${album.mediaCount} 个媒体',
                      en: '${album.mediaCount} media',
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
    if (target == null || !mounted) return;
    final moveFromAlbum =
        !copy && widget.albumId != null && widget.albumType == 'manual';
    await _runBatchMutation(
      () async {
        for (final id in ids) {
          await widget.backend.addMediaToAlbum(target.id, id);
          if (moveFromAlbum) {
            await widget.backend.removeMediaFromAlbum(widget.albumId!, id);
          }
        }
      },
      context.l10n.select(
        zh: moveFromAlbum
            ? '已将 ${ids.length} 项媒体移动到“${target.name}”。'
            : '已将 ${ids.length} 项媒体复制到“${target.name}”。',
        en: moveFromAlbum
            ? 'Moved ${ids.length} item(s) to “${target.name}”.'
            : 'Copied ${ids.length} item(s) to “${target.name}”.',
      ),
    );
  }

  Future<void> _showSingleMediaMenu(
    MediaAsset asset,
    TapDownDetails details,
  ) async {
    if (selecting || batchBusy) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = details.globalPosition;
    final action = await showMenu<_SingleMediaAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          key: const Key('single-media-copy'),
          value: _SingleMediaAction.copyToAlbum,
          child: _BatchActionLabel(
            icon: Icons.control_point_duplicate_rounded,
            text: context.l10n.select(zh: '复制到相册', en: 'Copy to album'),
          ),
        ),
        PopupMenuItem(
          key: const Key('single-media-move'),
          value: _SingleMediaAction.moveToAlbum,
          child: _BatchActionLabel(
            icon: Icons.drive_file_move_outline,
            text: context.l10n.select(zh: '移动到相册', en: 'Move to album'),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          key: const Key('single-media-delete'),
          value: _SingleMediaAction.delete,
          child: _BatchActionLabel(
            icon: Icons.delete_outline_rounded,
            color: Theme.of(context).colorScheme.error,
            text: context.l10n.select(zh: '删除', en: 'Delete'),
          ),
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _SingleMediaAction.copyToAlbum:
        await _batchAlbum(copy: true, mediaIds: [asset.id]);
        return;
      case _SingleMediaAction.moveToAlbum:
        await _batchAlbum(copy: false, mediaIds: [asset.id]);
        return;
      case _SingleMediaAction.delete:
        await _deleteSelectedMedia(mediaIds: [asset.id]);
        return;
    }
  }

  Future<void> _batchTags({required bool replace}) async {
    final tags = await _showBatchTagDialog(replace: replace);
    if (tags == null || !mounted) return;
    final selectedAssets = latestMedia
        .where((asset) => selectedMediaIds.contains(asset.id))
        .toList(growable: false);
    await _runBatchMutation(
      () async {
        for (final asset in selectedAssets) {
          final next = replace
              ? tags
              : ({...asset.tags, ...tags}.toList()..sort());
          await widget.backend.replaceTags(asset.id, next);
        }
      },
      context.l10n.select(
        zh: replace
            ? '已覆盖 ${selectedAssets.length} 项媒体的标签。'
            : '已为 ${selectedAssets.length} 项媒体新增标签。',
        en: replace
            ? 'Replaced tags on ${selectedAssets.length} item(s).'
            : 'Added tags to ${selectedAssets.length} item(s).',
      ),
    );
  }

  Future<List<String>?> _showBatchTagDialog({required bool replace}) async {
    final available = await widget.backend.listTags();
    if (!mounted) return null;
    final selected = <String>{};
    final custom = TextEditingController();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            context.l10n.select(
              zh: replace ? '覆盖标签' : '新增标签',
              en: replace ? 'Replace tags' : 'Add tags',
            ),
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (replace)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        context.l10n.select(
                          zh: '所选媒体原有的自定义标签将被替换。留空可清除标签。',
                          en: 'Existing custom tags will be replaced. Leave empty to clear them.',
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: available
                        .map(
                          (tag) => FilterChip(
                            label: Text(tag),
                            labelStyle: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontFamily: 'SmileySans',
                            ),
                            selected: selected.contains(tag),
                            onSelected: (enabled) => setDialogState(() {
                              if (enabled) {
                                selected.add(tag);
                              } else {
                                selected.remove(tag);
                              }
                            }),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    key: const Key('batch-custom-tags'),
                    controller: custom,
                    decoration: InputDecoration(
                      labelText: context.l10n.select(
                        zh: '其他标签',
                        en: 'Other tags',
                      ),
                      hintText: context.l10n.select(
                        zh: '多个标签使用逗号分隔',
                        en: 'Separate multiple tags with commas',
                      ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              key: const Key('apply-batch-tags'),
              onPressed: () {
                final entered = custom.text
                    .split(RegExp(r'[,，\n]'))
                    .map((tag) => tag.trim())
                    .where((tag) => tag.isNotEmpty);
                Navigator.pop(
                  dialogContext,
                  ({...selected, ...entered}.toList()..sort()),
                );
              },
              child: Text(context.l10n.select(zh: '应用', en: 'Apply')),
            ),
          ],
        ),
      ),
    );
    custom.dispose();
    return result;
  }

  Future<void> _runBatchMutation(
    Future<void> Function() mutation,
    String success,
  ) async {
    setState(() => batchBusy = true);
    try {
      await mutation();
      if (!mounted) return;
      setState(() {
        batchBusy = false;
        selecting = false;
        selectedMediaIds.clear();
        media = _load();
      });
      ScaffoldMessenger.of(context).showSnackBar(_messageSnackBar(success));
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to run batch media operation',
        error,
        stackTrace,
      );
      if (!mounted) return;
      setState(() => batchBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '批量操作失败：$error',
            en: 'Batch operation failed: $error',
          ),
          error: true,
        ),
      );
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
      await widget.backend.setFavorite(asset.id, next);
      if (!mounted) return;
      setState(() => favoriteBusy.remove(asset.id));
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to update favorite state for media ${asset.id}',
        error,
        stackTrace,
      );
      if (!mounted) return;
      setState(() {
        favoriteBusy.remove(asset.id);
        favoriteOverrides.remove(asset.id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '收藏状态更新失败：$error',
            en: 'Failed to update favorite: $error',
          ),
          error: true,
        ),
      );
    }
  }

  void _preloadVideoThumbnails(List<MediaAsset> items) {
    if (!widget.enableVideoFeatures) return;
    VideoThumbnailCache.preload(
      items,
      onError: (error, stackTrace) => widget.backend.logError(
        'Failed to generate video thumbnail',
        error,
        stackTrace,
      ),
    );
  }

  void _preloadGalleryImages(List<MediaAsset> items, int columns) {
    final limit = (columns * 3).clamp(6, 24);
    for (final asset
        in items.where((item) => item.kind == MediaKind.image).take(limit)) {
      if (!_preloadedImagePaths.add(asset.storagePath)) continue;
      unawaited(
        precacheImage(
          FileImage(File(asset.storagePath)),
          context,
          size: const Size(900, 600),
        ).catchError((_) {}),
      );
    }
  }

  Widget _buildHeaderActions(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      if (selecting) ...[
        IconButton.filledTonal(
          key: const Key('batch-select-all'),
          tooltip: context.l10n.select(
            zh: '全选当前媒体',
            en: 'Select all visible media',
          ),
          onPressed: batchBusy ? null : _selectAllVisibleMedia,
          icon: const Icon(Icons.select_all_rounded),
        ),
        IconButton.filledTonal(
          key: const Key('batch-invert-selection'),
          tooltip: context.l10n.select(
            zh: '反选当前媒体',
            en: 'Invert visible selection',
          ),
          onPressed: batchBusy ? null : _invertVisibleMediaSelection,
          icon: const Icon(Icons.flip_to_back_rounded),
        ),
        PopupMenuButton<_BatchMediaAction>(
          key: const Key('batch-media-actions'),
          tooltip: context.l10n.select(zh: '更多批量操作', en: 'More batch actions'),
          enabled: selectedMediaIds.isNotEmpty && !batchBusy,
          onSelected: _runBatchAction,
          itemBuilder: (context) => [
            PopupMenuItem(
              value: _BatchMediaAction.copyToAlbum,
              child: _BatchActionLabel(
                icon: Icons.control_point_duplicate_rounded,
                text: context.l10n.select(zh: '复制到相册', en: 'Copy to album'),
              ),
            ),
            PopupMenuItem(
              value: _BatchMediaAction.moveToAlbum,
              child: _BatchActionLabel(
                icon: Icons.drive_file_move_outline,
                text: context.l10n.select(zh: '移动到相册', en: 'Move to album'),
              ),
            ),
            PopupMenuItem(
              value: _BatchMediaAction.favorite,
              child: _BatchActionLabel(
                icon: Icons.favorite_border_rounded,
                text: context.l10n.select(zh: '收藏', en: 'Favorite'),
              ),
            ),
            PopupMenuItem(
              value: _BatchMediaAction.addTags,
              child: _BatchActionLabel(
                icon: Icons.new_label_outlined,
                text: context.l10n.select(zh: '新增标签', en: 'Add tags'),
              ),
            ),
            PopupMenuItem(
              value: _BatchMediaAction.replaceTags,
              child: _BatchActionLabel(
                icon: Icons.label_outline_rounded,
                text: context.l10n.select(zh: '覆盖标签', en: 'Replace tags'),
              ),
            ),
            PopupMenuItem(
              value: _BatchMediaAction.export,
              child: _BatchActionLabel(
                icon: Icons.save_alt_rounded,
                text: context.l10n.select(
                  zh: '导出至指定目录',
                  en: 'Export to directory',
                ),
              ),
            ),
            PopupMenuItem(
              value: _BatchMediaAction.mergeVideos,
              enabled:
                  latestMedia
                      .where(
                        (asset) =>
                            selectedMediaIds.contains(asset.id) &&
                            asset.kind == MediaKind.video,
                      )
                      .length >=
                  2,
              child: _BatchActionLabel(
                icon: Icons.video_call_outlined,
                text: context.l10n.select(zh: '合并视频', en: 'Merge videos'),
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              key: const Key('batch-delete-media'),
              value: _BatchMediaAction.delete,
              child: _BatchActionLabel(
                icon: Icons.delete_outline_rounded,
                color: Theme.of(context).colorScheme.error,
                text: context.l10n.select(zh: '删除所选媒体', en: 'Delete selected'),
              ),
            ),
          ],
          child: Chip(
            avatar: batchBusy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.more_horiz_rounded, size: 18),
            label: Text(context.l10n.select(zh: '批量操作', en: 'Actions')),
          ),
        ),
        TextButton.icon(
          onPressed: _toggleSelecting,
          icon: const Icon(Icons.close_rounded),
          label: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
        ),
      ] else ...[
        if (widget.showTransferAction)
          FilledButton.icon(
            onPressed: widget.onOpenTransfer,
            icon: const Icon(Icons.add_rounded),
            label: Text(context.l10n.select(zh: '导入与同步', en: 'Sync & Import')),
          ),
        OutlinedButton.icon(
          key: const Key('start-media-selection'),
          onPressed: _toggleSelecting,
          icon: const Icon(Icons.checklist_rounded),
          label: Text(context.l10n.select(zh: '批量选择', en: 'Select')),
        ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: selecting
        ? context.l10n.select(
            zh: '已选择 ${selectedMediaIds.length} 项',
            en: '${selectedMediaIds.length} selected',
          )
        : widget.albumName ?? context.l10n.select(zh: '图库', en: 'Library'),
    subtitle: widget.albumId == null
        ? null
        : widget.albumDescription?.trim().isNotEmpty == true
        ? widget.albumDescription!.trim()
        : context.l10n.select(
            zh: widget.albumSystemKey == 'favorites'
                ? '所有已收藏的图片与视频'
                : widget.albumType == 'smart'
                ? '根据自动规则持续整理媒体'
                : '手动整理的图片与视频',
            en: widget.albumSystemKey == 'favorites'
                ? 'All favorited photos and videos'
                : widget.albumType == 'smart'
                ? 'Media continuously organized by smart rules'
                : 'Manually organized photos and videos',
          ),
    leading: widget.onBack == null
        ? null
        : IconButton.filledTonal(
            key: const Key('album-detail-back'),
            tooltip: context.l10n.select(zh: '返回相册列表', en: 'Back to albums'),
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
    action: _buildHeaderActions(context),
    fixedHeader: true,
    child: Column(
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 310,
              child: TextField(
                key: const Key('library-search'),
                controller: searchController,
                style: const TextStyle(
                  fontFamilyFallback: [
                    'Microsoft YaHei UI',
                    'Microsoft YaHei',
                    'PingFang SC',
                    'Noto Sans CJK SC',
                  ],
                ),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: context.l10n.select(
                    zh: '搜索文件名、备注、游戏或标签',
                    en: 'Search file name, note, game, or tag',
                  ),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: searchController,
                    builder: (context, value, _) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            tooltip: context.l10n.select(
                              zh: '清除搜索',
                              en: 'Clear search',
                            ),
                            onPressed: () {
                              searchController.clear();
                              _commitSearch();
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                  ),
                  border: const OutlineInputBorder(),
                ),
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.search,
                autocorrect: false,
                enableSuggestions: true,
                onSubmitted: (_) => _commitSearch(),
              ),
            ),
            SegmentedButton<GalleryKindFilter>(
              segments: [
                ButtonSegment(
                  value: GalleryKindFilter.all,
                  label: Text(context.l10n.select(zh: '全部', en: 'All')),
                ),
                ButtonSegment(
                  value: GalleryKindFilter.image,
                  label: Text(context.l10n.select(zh: '图片', en: 'Photos')),
                ),
                ButtonSegment(
                  value: GalleryKindFilter.video,
                  label: Text(context.l10n.select(zh: '视频', en: 'Videos')),
                ),
              ],
              selected: {kind},
              showSelectedIcon: false,
              onSelectionChanged: (value) => _setKind(value.first),
            ),
            FilterChip(
              key: const Key('favorite-filter'),
              labelStyle: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontFamily: 'SmileySans',
              ),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    favoritesOnly ? Icons.favorite : Icons.favorite_border,
                    size: 18,
                    color: favoritesOnly
                        ? const Color(0xffd94766)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 7),
                  Text(context.l10n.select(zh: '收藏', en: 'Favorites')),
                ],
              ),
              selected: favoritesOnly,
              onSelected: (value) => setState(() {
                favoritesOnly = value;
                selectedMediaIds.clear();
                media = _load();
              }),
            ),
            InputChip(
              key: const Key('capture-date-filter'),
              labelStyle: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontFamily: 'SmileySans',
              ),
              avatar: const Icon(Icons.date_range_rounded, size: 18),
              label: Text(
                capturedRange == null
                    ? context.l10n.select(zh: '创建时间', en: 'Creation date')
                    : '${_shortDate(capturedRange!.start)} – ${_shortDate(capturedRange!.end)}',
              ),
              onPressed: _selectCapturedRange,
              onDeleted: capturedRange == null
                  ? null
                  : () => setState(() {
                      capturedRange = null;
                      media = _load();
                    }),
            ),
            PopupMenuButton<bool>(
              key: const Key('media-sort-menu'),
              tooltip: context.l10n.select(zh: '排序方式', en: 'Sort order'),
              initialValue: newestFirst,
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              onSelected: (value) => setState(() {
                newestFirst = value;
                selectedMediaIds.clear();
                media = _load();
              }),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: true,
                  child: Row(
                    children: [
                      const Icon(Icons.arrow_downward_rounded),
                      const SizedBox(width: 10),
                      Text(
                        context.l10n.select(
                          zh: '创建时间倒序',
                          en: 'Creation time, newest first',
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: false,
                  child: Row(
                    children: [
                      const Icon(Icons.arrow_upward_rounded),
                      const SizedBox(width: 10),
                      Text(
                        context.l10n.select(
                          zh: '创建时间正序',
                          en: 'Creation time, oldest first',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              child: Container(
                key: const Key('media-sort-control'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer
                      .withValues(alpha: .62),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary
                        .withValues(alpha: .22),
                  ),
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(context).colorScheme.shadow
                          .withValues(alpha: .06),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      newestFirst ? Icons.south_rounded : Icons.north_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      newestFirst
                          ? context.l10n.select(
                              zh: '创建时间 · 最新优先',
                              en: 'Created · Newest first',
                            )
                          : context.l10n.select(
                              zh: '创建时间 · 最早优先',
                              en: 'Created · Oldest first',
                            ),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.expand_more_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        FutureBuilder<List<GameTagSummary>>(
          future: gameTags,
          builder: (context, snapshot) {
            final games = snapshot.data ?? const <GameTagSummary>[];
            if (games.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 8),
              child: _GameTagFilters(
                games: games,
                selected: selectedGameTags,
                onChanged: _setGameTag,
                onClear: () => setState(() {
                  selectedGameTags.clear();
                  media = _load();
                }),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<MediaAsset>>(
          future: media,
          builder: (context, snapshot) {
            final source = snapshot.data ?? cachedMedia;
            if (source == null &&
                snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(48),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            if (source == null && snapshot.hasError) {
              return _ErrorPanel(
                message: context.l10n.select(
                  zh: '图库读取失败：${snapshot.error}',
                  en: 'Failed to load library: ${snapshot.error}',
                ),
                onRetry: _reload,
              );
            }
            final currentItems = source!
                .map(_withFavoriteOverride)
                .toList(growable: false);
            latestMedia = currentItems;
            _preloadVideoThumbnails(currentItems);
            final rows = currentItems.where((item) {
              if ((favoritesOnly || widget.albumSystemKey == 'favorites') &&
                  !item.favorite) {
                return false;
              }
              final text = [
                item.originalName,
                item.gameName,
                item.note ?? '',
                ...item.tags,
              ].join(' ');
              return normalizedTextContains(text, search);
            }).toList();
            final columns = widget.settings.value.galleryColumns.clamp(2, 7);
            _preloadGalleryImages(rows, columns);
            visibleMediaIds = rows
                .map((item) => item.id)
                .toList(growable: false);
            final Widget mediaContent;
            if (rows.isEmpty) {
              mediaContent = _EmptyPanel(
                icon: Icons.photo_library_outlined,
                message: context.l10n.select(
                  zh: '当前条件下没有媒体',
                  en: 'No media matches the current filters',
                ),
              );
            } else {
              mediaContent = LayoutBuilder(
                builder: (context, constraints) {
                  final previewRows = _isDesktop
                      ? 3
                      : widget.settings.value.galleryRows.clamp(2, 8);
                  final cardHeight = (420 / previewRows + 130).clamp(
                    210.0,
                    520.0,
                  );
                  return Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerMove: (event) =>
                        _updateSelectionAutoScroll(event.position),
                    onPointerUp: (_) => _endSelectionPointer(),
                    child: GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        mainAxisExtent: cardHeight,
                      ),
                      itemCount: rows.length,
                      itemBuilder: (context, index) => _MediaCard(
                        asset: rows[index],
                        settings: widget.settings.value,
                        onVideoThumbnailError: (error, stackTrace) =>
                            widget.backend.logError(
                              'Failed to generate video thumbnail for media ${rows[index].id}',
                              error,
                              stackTrace,
                            ),
                        selecting: selecting,
                        enableVideoFeatures: widget.enableVideoFeatures,
                        selected: selectedMediaIds.contains(rows[index].id),
                        onSelect: () => _toggleSelected(rows[index].id),
                        onSelectionPointerDown: (position) =>
                            _beginSelectionPointer(rows[index].id, position),
                        onSelectionPointerEnter: (position) =>
                            _enterSelectionPointer(rows[index].id, position),
                        onSelectionPointerUp: _endSelectionPointer,
                        onFavorite: favoriteBusy.contains(rows[index].id)
                            ? null
                            : () => _toggleFavorite(rows[index]),
                        onPreview: selecting
                            ? () => _handleSelectionTap(rows[index].id)
                            : rows[index].kind == MediaKind.video &&
                                  !widget.enableVideoFeatures
                            ? () => ScaffoldMessenger.of(context).showSnackBar(
                                _messageSnackBar(
                                  context.l10n.select(
                                    zh: '安全模式已禁用视频预览。',
                                    en: 'Video preview is disabled in safe mode.',
                                  ),
                                  error: true,
                                ),
                              )
                            : () => MediaViewer.open(
                                context,
                                backend: widget.backend,
                                items: rows,
                                initialIndex: index,
                                autoPlayVideo:
                                    widget.settings.value.autoPlayVideo,
                                compactTagDisplay:
                                    widget.settings.value.compactTagDisplay,
                                onMetadataChanged: _reload,
                              ),
                        onSecondaryTapDown: (details) =>
                            _showSingleMediaMenu(rows[index], details),
                        onEdit: () async {
                          final changed =
                              await showModalBottomSheet<MediaMetadataUpdate>(
                                context: context,
                                showDragHandle: true,
                                isScrollControlled: true,
                                constraints: const BoxConstraints(
                                  maxWidth: 680,
                                ),
                                builder: (_) => MediaMetadataEditor(
                                  backend: widget.backend,
                                  asset: rows[index],
                                ),
                              );
                          if (changed != null) _reload();
                        },
                      ),
                    ),
                  );
                },
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 7,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: snapshot.connectionState == ConnectionState.done
                        ? const SizedBox.shrink(
                            key: ValueKey('gallery-filter-idle'),
                          )
                        : const LinearProgressIndicator(
                            key: Key('gallery-filter-progress'),
                            minHeight: 3,
                          ),
                  ),
                ),
                if (snapshot.hasError)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      context.l10n.select(
                        zh: '筛选更新失败，正在显示上一次结果：${snapshot.error}',
                        en: 'Filter update failed; showing the previous results: ${snapshot.error}',
                      ),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 320),
                  reverseDuration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 320),
                    reverseDuration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    layoutBuilder: (currentChild, previousChildren) => Stack(
                      alignment: Alignment.topCenter,
                      children: [...previousChildren, ?currentChild],
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(rows.map((item) => item.id).join(',')),
                      child: mediaContent,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    ),
  );

  Future<void> _deleteSelectedMedia({List<int>? mediaIds}) async {
    if (widget.albumType == 'smart' && widget.albumSystemKey != 'favorites') {
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '自动相册由规则生成，不能单独移出其中的媒体。请修改相册规则或在图库中删除。',
            en: 'Smart albums are rule-based. Change its rules or delete the item from the library.',
          ),
        ),
      );
      return;
    }
    final ids = mediaIds ?? selectedMediaIds.toList(growable: false);
    if (ids.isEmpty) return;
    final inAlbum = widget.albumId != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          inAlbum
              ? context.l10n.select(
                  zh: '从当前相册移除 ${ids.length} 项？',
                  en: 'Remove ${ids.length} item(s) from this album?',
                )
              : context.l10n.select(
                  zh: '永久删除 ${ids.length} 项媒体？',
                  en: 'Permanently delete ${ids.length} item(s)?',
                ),
        ),
        content: Text(
          inAlbum
              ? context.l10n.select(
                  zh: '将先从“${widget.albumName}”移除。如果它已不属于任何其他相册，数据库记录和实际原件也会被永久删除。此操作无法撤销。',
                  en: 'It will be removed from “${widget.albumName}”. If no other album contains it, its database record and original file will also be permanently deleted. This cannot be undone.',
                )
              : context.l10n.select(
                  zh: '所选媒体将从图库、所有相册和磁盘中永久删除。此操作无法撤销。',
                  en: 'The selected media will be permanently deleted from the library, every album, and disk. This cannot be undone.',
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              inAlbum
                  ? context.l10n.select(zh: '移除并检查', en: 'Remove & check')
                  : context.l10n.select(zh: '永久删除', en: 'Delete permanently'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    var completed = 0;
    var deletedFiles = 0;
    var failed = 0;
    for (final id in ids) {
      try {
        final result = inAlbum
            ? await widget.backend.removeMediaFromAlbum(widget.albumId!, id)
            : await widget.backend.deleteMedia(id);
        completed += 1;
        if (result.deletedFromLibrary) deletedFiles += 1;
      } catch (error, stackTrace) {
        failed += 1;
        await widget.backend.logError(
          'Failed to delete media $id during batch operation',
          error,
          stackTrace,
        );
      }
    }
    if (!mounted) return;
    setState(() {
      selecting = false;
      selectedMediaIds.clear();
      media = _load();
    });
    final message = failed == 0
        ? (inAlbum
              ? context.l10n.select(
                  zh: '已从相册移除 $completed 项，其中 $deletedFiles 个实际原件因无其他归属而删除。',
                  en: 'Removed $completed item(s); $deletedFiles original file(s) had no other album and were deleted.',
                )
              : context.l10n.select(
                  zh: '已永久删除 $completed 项媒体及其实际文件。',
                  en: 'Permanently deleted $completed media item(s) and their files.',
                ))
        : context.l10n.select(
            zh: '已处理 $completed 项，$failed 项失败；详情已写入日志。',
            en: 'Processed $completed item(s); $failed failed. Details were written to the log.',
          );
    ScaffoldMessenger.of(context)
        .showSnackBar(_messageSnackBar(message, error: failed > 0));
  }
}

class _MediaCard extends StatelessWidget {
  const _MediaCard({
    required this.asset,
    required this.settings,
    required this.onVideoThumbnailError,
    required this.selecting,
    required this.selected,
    required this.onSelect,
    required this.onSelectionPointerDown,
    required this.onSelectionPointerEnter,
    required this.onSelectionPointerUp,
    required this.onFavorite,
    required this.onPreview,
    required this.onSecondaryTapDown,
    required this.onEdit,
    this.enableVideoFeatures = true,
  });

  final MediaAsset asset;
  final AppSettings settings;
  final Future<void> Function(Object error, StackTrace stackTrace)
  onVideoThumbnailError;
  final bool selecting;
  final bool selected;
  final VoidCallback onSelect;
  final ValueChanged<Offset> onSelectionPointerDown;
  final ValueChanged<Offset> onSelectionPointerEnter;
  final VoidCallback onSelectionPointerUp;
  final VoidCallback? onFavorite;
  final VoidCallback onPreview;
  final GestureTapDownCallback onSecondaryTapDown;
  final VoidCallback onEdit;
  final bool enableVideoFeatures;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: selecting
        ? (event) => onSelectionPointerEnter(event.position)
        : null,
    child: Listener(
      onPointerDown: selecting
          ? (event) => onSelectionPointerDown(event.position)
          : null,
      onPointerUp: selecting ? (_) => onSelectionPointerUp() : null,
      child: Card(
        key: ValueKey('media-card-${asset.id}'),
        clipBehavior: Clip.antiAlias,
        elevation: selected ? 6 : 1,
        shadowColor: selected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: .45)
            : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: selected
              ? BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                )
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: onPreview,
          onLongPress: selecting ? null : onSelect,
          onSecondaryTapDown: selecting ? null : onSecondaryTapDown,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _MediaPreview(
                      asset: asset,
                      enableVideoFeatures: enableVideoFeatures,
                      onVideoThumbnailError: onVideoThumbnailError,
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: selecting
                          ? SizedBox.square(
                              dimension: 48,
                              child: Center(
                                child: Transform.scale(
                                  scale: 1.25,
                                  child: Checkbox(
                                    key: ValueKey('media-selected-${asset.id}'),
                                    value: selected,
                                    onChanged: (_) => onSelect(),
                                  ),
                                ),
                              ),
                            )
                          : IconButton.filledTonal(
                              tooltip: asset.favorite
                                  ? context.l10n.select(
                                      zh: '取消收藏',
                                      en: 'Remove from favorites',
                                    )
                                  : context.l10n.select(
                                      zh: '收藏',
                                      en: 'Favorite',
                                    ),
                              onPressed: onFavorite,
                              icon: Icon(
                                asset.favorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: asset.favorite
                                    ? const Color(0xffe25270)
                                    : null,
                              ),
                            ),
                    ),
                    if (selected)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Theme.of(context).colorScheme.primary,
                                width: 4,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _HoverMarqueeText(
                            key: ValueKey('media-filename-${asset.id}'),
                            text: asset.originalName,
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: context.l10n.select(
                            zh: '编辑标签与备注',
                            en: 'Edit tags and note',
                          ),
                          onPressed: selecting ? null : onEdit,
                          icon: const Icon(Icons.edit_note_rounded, size: 20),
                        ),
                      ],
                    ),
                    if (settings.compactTagDisplay &&
                        ((settings.showGameTag && asset.gameName.isNotEmpty) ||
                            asset.tags.isNotEmpty)) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        key: ValueKey('media-card-compact-tags-${asset.id}'),
                        spacing: 5,
                        runSpacing: 5,
                        children: [
                          if (settings.showGameTag && asset.gameName.isNotEmpty)
                            _Tag(text: asset.gameName, game: true),
                          ...asset.tags.take(3).map((tag) => _Tag(text: tag)),
                        ],
                      ),
                    ] else ...[
                      if (settings.showGameTag &&
                          asset.gameName.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _Tag(text: asset.gameName, game: true),
                      ],
                      if (asset.tags.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: asset.tags
                              .take(3)
                              .map((tag) => _Tag(text: tag))
                              .toList(),
                        ),
                      ],
                    ],
                    if (settings.showNotePreview &&
                        (asset.note?.isNotEmpty ?? false)) ...[
                      const SizedBox(height: 8),
                      Text(
                        _notePreview(asset.note!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MediaPreview extends StatelessWidget {
  const _MediaPreview({
    required this.asset,
    required this.onVideoThumbnailError,
    this.enableVideoFeatures = true,
  });

  final MediaAsset asset;
  final Future<void> Function(Object error, StackTrace stackTrace)
  onVideoThumbnailError;
  final bool enableVideoFeatures;

  @override
  Widget build(BuildContext context) {
    if (asset.kind == MediaKind.image) {
      return Image.file(
        File(asset.storagePath),
        fit: BoxFit.cover,
        cacheWidth: 900,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(context),
      );
    }
    return _VideoCardPreview(
      asset: asset,
      enabled: enableVideoFeatures,
      onThumbnailError: onVideoThumbnailError,
    );
  }

  Widget _placeholder(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: asset.kind == MediaKind.video
            ? const [Color(0xff69599d), Color(0xffc5b7e7)]
            : const [Color(0xff536fae), Color(0xffa7c1f2)],
      ),
    ),
    child: Icon(
      asset.kind == MediaKind.video
          ? Icons.videocam_rounded
          : Icons.broken_image_outlined,
      color: Colors.white70,
      size: 48,
    ),
  );
}

class _VideoCardPreview extends StatelessWidget {
  const _VideoCardPreview({
    required this.asset,
    required this.onThumbnailError,
    this.enabled = true,
  });

  final MediaAsset asset;
  final Future<void> Function(Object error, StackTrace stackTrace)
  onThumbnailError;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xff69599d), Color(0xffc5b7e7)],
          ),
        ),
        child: Icon(Icons.videocam_rounded, color: Colors.white70, size: 48),
      );
    }
    return FutureBuilder<VideoThumbnailData>(
      future: VideoThumbnailCache.load(asset, onError: onThumbnailError),
      builder: (context, snapshot) {
        final data = snapshot.data ?? const VideoThumbnailData();
        return Stack(
          fit: StackFit.expand,
          children: [
            if (data.bytes != null)
              Image.memory(
                data.bytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            else
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xff69599d), Color(0xffc5b7e7)],
                  ),
                ),
                child: Icon(
                  Icons.videocam_rounded,
                  color: Colors.white70,
                  size: 48,
                ),
              ),
            const Positioned(
              left: 10,
              bottom: 10,
              child: Icon(
                Icons.play_circle_fill_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
            Positioned(
              right: 10,
              bottom: 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .72),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  child: Text(
                    _formatVideoDuration(data.duration),
                    key: ValueKey('video-duration-${asset.id}'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

String _formatVideoDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

String _notePreview(String note) =>
    note.length <= 15 ? note : '${note.substring(0, 15)}…';

class _HoverMarqueeText extends StatefulWidget {
  const _HoverMarqueeText({super.key, required this.text});

  final String text;

  @override
  State<_HoverMarqueeText> createState() => _HoverMarqueeTextState();
}

class _HoverMarqueeTextState extends State<_HoverMarqueeText> {
  final ScrollController controller = ScrollController();
  int animationGeneration = 0;
  bool hovering = false;

  @override
  void didUpdateWidget(covariant _HoverMarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      animationGeneration += 1;
      if (controller.hasClients) controller.jumpTo(0);
    }
  }

  @override
  void dispose() {
    animationGeneration += 1;
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.basic,
    onEnter: (_) => _start(),
    onExit: (_) => _stop(),
    child: ClipRect(
      child: SingleChildScrollView(
        key: const Key('filename-marquee-scroll'),
        controller: controller,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );

  Future<void> _start() async {
    hovering = true;
    final generation = ++animationGeneration;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    while (mounted && hovering && generation == animationGeneration) {
      if (!controller.hasClients) return;
      final extent = controller.position.maxScrollExtent;
      if (extent <= 0) return;
      await controller.animateTo(
        extent,
        duration: Duration(
          milliseconds: (extent * 28).round().clamp(1200, 6000).toInt(),
        ),
        curve: Curves.linear,
      );
      if (!mounted || !hovering || generation != animationGeneration) return;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted || !hovering || generation != animationGeneration) return;
      await controller.animateTo(
        0,
        duration: Duration(
          milliseconds: (extent * 18).round().clamp(800, 4000).toInt(),
        ),
        curve: Curves.easeOutCubic,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  void _stop() {
    hovering = false;
    animationGeneration += 1;
    if (controller.hasClients) {
      unawaited(
        controller.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, this.game = false});
  final String text;
  final bool game;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: game
          ? const Color(0xfffff1e7)
          : Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: game
              ? const Color(0xff98613f)
              : Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    ),
  );
}

enum _AlbumAction { rename, toggleSmart, editRules, delete }

class AlbumsPage extends StatefulWidget {
  const AlbumsPage({
    super.key,
    required this.backend,
    required this.onOpenAlbum,
    this.enableVideoFeatures = true,
  });
  final AppBackend backend;
  final ValueChanged<AlbumSummary> onOpenAlbum;
  final bool enableVideoFeatures;

  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<AlbumsPage> {
  late Future<List<AlbumSummary>> albums = widget.backend.listAlbums();
  final Map<int, Future<List<MediaAsset>>> albumCovers = {};

  void _reload() => setState(() {
    albumCovers.clear();
    albums = widget.backend.listAlbums();
  });

  Future<List<MediaAsset>> _coverFor(AlbumSummary album) =>
      albumCovers.putIfAbsent(
        album.id,
        () => widget.backend.listMedia(albumId: album.id, limit: 1),
      );

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: context.l10n.select(zh: '相册', en: 'Albums'),
    subtitle: context.l10n.select(
      zh: '普通相册手动管理，自动相册持续匹配规则',
      en: 'Manage regular albums manually and match smart album rules',
    ),
    action: FilledButton.icon(
      onPressed: _createAlbum,
      icon: const Icon(Icons.add_rounded),
      label: Text(context.l10n.select(zh: '新建相册', en: 'New album')),
    ),
    child: FutureBuilder<List<AlbumSummary>>(
      future: albums,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(48),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (snapshot.hasError) {
          return _ErrorPanel(
            message: context.l10n.select(
              zh: '相册读取失败：${snapshot.error}',
              en: 'Failed to load albums: ${snapshot.error}',
            ),
            onRetry: _reload,
          );
        }
        final rows = snapshot.data!;
        if (rows.isEmpty) {
          return _EmptyPanel(
            icon: Icons.collections_bookmark_outlined,
            message: context.l10n.select(zh: '还没有相册', en: 'No albums yet'),
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final count = (constraints.maxWidth / 280).floor().clamp(1, 4);
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: count,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 1.35,
              ),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final album = rows[index];
                return _AlbumCard(
                  album: album,
                  cover: _coverFor(album),
                  onTap: () => widget.onOpenAlbum(album),
                  onSecondaryTapDown: (details) =>
                      _showAlbumMenu(album, details.globalPosition),
                  onThumbnailError: (error, stackTrace) =>
                      widget.backend.logError(
                        'Failed to generate album cover for ${album.id}',
                        error,
                        stackTrace,
                      ),
                  enableVideoFeatures: widget.enableVideoFeatures,
                );
              },
            );
          },
        );
      },
    ),
  );

  Future<void> _createAlbum() async {
    final name = TextEditingController();
    final description = TextEditingController();
    var smart = false;
    var rules = <AlbumRule>[];
    var nameValid = false;
    final result = await showDialog<_AlbumDraft>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.l10n.select(zh: '新建相册', en: 'New album')),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  onChanged: (value) =>
                      setDialogState(() => nameValid = value.trim().isNotEmpty),
                  decoration: InputDecoration(
                    labelText: context.l10n.select(
                      zh: '相册名称',
                      en: 'Album name',
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('album-description-field'),
                  controller: description,
                  maxLength: 160,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: context.l10n.select(
                      zh: '相册描述（可选）',
                      en: 'Album description (optional)',
                    ),
                    alignLabelWithHint: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    context.l10n.select(zh: '自动相册', en: 'Smart album'),
                  ),
                  subtitle: Text(
                    context.l10n.select(
                      zh: '自动相册需要在创建前配置至少一条规则',
                      en: 'Configure at least one rule before creating a smart album',
                    ),
                  ),
                  value: smart,
                  onChanged: (value) => setDialogState(() => smart = value),
                ),
                if (smart) ...[
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      key: const Key('configure-new-smart-album-rules'),
                      onPressed: () async {
                        final next = await _showRuleEditor(
                          albumId: null,
                          initialRules: rules,
                        );
                        if (next != null) {
                          setDialogState(() => rules = next);
                        }
                      },
                      icon: const Icon(Icons.rule_rounded),
                      label: Text(
                        rules.isEmpty
                            ? context.l10n.select(
                                zh: '配置自动规则',
                                en: 'Configure smart rules',
                              )
                            : context.l10n.select(
                                zh: '已配置 ${rules.length} 条规则',
                                en: '${rules.length} rules configured',
                              ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              onPressed: !nameValid || (smart && rules.isEmpty)
                  ? null
                  : () {
                      final value = name.text.trim();
                      Navigator.pop(
                        context,
                        _AlbumDraft(
                          name: value,
                          description: description.text.trim(),
                          smart: smart,
                          rules: rules,
                        ),
                      );
                    },
              child: Text(context.l10n.select(zh: '创建', en: 'Create')),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    description.dispose();
    if (result == null) return;
    try {
      final albumId = await widget.backend.createAlbum(
        result.name,
        description: result.description,
        smart: result.smart,
      );
      if (result.smart) {
        await widget.backend.replaceAlbumRules(albumId, result.rules);
      }
      _reload();
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to create album',
        error,
        stackTrace,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '创建相册失败：$error',
            en: 'Failed to create album: $error',
          ),
          error: true,
        ),
      );
    }
  }

  Future<void> _showAlbumMenu(AlbumSummary album, Offset position) async {
    if (album.systemKey != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '默认“收藏”相册不可编辑。',
            en: 'The default Favorites album cannot be edited.',
          ),
        ),
      );
      return;
    }
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<_AlbumAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: _AlbumAction.rename,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.edit_outlined),
            title: Text(context.l10n.select(zh: '编辑相册', en: 'Edit album')),
          ),
        ),
        PopupMenuItem(
          value: _AlbumAction.toggleSmart,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              album.albumType == 'smart'
                  ? Icons.photo_album_outlined
                  : Icons.auto_awesome_rounded,
            ),
            title: Text(
              album.albumType == 'smart'
                  ? context.l10n.select(
                      zh: '转换为普通相册',
                      en: 'Convert to regular album',
                    )
                  : context.l10n.select(
                      zh: '转换为自动相册',
                      en: 'Convert to smart album',
                    ),
            ),
          ),
        ),
        if (album.albumType == 'smart')
          PopupMenuItem(
            value: _AlbumAction.editRules,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.rule_rounded),
              title: Text(
                context.l10n.select(zh: '编辑自动规则', en: 'Edit smart rules'),
              ),
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _AlbumAction.delete,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.delete_outline_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              context.l10n.select(zh: '删除相册', en: 'Delete album'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _AlbumAction.rename:
        await _renameAlbum(album);
        return;
      case _AlbumAction.toggleSmart:
        await _toggleAlbumType(album);
        return;
      case _AlbumAction.editRules:
        await _editAlbumRules(album);
        return;
      case _AlbumAction.delete:
        await _deleteAlbum(album);
        return;
    }
  }

  Future<void> _renameAlbum(AlbumSummary album) async {
    final draft = await _promptAlbumDetails(album);
    if (draft == null ||
        (draft.name == album.name && draft.description == album.description)) {
      return;
    }
    if (!mounted) return;
    final success = context.l10n.select(
      zh: '相册信息已更新。',
      en: 'Album details updated.',
    );
    await _runAlbumAction(
      () => widget.backend.updateAlbum(
        album.id,
        draft.name,
        description: draft.description,
        smart: album.albumType == 'smart',
      ),
      success: success,
    );
  }

  Future<void> _toggleAlbumType(AlbumSummary album) async {
    final toSmart = album.albumType != 'smart';
    if (toSmart) {
      final rules = await _showRuleEditor(albumId: album.id);
      if (rules == null || !mounted) return;
      await _runAlbumAction(
        () async {
          await widget.backend.updateAlbum(
            album.id,
            album.name,
            description: album.description,
            smart: true,
          );
          await widget.backend.replaceAlbumRules(album.id, rules);
        },
        success: context.l10n.select(
          zh: '已转换为自动相册。',
          en: 'Converted to a smart album.',
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          context.l10n.select(
            zh: '转换为普通相册？',
            en: 'Convert to a regular album?',
          ),
        ),
        content: Text(
          context.l10n.select(
            zh: '当前符合规则的媒体会固定加入普通相册，自动规则随后移除。图库中的原文件不会受到影响。',
            en: 'Current matches will become fixed members and smart rules will be removed. Library files are not affected.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
          ),
          FilledButton(
            key: const Key('confirm-convert-regular-album'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.select(zh: '转换', en: 'Convert')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runAlbumAction(
      () => widget.backend.updateAlbum(
        album.id,
        album.name,
        description: album.description,
        smart: false,
      ),
      success: context.l10n.select(
        zh: '已转换为普通相册。',
        en: 'Converted to a regular album.',
      ),
    );
  }

  Future<void> _editAlbumRules(AlbumSummary album) async {
    final rules = await _showRuleEditor(albumId: album.id);
    if (rules == null || !mounted) return;
    await _runAlbumAction(
      () => widget.backend.replaceAlbumRules(album.id, rules),
      success: context.l10n.select(
        zh: '自动相册规则已更新。',
        en: 'Smart album rules updated.',
      ),
    );
  }

  Future<void> _deleteAlbum(AlbumSummary album) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.select(zh: '删除相册？', en: 'Delete album?')),
        content: Text(
          context.l10n.select(
            zh: '将删除相册“${album.name}”及其成员关系，但不会删除图库中的任何图片或视频。',
            en: 'This deletes “${album.name}” and its membership links, but no photos or videos in the library.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
          ),
          FilledButton(
            key: const Key('confirm-delete-album'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.select(zh: '删除', en: 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runAlbumAction(
      () => widget.backend.deleteAlbum(album.id),
      success: context.l10n.select(zh: '相册已删除。', en: 'Album deleted.'),
    );
  }

  Future<_AlbumDraft?> _promptAlbumDetails(AlbumSummary album) {
    final name = TextEditingController(text: album.name);
    final description = TextEditingController(text: album.description);
    var valid = album.name.trim().isNotEmpty;
    return showDialog<_AlbumDraft>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.l10n.select(zh: '编辑相册', en: 'Edit album')),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('rename-album-field'),
                  controller: name,
                  autofocus: true,
                  maxLength: 80,
                  decoration: InputDecoration(
                    labelText: context.l10n.select(
                      zh: '相册名称',
                      en: 'Album name',
                    ),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (value) =>
                      setDialogState(() => valid = value.trim().isNotEmpty),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('edit-album-description-field'),
                  controller: description,
                  maxLength: 160,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: context.l10n.select(
                      zh: '相册描述（可选）',
                      en: 'Album description (optional)',
                    ),
                    alignLabelWithHint: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              key: const Key('confirm-rename-album'),
              onPressed: !valid
                  ? null
                  : () => Navigator.pop(
                      context,
                      _AlbumDraft(
                        name: name.text.trim(),
                        description: description.text.trim(),
                        smart: album.albumType == 'smart',
                        rules: const [],
                      ),
                    ),
              child: Text(context.l10n.select(zh: '保存', en: 'Save')),
            ),
          ],
        ),
      ),
    );
  }

  Future<List<AlbumRule>?> _showRuleEditor({
    required int? albumId,
    List<AlbumRule> initialRules = const [],
  }) => showDialog<List<AlbumRule>>(
    context: context,
    builder: (context) => _SmartAlbumRuleEditorDialog(
      backend: widget.backend,
      albumId: albumId,
      initialRules: initialRules,
    ),
  );

  Future<void> _runAlbumAction(
    Future<void> Function() action, {
    required String success,
  }) async {
    try {
      await action();
      if (!mounted) return;
      _reload();
      ScaffoldMessenger.of(context).showSnackBar(_messageSnackBar(success));
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to update album',
        error,
        stackTrace,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '相册操作失败：$error',
            en: 'Album operation failed: $error',
          ),
          error: true,
        ),
      );
    }
  }
}

class _RuleDraft {
  _RuleDraft({
    this.group = 0,
    this.field = 'tag',
    this.operator = 'equals',
    this.value = '',
  });

  factory _RuleDraft.fromRule(AlbumRule rule) => _RuleDraft(
    group: rule.ruleGroup,
    field: rule.field,
    operator: rule.operator_,
    value: rule.value,
  );

  int group;
  String field;
  String operator;
  String value;

  AlbumRule toRule() => AlbumRule(
    ruleGroup: group,
    field: field,
    operator_: operator,
    value: value.trim(),
  );
}

class _AlbumDraft {
  const _AlbumDraft({
    required this.name,
    required this.description,
    required this.smart,
    required this.rules,
  });

  final String name;
  final String description;
  final bool smart;
  final List<AlbumRule> rules;
}

class _SmartAlbumRuleEditorDialog extends StatefulWidget {
  const _SmartAlbumRuleEditorDialog({
    required this.backend,
    required this.albumId,
    this.initialRules = const [],
  });

  final AppBackend backend;
  final int? albumId;
  final List<AlbumRule> initialRules;

  @override
  State<_SmartAlbumRuleEditorDialog> createState() =>
      _SmartAlbumRuleEditorDialogState();
}

class _SmartAlbumRuleEditorDialogState
    extends State<_SmartAlbumRuleEditorDialog> {
  late final Future<List<AlbumRule>> loading = widget.albumId == null
      ? Future.value(List.of(widget.initialRules))
      : widget.backend.listAlbumRules(widget.albumId!);
  final List<_RuleDraft> rules = [];
  bool initialized = false;

  static const fields = ['tag', 'game', 'note', 'type', 'favorite'];
  static const textOperators = [
    'equals',
    'not_equals',
    'contains',
    'not_contains',
    'starts_with',
    'ends_with',
  ];

  @override
  Widget build(BuildContext context) => Dialog(
    key: const Key('smart-album-rule-editor'),
    insetPadding: const EdgeInsets.all(24),
    clipBehavior: Clip.antiAlias,
    child: SizedBox(
      width: 820,
      height: (MediaQuery.sizeOf(context).height - 48)
          .clamp(420.0, 680.0)
          .toDouble(),
      child: FutureBuilder<List<AlbumRule>>(
        future: loading,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ErrorPanel(
              message: context.l10n.select(
                zh: '自动相册规则读取失败：${snapshot.error}',
                en: 'Failed to load smart album rules: ${snapshot.error}',
              ),
              onRetry: () => Navigator.pop(context),
            );
          }
          if (!initialized) {
            initialized = true;
            rules.addAll((snapshot.data ?? const []).map(_RuleDraft.fromRule));
            if (rules.isEmpty) rules.add(_RuleDraft());
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 10, 12),
                child: Row(
                  children: [
                    const Icon(Icons.rule_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.l10n.select(
                              zh: '自动相册规则',
                              en: 'Smart album rules',
                            ),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            context.l10n.select(
                              zh: '同一规则组内为“并且”，不同规则组之间为“或者”。',
                              en: 'Rules in one group use AND; separate groups use OR.',
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: context.l10n.select(zh: '关闭', en: 'Close'),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: rules.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) => _ruleRow(index),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    TextButton.icon(
                      key: const Key('add-smart-album-rule'),
                      onPressed: () => setState(() => rules.add(_RuleDraft())),
                      icon: const Icon(Icons.add_rounded),
                      label: Text(
                        context.l10n.select(zh: '添加规则', en: 'Add rule'),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      key: const Key('save-smart-album-rules'),
                      onPressed:
                          rules.isNotEmpty &&
                              rules.every(
                                (rule) => rule.value.trim().isNotEmpty,
                              )
                          ? () => Navigator.pop(
                              context,
                              rules.map((rule) => rule.toRule()).toList(),
                            )
                          : null,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(
                        context.l10n.select(zh: '保存规则', en: 'Save rules'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _ruleRow(int index) {
    final rule = rules[index];
    final operators = rule.field == 'favorite' || rule.field == 'type'
        ? const ['equals', 'not_equals']
        : textOperators;
    if (!operators.contains(rule.operator)) rule.operator = 'equals';
    return Card(
      key: ValueKey('smart-rule-$index'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 112,
              child: DropdownButtonFormField<int>(
                initialValue: rule.group,
                decoration: InputDecoration(
                  labelText: context.l10n.select(zh: '规则组', en: 'Group'),
                  border: const OutlineInputBorder(),
                ),
                items: List.generate(
                  5,
                  (group) => DropdownMenuItem(
                    value: group,
                    child: Text('${group + 1}'),
                  ),
                ),
                onChanged: (value) => setState(() => rule.group = value ?? 0),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 150,
              child: DropdownButtonFormField<String>(
                initialValue: rule.field,
                decoration: InputDecoration(
                  labelText: context.l10n.select(zh: '字段', en: 'Field'),
                  border: const OutlineInputBorder(),
                ),
                items: fields
                    .map(
                      (field) => DropdownMenuItem(
                        value: field,
                        child: Text(_ruleFieldLabel(context, field)),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() {
                  rule.field = value ?? 'tag';
                  rule.operator = 'equals';
                  rule.value = '';
                }),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 160,
              child: DropdownButtonFormField<String>(
                key: ValueKey('rule-operator-$index-${rule.field}'),
                initialValue: rule.operator,
                decoration: InputDecoration(
                  labelText: context.l10n.select(zh: '条件', en: 'Condition'),
                  border: const OutlineInputBorder(),
                ),
                items: operators
                    .map(
                      (operator) => DropdownMenuItem(
                        value: operator,
                        child: Text(_ruleOperatorLabel(context, operator)),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setState(() => rule.operator = value ?? 'equals'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: _ruleValueInput(index, rule)),
            const SizedBox(width: 4),
            IconButton(
              key: ValueKey('remove-smart-rule-$index'),
              tooltip: context.l10n.select(zh: '删除规则', en: 'Remove rule'),
              onPressed: rules.length == 1
                  ? null
                  : () => setState(() => rules.removeAt(index)),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ruleValueInput(int index, _RuleDraft rule) {
    if (rule.field == 'favorite') {
      return DropdownButtonFormField<String>(
        key: ValueKey('rule-value-$index-favorite'),
        initialValue: rule.value.isEmpty ? null : rule.value,
        decoration: InputDecoration(
          labelText: context.l10n.select(zh: '值', en: 'Value'),
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem(
            value: 'true',
            child: Text(context.l10n.select(zh: '已收藏', en: 'Favorited')),
          ),
          DropdownMenuItem(
            value: 'false',
            child: Text(context.l10n.select(zh: '未收藏', en: 'Not favorited')),
          ),
        ],
        onChanged: (value) => setState(() => rule.value = value ?? ''),
      );
    }
    if (rule.field == 'type') {
      return DropdownButtonFormField<String>(
        key: ValueKey('rule-value-$index-type'),
        initialValue: rule.value.isEmpty ? null : rule.value,
        decoration: InputDecoration(
          labelText: context.l10n.select(zh: '值', en: 'Value'),
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem(
            value: 'image',
            child: Text(context.l10n.select(zh: '图片', en: 'Photo')),
          ),
          DropdownMenuItem(
            value: 'video',
            child: Text(context.l10n.select(zh: '视频', en: 'Video')),
          ),
        ],
        onChanged: (value) => setState(() => rule.value = value ?? ''),
      );
    }
    return TextFormField(
      key: ValueKey('rule-value-$index-${rule.field}'),
      initialValue: rule.value,
      decoration: InputDecoration(
        labelText: context.l10n.select(zh: '匹配值', en: 'Match value'),
        border: const OutlineInputBorder(),
      ),
      onChanged: (value) => setState(() => rule.value = value),
    );
  }
}

String _ruleFieldLabel(BuildContext context, String field) => switch (field) {
  'game' => context.l10n.select(zh: '游戏标签', en: 'Game tag'),
  'note' => context.l10n.select(zh: '备注', en: 'Note'),
  'type' => context.l10n.select(zh: '媒体类型', en: 'Media type'),
  'favorite' => context.l10n.select(zh: '收藏状态', en: 'Favorite'),
  _ => context.l10n.select(zh: '自定义标签', en: 'Custom tag'),
};

String _ruleOperatorLabel(BuildContext context, String operator) =>
    switch (operator) {
      'not_equals' => context.l10n.select(zh: '不等于', en: 'Does not equal'),
      'contains' => context.l10n.select(zh: '包含', en: 'Contains'),
      'not_contains' => context.l10n.select(zh: '不包含', en: 'Does not contain'),
      'starts_with' => context.l10n.select(zh: '开头是', en: 'Starts with'),
      'ends_with' => context.l10n.select(zh: '结尾是', en: 'Ends with'),
      _ => context.l10n.select(zh: '等于', en: 'Equals'),
    };

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.album,
    required this.cover,
    required this.onTap,
    required this.onSecondaryTapDown,
    required this.onThumbnailError,
    this.enableVideoFeatures = true,
  });

  final AlbumSummary album;
  final Future<List<MediaAsset>> cover;
  final VoidCallback onTap;
  final GestureTapDownCallback? onSecondaryTapDown;
  final Future<void> Function(Object error, StackTrace stackTrace)
  onThumbnailError;
  final bool enableVideoFeatures;

  @override
  Widget build(BuildContext context) => Card(
    key: ValueKey('album-card-${album.id}'),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      onSecondaryTapDown: onSecondaryTapDown,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<List<MediaAsset>>(
            future: cover,
            builder: (context, snapshot) {
              final asset = snapshot.data?.firstOrNull;
              if (asset == null) {
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: album.systemKey == 'favorites'
                          ? const [Color(0xffffd9cc), Color(0xfffff5d8)]
                          : const [Color(0xff5976ae), Color(0xffb7c9eb)],
                    ),
                  ),
                  child: Icon(
                    album.systemKey == 'favorites'
                        ? Icons.favorite_rounded
                        : Icons.photo_album_rounded,
                    size: 46,
                    color: Colors.white70,
                  ),
                );
              }
              return KeyedSubtree(
                key: ValueKey('album-cover-${album.id}-${asset.id}'),
                child: _MediaPreview(
                  asset: asset,
                  enableVideoFeatures: enableVideoFeatures,
                  onVideoThumbnailError: onThumbnailError,
                ),
              );
            },
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xcc111827)],
                stops: [0.35, 1],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 15,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (album.systemKey == 'favorites') ...[
                      const Icon(
                        Icons.favorite_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 7),
                    ],
                    Expanded(
                      child: Text(
                        _albumDisplayName(context, album),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (album.description.trim().isNotEmpty) ...[
                  Text(
                    album.description.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 3),
                ],
                Text(
                  context.l10n.select(
                    zh: '${album.mediaCount} 个媒体 · ${album.albumType == 'smart' ? '自动相册' : '普通相册'}',
                    en: '${album.mediaCount} media · ${album.albumType == 'smart' ? 'Smart album' : 'Regular album'}',
                  ),
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class TransferPage extends StatefulWidget {
  const TransferPage({
    super.key,
    required this.backend,
    required this.sync,
    required this.settings,
    required this.onImportComplete,
    this.onNintendoAccountChanged,
    this.enableVideoFeatures = true,
    this.enableMtpDetection = true,
  });
  final AppBackend backend;
  final SyncController sync;
  final SettingsController settings;
  final VoidCallback onImportComplete;
  final Future<void> Function()? onNintendoAccountChanged;
  final bool enableVideoFeatures;
  final bool enableMtpDetection;

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage>
    with SingleTickerProviderStateMixin {
  late final TabController tabs = TabController(length: 3, vsync: this);
  final TextEditingController callbackUrl = TextEditingController();
  final TextEditingController customGameName = TextEditingController();
  bool importing = false;
  bool loginBusy = false;
  bool completingLogin = false;
  bool addingAccount = false;
  bool? signedIn;
  NintendoAccountProfile? accountProfile;
  List<NintendoAccountProfile> accounts = const [];
  Map<String, SyncRuntimeState> accountSyncHistories = const {};
  String? selectedAccountId;
  ImportSummary? importSummary;
  Object? importError;
  Object? mtpDetectionError;
  List<NintendoMtpDevice> mtpDevices = const [];
  bool mtpScanning = false;
  bool mtpIndexing = false;
  NintendoMtpProgress? mtpProgress;
  _MtpSelectionStats? mtpSelectionStats;
  List<String> customImportPaths = const [];
  List<GameTagSummary> customGameTags = const [];
  bool customImporting = false;
  ImportSummary? customImportSummary;
  Object? customImportError;
  SyncState? _lastSyncState;

  @override
  void initState() {
    super.initState();
    tabs.addListener(_handleTransferTabChanged);
    _lastSyncState = widget.sync.state;
    widget.sync.addListener(_handleSyncStateChanged);
    unawaited(_loadAccountState());
    unawaited(_loadCustomGameTags());
    unawaited(widget.sync.refreshScheduleStatus());
  }

  void _handleTransferTabChanged() {
    if (widget.enableMtpDetection &&
        tabs.index == 1 &&
        !tabs.indexIsChanging &&
        Platform.isWindows) {
      unawaited(_loadMtpDevices());
    }
  }

  void _handleSyncStateChanged() {
    final next = widget.sync.state;
    final finished = next == SyncState.completed || next == SyncState.failed;
    final wasRunning =
        _lastSyncState == SyncState.running ||
        _lastSyncState == SyncState.cancelling;
    if (finished && wasRunning) {
      unawaited(_loadAccountState());
    }
    _lastSyncState = next;
  }

  Future<void> _loadCustomGameTags() async {
    try {
      final values = await widget.backend.listGameTags();
      if (mounted) setState(() => customGameTags = values);
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to load game tags for custom import',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _chooseCustomFiles() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: context.l10n.select(
        zh: '选择要导入的图片和视频',
        en: 'Choose photos and videos to import',
      ),
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'mp4', 'mov'],
    );
    if (result.isEmpty || !mounted) return;
    final selected = result.map((file) => file.path).whereType<String>();
    setState(() {
      customImportPaths = {...customImportPaths, ...selected}.toList();
      customImportSummary = null;
      customImportError = null;
    });
  }

  Future<void> _chooseCustomDirectory() async {
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: context.l10n.select(
        zh: '选择包含媒体的目录',
        en: 'Choose a directory containing media',
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      customImportPaths = {...customImportPaths, selected}.toList();
      customImportSummary = null;
      customImportError = null;
    });
  }

  Future<void> _runCustomImport() async {
    final gameName = customGameName.text.trim();
    if (customImportPaths.isEmpty || gameName.isEmpty || customImporting) {
      return;
    }
    setState(() {
      customImporting = true;
      customImportSummary = null;
      customImportError = null;
    });
    try {
      final summary = await widget.backend.importCustomFiles(
        customImportPaths,
        gameName,
      );
      if (!mounted) return;
      setState(() => customImportSummary = summary);
      widget.onImportComplete();
      await _loadCustomGameTags();
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Custom media import failed',
        error,
        stackTrace,
      );
      if (mounted) setState(() => customImportError = error);
    } finally {
      if (mounted) setState(() => customImporting = false);
    }
  }

  Future<void> _loadAccountState() async {
    List<NintendoAccountProfile> profiles = const [];
    String? selected;
    final histories = <String, SyncRuntimeState>{};
    try {
      profiles = await widget.backend.listNintendoAccounts();
      selected = await widget.backend.selectedNintendoAccountId;
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to load Nintendo accounts',
        error,
        stackTrace,
      );
    }
    if (widget.backend case final SyncHistoryBackend historyBackend) {
      await Future.wait(
        profiles.map((profile) async {
          try {
            histories[profile.accountId] = await historyBackend
                .loadSyncAccountHistory(profile.accountId);
          } catch (error, stackTrace) {
            await widget.backend.logError(
              'Failed to load Nintendo sync history',
              error,
              stackTrace,
            );
          }
        }),
      );
    }
    final profile = profiles
        .where((item) => item.accountId == selected)
        .firstOrNull;
    if (!mounted) return;
    setState(() {
      accounts = profiles;
      accountSyncHistories = histories;
      selectedAccountId = selected;
      signedIn = profiles.isNotEmpty;
      accountProfile = profile ?? profiles.firstOrNull;
    });
  }

  Future<void> _loadMtpDevices() async {
    if (!Platform.isWindows || mtpScanning) return;
    setState(() {
      mtpScanning = true;
      mtpDetectionError = null;
    });
    try {
      final devices = await WindowsNintendoMtp.listDevices();
      if (mounted) setState(() => mtpDevices = devices);
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to enumerate Nintendo MTP devices',
        error,
        stackTrace,
      );
      if (mounted) setState(() => mtpDetectionError = error);
    } finally {
      if (mounted) setState(() => mtpScanning = false);
    }
  }

  Future<void> _prepareMtpImport(NintendoMtpDevice device) async {
    setState(() {
      mtpIndexing = true;
      importError = null;
    });
    try {
      final entries = await WindowsNintendoMtp.scanAlbum(device);
      if (!mounted) return;
      setState(() => mtpIndexing = false);
      if (entries.isEmpty) {
        throw StateError('The Nintendo Album contains no supported media');
      }
      final selected = await showDialog<List<NintendoMtpMediaEntry>>(
        context: context,
        builder: (context) => _NintendoMtpImportDialog(entries: entries),
      );
      if (selected == null || selected.isEmpty || !mounted) return;
      await _importFromMtp(device, selected);
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to prepare Nintendo MTP import',
        error,
        stackTrace,
      );
      if (mounted) setState(() => importError = error);
    } finally {
      if (mounted) setState(() => mtpIndexing = false);
    }
  }

  Future<void> _showUsbGuide(int initialIndex) => showAppImageViewer(
    context,
    initialIndex: initialIndex,
    items: [
      AppImageViewerItem(
        image: const AssetImage('assets/images/import/import_step1.jpg'),
        label: context.l10n.select(zh: 'USB 导入步骤 1', en: 'USB import step 1'),
      ),
      AppImageViewerItem(
        image: const AssetImage('assets/images/import/import_step2.jpg'),
        label: context.l10n.select(zh: 'USB 导入步骤 2', en: 'USB import step 2'),
      ),
    ],
  );

  Future<void> _showLoginGuide() => showAppImageViewer(
    context,
    items: [
      AppImageViewerItem(
        image: const AssetImage('assets/images/nintendo/nso_login_help.png'),
        label: context.l10n.select(
          zh: '右键“选择此人”并复制链接地址',
          en: 'Right-click “Select this person” and copy the link address',
        ),
      ),
    ],
  );

  Future<void> _importFromMtp(
    NintendoMtpDevice device,
    List<NintendoMtpMediaEntry> entries,
  ) async {
    NintendoMtpStagingResult? staged;
    setState(() {
      importing = true;
      importSummary = null;
      importError = null;
      mtpProgress = const NintendoMtpProgress(completed: 0, total: 0);
      mtpSelectionStats = _MtpSelectionStats.fromEntries(entries);
    });
    try {
      staged = await WindowsNintendoMtp.stageAlbum(
        device,
        entries: entries,
        onProgress: (progress) {
          if (mounted) setState(() => mtpProgress = progress);
        },
      );
      final summary = await widget.backend.importMtpFiles(
        staged.files,
        device.name,
      );
      if (!mounted) return;
      setState(() => importSummary = summary);
      widget.onImportComplete();
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Nintendo MTP import failed',
        error,
        stackTrace,
      );
      if (mounted) setState(() => importError = error);
    } finally {
      if (staged != null && await staged.directory.exists()) {
        await staged.directory.delete(recursive: true);
      }
      if (mounted) {
        setState(() {
          importing = false;
          mtpProgress = null;
        });
      }
    }
  }

  @override
  void dispose() {
    widget.sync.removeListener(_handleSyncStateChanged);
    tabs.removeListener(_handleTransferTabChanged);
    tabs.dispose();
    callbackUrl.dispose();
    customGameName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: context.l10n.select(zh: '导入与同步', en: 'Sync & Import'),
    subtitle: context.l10n.select(
      zh: 'Nintendo 云端同步、Switch USB 与自定义导入统一管理',
      en: 'Manage Nintendo sync, Switch USB, and custom imports together',
    ),
    child: Column(
      children: [
        TabBar(
          controller: tabs,
          tabs: [
            Tab(
              text: context.l10n.select(zh: 'Nintendo 同步', en: 'Nintendo Sync'),
            ),
            Tab(
              text: context.l10n.select(zh: 'USB 导入', en: 'USB Import'),
            ),
            Tab(
              text: context.l10n.select(zh: '自定义导入', en: 'Custom Import'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 500,
          child: TabBarView(
            controller: tabs,
            children: [
              AnimatedBuilder(
                animation: widget.sync,
                builder: (context, _) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: ListView(
                      key: const Key('nintendo-sync-scroll'),
                      children: [
                        if (accounts.isEmpty)
                          Row(
                            children: [
                              const _NintendoAccountAvatar(
                                connected: false,
                                profile: null,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                context.l10n.select(
                                  zh: '尚未连接 Nintendo Account',
                                  en: 'No Nintendo Account connected',
                                ),
                                key: const Key('nintendo-account-display-name'),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          )
                        else ...[
                          Text(
                            context.l10n.select(
                              zh: 'Nintendo Account · 已连接 ${accounts.length} 个账号',
                              en: 'Nintendo Account · ${accounts.length} connected',
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (final profile in accounts)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _NintendoSyncAccountTile(
                                key: ValueKey(
                                  'sync-account-${profile.accountId}',
                                ),
                                profile: profile,
                                history:
                                    accountSyncHistories[profile.accountId],
                                selected:
                                    profile.accountId == selectedAccountId,
                                enabled:
                                    !loginBusy &&
                                    widget.sync.state != SyncState.running &&
                                    widget.sync.state != SyncState.cancelling,
                                onSelect: () =>
                                    _selectAccount(profile.accountId),
                                onAvatarTap:
                                    profile.avatarBytes?.isNotEmpty == true
                                    ? () => _showAvatar(profile)
                                    : null,
                              ),
                            ),
                        ],
                        if (signedIn == true) ...[
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              OutlinedButton.icon(
                                key: const Key('add-nintendo-account'),
                                onPressed: loginBusy ? null : _beginLogin,
                                icon: const Icon(
                                  Icons.person_add_alt_1_rounded,
                                ),
                                label: Text(
                                  context.l10n.select(
                                    zh: '添加账号',
                                    en: 'Add account',
                                  ),
                                ),
                              ),
                              TextButton.icon(
                                key: const Key('remove-nintendo-account'),
                                onPressed: loginBusy ? null : _signOut,
                                icon: const Icon(Icons.person_remove_outlined),
                                label: Text(
                                  context.l10n.select(
                                    zh: '移除当前账号',
                                    en: 'Remove current account',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 18),
                        if (signedIn != true || addingAccount) ...[
                          Text(
                            context.l10n.select(
                              zh: '点击登录后会打开 Nintendo Account 页面。完成登录后，将浏览器的“选择此人”按钮的地址完整复制到下方。',
                              en: 'After signing in, copy the complete link address of the browser’s “Select this person” button below.',
                            ),
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 420),
                              child: InkWell(
                                key: const Key('nintendo-login-help-image'),
                                borderRadius: BorderRadius.circular(14),
                                onTap: _showLoginGuide,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: AspectRatio(
                                    aspectRatio: 16 / 9,
                                    child: Image.asset(
                                      'assets/images/nintendo/nso_login_help.png',
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FilledButton.tonalIcon(
                              onPressed: loginBusy ? null : _beginLogin,
                              icon: const Icon(Icons.open_in_browser_outlined),
                              label: Text(
                                context.l10n.select(
                                  zh: '打开登录页面',
                                  en: 'Open sign-in page',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: callbackUrl,
                            decoration: InputDecoration(
                              labelText: context.l10n.select(
                                zh: 'Nintendo 登录回调地址',
                                en: 'Nintendo sign-in callback URL',
                              ),
                              hintText: 'npf71b963c1b7b6d119://auth#session_token_code=...',
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              key: const Key('login-nintendo-account'),
                              onPressed: loginBusy ? null : _completeLogin,
                              icon: completingLogin
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        key: Key('nintendo-login-progress'),
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.login_rounded),
                              label: Text(
                                completingLogin
                                    ? context.l10n.select(
                                        zh: '登录中',
                                        en: 'Signing in',
                                      )
                                    : context.l10n.select(
                                        zh: '登录',
                                        en: 'Sign in',
                                      ),
                              ),
                            ),
                          ),
                        ],
                        if (signedIn != true) ...[
                          const SizedBox(height: 20),
                          _SyncPolicyPanel(
                            controller: widget.settings,
                            sync: widget.sync,
                          ),
                        ],
                        if (signedIn == true) ...[
                          if (addingAccount) const Divider(height: 32),
                          Text(_syncText(context, widget.sync)),
                          const SizedBox(height: 18),
                          if (widget.sync.state == SyncState.running ||
                              widget.sync.state == SyncState.cancelling ||
                              widget.sync.state == SyncState.completed) ...[
                            LinearProgressIndicator(
                              key: const Key('nso-sync-progress'),
                              value: _syncProgressValue(widget.sync.progress),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _syncProgressText(context, widget.sync.progress),
                              key: const Key('nso-sync-progress-label'),
                            ),
                          ],
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            onPressed: widget.sync.state == SyncState.cancelling
                                ? null
                                : widget.sync.state == SyncState.running
                                ? widget.sync.cancel
                                : _runSync,
                            icon: Icon(
                              widget.sync.state == SyncState.running ||
                                      widget.sync.state == SyncState.cancelling
                                  ? Icons.close
                                  : Icons.sync,
                            ),
                            label: Text(
                              widget.sync.state == SyncState.cancelling
                                  ? context.l10n.select(
                                      zh: '正在取消…',
                                      en: 'Cancelling…',
                                    )
                                  : widget.sync.state == SyncState.running
                                  ? context.l10n.select(
                                      zh: '取消同步',
                                      en: 'Cancel sync',
                                    )
                                  : context.l10n.select(
                                      zh: '立即同步',
                                      en: 'Sync now',
                                    ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          _SyncPolicyPanel(
                            controller: widget.settings,
                            sync: widget.sync,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: ListView(
                    children: [
                      Icon(
                        Icons.create_new_folder_outlined,
                        size: 54,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        context.l10n.select(
                          zh: '从 Switch 通过 USB 导入',
                          en: 'Import from Switch over USB',
                        ),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.l10n.select(
                          zh: '连接 Nintendo Switch 或 Nintendo Switch 2 后，软件会自动检测媒体设备。',
                          en: 'Connect a Nintendo Switch or Nintendo Switch 2 and the app will detect the media device automatically.',
                        ),
                      ),
                      const SizedBox(height: 18),
                      if (importing) ...[
                        LinearProgressIndicator(
                          value: mtpProgress == null || mtpProgress!.total == 0
                              ? null
                              : mtpProgress!.completed / mtpProgress!.total,
                        ),
                        if (mtpProgress != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            mtpProgress!.total == 0
                                ? context.l10n.select(
                                    zh: '正在读取 Nintendo 相册…',
                                    en: 'Reading the Nintendo Album…',
                                  )
                                : context.l10n.select(
                                    zh: '正在从媒体设备复制 ${mtpProgress!.completed} / ${mtpProgress!.total}',
                                    en: 'Copying ${mtpProgress!.completed} / ${mtpProgress!.total} from the media device',
                                  ),
                          ),
                        ],
                      ],
                      if (Platform.isWindows) ...[
                        const SizedBox(height: 18),
                        Text(
                          context.l10n.select(
                            zh: '请按下图在 Switch 或 Switch 2 中开启 USB 媒体管理并使用 USB 线连接电脑（Switch 2 需要连接主机下方 Type-C 接口）。',
                            en: 'Follow the steps below to enable USB media management on Switch or Switch 2, then connect it to this computer with a USB cable. Switch 2 must use the lower Type-C port.',
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 14,
                          runSpacing: 14,
                          children: [
                            _ImportGuideImage(
                              key: const Key('switch-import-step-1'),
                              asset: 'assets/images/import/import_step1.jpg',
                              step: '1',
                              onTap: () => _showUsbGuide(0),
                            ),
                            _ImportGuideImage(
                              key: const Key('switch-import-step-2'),
                              asset: 'assets/images/import/import_step2.jpg',
                              step: '2',
                              onTap: () => _showUsbGuide(1),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Container(
                          key: const Key('nintendo-mtp-status'),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              if (mtpScanning)
                                const SizedBox.square(
                                  dimension: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                )
                              else
                                Icon(
                                  mtpDevices.isEmpty
                                      ? Icons.usb_off_rounded
                                      : Icons.check_circle_rounded,
                                  color: mtpDevices.isEmpty
                                      ? Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant
                                      : Theme.of(context).colorScheme.primary,
                                ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  mtpScanning
                                      ? context.l10n.select(
                                          zh: '正在检测 Nintendo Switch 媒体设备…',
                                          en: 'Detecting Nintendo Switch media devices…',
                                        )
                                      : mtpDevices.isNotEmpty
                                      ? context.l10n.select(
                                          zh: '已连接：${mtpDevices.first.name}',
                                          en: 'Connected: ${mtpDevices.first.name}',
                                        )
                                      : mtpDetectionError != null
                                      ? context.l10n.select(
                                          zh: '设备检测失败，请检查连接后重试。',
                                          en: 'Device detection failed. Check the connection and try again.',
                                        )
                                      : context.l10n.select(
                                          zh: '尚未检测到 Nintendo Switch 或 Nintendo Switch 2。',
                                          en: 'Nintendo Switch or Nintendo Switch 2 has not been detected yet.',
                                        ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              if (!mtpScanning && mtpDevices.isEmpty)
                                TextButton.icon(
                                  key: const Key('refresh-nintendo-mtp'),
                                  onPressed: _loadMtpDevices,
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: Text(
                                    context.l10n.select(
                                      zh: '重新检测',
                                      en: 'Detect again',
                                    ),
                                  ),
                                ),
                              if (!mtpScanning && mtpDevices.isNotEmpty)
                                FilledButton.icon(
                                  key: const Key('import-nintendo-mtp'),
                                  onPressed: importing || mtpIndexing
                                      ? null
                                      : () =>
                                            _prepareMtpImport(mtpDevices.first),
                                  icon: mtpIndexing
                                      ? const SizedBox.square(
                                          dimension: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.download_rounded),
                                  label: Text(
                                    mtpIndexing
                                        ? context.l10n.select(
                                            zh: '正在读取相册…',
                                            en: 'Reading album…',
                                          )
                                        : context.l10n.select(
                                            zh: '选择并导入',
                                            en: 'Select & import',
                                          ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                      if (!Platform.isWindows) ...[
                        const SizedBox(height: 22),
                        Text(
                          context.l10n.select(
                            zh: '当前平台暂不支持 Nintendo USB 媒体导入。',
                            en: 'Nintendo USB media import is not supported on this platform yet.',
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (importSummary case final summary?) ...[
                        const SizedBox(height: 16),
                        Text(
                          mtpSelectionStats != null
                              ? context.l10n.select(
                                  zh: '${mtpSelectionStats!.games} 个游戏 · ${mtpSelectionStats!.files} 个文件 · ${mtpSelectionStats!.images} 张图片 · ${mtpSelectionStats!.videos} 个视频 · ${_formatByteSize(mtpSelectionStats!.bytes)}；导入 ${summary.imported} · 重复 ${summary.duplicates} · 失败 ${summary.failed}',
                                  en: '${mtpSelectionStats!.games} games · ${mtpSelectionStats!.files} files · ${mtpSelectionStats!.images} photos · ${mtpSelectionStats!.videos} videos · ${_formatByteSize(mtpSelectionStats!.bytes)}; imported ${summary.imported} · duplicates ${summary.duplicates} · failed ${summary.failed}',
                                )
                              : context.l10n.select(
                                  zh: '发现 ${summary.totalFound} · 导入 ${summary.imported} · 重复 ${summary.duplicates} · 失败 ${summary.failed}',
                                  en: 'Found ${summary.totalFound} · Imported ${summary.imported} · Duplicates ${summary.duplicates} · Failed ${summary.failed}',
                                ),
                          key: const Key('import-summary'),
                        ),
                      ],
                      if (importError != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          context.l10n.select(
                            zh: '导入失败：$importError',
                            en: 'Import failed: $importError',
                          ),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: ListView(
                    key: const Key('custom-import-scroll'),
                    children: [
                      Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 54,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        context.l10n.select(
                          zh: '自定义导入图片与视频',
                          en: 'Custom photo and video import',
                        ),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.l10n.select(
                          zh: '选择多个文件，或选择一个目录递归导入其中的全部图片和视频。导入前请为这些媒体统一指定游戏标签。',
                          en: 'Choose multiple files or a directory to recursively import its photos and videos. Assign one game tag before importing.',
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          OutlinedButton.icon(
                            key: const Key('choose-custom-import-files'),
                            onPressed: customImporting
                                ? null
                                : _chooseCustomFiles,
                            icon: const Icon(Icons.file_open_outlined),
                            label: Text(
                              context.l10n.select(
                                zh: '选择多个文件',
                                en: 'Choose files',
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            key: const Key('choose-custom-import-directory'),
                            onPressed: customImporting
                                ? null
                                : _chooseCustomDirectory,
                            icon: const Icon(Icons.folder_open_rounded),
                            label: Text(
                              context.l10n.select(
                                zh: '选择目录',
                                en: 'Choose directory',
                              ),
                            ),
                          ),
                          if (customImportPaths.isNotEmpty)
                            TextButton.icon(
                              key: const Key('clear-custom-import-paths'),
                              onPressed: customImporting
                                  ? null
                                  : () => setState(
                                      () => customImportPaths = const [],
                                    ),
                              icon: const Icon(Icons.clear_all_rounded),
                              label: Text(
                                context.l10n.select(
                                  zh: '清空选择',
                                  en: 'Clear selection',
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (customImportPaths.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          constraints: const BoxConstraints(maxHeight: 120),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerLow,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: customImportPaths.length,
                            itemBuilder: (context, index) {
                              final path = customImportPaths[index];
                              return ListTile(
                                dense: true,
                                leading: Icon(
                                  Directory(path).existsSync()
                                      ? Icons.folder_outlined
                                      : Icons.insert_drive_file_outlined,
                                ),
                                title: Text(
                                  path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: IconButton(
                                  tooltip: context.l10n.select(
                                    zh: '移除',
                                    en: 'Remove',
                                  ),
                                  onPressed: customImporting
                                      ? null
                                      : () => setState(() {
                                          customImportPaths = [
                                            ...customImportPaths.take(index),
                                            ...customImportPaths.skip(
                                              index + 1,
                                            ),
                                          ];
                                        }),
                                  icon: const Icon(Icons.close_rounded),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      TextField(
                        key: const Key('custom-import-game-name'),
                        controller: customGameName,
                        enabled: !customImporting,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: context.l10n.select(
                            zh: '游戏标签',
                            en: 'Game tag',
                          ),
                          helperText: context.l10n.select(
                            zh: '可以选择已有游戏，也可以直接输入新的游戏名称。',
                            en: 'Choose an existing game or type a new game name.',
                          ),
                          prefixIcon: const Icon(Icons.sports_esports_rounded),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      if (customGameTags.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: customGameTags
                              .take(18)
                              .map(
                                (game) => ChoiceChip(
                                  label: Text(game.name),
                                  selected:
                                      customGameName.text.trim() == game.name,
                                  onSelected: customImporting
                                      ? null
                                      : (_) => setState(
                                          () => customGameName.text = game.name,
                                        ),
                                ),
                              )
                              .toList(growable: false),
                        ),
                      ],
                      const SizedBox(height: 18),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          key: const Key('start-custom-import'),
                          onPressed:
                              customImportPaths.isEmpty ||
                                  customGameName.text.trim().isEmpty ||
                                  customImporting
                              ? null
                              : _runCustomImport,
                          icon: customImporting
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download_rounded),
                          label: Text(
                            customImporting
                                ? context.l10n.select(
                                    zh: '正在导入…',
                                    en: 'Importing…',
                                  )
                                : context.l10n.select(
                                    zh: '开始导入',
                                    en: 'Start import',
                                  ),
                          ),
                        ),
                      ),
                      if (customImportSummary case final summary?) ...[
                        const SizedBox(height: 16),
                        Text(
                          context.l10n.select(
                            zh: '发现 ${summary.totalFound} · 导入 ${summary.imported} · 重复 ${summary.duplicates} · 失败 ${summary.failed}',
                            en: 'Found ${summary.totalFound} · Imported ${summary.imported} · Duplicates ${summary.duplicates} · Failed ${summary.failed}',
                          ),
                          key: const Key('custom-import-summary'),
                        ),
                      ],
                      if (customImportError != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          context.l10n.select(
                            zh: '自定义导入失败：$customImportError',
                            en: 'Custom import failed: $customImportError',
                          ),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Future<void> _beginLogin() async {
    setState(() => loginBusy = true);
    try {
      await widget.backend.beginNintendoLogin();
      if (mounted) setState(() => addingAccount = true);
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to open Nintendo sign-in page',
        error,
        stackTrace,
      );
      if (mounted) {
        _showMessage(
          context.l10n.select(
            zh: '无法打开登录页面：$error',
            en: 'Unable to open sign-in page: $error',
          ),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => loginBusy = false);
    }
  }

  Future<void> _completeLogin() async {
    final value = callbackUrl.text.trim();
    if (value.isEmpty) {
      _showMessage(
        context.l10n.select(
          zh: '请先粘贴 Nintendo 登录回调地址',
          en: 'Paste the Nintendo sign-in callback URL first',
        ),
      );
      return;
    }
    setState(() {
      loginBusy = true;
      completingLogin = true;
    });
    try {
      await widget.backend.completeNintendoLogin(value);
      final current = widget.settings.value;
      if (!current.syncPolicy.enabled) {
        await widget.settings.save(
          _copySettings(
            current,
            syncPolicy: SyncPolicy(
              enabled: true,
              activeIntervalMinutes: current.syncPolicy.activeIntervalMinutes,
              sleepAfterHours: current.syncPolicy.sleepAfterHours,
            ),
          ),
        );
      }
      await _loadAccountState();
      if (!mounted) return;
      setState(() => addingAccount = false);
      callbackUrl.clear();
      _showMessage(
        context.l10n.select(
          zh: 'Nintendo Account 已连接',
          en: 'Nintendo Account connected',
        ),
      );
      await widget.onNintendoAccountChanged?.call();
      unawaited(_runSync());
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Nintendo sign-in failed',
        error,
        stackTrace,
      );
      if (mounted) {
        _showMessage(
          context.l10n.select(zh: '登录失败：$error', en: 'Sign-in failed: $error'),
          error: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          loginBusy = false;
          completingLogin = false;
        });
      }
    }
  }

  Future<void> _signOut() async {
    final displayName = accountProfile?.nickname.trim();
    final accountName = displayName?.isNotEmpty == true
        ? displayName!
        : 'Nintendo Account';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          context.l10n.select(zh: '移除当前账号？', en: 'Remove current account?'),
        ),
        content: Text(
          context.l10n.select(
            zh: '将从本机移除 Nintendo Account“$accountName”的登录信息，以后如需同步此账号将需重新登录。已导入图库的图片、视频、标签、备注和相册不会被删除。',
            en: 'This removes the local sign-in information for Nintendo Account “$accountName”. You will need to sign in again to sync this account. Photos, videos, tags, notes, and albums already in the library will not be deleted.',
          ),
        ),
        actions: [
          TextButton(
            key: const Key('cancel-remove-nintendo-account'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
          ),
          FilledButton(
            key: const Key('confirm-remove-nintendo-account'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.select(zh: '移除账号', en: 'Remove account')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => loginBusy = true);
    try {
      await widget.backend.signOut();
      await _loadAccountState();
      await widget.onNintendoAccountChanged?.call();
    } finally {
      if (mounted) setState(() => loginBusy = false);
    }
  }

  Future<void> _selectAccount(String accountId) async {
    setState(() => loginBusy = true);
    try {
      await widget.backend.selectNintendoAccount(accountId);
      if (!mounted) return;
      setState(() {
        selectedAccountId = accountId;
        accountProfile = accounts
            .where((profile) => profile.accountId == accountId)
            .firstOrNull;
      });
      await widget.onNintendoAccountChanged?.call();
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to select Nintendo account $accountId',
        error,
        stackTrace,
      );
      if (mounted) {
        _showMessage(
          context.l10n.select(
            zh: '切换账号失败：$error',
            en: 'Failed to switch account: $error',
          ),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => loginBusy = false);
    }
  }

  Future<void> _runSync() async {
    await widget.sync.run();
    widget.onImportComplete();
  }

  Future<void> _showAvatar(NintendoAccountProfile profile) async {
    final bytes = profile.avatarBytes;
    if (bytes == null || bytes.isEmpty) return;
    await showAppImageViewer(
      context,
      items: [
        AppImageViewerItem(image: MemoryImage(bytes), label: profile.nickname),
      ],
      onSave: (_) => _saveAvatar(profile),
    );
  }

  Future<void> _saveAvatar(NintendoAccountProfile profile) async {
    final bytes = profile.avatarBytes;
    if (bytes == null || bytes.isEmpty) return;
    final png =
        bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47;
    final extension = png ? 'png' : 'jpg';
    try {
      final result = await FilePicker.saveFile(
        fileName: 'nintendo_avatar_${profile.accountId}.$extension',
        bytes: bytes,
        mimeType: png ? 'image/png' : 'image/jpeg',
        dialogTitle: context.l10n.select(
          zh: '另存 Nintendo 头像',
          en: 'Save Nintendo avatar as',
        ),
      );
      if (!mounted || result == null) return;
      _showMessage(context.l10n.select(zh: '头像已保存', en: 'Avatar saved'));
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to save Nintendo account avatar',
        error,
        stackTrace,
      );
      if (mounted) {
        _showMessage(
          context.l10n.select(
            zh: '头像保存失败：$error',
            en: 'Failed to save avatar: $error',
          ),
          error: true,
        );
      }
    }
  }

  void _showMessage(String message, {bool error = false}) {
    ScaffoldMessenger.of(context)
        .showSnackBar(_messageSnackBar(message, error: error));
  }
}

class _MtpSelectionStats {
  const _MtpSelectionStats({
    required this.games,
    required this.files,
    required this.images,
    required this.videos,
    required this.bytes,
  });

  factory _MtpSelectionStats.fromEntries(
    Iterable<NintendoMtpMediaEntry> entries,
  ) {
    final values = entries.toList(growable: false);
    final images = values.where(_isMtpImage).length;
    return _MtpSelectionStats(
      games: values.map((entry) => entry.gameName).toSet().length,
      files: values.length,
      images: images,
      videos: values.length - images,
      bytes: values.fold<int>(0, (sum, entry) => sum + entry.sizeBytes),
    );
  }

  final int games;
  final int files;
  final int images;
  final int videos;
  final int bytes;
}

bool _isMtpImage(NintendoMtpMediaEntry entry) {
  final extension = entry.fileName.split('.').last.toLowerCase();
  return const {'jpg', 'jpeg', 'png', 'webp'}.contains(extension);
}

String _formatByteSize(int bytes) {
  const gibibyte = 1024 * 1024 * 1024;
  const mebibyte = 1024 * 1024;
  if (bytes >= gibibyte) {
    return '${(bytes / gibibyte).toStringAsFixed(2)} GB';
  }
  return '${(bytes / mebibyte).toStringAsFixed(bytes >= 10 * mebibyte ? 1 : 2)} MB';
}

class _NintendoMtpImportDialog extends StatefulWidget {
  const _NintendoMtpImportDialog({required this.entries});

  final List<NintendoMtpMediaEntry> entries;

  @override
  State<_NintendoMtpImportDialog> createState() =>
      _NintendoMtpImportDialogState();
}

class _NintendoMtpImportDialogState extends State<_NintendoMtpImportDialog> {
  late final Map<String, List<NintendoMtpMediaEntry>> folders = () {
    final result = <String, List<NintendoMtpMediaEntry>>{};
    for (final entry in widget.entries) {
      result.putIfAbsent(entry.gameName, () => []).add(entry);
    }
    return Map.fromEntries(
      result.entries.toList()
        ..sort((left, right) => left.key.compareTo(right.key)),
    );
  }();
  late final Set<String> selectedGames = folders.keys.toSet();
  DateTimeRange? range;

  List<NintendoMtpMediaEntry> get selectedEntries => widget.entries
      .where((entry) {
        if (!selectedGames.contains(entry.gameName)) return false;
        final selectedRange = range;
        if (selectedRange == null) return true;
        final capturedAt = entry.capturedAt;
        if (capturedAt == null) return false;
        final date = DateUtils.dateOnly(capturedAt.toLocal());
        return !date.isBefore(DateUtils.dateOnly(selectedRange.start)) &&
            !date.isAfter(DateUtils.dateOnly(selectedRange.end));
      })
      .toList(growable: false);

  Future<void> _pickRange() async {
    final dates = widget.entries
        .map((entry) => entry.capturedAt?.toLocal())
        .whereType<DateTime>()
        .map(DateUtils.dateOnly)
        .toList(growable: false);
    final now = DateTime.now();
    final firstDate = dates.isEmpty
        ? DateTime(2000)
        : dates.reduce((left, right) => left.isBefore(right) ? left : right);
    final lastDate = dates.isEmpty
        ? DateTime(now.year + 1, 12, 31)
        : dates.reduce((left, right) => left.isAfter(right) ? left : right);
    final selected = await showDialog<DateTimeRange>(
      context: context,
      builder: (context) => _CreationDateRangeDialog(
        firstDate: firstDate,
        lastDate: lastDate,
        initialRange: range,
      ),
    );
    if (selected != null && mounted) setState(() => range = selected);
  }

  @override
  Widget build(BuildContext context) {
    final selected = selectedEntries;
    final stats = _MtpSelectionStats.fromEntries(selected);
    final localizations = MaterialLocalizations.of(context);
    return AlertDialog(
      title: Text(
        context.l10n.select(
          zh: '选择要导入的 Switch 媒体',
          en: 'Choose Switch media to import',
        ),
      ),
      content: SizedBox(
        width: 720,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              key: const Key('mtp-selection-summary'),
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                context.l10n.select(
                  zh: '${stats.games} 个游戏 · ${stats.files} 个文件 · ${stats.images} 张图片 · ${stats.videos} 个视频 · ${_formatByteSize(stats.bytes)}',
                  en: '${stats.games} games · ${stats.files} files · ${stats.images} photos · ${stats.videos} videos · ${_formatByteSize(stats.bytes)}',
                ),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const Key('mtp-time-range'),
                  onPressed: _pickRange,
                  icon: const Icon(Icons.date_range_rounded),
                  label: Text(
                    range == null
                        ? context.l10n.select(
                            zh: '全部创建时间',
                            en: 'All creation dates',
                          )
                        : '${localizations.formatMediumDate(range!.start)} — ${localizations.formatMediumDate(range!.end)}',
                  ),
                ),
                if (range != null)
                  TextButton(
                    onPressed: () => setState(() => range = null),
                    child: Text(
                      context.l10n.select(zh: '清除时间范围', en: 'Clear dates'),
                    ),
                  ),
                TextButton(
                  onPressed: () => setState(() {
                    if (selectedGames.length == folders.length) {
                      selectedGames.clear();
                    } else {
                      selectedGames.addAll(folders.keys);
                    }
                  }),
                  child: Text(
                    selectedGames.length == folders.length
                        ? context.l10n.select(zh: '取消全选', en: 'Select none')
                        : context.l10n.select(zh: '选择全部', en: 'Select all'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.select(
                zh: '按游戏文件夹选择；设置时间范围后，无法识别创建时间的文件不会被导入。',
                en: 'Choose game folders. Files without a recognized creation date are excluded when a date range is active.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.separated(
                itemCount: folders.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final folder = folders.entries.elementAt(index);
                  final folderStats = _MtpSelectionStats.fromEntries(
                    folder.value,
                  );
                  return CheckboxListTile(
                    key: ValueKey('mtp-folder-${folder.key}'),
                    value: selectedGames.contains(folder.key),
                    onChanged: (enabled) => setState(() {
                      if (enabled == true) {
                        selectedGames.add(folder.key);
                      } else {
                        selectedGames.remove(folder.key);
                      }
                    }),
                    title: Text(folder.key),
                    subtitle: Text(
                      context.l10n.select(
                        zh: '${folderStats.files} 个文件 · ${folderStats.images} 张图片 · ${folderStats.videos} 个视频 · ${_formatByteSize(folderStats.bytes)}',
                        en: '${folderStats.files} files · ${folderStats.images} photos · ${folderStats.videos} videos · ${_formatByteSize(folderStats.bytes)}',
                      ),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
        ),
        FilledButton.icon(
          key: const Key('confirm-mtp-import'),
          onPressed: selected.isEmpty
              ? null
              : () => Navigator.pop(context, selected),
          icon: const Icon(Icons.download_rounded),
          label: Text(context.l10n.select(zh: '开始导入', en: 'Start import')),
        ),
      ],
    );
  }
}

class _ImportGuideImage extends StatelessWidget {
  const _ImportGuideImage({
    super.key,
    required this.asset,
    required this.step,
    required this.onTap,
  });

  final String asset;
  final String step;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 330,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            context.l10n.select(zh: '步骤 $step', en: 'Step $step'),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 8),
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(asset, fit: BoxFit.cover),
                  const Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: EdgeInsets.all(10),
                      child: CircleAvatar(child: Icon(Icons.zoom_in_rounded)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _SyncPolicyPanel extends StatefulWidget {
  const _SyncPolicyPanel({required this.controller, required this.sync});

  final SettingsController controller;
  final SyncController sync;

  @override
  State<_SyncPolicyPanel> createState() => _SyncPolicyPanelState();
}

class _SyncPolicyPanelState extends State<_SyncPolicyPanel> {
  int? intervalDraft;

  Future<void> _save(AppSettings next) async {
    try {
      await widget.controller.save(next);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '自动同步设置保存失败：$error',
            en: 'Failed to save automatic sync settings: $error',
          ),
          error: true,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.controller, widget.sync]),
    builder: (context, _) {
      final value = widget.controller.value;
      final policy = value.syncPolicy;
      return Container(
        key: const Key('nso-auto-sync-settings'),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    context.l10n.select(
                      zh: 'NSO 自动同步与休眠',
                      en: 'NSO automatic sync & sleep',
                    ),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              context.l10n.select(
                zh: '活跃期按所选周期检查；长时间无新图片视频后降级为休眠期，休眠期每 60 分钟检查一次。',
                en: 'Checks at the selected interval while active. After a long period without new photos or videos, it enters sleep mode and checks every 60 minutes.',
              ),
            ),
            Material(
              color: Colors.transparent,
              child: SwitchListTile(
                key: const Key('nso-auto-sync-enabled'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  context.l10n.select(
                    zh: '启用自动同步策略',
                    en: 'Enable automatic sync policy',
                  ),
                ),
                value: policy.enabled,
                onChanged: widget.controller.saving
                    ? null
                    : (enabled) => _save(
                        _copySettings(
                          value,
                          syncPolicy: SyncPolicy(
                            enabled: enabled,
                            activeIntervalMinutes: policy.activeIntervalMinutes,
                            sleepAfterHours: policy.sleepAfterHours,
                          ),
                        ),
                      ),
              ),
            ),
            Material(
              color: Colors.transparent,
              child: SwitchListTile(
                key: const Key('nso-auto-sync-on-launch'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  context.l10n.select(
                    zh: '启动软件时自动同步',
                    en: 'Sync automatically on app launch',
                  ),
                ),
                subtitle: Text(
                  context.l10n.select(
                    zh: '仅在已有 Nintendo 账号连接时执行一次。',
                    en: 'Runs once only when a Nintendo Account is connected.',
                  ),
                ),
                value: value.autoSyncOnLaunch,
                onChanged: widget.controller.saving
                    ? null
                    : (enabled) => _save(
                        _copySettings(value, autoSyncOnLaunch: enabled),
                      ),
              ),
            ),
            Text(
              context.l10n.select(
                zh: '活跃期每 ${intervalDraft ?? policy.activeIntervalMinutes} 分钟检查',
                en: 'Check every ${intervalDraft ?? policy.activeIntervalMinutes} minutes while active',
              ),
            ),
            Slider(
              key: const Key('nso-auto-sync-interval'),
              value: (intervalDraft ?? policy.activeIntervalMinutes).toDouble(),
              min: 10,
              max: 60,
              divisions: 10,
              label: context.l10n.select(
                zh: '${intervalDraft ?? policy.activeIntervalMinutes} 分钟',
                en: '${intervalDraft ?? policy.activeIntervalMinutes} min',
              ),
              onChanged: widget.controller.saving
                  ? null
                  : (next) => setState(() => intervalDraft = next.round()),
              onChangeEnd: widget.controller.saving
                  ? null
                  : (next) async {
                      await _save(
                        _copySettings(
                          value,
                          syncPolicy: SyncPolicy(
                            enabled: policy.enabled,
                            activeIntervalMinutes: next.round(),
                            sleepAfterHours: policy.sleepAfterHours,
                          ),
                        ),
                      );
                      if (mounted) setState(() => intervalDraft = null);
                    },
            ),
            const SizedBox(height: 6),
            DropdownButtonFormField<int>(
              key: ValueKey('nso-sleep-after-${policy.sleepAfterHours}'),
              initialValue: policy.sleepAfterHours,
              decoration: InputDecoration(
                labelText: context.l10n.select(
                  zh: '连续无更新后进入休眠',
                  en: 'Sleep after no new media',
                ),
                border: const OutlineInputBorder(),
              ),
              items: const [6, 12, 24, 48, 72]
                  .map(
                    (hours) => DropdownMenuItem(
                      value: hours,
                      child: Text(
                        context.l10n.select(
                          zh: '$hours 小时',
                          en: '$hours hours',
                        ),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: widget.controller.saving
                  ? null
                  : (hours) {
                      if (hours == null) return;
                      _save(
                        _copySettings(
                          value,
                          syncPolicy: SyncPolicy(
                            enabled: policy.enabled,
                            activeIntervalMinutes: policy.activeIntervalMinutes,
                            sleepAfterHours: hours,
                          ),
                        ),
                      );
                    },
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.select(
                zh: policy.enabled
                    ? '当前策略：活跃期每 ${policy.activeIntervalMinutes} 分钟检查，连续 ${policy.sleepAfterHours} 小时无更新后进入休眠期，休眠期内每 60 分钟检查一次。'
                    : '当前策略：自动同步已关闭，仍可随时手动同步。',
                en: policy.enabled
                    ? 'Current policy: check every ${policy.activeIntervalMinutes} minutes while active; enter sleep mode after ${policy.sleepAfterHours} hours without updates, then check every 60 minutes.'
                    : 'Current policy: automatic sync is off; manual sync remains available.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (widget.sync.scheduleStatus case final status?) ...[
              const SizedBox(height: 6),
              Text(
                context.l10n.select(
                  zh: status.nextSyncAt == null
                      ? '调度状态：未安排下一次检查'
                      : '调度状态：${status.sleeping ? '休眠期' : '活跃期'} · 下次预计 ${status.nextSyncAt!.toLocal().toString().substring(0, 16)}',
                  en: status.nextSyncAt == null
                      ? 'Schedule: no next check planned'
                      : 'Schedule: ${status.sleeping ? 'sleeping' : 'active'} · next ${status.nextSyncAt!.toLocal().toString().substring(0, 16)}',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      );
    },
  );
}

class _NintendoSyncAccountTile extends StatelessWidget {
  const _NintendoSyncAccountTile({
    super.key,
    required this.profile,
    required this.history,
    required this.selected,
    required this.enabled,
    required this.onSelect,
    required this.onAvatarTap,
  });

  final NintendoAccountProfile profile;
  final SyncRuntimeState? history;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelect;
  final VoidCallback? onAvatarTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colorScheme.primaryContainer.withValues(alpha: .55)
          : colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: enabled && !selected ? onSelect : null,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _NintendoAccountAvatar(
                connected: true,
                profile: profile,
                onTap: onAvatarTap,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.nickname.trim().isEmpty
                          ? context.l10n.select(
                              zh: 'Nintendo 账号',
                              en: 'Nintendo Account',
                            )
                          : profile.nickname,
                      key: selected
                          ? const Key('nintendo-account-display-name')
                          : null,
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _accountSyncHistoryText(context, history),
                      key: Key('sync-history-${profile.accountId}'),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (selected)
                Chip(
                  avatar: const Icon(Icons.check_rounded, size: 16),
                  label: Text(context.l10n.select(zh: '当前', en: 'Selected')),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide.none,
                )
              else
                Icon(
                  Icons.radio_button_unchecked_rounded,
                  color: enabled
                      ? colorScheme.outline
                      : colorScheme.outlineVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _accountSyncHistoryText(
  BuildContext context,
  SyncRuntimeState? history,
) {
  final attempt = history?.latestAttempt;
  if (attempt == null) {
    return context.l10n.select(zh: '尚未同步', en: 'Never synced');
  }
  final time = attempt.attemptedAt.toLocal();
  final timestamp =
      '${time.year}-${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')} '
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
  final result = switch (attempt.status) {
    'success' => context.l10n.select(zh: '成功', en: 'Succeeded'),
    'partial_failure' => context.l10n.select(
      zh: '部分失败',
      en: 'Partially failed',
    ),
    'cancelled' => context.l10n.select(zh: '已取消', en: 'Cancelled'),
    _ => context.l10n.select(zh: '失败', en: 'Failed'),
  };
  return context.l10n.select(
    zh: '$timestamp · $result · 新增 ${attempt.downloaded} · 重复 ${attempt.duplicates} · 失败 ${attempt.failed}',
    en: '$timestamp · $result · New ${attempt.downloaded} · Duplicates ${attempt.duplicates} · Failed ${attempt.failed}',
  );
}

class _NintendoAccountAvatar extends StatelessWidget {
  const _NintendoAccountAvatar({
    required this.connected,
    required this.profile,
    this.onTap,
  });

  final bool connected;
  final NintendoAccountProfile? profile;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bytes = profile?.avatarBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return InkResponse(
        onTap: onTap,
        radius: 28,
        child: ClipOval(
          child: Image.memory(
            bytes,
            key: const Key('nintendo-account-avatar'),
            width: 46,
            height: 46,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _fallback(context),
          ),
        ),
      );
    }
    return _fallback(context);
  }

  Widget _fallback(BuildContext context) => CircleAvatar(
    radius: 23,
    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
    child: Icon(
      connected ? Icons.verified_user_outlined : Icons.account_circle_outlined,
      color: Theme.of(context).colorScheme.onPrimaryContainer,
    ),
  );
}

double? _syncProgressValue(SyncProgress? progress) {
  if (progress == null || progress.totalItems == BigInt.zero) return null;
  final processed = progress.processedItems.toDouble();
  final total = progress.totalItems.toDouble();
  return (processed / total).clamp(0.0, 1.0);
}

String _syncProgressText(BuildContext context, SyncProgress? progress) {
  if (progress == null || progress.totalItems == BigInt.zero) {
    return context.l10n.select(
      zh: '正在读取 Nintendo 相册列表…',
      en: 'Reading the Nintendo album list…',
    );
  }
  return context.l10n.select(
    zh: '已同步 ${progress.synchronizedItems} / ${progress.totalItems} · 已处理 ${progress.processedItems} · 失败 ${progress.failedItems}',
    en: 'Synced ${progress.synchronizedItems} / ${progress.totalItems} · Processed ${progress.processedItems} · Failed ${progress.failedItems}',
  );
}

String _syncText(BuildContext context, SyncController controller) {
  final summary = controller.summary;
  if (summary != null) {
    return context.l10n.select(
      zh: '新增 ${summary.downloaded} · 重复 ${summary.duplicates} · 已存在 ${summary.skippedRemote} · 失败 ${summary.failed}',
      en: 'New ${summary.downloaded} · Duplicates ${summary.duplicates} · Existing ${summary.skippedRemote} · Failed ${summary.failed}',
    );
  }
  if (controller.error != null) {
    return context.l10n.select(
      zh: '同步失败：${controller.error}',
      en: 'Sync failed: ${controller.error}',
    );
  }
  return switch (controller.state) {
    SyncState.idle => context.l10n.select(
      zh: '尚未运行同步',
      en: 'Sync has not run yet',
    ),
    SyncState.running => context.l10n.select(zh: '正在同步…', en: 'Syncing…'),
    SyncState.completed => context.l10n.select(zh: '同步完成', en: 'Sync complete'),
    SyncState.failed => context.l10n.select(zh: '同步失败', en: 'Sync failed'),
    SyncState.cancelling => context.l10n.select(zh: '正在取消…', en: 'Cancelling…'),
  };
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.backend,
    required this.onTagsChanged,
    this.onCheckForUpdates,
  });
  final SettingsController controller;
  final AppBackend backend;
  final VoidCallback onTagsChanged;
  final Future<void> Function()? onCheckForUpdates;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  late final TextEditingController proxy;
  int? _columnsDraft;
  int? _rowsDraft;
  bool movingLibrary = false;
  late Future<String> appVersion;

  @override
  void initState() {
    super.initState();
    proxy = TextEditingController(text: widget.controller.value.proxyUrl);
    appVersion = loadApplicationVersion();
  }

  @override
  void dispose() {
    proxy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: context.l10n.select(zh: '设置', en: 'Settings'),
    subtitle: context.l10n.select(
      zh: '外观、网络、存储与应用信息',
      en: 'Appearance, network, storage, and app information',
    ),
    child: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final value = widget.controller.value;
        return Column(
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.select(
                        zh: '外观与布局',
                        en: 'Appearance & layout',
                      ),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      key: ValueKey(value.language),
                      initialValue: value.language,
                      decoration: InputDecoration(
                        labelText: context.l10n.select(
                          zh: '界面语言',
                          en: 'Interface language',
                        ),
                        border: const OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                        DropdownMenuItem(value: 'en', child: Text('English')),
                      ],
                      onChanged: widget.controller.saving
                          ? null
                          : (language) {
                              if (language == null) return;
                              _save(_copySettings(value, language: language));
                            },
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children:
                          {
                            'ocean': const Color(0xff5577e8),
                            'teal': const Color(0xff159b88),
                            'orange': const Color(0xffdf754d),
                            'purple': const Color(0xff8562ca),
                            'rose': const Color(0xffcf5d82),
                          }.entries.map((entry) {
                            final selected = value.theme == entry.key;
                            return Tooltip(
                              message: _themeLabel(context, entry.key),
                              child: InkWell(
                                onTap: widget.controller.saving
                                    ? null
                                    : () => _save(
                                        _copySettings(value, theme: entry.key),
                                      ),
                                customBorder: const CircleBorder(),
                                child: Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: entry.value,
                                    border: Border.all(
                                      color: selected
                                          ? Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                          : Colors.transparent,
                                      width: 3,
                                    ),
                                  ),
                                  child: selected
                                      ? const Icon(
                                          Icons.check,
                                          color: Colors.white,
                                        )
                                      : null,
                                ),
                              ),
                            );
                          }).toList(),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      context.l10n.select(
                        zh: '每行 ${_columnsDraft ?? value.galleryColumns} 个媒体',
                        en: '${_columnsDraft ?? value.galleryColumns} media per row',
                      ),
                    ),
                    Slider(
                      key: const Key('gallery-columns-slider'),
                      value: (_columnsDraft ?? value.galleryColumns).toDouble(),
                      min: 2,
                      max: 7,
                      divisions: 5,
                      label: '${_columnsDraft ?? value.galleryColumns}',
                      onChanged: widget.controller.saving
                          ? null
                          : (next) =>
                                setState(() => _columnsDraft = next.round()),
                      onChangeEnd: widget.controller.saving
                          ? null
                          : (next) async {
                              await _save(
                                _copySettings(
                                  value,
                                  galleryColumns: next.round(),
                                ),
                              );
                              if (mounted) setState(() => _columnsDraft = null);
                            },
                    ),
                    if (!_isDesktop) ...[
                      Text(
                        context.l10n.select(
                          zh: '纵向预览 ${_rowsDraft ?? value.galleryRows} 行',
                          en: 'Preview ${_rowsDraft ?? value.galleryRows} rows',
                        ),
                      ),
                      Slider(
                        key: const Key('gallery-rows-slider'),
                        value: (_rowsDraft ?? value.galleryRows).toDouble(),
                        min: 2,
                        max: 8,
                        divisions: 6,
                        label: '${_rowsDraft ?? value.galleryRows}',
                        onChanged: widget.controller.saving
                            ? null
                            : (next) =>
                                  setState(() => _rowsDraft = next.round()),
                        onChangeEnd: widget.controller.saving
                            ? null
                            : (next) async {
                                await _save(
                                  _copySettings(
                                    value,
                                    galleryRows: next.round(),
                                  ),
                                );
                                if (mounted) setState(() => _rowsDraft = null);
                              },
                      ),
                    ],
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        context.l10n.select(
                          zh: '显示备注摘要',
                          en: 'Show note previews',
                        ),
                      ),
                      value: value.showNotePreview,
                      onChanged: widget.controller.saving
                          ? null
                          : (enabled) => _save(
                              _copySettings(value, showNotePreview: enabled),
                            ),
                    ),
                    SwitchListTile(
                      key: const Key('compact-tag-display'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        context.l10n.select(
                          zh: '标签紧凑展示',
                          en: 'Compact tag display',
                        ),
                      ),
                      subtitle: Text(
                        context.l10n.select(
                          zh: '开启后，游戏标签与自定义标签会在同一行排列。',
                          en: 'Show game and custom tags in the same row.',
                        ),
                      ),
                      value: value.compactTagDisplay,
                      onChanged: widget.controller.saving
                          ? null
                          : (enabled) => _save(
                              _copySettings(value, compactTagDisplay: enabled),
                            ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        context.l10n.select(
                          zh: '显示游戏硬性标签',
                          en: 'Show game tags',
                        ),
                      ),
                      value: value.showGameTag,
                      onChanged: widget.controller.saving
                          ? null
                          : (enabled) => _save(
                              _copySettings(value, showGameTag: enabled),
                            ),
                    ),
                    SwitchListTile(
                      key: const Key('auto-play-video'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        context.l10n.select(
                          zh: '打开视频后自动播放',
                          en: 'Autoplay videos when opened',
                        ),
                      ),
                      subtitle: Text(
                        context.l10n.select(
                          zh: '关闭时视频预览会保持暂停，手动点击后才播放。',
                          en: 'When off, video previews stay paused until you press play.',
                        ),
                      ),
                      value: value.autoPlayVideo,
                      onChanged: widget.controller.saving
                          ? null
                          : (enabled) => _save(
                              _copySettings(value, autoPlayVideo: enabled),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.all(20),
                leading: const Icon(Icons.sell_outlined),
                title: Text(
                  context.l10n.select(zh: '标签管理', en: 'Tag management'),
                ),
                subtitle: Text(
                  context.l10n.select(
                    zh: '查看自定义标签的媒体使用数量，并进行重命名或删除。',
                    en: 'Review custom tag usage, rename tags, or delete them.',
                  ),
                ),
                trailing: FilledButton.tonalIcon(
                  key: const Key('open-tag-management'),
                  onPressed: _openTagManagement,
                  icon: const Icon(Icons.tune_rounded),
                  label: Text(
                    context.l10n.select(zh: '管理标签', en: 'Manage tags'),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (Platform.isWindows || Platform.isMacOS) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('close-behavior-${value.closeBehavior}'),
                    initialValue: value.closeBehavior,
                    decoration: InputDecoration(
                      labelText: context.l10n.select(
                        zh: '关闭窗口后的操作',
                        en: 'When closing the window',
                      ),
                      prefixIcon: const Icon(Icons.window_rounded),
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'ask',
                        child: Text(
                          context.l10n.select(zh: '每次询问', en: 'Ask every time'),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'minimize_to_tray',
                        child: Text(
                          context.l10n.select(
                            zh: '最小化到托盘',
                            en: 'Minimize to tray',
                          ),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'exit',
                        child: Text(
                          context.l10n.select(zh: '退出软件', en: 'Exit the app'),
                        ),
                      ),
                    ],
                    onChanged: widget.controller.saving
                        ? null
                        : (behavior) {
                            if (behavior == null) return;
                            _save(
                              _copySettings(value, closeBehavior: behavior),
                            );
                          },
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.select(zh: '网络代理', en: 'Network proxy'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.l10n.select(
                        zh: 'Nintendo、NXAPI、Coral 和媒体下载统一使用。',
                        en: 'Used by Nintendo, NXAPI, Coral, and media downloads.',
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: proxy,
                      decoration: InputDecoration(
                        labelText: context.l10n.select(
                          zh: 'HTTP/HTTPS 代理地址',
                          en: 'HTTP/HTTPS proxy address',
                        ),
                        hintText: 'http://127.0.0.1:7890',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: widget.controller.saving
                            ? null
                            : () async {
                                final text = proxy.text.trim();
                                final saved = await _save(
                                  _copySettings(
                                    value,
                                    proxyUrl: text.isEmpty ? '' : text,
                                  ),
                                );
                                if (saved && mounted) {
                                  ScaffoldMessenger.of(this.context)
                                      .showSnackBar(
                                        _messageSnackBar(
                                          this.context.l10n.select(
                                            zh: text.isEmpty
                                                ? '代理设置已清除，将使用系统网络配置。'
                                                : '代理设置已保存，新的 Nintendo/NXAPI/Coral 请求将使用该地址。',
                                            en: text.isEmpty
                                                ? 'Proxy cleared. System network settings will be used.'
                                                : 'Proxy saved. New Nintendo, NXAPI, and Coral requests will use it.',
                                          ),
                                        ),
                                      );
                                }
                              },
                        child: Text(
                          context.l10n.select(zh: '保存代理', en: 'Save proxy'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.folder_outlined),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l10n.select(
                                  zh: '图片与视频存储位置',
                                  en: 'Photo & video storage location',
                                ),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              SelectableText(value.libraryPath),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.tonalIcon(
                          key: const Key('change-library-path'),
                          onPressed: widget.controller.saving || movingLibrary
                              ? null
                              : () => _changeLibraryPath(value),
                          icon: const Icon(Icons.drive_file_move_outline),
                          label: Text(
                            context.l10n.select(
                              zh: '更改位置',
                              en: 'Change location',
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (movingLibrary) ...[
                      const SizedBox(height: 16),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                      Text(
                        context.l10n.select(
                          zh: '正在复制并校验原件，完成前请勿关闭应用或断开目标磁盘。',
                          en: 'Copying and verifying originals. Keep the app open and the destination drive connected.',
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 10),
                      Text(
                        context.l10n.select(
                          zh: '更改后会先复制并校验全部原件，数据库切换成功后再清理旧位置。',
                          en: 'All originals are copied and verified first. The old location is cleaned only after the database switches successfully.',
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.all(20),
                leading: const Icon(Icons.description_outlined),
                title: Text(
                  context.l10n.select(zh: '应用日志', en: 'Application log'),
                ),
                subtitle: Text(widget.controller.logFilePath),
                trailing: FilledButton.tonalIcon(
                  onPressed: _openLog,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(context.l10n.select(zh: '打开日志', en: 'Open log')),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipOval(
                      child: Image.asset(
                        'assets/images/about/cypas_nya.jpg',
                        width: 76,
                        height: 76,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: const SizedBox(
                            width: 76,
                            height: 76,
                            child: Icon(Icons.person_rounded, size: 38),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.l10n.select(
                              zh: '关于鱿型相册',
                              en: 'About Fresh Album',
                            ),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Cypas_Nya',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  fontFamily: 'SmileySans',
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            context.l10n.select(
                              zh: '小鱿鱿bot作者',
                              en: 'Author of Xiao Youyou Bot',
                            ),
                          ),
                          const SizedBox(height: 8),
                          FutureBuilder<String>(
                            key: const Key('about-app-version'),
                            future: appVersion,
                            builder: (context, snapshot) => Text(
                              context.l10n.select(
                                zh: '版本 ${snapshot.data ?? '—'} · Flutter + Rust',
                                en: 'Version ${snapshot.data ?? '—'} · Flutter + Rust',
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          if (Platform.isWindows &&
                              widget.onCheckForUpdates != null) ...[
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              key: const Key('check-app-updates'),
                              onPressed: widget.onCheckForUpdates,
                              icon: const Icon(Icons.system_update_alt_rounded),
                              label: Text(
                                context.l10n.select(
                                  zh: '检查更新',
                                  en: 'Check for updates',
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('about-xiaoyouyou-link'),
                          onPressed: () => _openAboutLink(
                            'https://qun.qq.com/qunpro/robot/qunshare?robot_appid=102083290&robot_uin=3889005657',
                          ),
                          icon: const Icon(Icons.smart_toy_outlined),
                          label: Text(
                            context.l10n.select(
                              zh: '小鱿鱿bot',
                              en: 'Xiao Youyou Bot',
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const Key('about-feedback-link'),
                          onPressed: () =>
                              _openAboutLink('https://qm.qq.com/q/wXB8g8pxkI'),
                          icon: const Icon(Icons.forum_outlined),
                          label: Text(
                            context.l10n.select(
                              zh: '软件反馈群',
                              en: 'Feedback group',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (widget.controller.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  context.l10n.select(
                    zh: '保存失败：${widget.controller.error}',
                    en: 'Failed to save: ${widget.controller.error}',
                  ),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        );
      },
    ),
  );

  Future<bool> _save(AppSettings value) async {
    try {
      await widget.controller.save(value);
      return true;
    } catch (_) {
      // SettingsController exposes the error in the page.
      return false;
    }
  }

  Future<void> _openAboutLink(String value) async {
    final opened = await launchUrl(
      Uri.parse(value),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(zh: '无法打开链接。', en: 'Unable to open the link.'),
          error: true,
        ),
      );
    }
  }

  Future<void> _openTagManagement() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => _TagManagementDialog(backend: widget.backend),
    );
    if (changed == true) widget.onTagsChanged();
  }

  Future<void> _changeLibraryPath(AppSettings value) async {
    final dialogTitle = context.l10n.select(
      zh: '选择新的图片与视频存储目录',
      en: 'Choose a new photo and video storage directory',
    );
    String? selected;
    try {
      selected = await FilePicker.getDirectoryPath(dialogTitle: dialogTitle);
    } catch (error, stackTrace) {
      await widget.controller.logError(
        'Failed to open the media library directory picker',
        error,
        stackTrace,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '无法打开目录选择器：$error',
            en: 'Unable to open the directory picker: $error',
          ),
          error: true,
        ),
      );
      return;
    }
    if (selected == null || selected == value.libraryPath || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          context.l10n.select(zh: '迁移图片与视频？', en: 'Move photos and videos?'),
        ),
        content: Text(
          context.l10n.select(
            zh: '全部原件将复制到：\n$selected\n\n复制完成后会逐个校验 SHA-256，只有数据库成功切换后才会删除旧位置的文件。迁移期间请勿关闭应用。',
            en: 'All originals will be copied to:\n$selected\n\nEach file is SHA-256 verified. Files at the old location are removed only after the database switches successfully. Keep the app open during migration.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.select(zh: '开始迁移', en: 'Start migration')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => movingLibrary = true);
    try {
      final result = await widget.controller.relocateMediaLibrary(
        _copySettings(value, libraryPath: selected),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '存储位置已更改，共迁移 ${result.movedFiles} 个原件。',
            en: 'Storage location changed. ${result.movedFiles} original file(s) moved.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '迁移失败，原存储位置仍然有效：$error',
            en: 'Migration failed. The original storage location is still active: $error',
          ),
          error: true,
        ),
      );
    } finally {
      if (mounted) setState(() => movingLibrary = false);
    }
  }

  Future<void> _openLog() async {
    try {
      await widget.controller.openLogFile();
    } catch (error, stackTrace) {
      await widget.controller.logError(
        'Failed to open application log',
        error,
        stackTrace,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '无法打开日志：$error',
            en: 'Unable to open log: $error',
          ),
          error: true,
        ),
      );
    }
  }
}

class _TagManagementDialog extends StatefulWidget {
  const _TagManagementDialog({required this.backend});

  final AppBackend backend;

  @override
  State<_TagManagementDialog> createState() => _TagManagementDialogState();
}

class _TagManagementDialogState extends State<_TagManagementDialog>
    with SingleTickerProviderStateMixin {
  late Future<List<TagUsageSummary>> tags = widget.backend.listTagUsage();
  late Future<List<GameTagSummary>> gameTags = widget.backend.listGameTags();
  late Future<List<GameTagAliasSummary>> gameTagAliases = widget.backend
      .listGameTagAliases();
  late final TabController tabController = TabController(length: 2, vsync: this)
    ..addListener(() {
      if (mounted) setState(() {});
    });
  bool changed = false;
  int? busyTagId;
  String? busyGameTag;
  bool creatingTag = false;
  bool mergeBusy = false;
  final Set<int> selectedTagIds = {};
  final Set<String> selectedGameTags = {};

  @override
  void dispose() {
    tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.sizeOf(context).height - 48)
        .clamp(360.0, 640.0)
        .toDouble();
    return Dialog(
      key: const Key('tag-management-dialog'),
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 700,
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 10, 12),
              child: Row(
                children: [
                  const Icon(Icons.sell_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.select(zh: '标签管理', en: 'Tag management'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          context.l10n.select(
                            zh: '自定义标签与游戏标签分开管理；游戏标签支持替换显示名和多选合并。',
                            en: 'Custom and game tags are managed separately; game tags support display-name replacement and merging.',
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.select(zh: '关闭', en: 'Close'),
                    onPressed: () => Navigator.pop(context, changed),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            TabBar(
              controller: tabController,
              tabs: [
                Tab(
                  text: context.l10n.select(zh: '自定义标签', en: 'Custom tags'),
                ),
                Tab(
                  text: context.l10n.select(zh: '游戏标签', en: 'Game tags'),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                controller: tabController,
                children: [_customTagList(), _gameTagList()],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tabController.index == 0
                          ? context.l10n.select(
                              zh: '已选择 ${selectedTagIds.length} 个自定义标签',
                              en: '${selectedTagIds.length} custom tags selected',
                            )
                          : context.l10n.select(
                              zh: '已选择 ${selectedGameTags.length} 个游戏标签',
                              en: '${selectedGameTags.length} game tags selected',
                            ),
                    ),
                  ),
                  if (tabController.index == 0) ...[
                    OutlinedButton.icon(
                      key: const Key('create-custom-tag'),
                      onPressed: creatingTag || mergeBusy || busyTagId != null
                          ? null
                          : _createCustomTag,
                      icon: creatingTag
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add_rounded),
                      label: Text(
                        context.l10n.select(zh: '新增标签', en: 'New tag'),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  FilledButton.icon(
                    key: const Key('merge-selected-tags'),
                    onPressed:
                        mergeBusy ||
                            (tabController.index == 0
                                ? selectedTagIds.length < 2
                                : selectedGameTags.length < 2)
                        ? null
                        : () => _mergeSelected(game: tabController.index == 1),
                    icon: mergeBusy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.merge_rounded),
                    label: Text(
                      context.l10n.select(zh: '合并所选标签', en: 'Merge selected'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _customTagList() => FutureBuilder<List<TagUsageSummary>>(
    future: tags,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) {
        return _ErrorPanel(
          message: context.l10n.select(
            zh: '标签读取失败：${snapshot.error}',
            en: 'Failed to load tags: ${snapshot.error}',
          ),
          onRetry: _reload,
        );
      }
      final values = snapshot.data ?? const [];
      if (values.isEmpty) {
        return Center(
          child: Text(
            context.l10n.select(
              zh: '还没有用户自定义标签。',
              en: 'There are no custom tags yet.',
            ),
          ),
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: values.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final tag = values[index];
          final total = tag.imageCount + tag.videoCount;
          final busy = busyTagId == tag.id;
          return ListTile(
            key: ValueKey('managed-tag-${tag.id}'),
            leading: Checkbox(
              value: selectedTagIds.contains(tag.id),
              onChanged: mergeBusy
                  ? null
                  : (value) => setState(() {
                      value == true
                          ? selectedTagIds.add(tag.id)
                          : selectedTagIds.remove(tag.id);
                    }),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            title: Text(tag.name),
            subtitle: Text(
              context.l10n.select(
                zh: '${tag.imageCount} 张图片 · ${tag.videoCount} 个视频 · 共 $total 项',
                en: '${tag.imageCount} photos · ${tag.videoCount} videos · $total total',
              ),
            ),
            contentPadding: const EdgeInsets.only(left: 12, right: 8),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else ...[
                  IconButton(
                    key: ValueKey('rename-tag-${tag.id}'),
                    tooltip: context.l10n.select(zh: '重命名标签', en: 'Rename tag'),
                    onPressed: busyTagId == null && !mergeBusy
                        ? () => _rename(tag)
                        : null,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    key: ValueKey('delete-tag-${tag.id}'),
                    tooltip: context.l10n.select(zh: '删除标签', en: 'Delete tag'),
                    onPressed: busyTagId == null && !mergeBusy
                        ? () => _delete(tag)
                        : null,
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      );
    },
  );

  Widget _gameTagList() => FutureBuilder<List<GameTagSummary>>(
    future: gameTags,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) {
        return _ErrorPanel(
          message: context.l10n.select(
            zh: '游戏标签读取失败：${snapshot.error}',
            en: 'Failed to load game tags: ${snapshot.error}',
          ),
          onRetry: _reload,
        );
      }
      final values = snapshot.data ?? const [];
      if (values.isEmpty) {
        return Center(
          child: Text(
            context.l10n.select(
              zh: '还没有游戏标签。',
              en: 'There are no game tags yet.',
            ),
          ),
        );
      }
      return FutureBuilder<List<GameTagAliasSummary>>(
        future: gameTagAliases,
        builder: (context, aliasSnapshot) {
          final aliases = aliasSnapshot.data ?? const <GameTagAliasSummary>[];
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: values.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final tag = values[index];
              final total = tag.imageCount + tag.videoCount;
              final busy = busyGameTag == tag.name;
              final sourceNames = aliases
                  .where((alias) => alias.targetName == tag.name)
                  .map((alias) => alias.sourceName)
                  .toList();
              return ListTile(
                key: ValueKey('managed-game-tag-${tag.name}'),
                leading: Checkbox(
                  value: selectedGameTags.contains(tag.name),
                  onChanged: mergeBusy || busyGameTag != null
                      ? null
                      : (value) => setState(() {
                          value == true
                              ? selectedGameTags.add(tag.name)
                              : selectedGameTags.remove(tag.name);
                        }),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                title: Text(tag.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.select(
                        zh: '${tag.imageCount} 张图片 · ${tag.videoCount} 个视频 · 共 $total 项',
                        en: '${tag.imageCount} photos · ${tag.videoCount} videos · $total total',
                      ),
                    ),
                    if (sourceNames.isNotEmpty)
                      Text(
                        context.l10n.select(
                          zh: '原始名称：${sourceNames.join('、')} → ${tag.name}',
                          en: 'Aliases: ${sourceNames.join(', ')} → ${tag.name}',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
                contentPadding: const EdgeInsets.only(left: 12, right: 8),
                trailing: busy
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        key: ValueKey('rename-game-tag-${tag.name}'),
                        tooltip: context.l10n.select(
                          zh: '替换游戏标签显示名',
                          en: 'Replace game tag display name',
                        ),
                        onPressed: busyGameTag == null && !mergeBusy
                            ? () => _renameGameTag(tag)
                            : null,
                        icon: const Icon(Icons.edit_outlined),
                      ),
              );
            },
          );
        },
      );
    },
  );

  void _reload() => setState(() {
    tags = widget.backend.listTagUsage();
    gameTags = widget.backend.listGameTags();
    gameTagAliases = widget.backend.listGameTagAliases();
  });

  Future<void> _createCustomTag() async {
    final name = await _promptTagName(
      title: context.l10n.select(zh: '新增自定义标签', en: 'Create custom tag'),
      fieldKey: const Key('create-tag-field'),
      confirmKey: const Key('confirm-create-tag'),
      confirmLabel: context.l10n.select(zh: '创建', en: 'Create'),
    );
    if (name == null || !mounted) return;
    setState(() => creatingTag = true);
    try {
      await widget.backend.createTag(name);
      if (!mounted) return;
      setState(() {
        changed = true;
        creatingTag = false;
        tags = widget.backend.listTagUsage();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(zh: '已创建标签“$name”。', en: 'Tag “$name” created.'),
        ),
      );
    } catch (error, stackTrace) {
      await widget.backend.logError('Failed to create tag', error, stackTrace);
      if (!mounted) return;
      setState(() => creatingTag = false);
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '标签创建失败：$error',
            en: 'Failed to create tag: $error',
          ),
          error: true,
        ),
      );
    }
  }

  Future<void> _renameGameTag(GameTagSummary tag) async {
    final name = await _promptTagName(
      title: context.l10n.select(
        zh: '替换游戏标签显示名',
        en: 'Replace game tag display name',
      ),
      initialValue: tag.name,
      fieldKey: const Key('rename-game-tag-field'),
      confirmKey: const Key('confirm-rename-game-tag'),
      confirmLabel: context.l10n.select(zh: '保存', en: 'Save'),
    );
    if (name == null || name == tag.name || !mounted) return;
    setState(() => busyGameTag = tag.name);
    try {
      await widget.backend.renameGameTag(tag.name, name);
      if (!mounted) return;
      setState(() {
        changed = true;
        busyGameTag = null;
        selectedGameTags.remove(tag.name);
        gameTags = widget.backend.listGameTags();
        gameTagAliases = widget.backend.listGameTagAliases();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '游戏标签已替换为“$name”，媒体可读名称已同步更新。',
            en: 'Game tag replaced with “$name”; readable media names were updated.',
          ),
        ),
      );
    } catch (error, stackTrace) {
      await widget.backend.logError(
        'Failed to rename game tag',
        error,
        stackTrace,
      );
      if (!mounted) return;
      setState(() => busyGameTag = null);
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '游戏标签重命名失败：$error',
            en: 'Failed to replace game tag: $error',
          ),
          error: true,
        ),
      );
    }
  }

  Future<String?> _promptTagName({
    required String title,
    required Key fieldKey,
    required Key confirmKey,
    required String confirmLabel,
    String initialValue = '',
  }) {
    var draft = initialValue;
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: TextFormField(
            key: fieldKey,
            initialValue: initialValue,
            autofocus: true,
            maxLength: 80,
            decoration: InputDecoration(
              labelText: context.l10n.select(zh: '标签名称', en: 'Tag name'),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) => setDialogState(() => draft = value),
            onFieldSubmitted: (value) {
              final trimmed = value.trim();
              if (trimmed.isNotEmpty) Navigator.pop(context, trimmed);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              key: confirmKey,
              onPressed: draft.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, draft.trim()),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _mergeSelected({required bool game}) async {
    var draft = '';
    final targetName = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            context.l10n.select(
              zh: game ? '合并游戏标签' : '合并自定义标签',
              en: game ? 'Merge game tags' : 'Merge custom tags',
            ),
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          context.l10n.select(
                            zh: '此操作不可逆。所选旧标签将全部移除，并由新的标签名替换。',
                            en: 'This cannot be undone. All selected tags will be removed and replaced by the new tag name.',
                          ),
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('merged-tag-name-field'),
                  autofocus: true,
                  maxLength: 80,
                  decoration: InputDecoration(
                    labelText: context.l10n.select(
                      zh: '合并后的标签名',
                      en: 'Merged tag name',
                    ),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (value) => setDialogState(() => draft = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              key: const Key('confirm-merge-tags'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: draft.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, draft.trim()),
              child: Text(
                context.l10n.select(zh: '不可逆合并', en: 'Merge permanently'),
              ),
            ),
          ],
        ),
      ),
    );
    if (targetName == null || !mounted) return;
    setState(() => mergeBusy = true);
    try {
      if (game) {
        await widget.backend.mergeGameTags(
          selectedGameTags.toList(),
          targetName,
        );
      } else {
        await widget.backend.mergeTags(selectedTagIds.toList(), targetName);
      }
      if (!mounted) return;
      setState(() {
        changed = true;
        mergeBusy = false;
        selectedTagIds.clear();
        selectedGameTags.clear();
        tags = widget.backend.listTagUsage();
        gameTags = widget.backend.listGameTags();
        gameTagAliases = widget.backend.listGameTagAliases();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '标签已合并为“$targetName”。',
            en: 'Tags merged into “$targetName”.',
          ),
        ),
      );
    } catch (error, stackTrace) {
      await widget.backend.logError('Failed to merge tags', error, stackTrace);
      if (!mounted) return;
      setState(() => mergeBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        _messageSnackBar(
          context.l10n.select(
            zh: '标签合并失败：$error',
            en: 'Failed to merge tags: $error',
          ),
          error: true,
        ),
      );
    }
  }

  Future<void> _rename(TagUsageSummary tag) async {
    var draft = tag.name;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.l10n.select(zh: '重命名标签', en: 'Rename tag')),
          content: TextFormField(
            key: const Key('rename-tag-field'),
            initialValue: tag.name,
            autofocus: true,
            maxLength: 80,
            decoration: InputDecoration(
              labelText: context.l10n.select(zh: '标签名称', en: 'Tag name'),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) => setDialogState(() => draft = value),
            onFieldSubmitted: (value) {
              final trimmed = value.trim();
              if (trimmed.isNotEmpty) Navigator.pop(context, trimmed);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              key: const Key('confirm-rename-tag'),
              onPressed: draft.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, draft.trim()),
              child: Text(context.l10n.select(zh: '保存', en: 'Save')),
            ),
          ],
        ),
      ),
    );
    if (name == null || name == tag.name || !mounted) return;
    await _runTagAction(
      tag.id,
      () => widget.backend.renameTag(tag.id, name),
      success: context.l10n.select(
        zh: '标签已重命名为“$name”。',
        en: 'Tag renamed to “$name”.',
      ),
      failurePrefix: context.l10n.select(
        zh: '标签重命名失败',
        en: 'Failed to rename tag',
      ),
    );
  }

  Future<void> _delete(TagUsageSummary tag) async {
    final total = tag.imageCount + tag.videoCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.select(zh: '删除标签？', en: 'Delete tag?')),
        content: Text(
          context.l10n.select(
            zh: '“${tag.name}”正在被 $total 项媒体使用。删除后会从这些图片和视频中移除该标签，但不会删除任何媒体文件。',
            en: '“${tag.name}” is used by $total media items. Deleting it removes the tag from those items but does not delete any media files.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
          ),
          FilledButton(
            key: const Key('confirm-delete-tag'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.select(zh: '删除', en: 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runTagAction(
      tag.id,
      () => widget.backend.deleteTag(tag.id),
      success: context.l10n.select(
        zh: '标签“${tag.name}”已删除。',
        en: 'Tag “${tag.name}” deleted.',
      ),
      failurePrefix: context.l10n.select(
        zh: '标签删除失败',
        en: 'Failed to delete tag',
      ),
    );
  }

  Future<void> _runTagAction(
    int tagId,
    Future<void> Function() action, {
    required String success,
    required String failurePrefix,
  }) async {
    setState(() => busyTagId = tagId);
    try {
      await action();
      if (!mounted) return;
      setState(() {
        changed = true;
        busyTagId = null;
        tags = widget.backend.listTagUsage();
      });
      ScaffoldMessenger.of(context).showSnackBar(_messageSnackBar(success));
    } catch (error, stackTrace) {
      await widget.backend.logError(failurePrefix, error, stackTrace);
      if (!mounted) return;
      setState(() => busyTagId = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(_messageSnackBar('$failurePrefix：$error', error: true));
    }
  }
}

AppSettings _copySettings(
  AppSettings value, {
  bool? showNotePreview,
  bool? showGameTag,
  bool? compactTagDisplay,
  bool? autoPlayVideo,
  bool? autoSyncOnLaunch,
  String? closeBehavior,
  String? theme,
  String? language,
  int? galleryColumns,
  int? galleryRows,
  String? libraryPath,
  String? proxyUrl,
  SyncPolicy? syncPolicy,
}) => AppSettings(
  proxyUrl: proxyUrl == null
      ? value.proxyUrl
      : (proxyUrl.isEmpty ? null : proxyUrl),
  libraryPath: libraryPath ?? value.libraryPath,
  theme: theme ?? value.theme,
  language: language ?? value.language,
  galleryColumns: galleryColumns ?? value.galleryColumns,
  galleryRows: galleryRows ?? value.galleryRows,
  showNotePreview: showNotePreview ?? value.showNotePreview,
  showGameTag: showGameTag ?? value.showGameTag,
  compactTagDisplay: compactTagDisplay ?? value.compactTagDisplay,
  autoPlayVideo: autoPlayVideo ?? value.autoPlayVideo,
  autoSyncOnLaunch: autoSyncOnLaunch ?? value.autoSyncOnLaunch,
  closeBehavior: closeBehavior ?? value.closeBehavior,
  syncPolicy: syncPolicy ?? value.syncPolicy,
);

String _albumDisplayName(BuildContext context, AlbumSummary album) =>
    album.systemKey == 'favorites'
    ? context.l10n.select(zh: '收藏', en: 'Favorites')
    : album.name;

String _themeLabel(BuildContext context, String theme) => switch (theme) {
  'teal' => context.l10n.select(zh: '青绿', en: 'Teal'),
  'orange' => context.l10n.select(zh: '橙色', en: 'Orange'),
  'purple' => context.l10n.select(zh: '紫色', en: 'Purple'),
  'rose' => context.l10n.select(zh: '玫瑰', en: 'Rose'),
  _ => context.l10n.select(zh: '海洋蓝', en: 'Ocean blue'),
};

SnackBar _messageSnackBar(
  String message, {
  bool error = false,
  SnackBarAction? action,
}) => SnackBar(
  content: SelectableText(message, key: const Key('snackbar-message')),
  duration: Duration(seconds: error ? 12 : 8),
  showCloseIcon: true,
  action: action,
);

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(42),
      child: Center(
        child: Column(
          children: [
            Icon(icon, size: 42),
            const SizedBox(height: 12),
            Text(message),
          ],
        ),
      ),
    ),
  );
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              message,
              key: const Key('error-panel-message'),
            ),
          ),
          IconButton(
            key: const Key('error-panel-copy'),
            tooltip: context.l10n.select(zh: '复制错误', en: 'Copy error'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: message));
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                _messageSnackBar(
                  context.l10n.select(zh: '错误信息已复制', en: 'Error copied'),
                ),
              );
            },
            icon: const Icon(Icons.copy_rounded),
          ),
          TextButton(
            onPressed: onRetry,
            child: Text(context.l10n.select(zh: '重试', en: 'Retry')),
          ),
        ],
      ),
    ),
  );
}
