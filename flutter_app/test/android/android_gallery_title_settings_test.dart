@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/app_branding.dart';
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
    'Android root gallery brand title has inset and desktop-style yellow underline',
    (tester) async {
      await pumpApp(tester);

      final title = find.byKey(const Key('android-library-title'));
      expect(title, findsOneWidget);
      final titleRect = tester.getRect(title);
      final appBarRect = tester.getRect(find.byType(AppBar).first);
      expect(titleRect.left, greaterThan(appBarRect.left + 8));

      final underline = find.byKey(
        const Key('android-library-brand-underline'),
      );
      expect(underline, findsOneWidget);
      final decoration = tester.widget<DecoratedBox>(underline).decoration;
      expect(decoration, isA<BoxDecoration>());
      final box = decoration as BoxDecoration;
      expect(box.color, const Color(0xffffc107));
      expect(tester.getRect(underline).width, greaterThan(0));
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
