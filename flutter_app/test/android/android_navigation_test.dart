@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/ui/android/android_library_page.dart';
import 'package:squid_album/src/ui/platform_ui.dart';
import 'package:squid_album/src/rust/models.dart';

import '../home_shell_test.dart' show FakeBackend;

MediaAsset fixture() => MediaAsset(
  id: 1,
  sha256: 'fixture',
  originalName: 'long-local-image.png',
  storagePath: 'C:/nonexistent/image.png',
  kind: MediaKind.image,
  importedAt: DateTime(2026, 10, 13),
  gameName: 'Game',
  favorite: false,
  note: '',
  tags: const [],
);

void main() {
  testWidgets('primary page back hides keyboard before returning to library', (
    tester,
  ) async {
    await tester.pumpWidget(
      SquidAlbumApp(
        backend: FakeBackend(mediaItems: []),
        uiPlatform: AppUiPlatform.android,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(NavigationBar), findsNothing);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('back hides keyboard then exits gallery search mode first', (
    tester,
  ) async {
    await tester.pumpWidget(
      SquidAlbumApp(
        backend: FakeBackend(mediaItems: []),
        uiPlatform: AppUiPlatform.android,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-library-search-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-library-search')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(const Key('android-library-search')), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.context?.widget,
      isNot(isA<EditableText>()),
    );
    tester.view.resetViewInsets();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-library-search')), findsNothing);
    expect(find.byKey(const Key('android-library-title')), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('system back exits batch selection before leaving library', (
    tester,
  ) async {
    await tester.pumpWidget(
      SquidAlbumApp(
        backend: FakeBackend(mediaItems: []),
        uiPlatform: AppUiPlatform.android,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-select-media')));
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 项'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 项'), findsNothing);
    expect(find.byKey(const Key('android-select-media')), findsOneWidget);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('system back closes search before leaving an album route', (
    tester,
  ) async {
    final backend = FakeBackend(
      mediaItems: [],
      albumItems: [
        AlbumSummary(
          id: 10,
          name: 'Search return album',
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
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('android-album-10')));
    await tester.pumpAndSettle();
    expect(find.text('Search return album'), findsOneWidget);
    expect(find.byKey(const Key('android-page-back')), findsOneWidget);

    await tester.tap(find.byKey(const Key('android-library-search-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('android-library-search')),
      'no match',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AndroidLibraryPage), findsOneWidget);
    expect(find.text('Search return album'), findsOneWidget);
    expect(find.byKey(const Key('android-page-back')), findsOneWidget);
    expect(find.byKey(const Key('android-library-search')), findsNothing);
    expect(find.byKey(const Key('android-library-title')), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AndroidLibraryPage), findsNothing);
    expect(find.byKey(const ValueKey('android-album-10')), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets(
    'secondary pages hide destinations and back protects an unsaved edit',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 860);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        SquidAlbumApp(
          backend: FakeBackend(mediaItems: [fixture()]),
          uiPlatform: AppUiPlatform.android,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('android-media-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑标签与备注'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('android-metadata-note')),
        'draft',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.byKey(const Key('android-page-back')));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('android-metadata-note')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}
