import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../release_update.dart';
import '../../state/android_update_controller.dart';

Future<AndroidUpdateAction?> showAndroidReleaseUpdateDialog(
  BuildContext context, {
  required LatestReleaseInfo release,
}) => showDialog<AndroidUpdateAction>(
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
                zh: '发现新版本 ${release.version}。',
                en: 'Version ${release.version} is available.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              release.androidPackage == null
                  ? context.l10n.select(
                      zh: '暂时没有可验证的 Android 安装包，请稍后再检查。',
                      en: 'No verified Android package is available yet. Check again later.',
                    )
                  : context.l10n.select(
                      zh: '确认后将在后台下载安装包。下载完成并校验后，可通过通知或设置页打开系统安装器。现有图库和账号将保留。',
                      en: 'After confirmation, the package downloads in the background. Once verified, open the system installer from the notification or Settings. Your library and accounts are preserved.',
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
        key: const Key('android-update-later'),
        onPressed: () => Navigator.pop(context, AndroidUpdateAction.later),
        child: Text(context.l10n.select(zh: '稍后', en: 'Later')),
      ),
      TextButton(
        key: const Key('android-update-ignore'),
        onPressed: () => Navigator.pop(context, AndroidUpdateAction.ignore),
        child: Text(
          context.l10n.select(zh: '忽略此版本', en: 'Ignore this version'),
        ),
      ),
      if (release.androidPackage != null)
        FilledButton.icon(
          key: const Key('android-update-download'),
          onPressed: () => Navigator.pop(context, AndroidUpdateAction.download),
          icon: const Icon(Icons.download),
          label: Text(context.l10n.select(zh: '下载更新', en: 'Download update')),
        ),
    ],
  ),
);
