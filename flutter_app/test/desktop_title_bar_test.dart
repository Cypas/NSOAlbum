@Tags(['common'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/ui/font_families.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  setUp(() async => loadCustomFontFamilies(const []));

  testWidgets('custom title bar renders app branding and window controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: appFontFamily,
          fontFamilyFallback: appFontFallback,
        ),
        home: const DesktopTitleBar(
          title: 'NSOAlbum',
          iconAsset: 'assets/tray/app_icon.png',
        ),
      ),
    );

    expect(find.byKey(const Key('desktop-titlebar')), findsOneWidget);
    expect(find.byKey(const Key('desktop-titlebar-icon')), findsOneWidget);
    expect(find.byKey(const Key('desktop-titlebar-title')), findsOneWidget);
    expect(find.byKey(const Key('desktop-titlebar-minimize')), findsOneWidget);
    expect(find.byKey(const Key('desktop-titlebar-maximize')), findsOneWidget);
    expect(find.byKey(const Key('desktop-titlebar-close')), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const Key('desktop-titlebar-maximize')),
        matching: find.byType(DragToMoveArea),
      ),
      findsNothing,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('desktop-titlebar-title')))
          .style
          ?.fontFamily,
      'DFPT_ZY9',
    );
  });

  testWidgets('Chinese brand title uses one complete CJK family', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: appFontFamily,
          fontFamilyFallback: appFontFallback,
        ),
        home: const DesktopTitleBar(
          title: '鱿型相册',
          iconAsset: 'assets/tray/app_icon.png',
        ),
      ),
    );

    final title = tester.widget<Text>(
      find.byKey(const Key('desktop-titlebar-title')),
    );
    expect(title.style?.fontFamily, 'DFP_GBZY9');
    expect(title.style?.fontFamilyFallback, ['DFPT_ZY9', 'BlitzMain']);
    expect(
      tester.getSize(find.byKey(const Key('desktop-titlebar-brand-underline'))),
      const Size(40, 3),
    );
  });
}
