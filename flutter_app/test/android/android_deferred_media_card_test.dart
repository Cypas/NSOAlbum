import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/android/android_deferred_media_card.dart';
import 'package:squid_album/src/ui/android/android_media_card.dart';
import 'package:squid_album/src/ui/gallery_drag_loading.dart';
import 'package:squid_album/src/state/library_controller.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/ui/android/android_library_page.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets('real Android gallery defers new cards while touch is moving', (
    tester,
  ) async {
    final backend = FakeBackend(
      mediaItems: List.generate(
        80,
        (i) => MediaAsset(
          id: 50000 + i,
          sha256: i.toRadixString(16).padLeft(64, '0'),
          originalName: '$i.jpg',
          storagePath: 'missing-$i.jpg',
          kind: MediaKind.image,
          gameName: 'Game $i',
          favorite: false,
          tags: const ['Tag'],
        ),
      ),
    );
    final library = LibraryController(backend);
    final settings = SettingsController(backend);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: AndroidLibraryPage(controller: library, settings: settings),
      ),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(300, 450));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -300));
    await tester.pump();
    final placeholders = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<(String, int)> &&
          (widget.key! as ValueKey<(String, int)>).value.$1 ==
              'android-media-placeholder',
    );
    final viewport = tester.getRect(find.byType(CustomScrollView));
    final visible = placeholders
        .evaluate()
        .where(
          (element) =>
              tester.getRect(find.byWidget(element.widget)).overlaps(viewport),
        )
        .toList();
    expect(visible, isNotEmpty);
    final chosen = find.byWidget(visible.first.widget);
    final key = (visible.first.widget.key! as ValueKey<(String, int)>).value;
    final before = tester.getRect(chosen);
    await gesture.up();
    await tester.pumpAndSettle();
    final card = find.byKey(ValueKey('android-media-${key.$2}'));
    expect(card, findsOneWidget);
    // The entire row uses the same measured tags before and after hydration.
    expect(tester.getSize(card).height, closeTo(before.height, .01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    library.dispose();
    settings.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  for (final scale in [1.0, 2.0, 2.25]) {
    testWidgets('Android placeholders preserve tag geometry at ${scale}x', (
      tester,
    ) async {
      final experiment = GalleryLoadExperiment(enabled: true)
        ..setMode(GalleryLoadMode.settled);
      final controller = GalleryDragLoadController(experiment, cardsPerFrame: 2)
        ..begin()
        ..moved();
      final assets = List.generate(
        4,
        (i) => MediaAsset(
          id: 40000 + i,
          sha256: '$i'.padLeft(64, '0'),
          storagePath: 'missing-$i.png',
          originalName: '$i.png',
          kind: MediaKind.image,
          gameName: i == 0 ? '' : 'Long game name',
          favorite: false,
          tags: i < 2 ? const [] : ['标签一', 'Another tag', '第三个标签'],
        ),
      );
      final settings = FakeBackend().settings;
      Widget card(int index) => AndroidMediaCard(
        asset: assets[index],
        settings: settings,
        onOpen: () {},
        onMenu: () {},
        onFavorite: () {},
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQueryData(
              size: MediaQuery.sizeOf(context),
              textScaler: TextScaler.linear(scale),
              boldText: scale == 2.25,
              lineHeightScaleFactorOverride: scale == 2.25 ? 1.8 : null,
              letterSpacingOverride: scale == 2.25 ? 2 : null,
              wordSpacingOverride: scale == 2.25 ? 3 : null,
            ),
            child: scale == 2.25
                ? DefaultTextHeightBehavior(
                    textHeightBehavior: const TextHeightBehavior(
                      applyHeightToFirstAscent: false,
                      applyHeightToLastDescent: false,
                    ),
                    child: child!,
                  )
                : child!,
          ),
          home: GalleryPreviewLoadScope(
            controller: controller,
            child: SingleChildScrollView(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < 4; i++)
                    SizedBox(
                      key: ValueKey('slot-$i'),
                      width: 150,
                      child: AndroidDeferredMediaCard(
                        asset: assets[i],
                        settings: settings,
                        builder: (_) => card(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.byType(AndroidMediaCard), findsNothing);
      final heights = [
        for (var i = 0; i < 4; i++)
          tester.getSize(find.byKey(ValueKey('slot-$i'))).height,
      ];
      await tester.pump(const Duration(milliseconds: 49));
      expect(find.byType(AndroidMediaCard), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(find.byType(AndroidMediaCard), findsNWidgets(2));
      await tester.pumpAndSettle();
      expect(find.byType(AndroidMediaCard), findsNWidgets(4));
      for (var i = 0; i < 4; i++) {
        expect(
          tester.getSize(find.byKey(ValueKey('slot-$i'))).height,
          closeTo(heights[i], .01),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}
