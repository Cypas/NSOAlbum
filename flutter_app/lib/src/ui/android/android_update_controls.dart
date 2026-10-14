import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/android_update_controller.dart';

class AndroidUpdateControls extends StatelessWidget {
  const AndroidUpdateControls({
    super.key,
    required this.controller,
    this.onDownload,
  });

  final AndroidUpdateController controller;
  final Future<void> Function()? onDownload;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final message = controller.message(context.l10n.locale.languageCode);
      final status = controller.status;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(message, key: const Key('android-about-update-status')),
          ],
          if (status.busy) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value:
                  status.state == AndroidUpdateState.downloading &&
                      status.total > 0
                  ? (status.received / status.total).clamp(0, 1)
                  : null,
            ),
          ],
          if (controller.canInstall) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('android-install-update'),
              onPressed: controller.install,
              icon: const Icon(Icons.install_mobile),
              label: Text(
                context.l10n.select(zh: '安装新版本', en: 'Install new version'),
              ),
            ),
          ] else if (controller.canDownload && onDownload != null) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('android-download-update'),
              onPressed: controller.checking ? null : onDownload,
              icon: const Icon(Icons.download),
              label: Text(
                context.l10n.select(zh: '下载更新', en: 'Download update'),
              ),
            ),
          ],
        ],
      );
    },
  );
}
