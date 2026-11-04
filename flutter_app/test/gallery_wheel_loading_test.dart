import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/desktop_fluid_scroll_physics.dart';
import 'package:squid_album/src/ui/gallery_deferred_card.dart';
import 'package:squid_album/src/ui/gallery_drag_loading.dart';

void main() {
  for (final reducedMotion in [false, true]) {
    testWidgets(
      'consumed wheel gates new cards through animation then settles for 50ms (reduced=$reducedMotion)',
      (tester) async {
        final experiment = GalleryLoadExperiment(enabled: true)
          ..setMode(GalleryLoadMode.settled);
        final scroll = DesktopGalleryScrollController();
        final built = <int>[];
        await tester.pumpWidget(
          _host(
            scroll,
            experiment,
            reducedMotion: reducedMotion,
            child: ListView.builder(
              controller: scroll,
              itemCount: 100,
              itemExtent: 100,
              itemBuilder: (_, index) => GalleryDeferredCard(
                key: ValueKey(index),
                placeholderBuilder: (_) => Text('Pending $index'),
                builder: (_) {
                  built.add(index);
                  return Text('Full $index');
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final initial = built.length;
        await _wheel(tester, 1200);
        expect(experiment.admission.value, GalleryWorkAdmission.paused);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        if (!reducedMotion) {
          expect(scroll.position.isScrollingNotifier.value, isTrue);
          expect(experiment.admission.value, GalleryWorkAdmission.paused);
          expect(built.length, initial);
        }
        await _finishAnimation(tester, scroll);
        // Renew immediately: an old settle callback must not release new work.
        await _wheel(tester, 600);
        await tester.pump();
        await _finishAnimation(tester, scroll);
        expect(find.textContaining('Pending'), findsWidgets);
        expect(experiment.admission.value, GalleryWorkAdmission.paused);
        await tester.pump(const Duration(milliseconds: 49));
        expect(experiment.admission.value, GalleryWorkAdmission.paused);
        await tester.pump(const Duration(milliseconds: 1));
        expect(experiment.admission.value, GalleryWorkAdmission.all);
        for (var frame = 0; frame < 8; frame++) {
          final before = built.length;
          await tester.pump();
          expect(built.length - before, lessThanOrEqualTo(3));
        }
        final viewport = tester.getRect(find.byType(ListView));
        for (final element in find.textContaining('Pending').evaluate()) {
          expect(
            tester.getRect(find.byWidget(element.widget)).overlaps(viewport),
            isFalse,
          );
        }
        await tester.pumpWidget(const SizedBox());
        expect(experiment.admission.value, GalleryWorkAdmission.all);
        scroll.dispose();
      },
    );
  }

  testWidgets('replacing a wheel position releases the old activity listener', (
    tester,
  ) async {
    final experiment = GalleryLoadExperiment(enabled: true)
      ..setMode(GalleryLoadMode.settled);
    final scroll = DesktopGalleryScrollController();
    Widget host({required bool changed}) => _host(
      scroll,
      experiment,
      child: ListView(
        controller: scroll,
        physics: changed
            ? const BouncingScrollPhysics()
            : const ClampingScrollPhysics(),
        children: const [SizedBox(height: 4000)],
      ),
    );
    await tester.pumpWidget(host(changed: false));
    await _wheel(tester, 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final old = scroll.position;
    expect(experiment.admission.value, GalleryWorkAdmission.paused);
    await tester.pumpWidget(host(changed: true));
    expect(scroll.position, isNot(same(old)));
    await tester.pumpAndSettle();
    expect(experiment.admission.value, GalleryWorkAdmission.all);
    expect(tester.takeException(), isNull);
    // Replacement must not leave the next real wheel tied to its predecessor.
    await _wheel(tester, -120);
    expect(experiment.admission.value, GalleryWorkAdmission.paused);
    await tester.pump();
    await _finishAnimation(tester, scroll);
    await tester.pump(const Duration(milliseconds: 49));
    expect(experiment.admission.value, GalleryWorkAdmission.paused);
    await tester.pump(const Duration(milliseconds: 1));
    expect(experiment.admission.value, GalleryWorkAdmission.all);
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  testWidgets(
    'nested consumption and boundaries do not gate the outer gallery',
    (tester) async {
      final experiment = GalleryLoadExperiment(enabled: true)
        ..setMode(GalleryLoadMode.settled);
      final outer = DesktopGalleryScrollController();
      final inner = ScrollController();
      await tester.pumpWidget(
        _host(
          outer,
          experiment,
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
      );
      await _wheel(tester, 120, position: const Offset(200, 100));
      expect(inner.offset, 120);
      expect(outer.offset, 0);
      expect(experiment.admission.value, GalleryWorkAdmission.all);
      inner.jumpTo(inner.position.maxScrollExtent);
      await tester.pump();
      await _wheel(tester, 120, position: const Offset(200, 100));
      expect(experiment.admission.value, GalleryWorkAdmission.paused);
      await tester.pumpAndSettle();
      expect(experiment.admission.value, GalleryWorkAdmission.all);
      outer.jumpTo(outer.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await _wheel(tester, 120, position: const Offset(200, 400));
      expect(experiment.admission.value, GalleryWorkAdmission.all);
      await tester.pumpWidget(const SizedBox());
      outer.dispose();
      inner.dispose();
    },
  );

  testWidgets('trackpad bypass, focus loss and disposal release wheel holds', (
    tester,
  ) async {
    final experiment = GalleryLoadExperiment(enabled: true)
      ..setMode(GalleryLoadMode.settled);
    final scroll = DesktopGalleryScrollController();
    await tester.pumpWidget(
      _host(
        scroll,
        experiment,
        child: ListView(
          controller: scroll,
          children: const [SizedBox(height: 4000)],
        ),
      ),
    );
    await _wheel(tester, 120, kind: PointerDeviceKind.trackpad);
    expect(scroll.offset, 120);
    expect(experiment.admission.value, GalleryWorkAdmission.all);
    await _wheel(tester, 120);
    expect(experiment.admission.value, GalleryWorkAdmission.paused);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await _wheel(tester, 120, kind: PointerDeviceKind.trackpad);
    expect(experiment.admission.value, GalleryWorkAdmission.all);
    await _wheel(tester, 120);
    expect(experiment.admission.value, GalleryWorkAdmission.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(experiment.admission.value, GalleryWorkAdmission.all);
    await tester.pump(const Duration(milliseconds: 16));
    expect(experiment.admission.value, GalleryWorkAdmission.all);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _wheel(tester, 120);
    expect(experiment.admission.value, GalleryWorkAdmission.paused);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(experiment.admission.value, GalleryWorkAdmission.all);
    expect(tester.takeException(), isNull);
    scroll.dispose();
  });
}

Widget _host(
  DesktopGalleryScrollController controller,
  GalleryLoadExperiment experiment, {
  required Widget child,
  bool reducedMotion = false,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
    child: child!,
  ),
  home: DesktopSmoothScroll(
    controller: controller,
    child: GalleryDragLoadRegion(
      controller: controller,
      experiment: experiment,
      child: child,
    ),
  ),
);

Future<void> _wheel(
  WidgetTester tester,
  double delta, {
  Offset position = const Offset(200, 400),
  PointerDeviceKind kind = PointerDeviceKind.mouse,
}) => tester.sendEventToBinding(
  PointerScrollEvent(
    kind: kind,
    position: position,
    scrollDelta: Offset(0, delta),
  ),
);

Future<void> _finishAnimation(
  WidgetTester tester,
  ScrollController scroll,
) async {
  for (
    var frame = 0;
    frame < 30 && scroll.position.isScrollingNotifier.value;
    frame++
  ) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(
    scroll.position.isScrollingNotifier.value,
    isFalse,
    reason: 'The bounded wheel animation did not finish within 30 frames.',
  );
}
