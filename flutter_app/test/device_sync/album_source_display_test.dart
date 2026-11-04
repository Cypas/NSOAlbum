import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../fixtures/device_sync/album_source_fixture.dart';

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets(
      'desktop hides album sources and shows image/video counts/$language',
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
        await tester.ensureVisible(find.byKey(const ValueKey('album-card-2')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            language == 'zh' ? '1 张图片 · 2 个视频' : '1 photo · 2 videos',
          ),
          findsWidgets,
        );
        expect(
          find.textContaining(
            language == 'zh' ? '3 张图片 · 0 个视频' : '3 photos · 0 videos',
          ),
          findsWidgets,
        );
        expect(
          find.textContaining(language == 'zh' ? '来源' : 'Source:'),
          findsNothing,
        );
        expect(
          find.text(language == 'zh' ? '来源未知' : 'Unknown source'),
          findsNothing,
        );
        expect(
          find.textContaining('FAVORITES_SOURCE_MUST_NOT_APPEAR'),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('album-card-2')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining(language == 'zh' ? '来源' : 'Source:'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
