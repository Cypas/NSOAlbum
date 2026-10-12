import 'package:flutter/material.dart';

import '../app_branding.dart';
import '../l10n/app_localizations.dart';
import '../release_update.dart';

enum MacosUpdateAction { downloadPage, later, ignore }

/// Dismissing the dialog postpones the update rather than ignoring the version.
Future<MacosUpdateAction?> showMacosReleaseUpdateDialog(
  BuildContext context, {
  required LatestReleaseInfo release,
  required String architecture,
}) => showDialog<MacosUpdateAction>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(context.l10n.select(zh: '发现新版本', en: 'Update available')),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.select(
                zh: '发现 $appEnglishName ${release.version}。请前往 GitHub Releases 下载适合您 Mac 的 DMG，退出应用后手动安装。程序不会自动下载或替换应用。',
                en: '$appEnglishName ${release.version} is available. Visit GitHub Releases to download the DMG for your Mac, then quit the app and install it manually. The app will not download or replace itself.',
              ),
            ),
            if (!release.macosArchitectures.contains(architecture)) ...[
              const SizedBox(height: 12),
              Text(
                context.l10n.select(
                  zh: '暂时没有适用于 macOS $architecture 的 DMG。您仍可前往发布页面查看。',
                  en: 'No macOS $architecture DMG is available yet. You can still visit the release page.',
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              context.l10n.select(
                zh: 'DMG 未经 Apple 公证，首次打开可能需要在系统安全设置中手动允许。',
                en: 'The DMG is not notarized by Apple. On first launch, you may need to allow the app in system security settings.',
              ),
            ),
            if (release.body?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 16),
              Text(
                context.l10n.select(zh: '更新说明', en: 'Release notes'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              SelectableText(release.body!.trim()),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        key: const Key('macos-update-later'),
        onPressed: () => Navigator.pop(context, MacosUpdateAction.later),
        child: Text(context.l10n.select(zh: '稍后', en: 'Later')),
      ),
      TextButton(
        key: const Key('macos-update-ignore'),
        onPressed: () => Navigator.pop(context, MacosUpdateAction.ignore),
        child: Text(
          context.l10n.select(zh: '忽略此版本', en: 'Ignore this version'),
        ),
      ),
      FilledButton.icon(
        key: const Key('macos-update-download-page'),
        onPressed: () => Navigator.pop(context, MacosUpdateAction.downloadPage),
        icon: const Icon(Icons.open_in_new_rounded),
        label: Text(context.l10n.select(zh: '前往下载', en: 'Go to downloads')),
      ),
    ],
  ),
);
