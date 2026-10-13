import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../backend/app_backend.dart';
import '../../app_branding.dart';
import '../../app_version.dart';
import '../../l10n/app_localizations.dart';
import '../../release_update.dart';
import '../../state/settings_controller.dart';
import '../../state/settings_copy.dart';
import 'android_page_frame.dart';
import 'android_tag_management_page.dart';

class AndroidSettingsPage extends StatefulWidget {
  const AndroidSettingsPage({
    super.key,
    required this.controller,
    required this.backend,
    this.onCheckForUpdates,
    this.latestReleaseVersion,
    this.updateStatus,
  });
  final SettingsController controller;
  final AppBackend backend;
  final Future<void> Function()? onCheckForUpdates;
  final String? latestReleaseVersion;
  final UpdateStatusKind? updateStatus;
  @override
  State<AndroidSettingsPage> createState() => _AndroidSettingsPageState();
}

class _AndroidSettingsPageState extends State<AndroidSettingsPage> {
  late final proxy = TextEditingController(
    text: widget.controller.value.proxyUrl,
  );
  final version = loadApplicationVersion();
  bool checkingUpdates = false;
  @override
  void dispose() {
    proxy.dispose();
    super.dispose();
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
            Text(
              context.l10n.select(
                zh: '每行最多 ${value.galleryColumns} 个媒体',
                en: 'Up to ${value.galleryColumns} media per row',
              ),
            ),
            Slider(
              value: value.galleryColumns.clamp(2, 7).toDouble(),
              min: 2,
              max: 7,
              divisions: 5,
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
            TextField(
              controller: proxy,
              decoration: InputDecoration(
                labelText: context.l10n.select(zh: '网络代理', en: 'Network proxy'),
              ),
              autocorrect: false,
              enableSuggestions: false,
            ),
            FilledButton(
              onPressed: controller.saving
                  ? null
                  : () => save(
                      controller.save(
                        copyAppSettings(value, proxyUrl: proxy.text.trim()),
                      ),
                    ),
              child: Text(context.l10n.select(zh: '保存代理', en: 'Save proxy')),
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
                    if (widget.updateStatus case final status?) ...[
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
