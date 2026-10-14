import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';

class AndroidOperationProgress extends StatelessWidget {
  const AndroidOperationProgress({super.key, this.progress});
  final OperationProgressValue? progress;

  @override
  Widget build(BuildContext context) {
    final value = progress?.value;
    final label = switch (progress?.phase) {
      'encoding' => context.l10n.select(zh: '正在处理视频', en: 'Processing video'),
      'ingesting' => context.l10n.select(
        zh: '正在校验并保存',
        en: 'Verifying and saving',
      ),
      'finished' when progress?.status == 'completed' => context.l10n.select(
        zh: '已完成',
        en: 'Completed',
      ),
      _ => context.l10n.select(zh: '正在准备', en: 'Preparing'),
    };
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value == null ? label : '$label · ${(value * 100).round()}%'),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: value),
        ],
      ),
    );
  }
}
