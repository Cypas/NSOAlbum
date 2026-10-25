@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/ui/android/android_albums_page.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../fixtures/device_sync/album_source_fixture.dart';

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets(
      'Android album row and details display source at 320dp/$language/2x',
      (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          SquidAlbumApp(
            backend: albumSourceBackend(language: language),
            uiPlatform: AppUiPlatform.android,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(NavigationDestination).at(1));
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey('android-album-2'));
        await tester.scrollUntilVisible(
          card,
          250,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        final known = language == 'zh' ? '来源：Desktop' : 'Source: Desktop';
        expect(
          find.descendant(of: card, matching: find.text(known)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: card,
            matching: find.text(
              language == 'zh' ? '普通相册' : 'Regular album',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: card,
            matching: find.text('My regular album note'),
          ),
          findsOneWidget,
        );
        for (final entry in [
          (3, language == 'zh' ? '来源：Phone' : 'Source: Phone'),
          (4, language == 'zh' ? '来源未知' : 'Unknown source'),
        ]) {
          final next = find.byKey(ValueKey('android-album-${entry.$1}'));
          await tester.scrollUntilVisible(
            next,
            250,
            scrollable: find.byType(Scrollable).last,
          );
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: next, matching: find.text(entry.$2)),
            findsOneWidget,
          );
        }
        final smartCard = find.byKey(const ValueKey('android-album-3'));
        await tester.scrollUntilVisible(
          smartCard,
          250,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: smartCard,
            matching: find.text(
              language == 'zh' ? '自动相册' : 'Smart album',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: smartCard,
            matching: find.text('My smart album note'),
          ),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          card,
          -250,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('FAVORITES_SOURCE_MUST_NOT_APPEAR'),
          findsNothing,
        );
        await tester.tap(
          find.descendant(of: card, matching: find.byType(ListTile)),
        );
        await tester.pumpAndSettle();
        expect(find.text(known), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Android actual long source row and picker fit narrow/$language/2x/light/dark',
      (tester) async {
        tester.view.physicalSize = const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          SquidAlbumApp(
            backend: albumSourceBackend(
              language: language,
              withMedia: true,
              longDeviceName: true,
            ),
            uiPlatform: AppUiPlatform.android,
          ),
        );
        await tester.pumpAndSettle();
        await tester.longPress(find.byKey(const ValueKey('android-media-1')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(language == 'zh' ? '复制到相册' : 'Copy to album'),
        );
        await tester.pumpAndSettle();
        final source = language == 'zh'
            ? '来源：$longAlbumDeviceName'
            : 'Source: $longAlbumDeviceName';
        final picker = tester.widget<SimpleDialogOption>(
          find
              .ancestor(
                of: find.text(source),
                matching: find.byType(SimpleDialogOption),
              )
              .first,
        );
        final backend = albumSourceBackend(
          language: language,
          longDeviceName: true,
        );
        final settings = SettingsController(backend);
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
                home: Scaffold(
                  body: Column(
                    children: [
                      Expanded(
                        child: AndroidAlbumsPage(
                          backend: backend,
                          settings: settings,
                        ),
                      ),
                      picker,
                    ],
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final card = find.byKey(const ValueKey('android-album-2'));
            await tester.scrollUntilVisible(
              card,
              200,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(find.text(source), findsNWidgets(2));
            expect(
              tester.takeException(),
              isNull,
              reason: 'Android carriers: $width/$brightness/$language/2x',
            );
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        settings.dispose();
      },
    );
  }
}
