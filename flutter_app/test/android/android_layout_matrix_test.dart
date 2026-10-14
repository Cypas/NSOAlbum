import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/state/settings_copy.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;
import 'android_experience_test.dart' show media;

void main() {
  for (final language in ['zh', 'en']) {
    for (final width in [320.0, 360.0, 412.0, 600.0, 640.0, 840.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets(
          '$language ${width}dp ${scale}x root pages stay within bounds',
          (tester) async {
            tester.view.physicalSize = Size(width, width == 640 ? 360 : 800);
            tester.view.devicePixelRatio = 1;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final long = List.filled(30, 'Long游戏').join();
            final backend = FakeBackend(
              mediaItems: [
                MediaAsset(
                  id: 1,
                  sha256: 'fixture-long',
                  originalName: '$long.png',
                  storagePath: 'missing.png',
                  kind: MediaKind.image,
                  importedAt: DateTime(2026, 10, 14),
                  gameName: long,
                  favorite: false,
                  note: long,
                  tags: [long, 'another tag'],
                ),
                media(2),
              ],
            );
            backend.settings = copyAppSettings(
              backend.settings,
              language: language,
              galleryColumns: 2,
            );
            await tester.pumpWidget(
              SquidAlbumApp(
                backend: backend,
                uiPlatform: AppUiPlatform.android,
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: 'initial gallery');
            for (var index = 1; index < 4; index++) {
              await tester.tap(find.byType(NavigationDestination).at(index));
              await tester.pumpAndSettle();
              expect(
                tester.takeException(),
                isNull,
                reason: 'destination $index',
              );
              if (index == 3) {
                await tester.tap(find.byType(DropdownButtonFormField<String>));
                await tester.pumpAndSettle();
                expect(tester.takeException(), isNull, reason: 'language menu');
                await tester.binding.handlePopRoute();
                await tester.pumpAndSettle();
              }
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          },
          variant: TargetPlatformVariant({TargetPlatform.android}),
        );
      }
    }
  }
}
