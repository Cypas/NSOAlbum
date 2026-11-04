import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../rust/models.dart';
import 'display_time.dart';

class MediaDetailsDialog extends StatelessWidget {
  const MediaDetailsDialog({
    super.key,
    required this.details,
    required this.onOpenDirectory,
    this.accountNames = const {},
  });
  final MediaDetails details;
  final VoidCallback onOpenDirectory;
  final Map<String, String> accountNames;

  String _formatMediaSize(BigInt bytes) {
    if (bytes < BigInt.from(1024)) return '$bytes B';
    var value = bytes.toDouble();
    const units = ['KB', 'MB', 'GB', 'TB'];
    var unitIndex = -1;
    do {
      value /= 1024;
      unitIndex++;
    } while (value >= 1024 && unitIndex < units.length - 1);
    return '${value.toStringAsFixed(2)} ${units[unitIndex]}';
  }

  @override
  Widget build(BuildContext context) {
    String date(DateTime? value) => value == null
        ? context.l10n.select(zh: '未记录', en: 'Not recorded')
        : formatUserDateTime(value);
    String sourceLabel(MediaSourceDetails source) {
      if (source.sourceType == 'nso') {
        final provider = source.provider ?? '';
        final id = provider.startsWith('nso_coral:')
            ? provider.substring('nso_coral:'.length)
            : '';
        final name = accountNames[id];
        return 'NSO · ${name != null && name.trim().isNotEmpty ? name : context.l10n.select(zh: '未知账号', en: 'Unknown account')}';
      }
      return '${source.sourceType}'
          '${source.provider == null ? '' : ' · ${source.provider}'}'
          '${source.sourcePath == null ? '' : '\n${source.sourcePath}'}';
    }

    return AlertDialog(
      title: Text(context.l10n.select(zh: '媒体详情', en: 'Media details')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(details.storagePath),
              const SizedBox(height: 12),
              Text(
                context.l10n.select(
                  zh: '录入时间：${date(details.importedAt)}',
                  en: 'Imported: ${date(details.importedAt)}',
                ),
              ),
              Text(
                context.l10n.select(
                  zh: '拍摄时间：${date(details.capturedAt)}',
                  en: 'Captured: ${date(details.capturedAt)}',
                ),
              ),
              Text(
                context.l10n.select(
                  zh: '媒体大小：${_formatMediaSize(details.sizeBytes)}',
                  en: 'Media size: ${_formatMediaSize(details.sizeBytes)}',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.select(zh: '媒体来源', en: 'Sources'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (details.sources.isEmpty)
                Text(context.l10n.select(zh: '未记录来源', en: 'No source recorded'))
              else
                for (final source in details.sources) Text(sourceLabel(source)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: onOpenDirectory,
          child: Text(
            context.l10n.select(zh: '打开所在目录', en: 'Open containing folder'),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.select(zh: '关闭', en: 'Close')),
        ),
      ],
    );
  }
}
