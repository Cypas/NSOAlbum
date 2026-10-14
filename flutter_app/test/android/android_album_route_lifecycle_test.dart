import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/android/android_library_page.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  for (final favorites in [true, false]) {
    for (final systemBack in [false, true]) {
      testWidgets(
        '${favorites ? 'favorites' : 'ordinary'} album keeps its controller '
        'alive through ${systemBack ? 'system' : 'arrow'} return',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(360, 800);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final semantics = tester.ensureSemantics();
          await tester.pumpWidget(
            SquidAlbumApp(
              backend: FakeBackend(mediaItems: [])
                ..albumItems = [
                  AlbumSummary(
                    id: 1,
                    name: favorites ? '收藏' : 'Test album',
                    description: '',
                    albumType: favorites ? 'smart' : 'manual',
                    pinned: favorites,
                    systemKey: favorites ? 'favorites' : null,
                    mediaCount: BigInt.zero,
                  ),
                ],
              uiPlatform: AppUiPlatform.android,
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byType(NavigationDestination).at(1));
          await tester.pumpAndSettle();
          final card = find.byKey(const ValueKey('android-album-1'));
          await tester.tap(
            find.descendant(of: card, matching: find.byType(InkWell)).first,
          );
          await tester.pumpAndSettle();
          final page = tester.widget<AndroidLibraryPage>(
            find.byType(AndroidLibraryPage),
          );
          final controller = page.controller;
          expect(controller.disposed, isFalse);
          expect(find.byType(NavigationBar), findsNothing);

          if (systemBack) {
            await tester.binding.handlePopRoute();
          } else {
            await tester.tap(find.byKey(const Key('android-page-back')));
          }
          await tester.pump();
          expect(find.byType(AndroidLibraryPage), findsOneWidget);
          expect(
            controller.disposed,
            isFalse,
            reason: 'The exiting album still needs its controller.',
          );
          // A rebuild during reverse animation must not attach listeners to a
          // disposed controller, even with Android semantics enabled.
          tester.element(find.byType(AndroidLibraryPage)).markNeedsBuild();
          await tester.pump(const Duration(milliseconds: 50));
          expect(tester.takeException(), isNull);
          expect(controller.disposed, isFalse);
          await tester.pumpAndSettle();
          expect(find.byType(AndroidLibraryPage), findsNothing);
          expect(controller.disposed, isTrue);
          expect(find.byType(NavigationBar), findsOneWidget);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
        variant: TargetPlatformVariant({TargetPlatform.android}),
      );
    }
  }
}
