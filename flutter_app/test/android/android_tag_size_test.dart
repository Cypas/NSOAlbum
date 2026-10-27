@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/android/android_tag.dart';
import 'package:squid_album/src/ui/android/android_theme.dart';

import '../layout_viewport.dart';

void main() {
  testWidgets('long tag tooltips wrap inside a narrow dark large-text screen', (
    tester,
  ) async {
    await useLayoutTestViewport(tester, const Size(320, 640));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const label =
        'これは長いゲームタイトルです / A long game tag that must remain fully readable';
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: Brightness.dark,
          ),
        ),
        home: const Scaffold(
          body: Center(
            child: AndroidTag(label: label, game: true, compact: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(AndroidTag));
    await tester.pumpAndSettle();
    final bubble = find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == label,
    );
    final text = tester.widget<RichText>(bubble);
    expect(text.text.style?.color, Colors.black);
    expect(tester.getRect(bubble).left, greaterThanOrEqualTo(12));
    expect(tester.getRect(bubble).right, lessThanOrEqualTo(308));
    expect(tester.getSize(bubble).height, greaterThan(24));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  for (final game in [true, false]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'tag long-press bubble is compact and keeps the full label, game $game at ${scale}x',
        (tester) async {
          await useLayoutTestViewport(tester, const Size(320, 640));
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          const label = '完整游戏标签';
          await tester.pumpWidget(
            MaterialApp(
              theme: androidTheme('ocean'),
              home: Scaffold(
                body: Center(
                  child: AndroidTag(label: label, game: game, compact: true),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final tag = find.byType(AndroidTag);
          final tagSize = tester.getSize(tag);

          await tester.longPress(tag);
          await tester.pumpAndSettle();
          final bubble = find.byWidgetPredicate(
            (widget) =>
                widget is RichText && widget.text.toPlainText() == label,
          );
          expect(bubble, findsOneWidget);
          final text = tester.widget<RichText>(bubble);
          expect(text.text.style?.fontSize, 11);
          final decoration = find
              .ancestor(of: bubble, matching: find.byType(DecoratedBox))
              .first;
          expect(
            tester.getSize(decoration).height,
            lessThanOrEqualTo(scale == 1 ? 24 : 40),
          );
          expect(
            tester.getSize(decoration).width,
            lessThanOrEqualTo(scale == 1 ? 100 : 170),
          );
          expect(tester.getSize(tag), tagSize);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 2));
        },
      );
    }
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('card tags are smaller than detail tags at ${scale}x text', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: androidTheme('ocean'),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: const Scaffold(
              body: Wrap(
                children: [
                  AndroidTag(
                    key: Key('compact'),
                    label: 'Tag',
                    game: true,
                    compact: true,
                  ),
                  AndroidTag(key: Key('detail'), label: 'Tag'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final compact = find.byKey(const Key('compact'));
      final detail = find.byKey(const Key('detail'));
      final smallText = tester.widget<Text>(
        find.descendant(of: compact, matching: find.byType(Text)),
      );
      final fullText = tester.widget<Text>(
        find.descendant(of: detail, matching: find.byType(Text)),
      );
      expect(smallText.style!.fontSize, lessThan(fullText.style!.fontSize!));
      expect(
        tester.getSize(compact).height,
        lessThan(tester.getSize(detail).height),
      );
      expect(
        tester.getSize(compact).width,
        lessThan(tester.getSize(detail).width),
      );
      final compactBox = tester.widget<Container>(
        find.descendant(of: compact, matching: find.byType(Container)),
      );
      final detailBox = tester.widget<Container>(
        find.descendant(of: detail, matching: find.byType(Container)),
      );
      expect(
        (compactBox.decoration! as BoxDecoration).color,
        isNot((detailBox.decoration! as BoxDecoration).color),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
