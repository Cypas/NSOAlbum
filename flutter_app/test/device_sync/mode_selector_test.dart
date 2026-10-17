import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/ui/device_sync/mode_selector.dart';

void main() {
  testWidgets(
    'explicit modes select each direction, behavior and account scope',
    (tester) async {
      var phoneToDesktop = false, overwrite = false, accounts = false;
      await tester.pumpWidget(
        selectorApp(
          builder: (context, setState) => DeviceSyncModeSelector(
            phoneToDesktop: phoneToDesktop,
            overwrite: overwrite,
            includeAccounts: accounts,
            enabled: true,
            onDirectionChanged: (value) =>
                setState(() => phoneToDesktop = value),
            onOverwriteChanged: (value) => setState(() => overwrite = value),
            onAccountsChanged: (value) => setState(() => accounts = value),
          ),
        ),
      );
      expect(find.byType(SwitchListTile), findsNothing);
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const Key('device-desktop-to-phone')),
            )
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('device-library-only')))
            .selected,
        isTrue,
      );
      for (final key in [
        'device-phone-to-desktop',
        'device-mode-overwrite',
        'device-with-accounts',
      ]) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.tap(find.byKey(Key(key)));
        await tester.pump();
        expect(
          tester.widget<ChoiceChip>(find.byKey(Key(key))).selected,
          isTrue,
        );
      }
      expect((phoneToDesktop, overwrite, accounts), (true, true, true));
      expect(find.textContaining('When off'), findsNothing);
    },
  );

  testWidgets('disabled modes cannot change selection', (tester) async {
    var changes = 0;
    await tester.pumpWidget(
      selectorApp(
        builder: (_, _) => DeviceSyncModeSelector(
          phoneToDesktop: false,
          overwrite: false,
          includeAccounts: false,
          enabled: false,
          onDirectionChanged: (_) => changes++,
          onOverwriteChanged: (_) => changes++,
          onAccountsChanged: (_) => changes++,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('device-phone-to-desktop')));
    await tester.pump();
    expect(changes, 0);
  });

  testWidgets('bilingual options wrap at narrow widths and large text', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    for (final width in [320.0, 360.0, 412.0]) {
      tester.view.physicalSize = Size(width, 820);
      for (final language in ['zh', 'en']) {
        for (final brightness in Brightness.values) {
          await tester.pumpWidget(
            selectorApp(
              language: language,
              brightness: brightness,
              scale: 2,
              builder: (_, _) => DeviceSyncModeSelector(
                phoneToDesktop: false,
                overwrite: false,
                includeAccounts: false,
                enabled: true,
                onDirectionChanged: (_) {},
                onOverwriteChanged: (_) {},
                onAccountsChanged: (_) {},
              ),
            ),
          );
          await tester.ensureVisible(
            find.byKey(const Key('device-with-accounts')),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
  });
}

Widget selectorApp({
  required StatefulWidgetBuilder builder,
  String language = 'en',
  Brightness brightness = Brightness.light,
  double scale = 1,
}) => MaterialApp(
  locale: Locale(language),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: ThemeData(brightness: brightness),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: StatefulBuilder(builder: builder),
      ),
    ),
  ),
);
