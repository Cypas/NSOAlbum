@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/ui/android/android_media_swipe_region.dart';
import 'package:squid_album/src/ui/android/android_video_controls.dart';
import 'package:squid_album/src/ui/android/android_video_failure_view.dart';

void main() {
  testWidgets('failed video can still swipe to another media', (tester) async {
    final changes = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        home: Scaffold(body: AndroidVideoFailureView(onSwipe: changes.add)),
      ),
    );
    expect(find.text('Unable to play this video'), findsOneWidget);
    await tester.drag(
      find.byType(AndroidVideoFailureView),
      const Offset(-180, 0),
    );
    expect(changes, [1]);
    await tester.drag(
      find.byType(AndroidVideoFailureView),
      const Offset(180, 0),
    );
    expect(changes, [1, -1]);
  });

  for (final language in ['zh', 'en']) {
    for (final brightness in Brightness.values) {
      testWidgets('video controls $language $brightness fit 320dp at 2x', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 640);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        var toggles = 0;
        var mutes = 0;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: AndroidVideoControls(
                  playing: false,
                  position: const Duration(seconds: 12),
                  duration: const Duration(minutes: 3),
                  muted: false,
                  onToggle: () {
                    toggles++;
                  },
                  onMute: () {
                    mutes++;
                  },
                  onSeek: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip(language == 'zh' ? '播放' : 'Play'));
        await tester.tap(find.byTooltip(language == 'zh' ? '静音' : 'Mute'));
        expect(toggles, 1);
        expect(mutes, 1);
        expect(find.text('00:12 / 03:00'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'video swipe changes media, seek drag only changes playback time',
    (tester) async {
      final swipes = <int>[];
      final seeks = <Duration>[];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [AppLocalizations.delegate],
          locale: const Locale('en'),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: AndroidMediaSwipeRegion(
                      onSwipe: swipes.add,
                      child: const ColoredBox(
                        key: Key('picture-area'),
                        color: Colors.blueGrey,
                      ),
                    ),
                  ),
                  AndroidVideoControls(
                    playing: false,
                    position: const Duration(seconds: 10),
                    duration: const Duration(seconds: 60),
                    muted: false,
                    onToggle: () {},
                    onMute: () {},
                    onSeek: seeks.add,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.text('00:10 / 01:00'), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('picture-area')),
        const Offset(-150, 0),
      );
      expect(swipes, [1]);
      await tester.drag(
        find.byKey(const Key('android-video-seek')),
        const Offset(100, 0),
      );
      expect(seeks, isNotEmpty);
      expect(seeks.last.inSeconds, greaterThan(30));
      expect(swipes, [1]);
    },
  );

  testWidgets('pinch and zoomed pan do not switch media', (tester) async {
    final swipes = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AndroidMediaSwipeRegion(
          onSwipe: swipes.add,
          child: const SizedBox.expand(),
        ),
      ),
    );
    final one = await tester.startGesture(const Offset(100, 150), pointer: 1);
    final two = await tester.startGesture(const Offset(160, 150), pointer: 2);
    await one.moveBy(const Offset(-100, 0));
    await two.moveBy(const Offset(100, 0));
    await one.up();
    await two.up();
    expect(swipes, isEmpty);
    await tester.pumpWidget(
      MaterialApp(
        home: AndroidMediaSwipeRegion(
          enabled: false,
          onSwipe: swipes.add,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.drag(
      find.byType(AndroidMediaSwipeRegion),
      const Offset(-150, 0),
    );
    expect(swipes, isEmpty);
  });
}
