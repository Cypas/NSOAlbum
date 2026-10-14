import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
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
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
    tester.view.resetViewInsets();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('back hides library keyboard before exiting batch selection', (
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
    await tester.tap(find.byKey(const Key('android-library-search')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('已选择 0 项'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.context?.widget,
      isNot(isA<EditableText>()),
    );
    tester.view.resetViewInsets();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 项'), findsNothing);
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
      await tester.tap(find.byTooltip('编辑标签与备注'));
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
