import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/media_viewer.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets(
    'desktop neighbors decode thumbnails, current photo retains original',
    (tester) async {
      final items = List.generate(
        3,
        (i) => MediaAsset(
          id: i + 1,
          sha256: 'neighbor-$i',
          originalName: '$i.png',
          storagePath: 'missing-neighbor-$i.png',
          kind: MediaKind.image,
          gameName: 'Game',
          favorite: false,
          tags: const [],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: MediaViewer(
            backend: FakeBackend(mediaItems: items),
            items: items,
            initialIndex: 1,
            autoPlayVideo: false,
            compactTagDisplay: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('media-viewer-next')));
      await tester.pump();
      // Inspect the incoming page before it becomes the active item.
      await tester.pump(const Duration(milliseconds: 20));
      final providers = tester
          .widgetList<Image>(find.byType(Image))
          .map((widget) => widget.image)
          .toList();
      final originals = providers.whereType<FileImage>().toList();
      expect(originals.map((image) => image.file.path), [
        'missing-neighbor-1.png',
      ]);
      final neighbors = providers.whereType<ResizeImage>().toList();
      expect(neighbors, isNotEmpty);
      for (final image in neighbors) {
        expect(image.width, 512);
        expect(image.height, 512);
        expect(image.policy, ResizeImagePolicy.fit);
      }
      expect(tester.takeException(), isNull);
    },
  );
}
