import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  Future<void> openApp(WidgetTester tester, {double width = 412}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 860);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      SquidAlbumApp(
        backend: FakeBackend(mediaItems: []),
        uiPlatform: AppUiPlatform.android,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Android uses its own shell even on a wide display', (
    tester,
  ) async {
    await openApp(tester, width: 1000);
    expect(find.byKey(const Key('android-shell')), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(const Key('desktop-sidebar')), findsNothing);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('Android uses platform typography rather than desktop families', (
    tester,
  ) async {
    await openApp(tester);
    final title = find.text('图库').first;
    final theme = Theme.of(tester.element(title));
    expect(theme.textTheme.bodyMedium?.fontFamily, isNot('DFPT_ZY9'));
    expect(theme.textTheme.bodyMedium?.fontFamilyFallback, isNull);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('transfer uses two task entries with no USB or tabs', (
    tester,
  ) async {
    await openApp(tester);
    await tester.tap(find.text('导入与同步').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-sync-entry')), findsOneWidget);
    expect(find.byKey(const Key('android-import-entry')), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('USB 导入'), findsNothing);
    await tester.tap(find.byKey(const Key('android-import-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-page-back')), findsOneWidget);
    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-sync-entry')), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('system back returns from a primary destination to library', (
    tester,
  ) async {
    await openApp(tester);
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final navigation = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navigation.selectedIndex, 0);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}
