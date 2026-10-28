@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/app_branding.dart';
import 'package:squid_album/src/ui/app_brand_title.dart';
import 'package:squid_album/src/ui/font_families.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      SquidAlbumApp(
        backend: FakeBackend(mediaItems: const []),
        uiPlatform: AppUiPlatform.android,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Android root gallery brand title uses the shared desktop title style',
    (tester) async {
      await pumpApp(tester);

      final title = find.byKey(const Key('android-library-title'));
      expect(title, findsOneWidget);
      final titleRect = tester.getRect(title);
      final appBarRect = tester.getRect(find.byType(AppBar).first);
      expect(titleRect.left, greaterThan(appBarRect.left + 8));

      expect(find.byType(AppBrandTitle), findsOneWidget);
      final underline = find.byKey(
        const Key('android-library-brand-underline'),
      );
      expect(underline, findsOneWidget);
      expect(tester.getSize(underline), const Size(40, 3));
      expect(
        tester.widget<DecoratedBox>(underline).decoration,
        isA<BoxDecoration>()
            .having(
              (decoration) => decoration.color,
              'color',
              const Color(0xffffc107),
            )
            .having(
              (decoration) => decoration.borderRadius,
              'borderRadius',
              BorderRadius.circular(2),
            ),
      );
      final style = tester.widget<Text>(title).style;
      expect(style?.fontSize, 14);
      expect(style?.fontWeight, FontWeight.w700);
      expect(style?.fontFamily, appBrandFontFamily);
      expect(style?.fontFamilyFallback, appBrandFontFallback);
      expect(find.text(appChineseName), findsOneWidget);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'Android gallery default and selection toolbars both use the compact height',
    (tester) async {
      await pumpApp(tester);

      expect(tester.getSize(find.byType(AppBar).first).height, 48);
      await tester.tap(find.byKey(const Key('android-select-media')));
      await tester.pumpAndSettle();

      expect(find.text('已选择 0 项'), findsOneWidget);
      expect(tester.getSize(find.byType(AppBar).first).height, 48);
      expect(
        find.byKey(const Key('android-library-brand-underline')),
        findsNothing,
      );
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'Android About title and author use one smaller typography tier',
    (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byType(NavigationDestination).at(3));
      await tester.pumpAndSettle();
      final aboutCard = find.byKey(const Key('android-about-card'));
      await tester.scrollUntilVisible(
        aboutCard,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      final aboutTitle = tester.widget<Text>(
        find.byKey(const Key('android-about-app-title')),
      );
      final author = tester.widget<Text>(
        find.byKey(const Key('android-about-author')),
      );
      expect(aboutTitle.style?.fontSize, 14);
      expect(author.style?.fontSize, 20);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}
