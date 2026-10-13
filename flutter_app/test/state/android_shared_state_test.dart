import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/library_controller.dart';
import 'package:squid_album/src/state/media_edit_controller.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/sync_controller.dart';
import 'package:squid_album/src/state/transfer_controller.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  test('closed library ignores reload without touching the backend', () async {
    final backend = FakeBackend(mediaItems: []);
    final library = LibraryController(backend)..dispose();
    await library.reload();
    expect(backend.listMediaCalls, 0);
  });

  test('disposed library does not publish pending query results', () async {
    final gate = Completer<void>();
    final backend = FakeBackend(mediaItems: [])..nextMediaGate = gate;
    final library = LibraryController(backend);
    var notifications = 0;
    library.addListener(() => notifications++);
    final pending = library.reload();
    library.dispose();
    gate.complete();
    await pending;
    expect(notifications, 1);
  });

  test(
    'login enables policy but does not lock page until sync finishes',
    () async {
      final gate = Completer<SyncSummary>();
      final backend = FakeBackend(signedIn: true, syncFuture: gate.future);
      final settings = SettingsController(backend);
      final sync = SyncController(backend);
      final transfer = TransferController(backend, settings, sync);
      final login = transfer.completeLogin('test-callback');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      try {
        expect(settings.value.syncPolicy.enabled, isTrue);
        expect(transfer.busy, isFalse);
      } finally {
        gate.complete(
          SyncSummary(
            jobId: 'test',
            totalFound: BigInt.zero,
            downloaded: BigInt.zero,
            duplicates: BigInt.zero,
            failed: BigInt.zero,
            skippedRemote: BigInt.zero,
            errors: const [],
          ),
        );
        await login;
        transfer.dispose();
        sync.dispose();
        settings.dispose();
      }
    },
  );

  test('import validates game before calling the backend', () async {
    final backend = FakeBackend(mediaItems: []);
    final settings = SettingsController(backend);
    final sync = SyncController(backend);
    final transfer = TransferController(backend, settings, sync)
      ..addPaths(['test.png']);
    expect(await transfer.importSelected(), isFalse);
    expect(backend.lastImportPaths, isEmpty);
    transfer.dispose();
    sync.dispose();
    settings.dispose();
  });

  test('preview cleanup is single-owner and idempotent', () async {
    final backend = _CleanupBackend();
    final editor = MediaEditController(backend);
    await editor.preview([]);
    await editor.dispose();
    await editor.dispose();
    expect(backend.discarded, ['C:/temp/merged-preview.mp4']);
  });

  test('concurrent disposal waits for owned preview cleanup', () async {
    final backend = _DelayedCleanupBackend();
    final editor = MediaEditController(backend);
    await editor.preview([]);
    final first = editor.dispose();
    var secondFinished = false;
    final second = editor.dispose().then((_) => secondFinished = true);
    await Future<void>.delayed(Duration.zero);
    expect(secondFinished, isFalse);
    backend.gate.complete();
    await Future.wait([first, second]);
    expect(backend.discarded.length, 1);
  });
  test(
    'failed merge does not leave a consumed temporary preview for retry',
    () async {
      final backend = _FailedMergeBackend();
      final editor = MediaEditController(backend);
      await editor.preview([]);
      await expectLater(editor.merge([]), throwsStateError);
      expect(editor.previewPath, isNull);
      await editor.dispose();
    },
  );
}

class _FailedMergeBackend extends _CleanupBackend {
  @override
  Future<MediaAsset> saveMergedVideo(
    List<MediaAsset> videos, {
    String? preparedPath,
  }) async =>
      throw StateError('The commit failed after consuming the preview.');
}

class _DelayedCleanupBackend extends _CleanupBackend {
  final gate = Completer<void>();
  @override
  Future<void> discardTemporaryMedia(String path) async {
    await super.discardTemporaryMedia(path);
    await gate.future;
  }
}

class _CleanupBackend extends FakeBackend {
  final discarded = <String>[];
  @override
  Future<void> discardTemporaryMedia(String path) async => discarded.add(path);
}
