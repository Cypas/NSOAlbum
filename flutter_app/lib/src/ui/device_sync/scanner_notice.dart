import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';

class DeviceScannerNotice extends StatelessWidget {
  const DeviceScannerNotice({super.key});

  Future<void> _open(BuildContext context, String url) async {
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // The OS browser is optional and must not block local pairing.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.select(zh: '无法打开链接。', en: 'Unable to open the link.'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.select(zh: '扫码与数据说明', en: 'Scanner and data notice'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.select(
              zh: 'Google ML Kit 的扫码输入图像和识别结果仅在本机处理，不发送给 Google。ML Kit 会发送设备/应用信息、安装标识及 API 使用/性能指标等诊断数据，并可能联系 Google 获取更新。不启用相机不影响图库。',
              en: 'Google ML Kit processes scanner images and recognition results on this device, without sending them to Google. ML Kit sends diagnostic data such as device/app information, installation identifiers, and API usage/performance metrics, and may contact Google for updates. Your library remains available without enabling the camera.',
            ),
          ),
          TextButton.icon(
            key: const Key('device-scanner-terms'),
            onPressed: () =>
                _open(context, 'https://developers.google.com/ml-kit/terms'),
            icon: const Icon(Icons.open_in_new),
            label: Text(
              context.l10n.select(
                zh: 'Google ML Kit 条款',
                en: 'Google ML Kit terms',
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () => _open(
              context,
              'https://developers.google.com/ml-kit/android-data-disclosure',
            ),
            icon: const Icon(Icons.open_in_new),
            label: Text(
              context.l10n.select(
                zh: 'Android 数据说明',
                en: 'Android data disclosure',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
