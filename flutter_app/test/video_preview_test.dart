import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/video_preview.dart';
import 'package:squid_album/src/ui/video_preview_prefetch.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

final _pixel = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/XyoAAAAASUVORK5CYII=',
  ),
);

void main() {
  testWidgets('poster stays until rendered frame, not thumbnail completion', (
    tester,
  ) async {
    final frame = Completer<void>();
    await tester.pumpWidget(
      _app(
        VideoFirstFrameCover(
          identity: 'a',
          firstFrame: frame.future,
          thumbnail: Future.value(VideoThumbnailData(bytes: _pixel)),
          child: const Text('Playback controls'),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Playback controls'), findsOneWidget);
    await tester.pump(const Duration(seconds: 20));
    expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);
    frame.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('video-first-frame-cover')), findsNothing);
    expect(find.text('Playback controls'), findsOneWidget);
  });

  testWidgets('old frame and cover callbacks cannot reveal a new video', (
    tester,
  ) async {
    final oldFrame = Completer<void>();
    final newFrame = Completer<void>();
    final oldPoster = Completer<VideoThumbnailData>();
    await tester.pumpWidget(
      _app(
        VideoFirstFrameCover(
          identity: 'old',
          firstFrame: oldFrame.future,
          thumbnail: oldPoster.future,
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pumpWidget(
      _app(
        VideoFirstFrameCover(
          identity: 'new',
          firstFrame: newFrame.future,
          thumbnail: Future.value(const VideoThumbnailData()),
          child: const SizedBox(),
        ),
      ),
    );
    oldFrame.complete();
    oldPoster.complete(VideoThumbnailData(bytes: _pixel));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);
    newFrame.complete();
    await tester.pump();
    expect(find.byKey(const Key('video-first-frame-cover')), findsNothing);
  });

  testWidgets('missing cover has visible loading then stable playback error', (
    tester,
  ) async {
    final frame = Completer<void>();
    final missing = Completer<VideoThumbnailData>();
    await tester.pumpWidget(
      _app(
        VideoFirstFrameCover(
          identity: 'a',
          firstFrame: frame.future,
          thumbnail: missing.future,
          child: const Text('Playback controls'),
        ),
      ),
    );
    missing.completeError(StateError('missing cover'));
    await tester.pump();
    expect(find.byKey(const Key('video-preview-loading')), findsOneWidget);
    frame.completeError(StateError('native output failed'));
    await tester.pump();
    expect(find.text('Unable to play this video'), findsOneWidget);
    expect(find.byKey(const Key('video-preview-loading')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'rapid prefetch updates keep one active request and latest neighbors only',
    () async {
      final first = Completer<void>();
      final loaded = <int>[];
      var active = 0, peak = 0;
      final prefetch = MediaPreviewPrefetch(
        warm: (asset) async {
          loaded.add(asset.id);
          active++;
          if (active > peak) peak = active;
          if (loaded.length == 1) await first.future;
          active--;
        },
      );
      final items = List.generate(10, _asset);
      prefetch.around(items, 1);
      await Future<void>.delayed(Duration.zero);
      prefetch.around(items, 3);
      prefetch.around(items, 7);
      first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(loaded, [0, 6, 8]);
      expect(peak, 1);
      prefetch.dispose();
      prefetch.around(items, 5);
      await Future<void>.delayed(Duration.zero);
      expect(loaded, [0, 6, 8]);
    },
  );

  test('leaving cancels queued neighbor work', () async {
    final first = Completer<void>();
    final loaded = <int>[];
    final prefetch = MediaPreviewPrefetch(
      warm: (asset) async {
        loaded.add(asset.id);
        await first.future;
      },
    );
    prefetch.around(List.generate(4, _asset), 1);
    prefetch.dispose();
    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(loaded, [0]);
  });
}

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const [AppLocalizations.delegate],
  home: Scaffold(body: SizedBox(width: 400, height: 250, child: child)),
);

MediaAsset _asset(int index) => MediaAsset(
  id: index,
  sha256: 'sha-$index',
  originalName: '$index.mp4',
  storagePath: 'missing-$index.mp4',
  kind: MediaKind.video,
  gameName: 'Game',
  favorite: false,
  tags: const [],
);
