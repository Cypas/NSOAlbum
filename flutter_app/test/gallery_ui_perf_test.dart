import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/gallery_page_controller.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/sync_controller.dart';
import 'package:squid_album/src/state/transfer_controller.dart';
import 'package:squid_album/src/ui/android/android_media_card.dart';
import 'package:squid_album/src/ui/android/android_shell.dart';
import 'package:squid_album/src/ui/gallery_perf.dart';
import 'package:squid_album/src/ui/video_preview_cache.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    GalleryPerf.instance.stop();
    GalleryPerf.instance.coverMode.value = GalleryCoverMode.normal;
  });

  testWidgets(
    'placeholder comparison cancels video request without remounting the preview',
    (tester) async {
      final perf = GalleryPerf.instance;
      perf.start(mode: GalleryCoverMode.placeholder);
      final completions = <Completer<VideoThumbnailData?>>[];
      var cancelled = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 160,
              height: 90,
              child: AndroidMediaThumbnail(
                asset: _asset,
                requestFactory: (_, {bool urgent = false}) {
                  final pending = Completer<VideoThumbnailData?>();
                  completions.add(pending);
                  return PreviewRequest(pending.future, () {
                    cancelled++;
                    if (!pending.isCompleted) pending.complete(null);
                  });
                },
              ),
            ),
          ),
        ),
      );
      final state = tester.state(find.byType(AndroidMediaThumbnail));
      final rect = tester.getRect(find.byType(AndroidMediaThumbnail));
      expect(completions, isEmpty);
      perf.start();
      await tester.pump();
      expect(completions, hasLength(1));
      perf.start(mode: GalleryCoverMode.placeholder);
      await tester.pump();
      expect(cancelled, 1);
      expect(tester.state(find.byType(AndroidMediaThumbnail)), same(state));
      expect(tester.getRect(find.byType(AndroidMediaThumbnail)), rect);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !GalleryPerf.compiled,
  );

  test(
    'page wait records backend completion and emits no media identity',
    () async {
      final perf = GalleryPerf.instance;
      perf.start();
      final controller = GalleryPageController(
        FakeBackend(mediaItems: [_asset]),
      );
      await controller.reload(
        const GalleryQuery(
          kind: GalleryKindFilter.all,
          limit: 60,
          offset: 0,
          favoriteOnly: false,
          newestFirst: true,
          gameNames: [],
        ),
      );
      final snapshot = perf.snapshot();
      expect((snapshot['timings'] as Map)['pageWait'], isNotNull);
      expect(snapshot.toString(), isNot(contains('private-name')));
      expect(snapshot.toString(), isNot(contains('private-hash')));
      controller.dispose();
    },
    skip: !GalleryPerf.compiled,
  );

  testWidgets(
    'background observation follows existing signals and detaches on disposal',
    (tester) async {
      final perf = GalleryPerf.instance;
      final backend = FakeBackend(mediaItems: []);
      final settings = SettingsController(backend);
      final sync = _ObservableSync(backend);
      perf.start();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: AndroidShell(backend: backend, settings: settings, sync: sync),
        ),
      );
      await tester.pumpAndSettle();
      expect((perf.snapshot()['background'] as Map)['syncBusy'], 0);
      sync.transition(SyncState.running);
      expect((perf.snapshot()['background'] as Map)['syncBusy'], 1);
      final dynamic shell = tester.state(find.byType(AndroidShell));
      final transfer = shell.transfer as TransferController;
      final completion = Completer<void>();
      final pending = transfer.perform(() => completion.future);
      expect((perf.snapshot()['background'] as Map)['importBusy'], 1);
      completion.complete();
      await pending;
      expect((perf.snapshot()['background'] as Map)['importBusy'], 0);
      await tester.pumpWidget(const SizedBox.shrink());
      sync.transition(SyncState.idle);
      expect(
        (perf.snapshot()['background'] as Map)['syncBusy'],
        1,
        reason: 'Disposed shell must no longer observe the signal.',
      );
      sync.dispose();
      settings.dispose();
    },
    skip: !GalleryPerf.compiled,
  );
}

class _ObservableSync extends SyncController {
  _ObservableSync(super.backend);
  void transition(SyncState next) {
    state = next;
    notifyListeners();
  }
}

final _asset = MediaAsset(
  id: 1,
  sha256: 'private-hash',
  originalName: 'private-name.mp4',
  storagePath: 'private-name.mp4',
  kind: MediaKind.video,
  importedAt: DateTime.utc(2026, 11, 1),
  gameName: '',
  favorite: false,
  tags: const [],
);
