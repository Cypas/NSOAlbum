import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';

import '../rust/models.dart';

/// One thumbnail key for explicit prefetch and incoming image pages.
ResizeImage mediaPreviewImage(String path) => ResizeImage(
  FileImage(File(path)),
  width: 512,
  height: 512,
  policy: ResizeImagePolicy.fit,
);

/// Coalesces rapid navigation into at most one active cache read and two pending
/// neighbor reads. Never opens players or reads video originals.
class MediaPreviewPrefetch {
  MediaPreviewPrefetch({required this.warm});
  final Future<void> Function(MediaAsset) warm;
  List<MediaAsset> _pending = [];
  bool _running = false;
  bool _disposed = false;

  void around(List<MediaAsset> items, int index) {
    if (_disposed) return;
    _pending = [
      for (final neighbor in [index - 1, index + 1])
        if (neighbor >= 0 && neighbor < items.length) items[neighbor],
    ];
    if (!_running) unawaited(_drain());
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (!_disposed && _pending.isNotEmpty) {
        final item = _pending.removeAt(0);
        try {
          await warm(item);
        } catch (_) {
          // Prefetch is optional; current-item loading has its own error UI.
        }
      }
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
  }
}
