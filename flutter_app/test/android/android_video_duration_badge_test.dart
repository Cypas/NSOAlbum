import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/android/android_media_card.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

void main() {
  testWidgets('video duration includes a play glyph even without a cover', (
    tester,
  ) async {
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('android-duration-badge-'),
    );
    final root = directory!;
    addTearDown(() => root.delete(recursive: true));
    const sha = 'duration-badge-fixture';
    final source = File('${root.path}/source.mp4');
    await tester.runAsync(() async {
      final cache = Directory('${root.path}/cache/video_thumbnails');
      await cache.create(recursive: true);
      await source.writeAsBytes([]);
      await File('${cache.path}/$sha.duration').writeAsString('29000');
      await File('${cache.path}/$sha.failed').writeAsString('v2:test');
    });
    VideoThumbnailCache.configureCacheRoot(root.path);
    final asset = MediaAsset(
      id: 1,
      sha256: sha,
      originalName: 'test.mp4',
      storagePath: source.path,
      kind: MediaKind.video,
      importedAt: DateTime(2026, 10, 14),
      gameName: '',
      favorite: false,
      tags: const [],
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 180,
              height: 100,
              child: AndroidMediaThumbnail(asset: asset),
            ),
          ),
        ),
      );
      await VideoThumbnailCache.load(asset, onError: (_, _) async {});
    });
    await tester.pumpAndSettle();
    expect(find.text('▶ 0:29'), findsOneWidget);
    final duration = find.text('▶ 0:29');
    expect(tester.widget<Text>(duration).style!.fontSize, lessThan(12));
    final badge = find
        .ancestor(of: duration, matching: find.byType(Padding))
        .first;
    expect(tester.getSize(badge).height, lessThan(18));
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
