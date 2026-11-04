import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../rust/models.dart';

/// Android-only media sharing bridge.
///
/// Native code copies the selected originals into an app-private cache
/// directory and exposes them through temporary `content://` URIs. Dart never
/// constructs or persists a share URI.
class AndroidMediaShare {
  AndroidMediaShare({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  static const _defaultChannel = MethodChannel(
    'io.github.cypas.nsoalbum/share',
  );

  final MethodChannel _channel;

  Future<void> share(List<String> paths) async {
    final sanitized = paths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    if (sanitized.isEmpty) {
      throw ArgumentError.value(
        paths,
        'paths',
        'At least one media file is required',
      );
    }
    await _channel.invokeMethod<void>('shareMedia', {'paths': sanitized});
  }
}

Future<void> showAndroidMediaShareSheet(
  BuildContext context,
  Iterable<MediaAsset> items, {
  AndroidMediaShare? share,
}) async {
  final selected = items.toList(growable: false);
  if (selected.isEmpty) return;
  final bridge = share ?? AndroidMediaShare();
  try {
    await bridge.share(
      selected.map((item) => item.storagePath).toList(growable: false),
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.select(zh: '无法分享媒体', en: 'Unable to share media'),
          ),
        ),
      );
    }
  }
}
