import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/gallery_return_layout.dart';
import 'package:squid_album/src/ui/scroll_to_top_button.dart';

void main() {
  testWidgets(
    'far variable-list relocation does not construct skipped middle rows',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final built = <int>[];
      var generation = 0;
      late StateSetter update;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _variableGallery(controller, built, generation: generation);
          },
        ),
      );
      final unbind = GalleryReturnLayout.bind(
        controller,
        () => update(() => generation++),
      );
      addTearDown(unbind);
      controller.jumpTo(50000);
      await tester.pumpAndSettle();
      built.clear();

      final returned = scrollGalleryToTop(controller);
      await tester.pumpAndSettle();
      await returned;

      expect(
        built.where((index) => index >= 30 && index < 500),
        isEmpty,
        reason: 'A return to the top must not realize hundreds of skipped variable-height rows.',
      );
      expect(controller.offset, 0);
      expect(generation, 1);
    },
  );

  test(
    'unbinding an old gallery does not remove its replacement layout binding',
    () {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var first = 0, replacement = 0;
      final oldUnbind = GalleryReturnLayout.bind(controller, () => first++);
      final unbind = GalleryReturnLayout.bind(controller, () => replacement++);
      oldUnbind();
      GalleryReturnLayout.reset(controller);
      expect(first, 0);
      expect(replacement, 1);
      unbind();
      unbind();
      GalleryReturnLayout.reset(controller);
      expect(replacement, 1);
    },
  );

  testWidgets('near return keeps the existing animation without a jump', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_gallery(controller));
    controller.jumpTo(600);
    final returned = scrollGalleryToTop(controller);
    expect(controller.offset, 600);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(600));
    await tester.pumpAndSettle();
    await returned;
    expect(controller.offset, 0);
  });

  testWidgets(
    'far return jumps near the top before animating the last viewport',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_gallery(controller));
      controller.jumpTo(5000);
      final returned = scrollGalleryToTop(controller);
      expect(controller.offset, 400);
      await tester.pump();
      expect(
        controller.offset,
        400,
        reason: 'Animation starts after the near-top layout has completed.',
      );
      await tester.pumpAndSettle();
      await returned;
      expect(controller.offset, 0);
    },
  );

  testWidgets('repeated return requests share one in-flight operation', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_gallery(controller));
    controller.jumpTo(5000);
    final first = scrollGalleryToTop(controller);
    final repeated = scrollGalleryToTop(controller);
    expect(identical(first, repeated), isTrue);
    await tester.pumpAndSettle();
    await Future.wait([first, repeated]);
    expect(controller.offset, 0);
    controller.jumpTo(600);
    final next = scrollGalleryToTop(controller);
    expect(identical(first, next), isFalse);
    await tester.pumpAndSettle();
    await next;
  });

  testWidgets(
    'a drag during far-return preparation cancels the remaining animation',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_gallery(controller));
      controller.jumpTo(5000);
      final returned = scrollGalleryToTop(controller);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('gallery-list'))),
      );
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      await returned;
      expect(controller.offset, greaterThan(0));
    },
  );

  testWidgets(
    'a drag interrupts the ordinary near return without restarting it',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_gallery(controller));
      controller.jumpTo(600);
      final returned = scrollGalleryToTop(controller);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.drag(
        find.byKey(const Key('gallery-list')),
        const Offset(0, -100),
      );
      await tester.pumpAndSettle();
      await returned;
      expect(controller.offset, greaterThan(0));
    },
  );

  for (final offset in [600.0, 5000.0]) {
    testWidgets('disposing the page during return from $offset stops safely', (
      tester,
    ) async {
      final controller = ScrollController();
      await tester.pumpWidget(_gallery(controller));
      controller.jumpTo(offset);
      final returned = scrollGalleryToTop(controller);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pumpAndSettle();
      await returned;
      expect(tester.takeException(), isNull);
    });
  }

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

Widget _gallery(ScrollController controller) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 400,
      height: 400,
      child: ListView.builder(
        key: const Key('gallery-list'),
        controller: controller,
        itemExtent: 40,
        itemCount: 400,
        itemBuilder: (context, index) => Text('item $index'),
      ),
    ),
  ),
);

Widget _variableGallery(
  ScrollController controller,
  List<int> built, {
  int generation = 0,
}) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 400,
      height: 400,
      child: CustomScrollView(
        controller: controller,
        slivers: [
          SliverList.builder(
            key: ValueKey(generation),
            itemCount: 800,
            itemBuilder: (context, index) {
              built.add(index);
              return SizedBox(
                height: 80 + index % 5 * 7,
                child: Text('item $index'),
              );
            },
          ),
        ],
      ),
    ),
  ),
);
