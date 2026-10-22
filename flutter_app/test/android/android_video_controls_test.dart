@Tags(['platform-android'])
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/ui/android/android_theme.dart';
import 'package:squid_album/src/ui/android/android_video_controls.dart';

void main() {
  testWidgets(
    'preparing video retains track appearance without admitting seeks',
    (tester) async {
      final boundaryKey = GlobalKey();
      final seeks = <Duration>[];
      Widget app(bool ready) => MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        theme: androidTheme('ocean'),
        home: Scaffold(
          body: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 360,
              child: AndroidVideoControls(
                enabled: ready,
                playing: false,
                position: Duration.zero,
                duration: ready ? const Duration(minutes: 1) : Duration.zero,
                muted: false,
                onToggle: () {},
                onMute: () {},
                onSeek: seeks.add,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      final slider = find.byKey(const Key('android-video-seek'));
      final firstState = tester.state(slider);
      expect(tester.widget<Slider>(slider).onChanged, isNull);
      final before = await _trackPixel(tester, boundaryKey, slider);
      final beforeThumb = await _trackPixel(
        tester,
        boundaryKey,
        slider,
        thumb: true,
      );
      await tester.tap(slider);
      await tester.pumpAndSettle();
      expect(seeks, isEmpty);

      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(tester.state(slider), same(firstState));
      expect(tester.widget<Slider>(slider).onChanged, isNotNull);
      final after = await _trackPixel(tester, boundaryKey, slider);
      final afterThumb = await _trackPixel(
        tester,
        boundaryKey,
        slider,
        thumb: true,
      );
      expect(
        after,
        [143, 143, 143, 255],
        reason: 'The sampled pixel must belong to the painted progress track.',
      );
      expect(
        before,
        after,
        reason: 'Enabling the loaded video must not flash the entire track to a new color.',
      );
      expect(
        beforeThumb,
        afterThumb,
        reason: 'The prepared thumb must retain its paint as seeking becomes available.',
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<List<int>> _trackPixel(
  WidgetTester tester,
  GlobalKey key,
  Finder slider, {
  bool thumb = false,
}) async {
  final bounds = tester.getRect(slider);
  final surface = tester.getRect(find.byKey(key));
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final x = (bounds.left - surface.left + (thumb ? 24 : bounds.width * .75))
      .round();
  final y = (bounds.center.dy - surface.top).round();
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final offset = (y * image.width + x) * 4;
      return bytes!.buffer.asUint8List().sublist(offset, offset + 4);
    } finally {
      image.dispose();
    }
  }))!;
}
