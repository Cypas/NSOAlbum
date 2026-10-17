import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

String? albumSourceText(
  BuildContext context, {
  String? name,
  String? systemKey,
}) {
  if (systemKey == 'favorites') return null;
  final value = name?.trim();
  if (value == null || value.isEmpty) {
    return context.l10n.select(zh: '来源未知', en: 'Unknown source');
  }
  return context.l10n.select(zh: '来源：$value', en: 'Source: $value');
}

class AlbumSourceLabel extends StatelessWidget {
  const AlbumSourceLabel({super.key, this.name, this.systemKey, this.style});
  final String? name, systemKey;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final text = albumSourceText(context, name: name, systemKey: systemKey);
    if (text == null) return const SizedBox.shrink();
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: style ?? Theme.of(context).textTheme.bodySmall,
    );
  }
}
