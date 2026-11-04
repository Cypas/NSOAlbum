@Tags(['platform-android'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/android/android_media_card.dart';
import 'package:squid_album/src/ui/video_preview_cache.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

void main() {
  testWidgets('warm video cover is visible immediately after remount', (
    tester,
  ) async {
    final asset = _video('android-warm-remount');
    VideoThumbnailCache.seedForTest(
      asset.sha256,
      VideoThumbnailData(
        bytes: image.encodeJpg(image.Image(width: 16, height: 9)),
        duration: const Duration(seconds: 10),
      ),
    );
    Widget host() => MaterialApp(
      home: SizedBox(
        width: 160,
        height: 90,
        child: AndroidMediaThumbnail(asset: asset),
      ),
    );

    await tester.pumpWidget(host());
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(host());
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('thumbnail releases requests when replaced and removed', (
    tester,
  ) async {
    final releases = <int>[];
    final urgency = <bool>[];
    PreviewRequest<VideoThumbnailData> requestFor(
      MediaAsset _, {
      bool urgent = false,
    }) {
      urgency.add(urgent);
      final index = releases.length;
      releases.add(0);
      final completion = Completer<VideoThumbnailData?>();
      return PreviewRequest(completion.future, () {
        releases[index]++;
        if (!completion.isCompleted) completion.complete(null);
      });
    }

    Widget host(MediaAsset asset) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 180,
          height: 100,
          child: AndroidMediaThumbnail(
            key: const ValueKey('thumbnail'),
            asset: asset,
            requestFactory: requestFor,
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(_video('first-video')));
    expect(releases, [0]);
    expect(urgency, [true]);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);

    await tester.pumpWidget(host(_video('second-video')));
    expect(releases, [1, 0]);
    expect(urgency, [true, true]);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(releases, [1, 1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('thumbnail errors leave the video placeholder visible', (
    tester,
  ) async {
    final failure = Completer<VideoThumbnailData?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AndroidMediaThumbnail(
            asset: _video('failed-video'),
            requestFactory: (_, {bool urgent = false}) =>
                PreviewRequest(failure.future),
          ),
        ),
      ),
    );

    failure.completeError(StateError('thumbnail failed'));
    await tester.pump();

    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

MediaAsset _video(String sha) => MediaAsset(
  id: 1,
  sha256: sha,
  originalName: '$sha.mp4',
  storagePath: '$sha.mp4',
  kind: MediaKind.video,
  importedAt: DateTime(2026, 10, 25),
  gameName: '',
  favorite: false,
  tags: const [],
);
