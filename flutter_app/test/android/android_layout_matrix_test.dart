import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/ui/platform_ui.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/settings_copy.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  for (final width in [320.0, 360.0, 412.0, 600.0, 840.0]) {
    for (final language in ['zh', 'en']) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('pages fit $width $language text scale $scale', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 860);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final long = List.filled(30, 'Long游戏').join();
          final backend = FakeBackend(
            mediaItems: [
              MediaAsset(
                id: 1,
                sha256: 'fixture',
                originalName: '$long.png',
                storagePath: 'C:/nonexistent/image.png',
                kind: MediaKind.image,
                importedAt: DateTime(2026, 10, 13),
                gameName: long,
                favorite: false,
                note: long,
                tags: [long, 'another tag'],
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
          expect(tester.takeException(), isNull);
          for (var i = 1; i < 4; i++) {
            await tester.tap(find.byType(NavigationDestination).at(i));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }, variant: TargetPlatformVariant({TargetPlatform.android}));
      }
    }
  }
}
