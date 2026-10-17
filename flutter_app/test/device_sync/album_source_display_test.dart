import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/ui/platform_ui.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';

import '../fixtures/device_sync/album_source_fixture.dart';

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets(
      'desktop distinguishes same-name album sources and details at 1280dp/$language',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          SquidAlbumApp(
            backend: albumSourceBackend(language: language),
            uiPlatform: AppUiPlatform.desktop,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('sidebar-destination-1')));
        await tester.pumpAndSettle();
        final known = language == 'zh' ? '来源：Desktop' : 'Source: Desktop';
        await tester.ensureVisible(find.byKey(const ValueKey('album-card-2')));
        await tester.pumpAndSettle();
        expect(find.text(known), findsOneWidget);
        expect(
          find.text(language == 'zh' ? '来源：Phone' : 'Source: Phone'),
          findsOneWidget,
        );
        expect(
          find.text(language == 'zh' ? '来源未知' : 'Unknown source'),
          findsOneWidget,
        );
        expect(
          find.textContaining('FAVORITES_SOURCE_MUST_NOT_APPEAR'),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('album-card-2')));
        await tester.pumpAndSettle();
        expect(find.textContaining(known), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'actual source card and picker carriers fit narrow/$language/2x/light/dark',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          SquidAlbumApp(
            backend: albumSourceBackend(
              language: language,
              longDeviceName: true,
            ),
            uiPlatform: AppUiPlatform.desktop,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('sidebar-destination-1')));
        await tester.pumpAndSettle();
        final card = tester.widget<Card>(
          find.byKey(const ValueKey('album-card-2')),
        );
        // Capture the actual production picker item, not a test reconstruction.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          SquidAlbumApp(
            backend: albumSourceBackend(
              language: language,
              withMedia: true,
              longDeviceName: true,
            ),
            uiPlatform: AppUiPlatform.desktop,
          ),
        );
        await tester.pumpAndSettle();
        final media = find.byKey(const ValueKey('media-card-1'));
        await tester.tapAt(
          tester.getRect(media).topLeft + const Offset(20, 20),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('single-media-copy')));
        await tester.pumpAndSettle();
        final source = language == 'zh'
            ? '来源：$longAlbumDeviceName'
            : 'Source: $longAlbumDeviceName';
        final picker = tester.widget<ListTile>(
          find
              .ancestor(of: find.text(source), matching: find.byType(ListTile))
              .first,
        );
        for (final width in [320.0, 360.0, 412.0]) {
          for (final brightness in [Brightness.light, Brightness.dark]) {
            tester.view.physicalSize = Size(width, 900);
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(language),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                theme: ThemeData(brightness: brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: Scaffold(
                  body: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    children: [
                      AspectRatio(aspectRatio: 1.35, child: card),
                      picker,
                    ],
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text(source), findsNWidgets(2));
            expect(
              tester.takeException(),
              isNull,
              reason: 'Actual source carriers: $width/$brightness/$language/2x',
            );
          }
        }
      },
    );
  }
}
