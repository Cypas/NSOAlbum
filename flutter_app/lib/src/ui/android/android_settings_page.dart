import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../backend/app_backend.dart';
import '../../app_branding.dart';
import '../../app_version.dart';
import '../../l10n/app_localizations.dart';
import '../../release_update.dart';
import '../../state/settings_controller.dart';
import '../../state/settings_copy.dart';
import '../../state/android_update_controller.dart';
import 'android_page_frame.dart';
import 'android_tag_management_page.dart';
import 'android_update_controls.dart';
import 'android_log_viewer_page.dart';

class AndroidSettingsPage extends StatefulWidget {
  const AndroidSettingsPage({
    super.key,
    required this.controller,
    required this.backend,
    this.onCheckForUpdates,
    this.latestReleaseVersion,
    this.updateStatus,
    this.updateController,
  });
  final SettingsController controller;
  final AppBackend backend;
  final Future<void> Function()? onCheckForUpdates;
  final String? latestReleaseVersion;
  final UpdateStatusKind? updateStatus;
  final AndroidUpdateController? updateController;
  @override
  State<AndroidSettingsPage> createState() => _AndroidSettingsPageState();
}

class _AndroidSettingsPageState extends State<AndroidSettingsPage> {
  final version = loadApplicationVersion();
  bool checkingUpdates = false;
  bool choosingStorage = false;
  bool movingStorage = false;

  Future<void> chooseStorage() async {
    if (widget.backend is! MobileStorageBackend || choosingStorage) return;
    setState(() => choosingStorage = true);
    try {
      final locations = await (widget.backend as MobileStorageBackend)
          .mobileStorageLocations();
      if (!mounted) return;
      final selected = await showModalBottomSheet<MobileStorageLocation>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final location in locations)
                ListTile(
                  leading: Icon(
                    location.removable ? Icons.sd_storage : Icons.phone_android,
                  ),
                  title: Text(
                    context.l10n.select(
                      zh: location.removable ? 'SD 卡' : '内部存储',
                      en: location.removable ? 'SD card' : 'Internal storage',
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.select(
                      zh: '应用专用目录',
                      en: 'App-specific directory',
                    ),
                  ),
                  onTap: () => Navigator.pop(context, location),
                ),
              if (!locations.any((location) => location.removable))
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    context.l10n.select(
                      zh: '没有可用的 SD 卡。',
                      en: 'No SD card is available.',
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      if (selected == null ||
          !mounted ||
          selected.path == widget.controller.value.libraryPath) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            context.l10n.select(zh: '更改图库位置？', en: 'Change library location?'),
          ),
          content: Text(
            context.l10n.select(
              zh: '将复制并校验媒体后切换图库。请保持存储设备连接；失败时仍使用原图库。',
              en: 'Media will be copied and verified before switching. Keep storage connected; a failure leaves the original library active.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              key: const Key('android-confirm-storage'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.select(zh: '继续', en: 'Continue')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => movingStorage = true);
      // Re-enumerate after confirmation: an external card may have been removed.
      final available = await (widget.backend as MobileStorageBackend)
          .mobileStorageLocations();
      if (!available.any(
        (item) => item.id == selected.id && item.path == selected.path,
      )) {
        if (mounted) {
          androidMessage(
            context,
            context.l10n.select(
              zh: '所选存储不可用，请重新连接后再试。',
              en: 'Selected storage is unavailable. Reconnect it and try again.',
            ),
            isError: true,
          );
        }
        return;
      }
      await widget.controller.relocateMediaLibrary(
        copyAppSettings(widget.controller.value, libraryPath: selected.path),
      );
      if (mounted) {
        androidMessage(
          context,
          context.l10n.select(zh: '图库位置已更新。', en: 'Library location updated.'),
          isError: false,
        );
      }
    } catch (error) {
      if (mounted) androidMessage(context, error);
    } finally {
      if (mounted) {
        setState(() {
          choosingStorage = false;
          movingStorage = false;
        });
      }
    }
  }

  Future<void> checkForUpdates() async {
    final callback = widget.onCheckForUpdates;
    if (callback == null || checkingUpdates) return;
    setState(() => checkingUpdates = true);
    try {
      await callback();
    } catch (error) {
      if (mounted) androidMessage(context, error);
    } finally {
      if (mounted) setState(() => checkingUpdates = false);
    }
  }

  Future<void> openLink(String value) async {
    try {
      final opened = await launchUrl(
        Uri.parse(value),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw StateError('Unable to open the link.');
    } catch (error) {
      if (mounted) androidMessage(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => AndroidPageFrame(
    title: context.l10n.select(zh: '设置', en: 'Settings'),
    child: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final value = controller.value;
        Future<void> save(Future<void> operation) async {
          try {
            await operation;
          } catch (error) {
            if (context.mounted) androidMessage(context, error);
          }
        }

        return AndroidPageList(
          children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              itemHeight: null,
              initialValue: value.language,
              decoration: InputDecoration(
                labelText: context.l10n.select(
                  zh: '界面语言',
                  en: 'Interface language',
                ),
              ),
              items: const [
                DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                DropdownMenuItem(value: 'en', child: Text('English')),
              ],
              onChanged: controller.saving
                  ? null
                  : (language) => save(
                      controller.save(
                        copyAppSettings(value, language: language),
                      ),
                    ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in {
                  'ocean': Colors.blue,
                  'teal': Colors.teal,
                  'orange': Colors.orange,
                  'purple': Colors.purple,
                  'rose': Colors.pink,
                }.entries)
                  IconButton(
                    tooltip: switch (entry.key) {
                      'teal' => context.l10n.select(zh: '青绿', en: 'Teal'),
                      'orange' => context.l10n.select(zh: '橙色', en: 'Orange'),
                      'purple' => context.l10n.select(zh: '紫色', en: 'Purple'),
                      'rose' => context.l10n.select(zh: '玫瑰', en: 'Rose'),
                      _ => context.l10n.select(zh: '海洋蓝', en: 'Ocean blue'),
                    },
                    onPressed: controller.saving
                        ? null
                        : () => save(
                            controller.save(
                              copyAppSettings(value, theme: entry.key),
                            ),
                          ),
                    icon: Icon(
                      value.theme == entry.key
                          ? Icons.check_circle
                          : Icons.circle,
                      color: entry.value,
                    ),
                  ),
              ],
            ),
            if (widget.backend is MobileStorageBackend)
              OutlinedButton.icon(
                key: const Key('android-storage-location'),
                onPressed: choosingStorage || controller.saving
                    ? null
                    : chooseStorage,
                icon: movingStorage
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder_outlined),
                label: Text(
                  context.l10n.select(
                    zh: movingStorage ? '正在处理，请稍后' : '选择图库位置',
                    en: movingStorage
                        ? 'Processing, please wait'
                        : 'Choose library location',
                  ),
                ),
              ),
            Text(
              context.l10n.select(
                zh: '每行最多 ${value.galleryColumns} 个媒体',
                en: 'Up to ${value.galleryColumns} media per row',
              ),
            ),
            Slider(
              value: value.galleryColumns.clamp(1, 7).toDouble(),
              min: 1,
              max: 7,
              divisions: 6,
              onChanged: controller.saving
                  ? null
                  : (next) => save(
                      controller.save(
                        copyAppSettings(value, galleryColumns: next.round()),
                      ),
                    ),
            ),
            Text(
              context.l10n.select(
                zh: '屏幕空间不足时会自动减少列数。',
                en: 'Fewer columns are used when screen space is limited.',
              ),
            ),
            for (final item in [
              (
                context.l10n.select(zh: '显示游戏标签', en: 'Show game tags'),
                value.showGameTag,
                (bool next) => copyAppSettings(value, showGameTag: next),
              ),
              (
                context.l10n.select(zh: '显示备注摘要', en: 'Show note previews'),
                value.showNotePreview,
                (bool next) => copyAppSettings(value, showNotePreview: next),
              ),
              (
                context.l10n.select(zh: '标签紧凑展示', en: 'Compact tags'),
                value.compactTagDisplay,
                (bool next) => copyAppSettings(value, compactTagDisplay: next),
              ),
              (
                context.l10n.select(zh: '打开视频后自动播放', en: 'Auto-play videos'),
                value.autoPlayVideo,
                (bool next) => copyAppSettings(value, autoPlayVideo: next),
              ),
            ])
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(item.$1),
                value: item.$2,
                onChanged: controller.saving
                    ? null
                    : (next) => save(controller.save(item.$3(next))),
              ),
            Card(
              child: ListTile(
                key: const Key('android-manage-tags'),
                leading: const Icon(Icons.sell_outlined),
                title: Text(
                  context.l10n.select(zh: '标签管理', en: 'Tag management'),
                ),
                subtitle: Text(
                  context.l10n.select(
                    zh: '创建和查看自定义标签。',
                    en: 'Create and review custom tags.',
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AndroidTagManagementPage(backend: widget.backend),
                  ),
                ),
              ),
            ),
            Card(
              child: ListTile(
                key: const Key('android-view-logs'),
                leading: const Icon(Icons.article_outlined),
                title: Text(context.l10n.select(zh: '查看日志', en: 'View logs')),
                subtitle: Text(
                  context.l10n.select(
                    zh: '查看最近运行记录并复制脱敏内容。',
                    en: 'Review recent activity and copy a redacted report.',
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AndroidLogViewerPage(backend: widget.backend),
                  ),
                ),
              ),
            ),
            SelectableText(
              context.l10n.select(
                zh: '图库路径：${value.libraryPath}',
                en: 'Library: ${value.libraryPath}',
              ),
            ),
            Card(
              key: const Key('android-about-card'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipOval(
                          child: Image.asset(
                            'assets/images/about/cypas_nya.jpg',
                            width: 60,
                            height: 60,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => DecoratedBox(
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                                shape: BoxShape.circle,
                              ),
                              child: const SizedBox.square(
                                dimension: 60,
                                child: Icon(Icons.person_outline, size: 32),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l10n.select(
                                  zh: '关于$appChineseName',
                                  en: 'About $appEnglishName',
                                ),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Cypas_Nya',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              Text(
                                context.l10n.select(
                                  zh: '小鱿鱿bot作者',
                                  en: 'Author of Xiao Youyou Bot',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    FutureBuilder<String>(
                      key: const Key('android-about-app-version'),
                      future: version,
                      builder: (context, snapshot) => Text(
                        context.l10n.select(
                          zh: '版本 ${snapshot.data ?? '—'}',
                          en: 'Version ${snapshot.data ?? '—'}',
                        ),
                      ),
                    ),
                    if (widget.updateController case final updater?)
                      AndroidUpdateControls(
                        controller: updater,
                        onDownload: widget.onCheckForUpdates,
                      )
                    else if (widget.updateStatus case final status?) ...[
                      const SizedBox(height: 4),
                      Text(switch (status) {
                        UpdateStatusKind.latest => context.l10n.select(
                          zh: '已是最新版本',
                          en: 'You are using the latest version.',
                        ),
                        UpdateStatusKind.available => context.l10n.select(
                          zh: '发现新版本 ${widget.latestReleaseVersion ?? '—'}，可在 GitHub Releases 查看。',
                          en: 'Version ${widget.latestReleaseVersion ?? '—'} is available on GitHub Releases.',
                        ),
                        UpdateStatusKind.failed => context.l10n.select(
                          zh: '更新检查失败',
                          en: 'Update check failed.',
                        ),
                        UpdateStatusKind.macosPackageUnavailable =>
                          context.l10n.select(
                            zh: '最新版本 ${widget.latestReleaseVersion ?? '—'}，请在 GitHub Releases 查看。',
                            en: 'Latest version ${widget.latestReleaseVersion ?? '—'}; see GitHub Releases.',
                          ),
                      }, key: const Key('android-about-update-status')),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('android-check-updates'),
                          onPressed:
                              widget.onCheckForUpdates == null ||
                                  checkingUpdates
                              ? null
                              : checkForUpdates,
                          icon: checkingUpdates
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.system_update_alt),
                          label: Text(
                            context.l10n.select(
                              zh: '检查更新',
                              en: 'Check for updates',
                            ),
                          ),
                        ),
                        OutlinedButton.icon(
                          key: const Key('android-about-github-link'),
                          onPressed: () =>
                              openLink('https://github.com/Cypas/NSOAlbum'),
                          icon: const Icon(Icons.code),
                          label: Text(
                            context.l10n.select(
                              zh: 'GitHub 仓库',
                              en: 'GitHub repository',
                            ),
                          ),
                        ),
                        OutlinedButton.icon(
                          key: const Key('android-about-feedback-link'),
                          onPressed: () =>
                              openLink('https://qm.qq.com/q/wXB8g8pxkI'),
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
          ],
        );
      },
    ),
  );
}
