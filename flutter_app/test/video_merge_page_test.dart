import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/video_merge_page.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets(
    'merge order cards stay within the 278 pixel strip at large text scale',
    (tester) async {
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final videos = List.generate(
        2,
        (index) => MediaAsset(
          id: index + 1,
          sha256: 'merge-$index',
          originalName:
              'a-very-long-video-file-name-that-must-not-overflow-$index.mp4',
          storagePath: 'missing-$index.mp4',
          kind: MediaKind.video,
          gameName: 'A very long game title that must be constrained in the order card',
          favorite: false,
          tags: index == 0
              ? const [
                  'Custom tag one',
                  'Custom tag two',
                  'Custom tag three',
                  'Custom tag four',
                  'Custom tag five',
                  'Custom tag six',
                  'Custom tag seven',
                  'Custom tag eight',
                ]
              : const [],
        ),
      );
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: VideoMergePage(
              backend: FakeBackend(mediaItems: videos),
              videos: videos,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('video-merge-order-list')), findsOneWidget);
      expect(find.text('Custom tag one'), findsOneWidget);
      expect(find.text('Custom tag two'), findsOneWidget);
      expect(find.text('Custom tag eight'), findsOneWidget);
      expect(
        find.text(
          'A very long game title that must be constrained in the order card',
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      for (final card in find.byType(Card).evaluate()) {
        final rect = tester.getRect(
          find.byElementPredicate((element) => element == card),
        );
        expect(rect.height, lessThanOrEqualTo(278));
      }
    },
  );
}
