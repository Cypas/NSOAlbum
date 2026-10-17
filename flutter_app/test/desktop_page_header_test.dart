import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/sync_controller.dart';
import 'package:squid_album/src/ui/font_families.dart';
import 'package:squid_album/src/ui/home_shell.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Ahem has different line metrics and hides the production 1px overflow.
    for (final (family, asset) in [
      ('DFPT_ZY9', 'assets/fonts/default/DFPT_ZY9.ttf'),
      ('DFP_GBZY9', 'assets/fonts/default/DFP_GBZY9.ttf'),
      ('BlitzMain', 'assets/fonts/default/BlitzMain.otf'),
    ]) {
      final loader = FontLoader(family)..addFont(rootBundle.load(asset));
      await loader.load();
    }
    PackageInfo.setMockInitialValues(
      appName: 'Synthetic album',
      packageName: 'test.synthetic.album',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  for (final page in ['albums', 'transfer', 'settings']) {
    for (final language in ['zh', 'en']) {
      for (final scale in [1.0, 1.25, 1.5, 2.0]) {
        testWidgets(
          '$page header contains both title lines with real $language fonts at ${scale}x',
          (tester) async {
            tester.view.physicalSize = const Size(1280, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await loadCustomFontFamilies(const [], language: language);
            addTearDown(() => loadCustomFontFamilies(const []));
            final backend = FakeBackend(mediaItems: []);
            final settings = SettingsController(backend);
            final sync = SyncController(backend);
            addTearDown(settings.dispose);
            addTearDown(sync.dispose);
            final child = switch (page) {
              'albums' => AlbumsPage(
                backend: backend,
                onOpenAlbum: (_) {},
                enableVideoFeatures: false,
              ),
              'transfer' => TransferPage(
                backend: backend,
                sync: sync,
                settings: settings,
                onImportComplete: () {},
                enableVideoFeatures: false,
                enableMtpDetection: false,
              ),
              _ => SettingsPage(
                backend: backend,
                controller: settings,
                onTagsChanged: () {},
              ),
            };
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
                theme: ThemeData(
                  fontFamily: appFontFamily,
                  fontFamilyFallback: appFontFallback,
                  textTheme: Typography.material2021().black.apply(
                    fontFamily: appFontFamily,
                    fontFamilyFallback: appFontFallback,
                  ),
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(body: child),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final header = find.byKey(const Key('page-header'));
            final titleLines = find.descendant(
              of: header,
              matching: find.byType(Text),
            );
            expect(titleLines.evaluate().length, greaterThanOrEqualTo(2));
            final headerBounds = tester.getRect(header);
            for (final text in titleLines.evaluate()) {
              final bounds = tester.getRect(
                find.byElementPredicate(
                  (candidate) => identical(candidate, text),
                ),
              );
              expect(bounds.top, greaterThanOrEqualTo(headerBounds.top));
              expect(bounds.bottom, lessThanOrEqualTo(headerBounds.bottom));
            }
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }
}
