import 'dart:async';

import 'package:flutter/foundation.dart';

import '../backend/app_backend.dart';
import '../rust/models.dart';

/// Business execution only. Widgets own players and editable UI drafts.
class MediaEditController {
  MediaEditController(this.backend);
  final AppBackend backend;
  String? previewPath;
  bool busy = false;
  bool disposed = false;
  Future<void>? _cleanup;
  Future<void>? _disposal;
  final progress = ValueNotifier<OperationProgressValue?>(null);
  StreamSubscription<OperationProgressValue>? _progressSubscription;

  Future<T> execute<T>(Future<T> Function() action) async {
    if (busy || disposed) throw StateError('Media operation is unavailable.');
    busy = true;
    progress.value = null;
    if (backend case final OperationProgressBackend reporting) {
      _progressSubscription = reporting.operationProgress.listen((update) {
        if (!disposed && busy && update.kind.startsWith('video_')) {
          progress.value = update;
        }
      });
    }
    try {
      return await action();
    } finally {
      busy = false;
      await _progressSubscription?.cancel();
      _progressSubscription = null;
    }
  }

  Future<MediaAsset> trim(
    MediaAsset source,
    Duration start,
    Duration end, {
    required bool overwrite,
  }) => execute(
    () => backend.trimVideo(source, start, end, overwrite: overwrite),
  );

  Future<MediaAsset> frame(
    MediaAsset source,
    Uint8List bytes, {
    String extension = 'jpg',
  }) => execute(() => backend.saveVideoFrame(source, bytes, extension));

  Future<String> preview(List<MediaAsset> videos) => execute(() async {
    await discardPreview();
    final path = await backend.createMergedVideoPreview(videos);
    if (disposed) {
      await backend.discardTemporaryMedia(path);
      throw StateError('Preview was closed.');
    }
    previewPath = path;
    return path;
  });

  Future<MediaAsset> merge(List<MediaAsset> videos, {String? preparedPath}) =>
      execute(() async {
        // The backend consumes and cleans the prepared path on either outcome.
        final path = preparedPath ?? previewPath;
        previewPath = null;
        return backend.saveMergedVideo(videos, preparedPath: path);
      });

  Future<void> discardPreview() {
    final path = previewPath;
    previewPath = null;
    if (path == null) return _cleanup ?? Future<void>.value();
    return _cleanup = backend.discardTemporaryMedia(path);
  }

  Future<void> dispose() {
    if (disposed) return _disposal ?? Future.value();
    disposed = true;
    progress.dispose();
    return _disposal ??= () async {
      await _progressSubscription?.cancel();
      _progressSubscription = null;
      await discardPreview();
    }();
  }
}
