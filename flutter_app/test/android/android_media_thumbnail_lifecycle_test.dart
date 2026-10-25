@Tags(['platform-android'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/android/android_media_card.dart';
import 'package:squid_album/src/ui/video_preview_cache.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

void main() {
  testWidgets('thumbnail releases requests when replaced and removed', (
    tester,
  ) async {
    final releases = <int>[];
    PreviewRequest<VideoThumbnailData> requestFor(MediaAsset _) {
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
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);

    await tester.pumpWidget(host(_video('second-video')));
    expect(releases, [1, 0]);

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
            requestFactory: (_) => PreviewRequest(failure.future),
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
