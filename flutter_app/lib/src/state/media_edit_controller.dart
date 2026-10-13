import 'dart:typed_data';

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

  Future<T> execute<T>(Future<T> Function() action) async {
    if (busy || disposed) throw StateError('Media operation is unavailable.');
    busy = true;
    try {
      return await action();
    } finally {
      busy = false;
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
    disposed = true;
    return _disposal ??= discardPreview();
  }
}
