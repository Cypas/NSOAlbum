import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../fixtures/device_sync/album_source_fixture.dart';

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets(
      'desktop distinguishes same-name album sources and details at 1280dp/$language',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          SquidAlbumApp(
            backend: albumSourceBackend(language: language),
            uiPlatform: AppUiPlatform.desktop,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('sidebar-destination-1')));
        await tester.pumpAndSettle();
        final known = language == 'zh' ? '来源：Desktop' : 'Source: Desktop';
        await tester.ensureVisible(find.byKey(const ValueKey('album-card-2')));
        await tester.pumpAndSettle();
        expect(find.text(known), findsOneWidget);
        expect(
          find.text(language == 'zh' ? '来源：Phone' : 'Source: Phone'),
          findsOneWidget,
        );
        expect(
          find.text(language == 'zh' ? '来源未知' : 'Unknown source'),
          findsOneWidget,
        );
        expect(
          find.textContaining('FAVORITES_SOURCE_MUST_NOT_APPEAR'),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('album-card-2')));
        await tester.pumpAndSettle();
        expect(find.textContaining(known), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
