@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/state/settings_copy.dart';
import 'package:squid_album/src/ui/platform_ui.dart';
import 'package:squid_album/src/ui/android/android_settings_page.dart';
import 'package:squid_album/src/rust/models.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets('Android settings hide compact-tag option and library path', (
    tester,
  ) async {
    final backend = FakeBackend(mediaItems: []);
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    expect(find.text('标签紧凑展示'), findsNothing);
    expect(find.text('Compact tags'), findsNothing);
    expect(find.text('显示备注摘要'), findsNothing);
    expect(find.text('Show note previews'), findsNothing);
    expect(
      find.byKey(const Key('android-storage-permission-card')),
      findsNothing,
    );
    expect(find.byKey(const Key('android-storage-permission')), findsNothing);
    expect(find.byKey(const Key('android-storage-card')), findsNothing);
    expect(find.byKey(const Key('android-storage-location')), findsNothing);
    expect(find.textContaining('图库路径：'), findsNothing);
    expect(find.textContaining('Library:'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  for (final language in ['zh', 'en']) {
    testWidgets(
      'Android settings uses rounded sections and compact language options in $language at large text',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 800);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final backend = FakeBackend(mediaItems: []);
        backend.settings = copyAppSettings(
          backend.settings,
          language: language,
        );
        await tester.pumpWidget(
          SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(NavigationDestination).at(3));
        await tester.pumpAndSettle();

        final appearanceCard = find.byKey(
          const Key('android-appearance-settings-card'),
        );
        final displayCard = find.byKey(
          const Key('android-display-settings-card'),
        );
        final networkCard = find.byKey(
          const Key('android-network-settings-card'),
          skipOffstage: false,
        );
        final splatoonCard = find.byKey(
          const Key('android-splatoon-settings-card'),
          skipOffstage: false,
        );
        expect(appearanceCard, findsOneWidget);
        expect(displayCard, findsOneWidget);
        expect(
          tester.widget<Card>(appearanceCard).shape,
          isA<RoundedRectangleBorder>(),
        );
        final appearanceShape =
            tester.widget<Card>(appearanceCard).shape as RoundedRectangleBorder;
        final appearanceRadius = appearanceShape.borderRadius as BorderRadius;
        expect(appearanceRadius.topLeft.x, 16);
        expect(
          tester.widget<Card>(displayCard).shape,
          isA<RoundedRectangleBorder>(),
        );
        final languageField = find.byType(DropdownButtonFormField<String>);
        await tester.ensureVisible(languageField);
        await tester.tap(languageField);
        await tester.pumpAndSettle();
        final englishOption = find.text('English').last;
        expect(englishOption, findsOneWidget);
        expect(tester.widget<Text>(englishOption).style?.fontSize, 14);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        final settingsScroll = find
            .descendant(
              of: find.byType(AndroidSettingsPage),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          networkCard,
          240,
          scrollable: settingsScroll,
        );
        await tester.pumpAndSettle();
        expect(networkCard, findsOneWidget);
        expect(
          find.descendant(
            of: networkCard,
            matching: find.byKey(const Key('android-doh-enabled')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: networkCard,
            matching: find.text(
              language == 'zh'
                  ? '同步一直请求失败时可以尝试开启此选项'
                  : 'If synchronization keeps failing, try enabling this option.',
              skipOffstage: false,
            ),
          ),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          splatoonCard,
          320,
          scrollable: settingsScroll,
        );
        await tester.pumpAndSettle();
        expect(splatoonCard, findsOneWidget);
        expect(
          find.descendant(
            of: displayCard,
            matching: find.byKey(const Key('android-splatoon-friend-activity')),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: splatoonCard,
            matching: find.byKey(const Key('android-splatoon-friend-activity')),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('android-storage-permission-card')),
          findsNothing,
        );
        expect(find.byKey(const Key('android-storage-card')), findsNothing);

        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({TargetPlatform.android}),
    );
  }

  testWidgets('one media per row is saved and used in library and albums', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeBackend(
      mediaItems: [
        for (final id in [1, 2])
          MediaAsset(
            id: id,
            sha256: 'single-column-$id',
            originalName: 'test$id.png',
            storagePath: 'missing.png',
            kind: MediaKind.image,
            importedAt: DateTime(2026, 10, 14),
            gameName: 'Game',
            favorite: false,
            tags: const [],
          ),
      ],
      albumItems: [
        for (final id in [1, 2])
          AlbumSummary(
            id: id,
            name: 'Album $id',
            description: '',
            albumType: 'manual',
            pinned: false,
            mediaCount: BigInt.zero,
          ),
      ],
    );
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    final slider = find.byType(Slider);
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    final rect = tester.getRect(slider);
    await tester.tapAt(Offset(rect.left + 1, rect.center.dy));
    await tester.pumpAndSettle();
    expect(backend.settings.galleryColumns, 1);
    expect(tester.widget<Slider>(slider).value, 1);
    await tester.tap(find.byType(NavigationDestination).at(0));
    await tester.pumpAndSettle();
    final first = tester.getTopLeft(
      find.byKey(const ValueKey('android-media-1')),
    );
    final second = tester.getTopLeft(
      find.byKey(const ValueKey('android-media-2')),
    );
    expect(first.dx, second.dx);
    expect(first.dy, isNot(second.dy));
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      1,
    );
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 1);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('Android retains author information and tag creation', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'NSOAlbum',
      packageName: 'io.github.cypas.nsoalbum',
      version: '4.5.6',
      buildNumber: '78',
      buildSignature: '',
    );
    final backend = _TagBackend();
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    final settingsScroll = find
        .descendant(
          of: find.byType(AndroidSettingsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('android-manage-tags')),
      320,
      scrollable: settingsScroll,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('android-about-card')),
      200,
      scrollable: settingsScroll,
    );
    await tester.pumpAndSettle();
    expect(find.text('Cypas_Nya'), findsOneWidget);
    expect(find.text('小鱿鱿bot作者'), findsOneWidget);
    expect(find.text('版本 4.5.6+78 Debug'), findsOneWidget);
    expect(find.byKey(const Key('android-about-github-link')), findsOneWidget);
    expect(
      find.byKey(const Key('android-about-feedback-link')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('android-manage-tags')),
      -200,
      scrollable: settingsScroll,
    );
    await tester.tap(find.byKey(const Key('android-manage-tags')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新增标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '独立标签');
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(backend.createdTags, ['独立标签']);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}

class _TagBackend extends FakeBackend {
  _TagBackend() : super(mediaItems: []);
  final createdTags = <String>[];
  @override
  Future<int> createTag(String name) async {
    createdTags.add(name);
    return createdTags.length;
  }
}
