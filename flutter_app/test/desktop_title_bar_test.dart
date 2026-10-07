import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';

void main() {
  testWidgets('custom title bar renders app branding and window controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'SmileySans'),
        home: const DesktopTitleBar(
          title: 'Fresh Album',
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
      tester.widget<Text>(find.byKey(const Key('desktop-titlebar-title'))).style?.fontFamily,
      'SmileySans',
    );
  });
}
