import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/image_thumbnail.dart';

void main() {
  testWidgets(
    'warm image cover is visible in the first frame after remount',
    (tester) async {
      late Directory root;
      late String cacheRoot;
      final asset = MediaAsset(
        id: 1,
        sha256: 'c' * 64,
        originalName: 'cached.jpg',
        storagePath: 'unavailable-original.jpg',
        kind: MediaKind.image,
        gameName: '',
        favorite: false,
        tags: const [],
      );
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('image-cover-remount-');
        cacheRoot = root.path;
        final jpeg = image.encodeJpg(image.Image(width: 16, height: 9));
        await File('$cacheRoot/${asset.sha256}_v4_1024.jpg').writeAsBytes(jpeg);
        expect(
          await ImageThumbnailCache.ensure(asset, cacheRoot: cacheRoot),
          isNotNull,
        );
      });
      addTearDown(() => root.delete(recursive: true));
      Widget host([MediaAsset? shown]) => MaterialApp(
        home: SizedBox(
          width: 160,
          height: 90,
          child: ImageThumbnail(
            asset: shown ?? asset,
            cacheRoot: cacheRoot,
            placeholder: const SizedBox(key: Key('image-cover-placeholder')),
          ),
        ),
      );

      await tester.pumpWidget(host());
      expect(find.byType(Image), findsOneWidget);
      expect(
        (tester.widget<Image>(find.byType(Image)).image as ResizeImage).width,
        1024,
      );
      expect(find.byKey(const Key('image-cover-placeholder')), findsNothing);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(host());
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('image-cover-placeholder')), findsNothing);
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        host(
          MediaAsset(
            id: asset.id,
            sha256: asset.sha256,
            originalName: asset.originalName,
            storagePath: asset.storagePath,
            kind: MediaKind.video,
            gameName: '',
            favorite: false,
            tags: const [],
          ),
        ),
      );
      expect(
        find.byType(Image),
        findsNothing,
        reason: 'An image snapshot must not survive a media-kind change.',
      );
      await tester.pumpWidget(
        host(
          MediaAsset(
            id: 2,
            sha256: 'b' * 64,
            originalName: 'new.jpg',
            storagePath: 'unavailable-new-original.jpg',
            kind: MediaKind.image,
            gameName: '',
            favorite: false,
            tags: const [],
          ),
        ),
      );
      expect(
        find.byType(Image),
        findsNothing,
        reason: 'A new media identity must not inherit the preceding cover.',
      );
      expect(find.byKey(const Key('image-cover-placeholder')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}
