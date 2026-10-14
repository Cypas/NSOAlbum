@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/settings_copy.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  for (final size in [
    const Size(320, 860),
    const Size(860, 360),
    const Size(840, 900),
  ]) {
    for (final language in ['zh', 'en']) {
      testWidgets('secondary pages fit $size $language with large text', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final long = List.filled(20, 'Long游戏 name').join();
        final backend = FakeBackend(
          mediaItems: [
            MediaAsset(
              id: 1,
              sha256: 'image-fixture',
              originalName: '$long.png',
              storagePath: 'C:/nonexistent/image.png',
              kind: MediaKind.image,
              importedAt: DateTime(2026, 10, 13),
              gameName: long,
              favorite: false,
              tags: [long],
              note: long,
            ),
          ],
        );
        backend.settings = copyAppSettings(
          backend.settings,
          language: language,
        );
        await tester.pumpWidget(
          SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(NavigationDestination).at(2));
        await tester.pumpAndSettle();
        for (final entry in ['android-sync-entry', 'android-import-entry']) {
          await tester.ensureVisible(find.byKey(Key(entry)));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(Key(entry)));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const Key('android-page-back')));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byType(NavigationDestination).first);
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey('android-media-1'));
        await tester.ensureVisible(card);
        await tester.pumpAndSettle();
        await tester.tapAt(tester.getTopLeft(card) + const Offset(24, 24));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.byTooltip(language == 'zh' ? '编辑标签与备注' : 'Edit tags and note'),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }, variant: TargetPlatformVariant({TargetPlatform.android}));
    }
  }
}
