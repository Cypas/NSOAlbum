@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/state/settings_copy.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  Future<void> openApp(
    WidgetTester tester, {
    double width = 412,
    String language = 'zh',
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 860);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeBackend(mediaItems: []);
    backend.settings = copyAppSettings(backend.settings, language: language);
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
  }

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
