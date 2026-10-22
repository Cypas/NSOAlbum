@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/ui/account_tools/account_tool_frame.dart';

import '../layout_viewport.dart';

void main() {
  for (final locale in ['zh', 'en']) {
    for (final width in [320.0, 360.0, 412.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'account headers keep title and back usable at $locale/$width/$scale',
          (tester) async {
            await useLayoutTestViewport(tester, Size(width, 800));
            for (final title
                in locale == 'zh'
                    ? ['好友', '鱿鱼圈 3', '观星']
                    : ['Friends', 'SplatNet 3', 'Gear seed']) {
              var returned = false;
              await tester.pumpWidget(
                MaterialApp(
                  locale: Locale(locale),
                  supportedLocales: AppLocalizations.supportedLocales,
                  localizationsDelegates: const [
                    AppLocalizations.delegate,
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: AccountToolFrame(
                    mobile: true,
                    title: title,
                    onBack: () => returned = true,
                    actions: [
                      IconButton(
                        onPressed: () {},
                        tooltip: 'Refresh',
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                    child: const Text('Page content'),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(
                tester.getSize(find.byType(Scaffold).first).width,
                width,
                reason: 'The matrix must render at its requested viewport.',
              );
              // AppBar also contains the system status-bar inset on a device.
              // Measure the actual title/back toolbar, which must stay compact.
              final toolbar = tester.getRect(find.byType(NavigationToolbar));
              final titleBounds = tester.getRect(find.text(title));
              expect(titleBounds.top, greaterThanOrEqualTo(toolbar.top));
              expect(titleBounds.bottom, lessThanOrEqualTo(toolbar.bottom));
              if (scale == 1) expect(toolbar.height, lessThan(56));
              final back = find.byKey(const Key('android-page-back'));
              final backBounds = tester.getRect(back);
              expect(backBounds.width, greaterThanOrEqualTo(48));
              expect(backBounds.height, greaterThanOrEqualTo(48));
              await tester.tap(back);
              expect(returned, isTrue);
              expect(tester.takeException(), isNull);
            }
          },
          variant: TargetPlatformVariant({TargetPlatform.android}),
        );
      }
    }
  }
}
