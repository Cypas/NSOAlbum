import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/scroll_to_top_button.dart';

void main() {
  testWidgets('appears after scrolling and returns to the top', (tester) async {
    final controller = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 300,
          child: Stack(
            children: [
              ListView.builder(
                controller: controller,
                itemCount: 40,
                itemBuilder: (context, index) =>
                    SizedBox(height: 40, child: Text('item $index')),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: ScrollToTopButton(
                    controller: controller,
                    tooltip: 'Back to top',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final button = find.byTooltip('Back to top');
    expect(button, findsOneWidget);
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(of: button, matching: find.byType(IgnorePointer))
                .first,
          )
          .ignoring,
      isTrue,
    );

    controller.jumpTo(500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(of: button, matching: find.byType(IgnorePointer))
                .first,
          )
          .ignoring,
      isFalse,
    );

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(controller.position.pixels, 0);
  });
}
