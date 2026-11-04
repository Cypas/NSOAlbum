import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/desktop_fluid_scroll_physics.dart';

void main() {
  testWidgets('reduced motion keeps wheel immediate', (tester) async {
    final controller = DesktopGalleryScrollController();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: DesktopSmoothScroll(
          controller: controller,
          child: ListView(
            controller: controller,
            children: const [SizedBox(height: 4000)],
          ),
        ),
      ),
    );
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(200, 200),
        scrollDelta: Offset(0, 120),
      ),
    );
    expect(controller.offset, 120);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('nested lists consume wheel before the smooth outer gallery', (
    tester,
  ) async {
    final outer = DesktopGalleryScrollController();
    final inner = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopSmoothScroll(
          controller: outer,
          child: ListView(
            controller: outer,
            children: [
              SizedBox(
                height: 200,
                child: ListView(
                  controller: inner,
                  children: const [SizedBox(height: 2000)],
                ),
              ),
              const SizedBox(height: 4000),
            ],
          ),
        ),
      ),
    );
    const event = PointerScrollEvent(
      position: Offset(200, 100),
      scrollDelta: Offset(0, 120),
    );
    await tester.sendEventToBinding(event);
    expect(inner.offset, 120);
    expect(outer.offset, 0);
    inner.jumpTo(inner.position.maxScrollExtent);
    await tester.pump();
    await tester.sendEventToBinding(event);
    await tester.pumpAndSettle();
    expect(outer.offset, closeTo(120, .01));
    await tester.pumpWidget(const SizedBox());
    inner.dispose();
    outer.dispose();
  });

  testWidgets('trackpad stays immediate and touching interrupts wheel easing', (
    tester,
  ) async {
    final controller = DesktopGalleryScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopSmoothScroll(
          controller: controller,
          child: ListView(
            controller: controller,
            children: const [SizedBox(height: 4000)],
          ),
        ),
      ),
    );
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        kind: PointerDeviceKind.trackpad,
        position: Offset(200, 200),
        scrollDelta: Offset(0, 120),
      ),
    );
    expect(controller.offset, 120);
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(200, 200),
        scrollDelta: Offset(0, 120),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final gesture = await tester.startGesture(const Offset(200, 250));
    final held = controller.offset;
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.offset, held);
    await gesture.cancel();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
    'wheel smoothing accumulates, reverses and clamps without a tail',
    (tester) async {
      final controller = DesktopGalleryScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopSmoothScroll(
            controller: controller,
            child: ListView(
              controller: controller,
              children: const [SizedBox(height: 4000)],
            ),
          ),
        ),
      );
      Future<void> wheel(double delta) => tester.sendEventToBinding(
        PointerScrollEvent(
          position: const Offset(200, 200),
          scrollDelta: Offset(0, delta),
        ),
      );
      await wheel(120);
      expect(controller.offset, 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.offset, greaterThan(0));
      expect(controller.offset, lessThan(120));
      await wheel(120);
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(240, .01));
      await wheel(120);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 25));
      final beforeReverse = controller.offset;
      await wheel(-120);
      await tester.pumpAndSettle();
      expect(controller.offset, lessThan(beforeReverse));
      await wheel(-10000);
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(tester.binding.hasScheduledFrame, false);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
