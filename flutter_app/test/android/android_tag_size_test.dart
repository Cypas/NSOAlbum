import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/android/android_tag.dart';
import 'package:squid_album/src/ui/android/android_theme.dart';

void main() {
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
