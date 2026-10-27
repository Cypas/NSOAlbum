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

  for (final language in ['zh', 'en']) {
    testWidgets(
      'primary destinations show each name only in navigation in $language',
      (tester) async {
        await openApp(tester, language: language);
        final labels = language == 'zh'
            ? ['图库', '相册', '导入与同步', '设置']
            : ['Library', 'Albums', 'Sync & Import', 'Settings'];
        for (var index = 0; index < labels.length; index++) {
          await tester.tap(find.byType(NavigationDestination).at(index));
          await tester.pumpAndSettle();
          expect(find.text(labels[index]), findsOneWidget);
          expect(find.byKey(const Key('android-page-back')), findsNothing);
          if (index == 0) {
            expect(
              find.byKey(const Key('android-library-filter')),
              findsOneWidget,
            );
            await tester.tap(find.byKey(const Key('android-select-media')));
            await tester.pumpAndSettle();
            expect(
              find.text(language == 'zh' ? '已选择 0 项' : '0 selected'),
              findsOneWidget,
            );
            await tester.tap(find.byKey(const Key('android-page-back')));
            await tester.pumpAndSettle();
          } else if (index == 1) {
            await tester.tap(
              find.byTooltip(language == 'zh' ? '创建相册' : 'Create album'),
            );
            await tester.pumpAndSettle();
            expect(
              find.text(language == 'zh' ? '编辑相册' : 'Edit album'),
              findsOneWidget,
            );
            expect(find.byKey(const Key('android-page-back')), findsOneWidget);
            await tester.tap(find.byKey(const Key('android-page-back')));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
        }
      },
      variant: TargetPlatformVariant({TargetPlatform.android}),
    );
  }

  testWidgets(
    'primary pages without actions remove the title gap and respect the status bar',
    (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await openApp(tester);

      await tester.tap(find.byType(NavigationDestination).at(2));
      await tester.pumpAndSettle();
      final transferTop = tester.getTopLeft(find.byType(Card).first).dy;
      expect(transferTop, greaterThanOrEqualTo(24));
      expect(transferTop, lessThan(60));
      expect(find.byType(AppBar), findsNothing);

      await tester.tap(find.byType(NavigationDestination).at(3));
      await tester.pumpAndSettle();
      final settingsTop = tester
          .getTopLeft(find.byType(DropdownButtonFormField<String>).first)
          .dy;
      expect(settingsTop, greaterThanOrEqualTo(24));
      expect(settingsTop, lessThan(60));
      expect(find.byType(AppBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

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

  testWidgets(
    'gallery brand title uses compact desktop typography without changing body text',
    (tester) async {
      await openApp(tester);
      final brand = find.byKey(const Key('android-library-title'));
      final title = tester.widget<Text>(brand);
      expect(title.style?.fontFamily, 'DFP_GBZY9');
      expect(title.style?.fontFamilyFallback, ['DFPT_ZY9', 'BlitzMain']);
      expect(title.style?.fontSize, 14);
      expect(title.style?.fontWeight, FontWeight.w700);
      expect(
        Theme.of(tester.element(brand)).textTheme.bodyMedium?.fontFamily,
        isNot('DFPT_ZY9'),
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

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
