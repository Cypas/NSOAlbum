import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:squid_album/main.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/android/android_media_card.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  for (final android in [false, true]) {
    testWidgets(
      '${android ? 'Android' : 'desktop'} video cards keep the higher cover decode resolution',
      (tester) async {
        final asset = MediaAsset(
          id: 95001,
          sha256: android ? 'quality-android-cover' : 'quality-desktop-cover',
          originalName: 'synthetic-video.mp4',
          storagePath: 'missing-synthetic-video.mp4',
          kind: MediaKind.video,
          gameName: '',
          favorite: false,
          tags: const [],
        );
        final bytes = image.encodeJpg(image.Image(width: 1024, height: 576));
        VideoThumbnailCache.seedForTest(
          asset.sha256,
          VideoThumbnailData(
            bytes: bytes,
            duration: const Duration(seconds: 1),
          ),
        );
        await tester.pumpWidget(
          android
              ? MaterialApp(
                  home: SizedBox(
                    width: 180,
                    height: 100,
                    child: AndroidMediaThumbnail(asset: asset),
                  ),
                )
              : SquidAlbumApp(backend: FakeBackend(mediaItems: [asset])),
        );
        await tester.pumpAndSettle();
        final cover = android
            ? find.byType(Image)
            : find.descendant(
                of: find.byKey(const ValueKey('media-card-95001')),
                matching: find.byType(Image),
              );
        expect(cover, findsOneWidget);
        final provider = tester.widget<Image>(cover).image;
        expect(provider, isA<ResizeImage>());
        expect(
          (provider as ResizeImage).width,
          1024,
          reason: 'Decoding at 512 would discard the newly generated detail.',
        );
      },
      variant: TargetPlatformVariant({
        android ? TargetPlatform.android : TargetPlatform.windows,
      }),
    );
  }
}
