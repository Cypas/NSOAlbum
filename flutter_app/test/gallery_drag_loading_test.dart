import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:squid_album/src/ui/gallery_drag_loading.dart';
import 'package:squid_album/src/ui/gallery_perf.dart';
import 'package:squid_album/src/ui/video_preview_cache.dart';

void main() {
  testWidgets('Android touch movement settles at 50ms and releases on cancel', (
    tester,
  ) async {
    final experiment = GalleryLoadExperiment(enabled: true)
      ..setMode(GalleryLoadMode.settled);
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: GalleryDragLoadRegion(
          controller: scroll,
          experiment: experiment,
          touchDragging: true,
          cardsPerFrame: 2,
          showScrollbar: false,
          child: ListView(
            controller: scroll,
            children: const [SizedBox(height: 4000)],
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(200, 450));
    expect(experiment.admission.value, GalleryWorkAdmission.all);
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    expect(scroll.offset, greaterThan(0));
    expect(experiment.admission.value, GalleryWorkAdmission.paused);
    await tester.pump(const Duration(milliseconds: 49));
    expect(experiment.admission.value, GalleryWorkAdmission.paused);
    await tester.pump(const Duration(milliseconds: 1));
    expect(experiment.admission.value, GalleryWorkAdmission.visible);
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    expect(experiment.admission.value, GalleryWorkAdmission.paused);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(experiment.admission.value, GalleryWorkAdmission.all);
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  testWidgets('B admits visible work after 50ms without releasing the thumb', (
    tester,
  ) async {
    final experiment = GalleryLoadExperiment(enabled: true);
    final drag = GalleryDragLoadController(experiment);
    addTearDown(drag.dispose);
    experiment.setMode(GalleryLoadMode.settled);
    drag.begin();
    drag.moved();
    expect(experiment.admission.value, GalleryWorkAdmission.paused);
    await tester.pump(const Duration(milliseconds: 49));
    expect(experiment.admission.value, GalleryWorkAdmission.paused);
    await tester.pump(const Duration(milliseconds: 1));
    expect(experiment.admission.value, GalleryWorkAdmission.visible);
    expect(drag.held, isTrue);
    drag.moved();
    expect(experiment.admission.value, GalleryWorkAdmission.paused);
    drag.end();
    expect(experiment.admission.value, GalleryWorkAdmission.all);
    await tester.pump(const Duration(seconds: 1));
    expect(experiment.admission.value, GalleryWorkAdmission.all);
  });

  testWidgets('A and disabled experiment never hold thumbnail work', (
    tester,
  ) async {
    for (final enabled in [false, true]) {
      final experiment = GalleryLoadExperiment(enabled: enabled);
      final drag = GalleryDragLoadController(experiment);
      drag.begin();
      drag.moved();
      expect(experiment.admission.value, GalleryWorkAdmission.all);
      if (!enabled) experiment.setMode(GalleryLoadMode.settled);
      expect(experiment.admission.value, GalleryWorkAdmission.all);
      drag.dispose();
    }
  });

  testWidgets('switching modes and disposal release every scheduling hold', (
    tester,
  ) async {
    final experiment = GalleryLoadExperiment(enabled: true)
      ..setMode(GalleryLoadMode.settled);
    final drag = GalleryDragLoadController(experiment)
      ..begin()
      ..moved();
    experiment.setMode(GalleryLoadMode.immediate);
    expect(drag.held, isFalse);
    expect(experiment.admission.value, GalleryWorkAdmission.all);
    experiment.setMode(GalleryLoadMode.settled);
    drag.begin();
    drag.moved();
    drag.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(experiment.admission.value, GalleryWorkAdmission.all);
  });

  testWidgets(
    'paused workers skip departed jobs and run visible before background',
    (tester) async {
      final admission = _AdmissionNotifier();
      final cache = PreviewCache<int>(
        maxEntries: 10,
        maxBytes: 100,
        sizeOf: (_) => 1,
        admission: admission,
      );
      final starts = <String>[];
      final activeGate = Completer<int?>();
      final active = cache.request(
        'active',
        load: (_) {
          starts.add('active');
          return activeGate.future;
        },
      );
      admission.value = GalleryWorkAdmission.paused;
      final background = cache.request(
        'background',
        load: (_) async {
          starts.add('background');
          return 2;
        },
      );
      final stale = cache.request(
        'stale',
        urgent: true,
        load: (_) async {
          starts.add('stale');
          return 3;
        },
      );
      final visible = cache.request(
        'visible',
        urgent: true,
        load: (_) async {
          starts.add('visible');
          return 4;
        },
      );
      stale.cancel();
      activeGate.complete(1);
      await active.future;
      await tester.pump();
      expect(starts, ['active']);
      admission.value = GalleryWorkAdmission.visible;
      await tester.pump();
      expect(starts, ['active', 'visible']);
      admission.value = GalleryWorkAdmission.all;
      await tester.pump();
      expect(await background.future, 2);
      expect(await visible.future, 4);
      expect(await stale.future, isNull);
      expect(starts, ['active', 'visible', 'background']);
      expect(admission.observed, isFalse);
    },
  );

  testWidgets(
    'started thumbnail work finishes and can be reused during a drag',
    (tester) async {
      final admission = _AdmissionNotifier();
      final gate = Completer<int?>();
      var cancelled = false;
      final cache = PreviewCache<int>(
        maxEntries: 4,
        maxBytes: 100,
        sizeOf: (_) => 1,
        admission: admission,
      );
      final request = cache.request(
        'started',
        load: (work) {
          work.onCancel = () => cancelled = true;
          return gate.future;
        },
      );
      admission.value = GalleryWorkAdmission.paused;
      request.cancel();
      expect(cancelled, isFalse);
      gate.complete(8);
      expect(await request.future, 8);
      expect(cache.peek('started'), 8);
      expect(admission.observed, isFalse);
    },
  );

  testWidgets(
    'departed visible consumer cannot promote a background job through the settle gate',
    (tester) async {
      final admission = _AdmissionNotifier()
        ..value = GalleryWorkAdmission.paused;
      final cache = PreviewCache<int>(
        maxEntries: 4,
        maxBytes: 100,
        sizeOf: (_) => 1,
        admission: admission,
      );
      var starts = 0;
      final background = cache.request(
        'shared',
        load: (_) async {
          starts++;
          return 7;
        },
      );
      final visible = cache.request(
        'shared',
        urgent: true,
        load: (_) async => 8,
      );
      visible.cancel();
      admission.value = GalleryWorkAdmission.visible;
      await tester.pump();
      expect(starts, 0);
      admission.value = GalleryWorkAdmission.all;
      await tester.pump();
      expect(await background.future, 7);
      expect(starts, 1);
      expect(admission.observed, isFalse);
    },
  );

  test(
    'drag and recovery frame summaries are separated and remain numeric',
    () {
      final perf = GalleryPerf(enabled: true)..start();
      perf.loadingPhase(GalleryDragPhase.moving);
      perf.increment(GalleryMetric.dragDeferred, 3);
      perf.recordFrame(uiMicros: 20000, rasterMicros: 1000, refreshHz: 60);
      perf.loadingPhase(GalleryDragPhase.settling);
      perf.recordFrame(uiMicros: 3000, rasterMicros: 2000, refreshHz: 60);
      final snapshot = perf.stop();
      expect(
        ((snapshot['dragFrames'] as Map)['moving'] as Map)['overBudget'],
        1,
      );
      expect(
        ((snapshot['dragFrames'] as Map)['settling'] as Map)['overBudget'],
        0,
      );
      expect(
        ((snapshot['dragCounters'] as Map)['moving'] as Map)['dragDeferred'],
        3,
      );
      expect(snapshot['loadingPolicy'], 'settled');
    },
  );

  testWidgets(
    'real thumb drag pauses B, holding resumes, release cancels the timer',
    (tester) async {
      final experiment = GalleryLoadExperiment(enabled: true)
        ..setMode(GalleryLoadMode.settled);
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            platform: TargetPlatform.windows,
            scrollbarTheme: const ScrollbarThemeData(
              thumbVisibility: WidgetStatePropertyAll(true),
            ),
          ),
          home: SizedBox(
            width: 800,
            height: 600,
            child: GalleryDragLoadRegion(
              controller: scroll,
              experiment: experiment,
              child: ListView.builder(
                controller: scroll,
                itemExtent: 100,
                itemCount: 100,
                itemBuilder: (_, i) => Text('Item $i'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Flutter's painted thumb, not an arbitrary right-edge hit region.
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.byWidgetPredicate(
                      (widget) =>
                          widget is CustomPaint &&
                          widget.foregroundPainter is ScrollbarPainter,
                    ),
                  )
                  .foregroundPainter!
              as ScrollbarPainter;
      Offset? hit;
      final box = tester.getRect(find.byType(GalleryDragLoadRegion));
      for (var y = 2.0; y < box.height && hit == null; y += 2) {
        for (var x = box.width - 1; x > box.width - 24; x--) {
          if (painter.hitTestOnlyThumbInteractive(
            Offset(x, y),
            PointerDeviceKind.mouse,
          )) {
            hit = box.topLeft + Offset(x, y);
            break;
          }
        }
      }
      expect(hit, isNotNull);
      final gesture = await tester.startGesture(
        hit!,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(scroll.offset, greaterThan(0));
      expect(experiment.admission.value, GalleryWorkAdmission.paused);
      await tester.pump(const Duration(milliseconds: 100));
      expect(experiment.admission.value, GalleryWorkAdmission.visible);
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      expect(experiment.admission.value, GalleryWorkAdmission.paused);
      await gesture.up();
      await tester.pump();
      expect(experiment.admission.value, GalleryWorkAdmission.all);
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
      expect(experiment.admission.value, GalleryWorkAdmission.all);
    },
  );

  testWidgets(
    'encoded bytes alone do not decode during dragging; warm decoded image does',
    (tester) async {
      final experiment = GalleryLoadExperiment(enabled: true)
        ..setMode(GalleryLoadMode.settled);
      final drag = GalleryDragLoadController(experiment)
        ..begin()
        ..moved();
      final bytes = Uint8List.fromList(
        image.encodeJpg(image.Image(width: 16, height: 9)),
      );
      Widget host() => MaterialApp(
        home: GalleryPreviewLoadScope(
          controller: drag,
          child: GalleryDeferredImage(
            bytes: bytes,
            cacheWidth: 768,
            placeholder: const SizedBox(key: Key('placeholder')),
            builder: () => Image.memory(bytes, cacheWidth: 768),
          ),
        ),
      );
      await tester.pumpWidget(host());
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.byKey(const Key('placeholder')), findsOneWidget);
      drag.end();
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      await tester.runAsync(
        () => precacheImage(
          ResizeImage.resizeIfNeeded(768, null, MemoryImage(bytes)),
          tester.element(find.byType(Image)),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      drag.begin();
      drag.moved();
      await tester.pumpWidget(host());
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      drag.dispose();
    },
  );

  testWidgets(
    'wheel and track taps do not pause; thumb cancellation and focus loss release B',
    (tester) async {
      final experiment = GalleryLoadExperiment(enabled: true)
        ..setMode(GalleryLoadMode.settled);
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            platform: TargetPlatform.windows,
            scrollbarTheme: const ScrollbarThemeData(
              thumbVisibility: WidgetStatePropertyAll(true),
            ),
          ),
          home: GalleryDragLoadRegion(
            controller: scroll,
            experiment: experiment,
            child: ListView.builder(
              controller: scroll,
              itemCount: 100,
              itemExtent: 100,
              itemBuilder: (_, i) => Text('Item $i'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      scroll.position.pointerScroll(120);
      await tester.pump();
      expect(experiment.admission.value, GalleryWorkAdmission.all);
      await tester.tapAt(const Offset(796, 500), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(experiment.admission.value, GalleryWorkAdmission.all);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      Offset thumb() {
        final painter =
            tester
                    .widget<CustomPaint>(
                      find.byWidgetPredicate(
                        (widget) =>
                            widget is CustomPaint &&
                            widget.foregroundPainter is ScrollbarPainter,
                      ),
                    )
                    .foregroundPainter!
                as ScrollbarPainter;
        final rect = tester.getRect(find.byType(GalleryDragLoadRegion));
        for (var y = 1.0; y < rect.height; y += 2) {
          for (var x = rect.width - 1; x > rect.width - 24; x--) {
            if (painter.hitTestOnlyThumbInteractive(
              Offset(x, y),
              PointerDeviceKind.mouse,
            )) {
              return rect.topLeft + Offset(x, y);
            }
          }
        }
        throw StateError('Painted thumb unavailable');
      }

      var gesture = await tester.startGesture(
        thumb(),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 25));
      await tester.pump();
      expect(experiment.admission.value, GalleryWorkAdmission.paused);
      await gesture.cancel();
      await tester.pump();
      expect(experiment.admission.value, GalleryWorkAdmission.all);
      await tester.pumpAndSettle();
      gesture = await tester.startGesture(
        thumb(),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      expect(experiment.admission.value, GalleryWorkAdmission.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(experiment.admission.value, GalleryWorkAdmission.all);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await gesture.up();
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
    },
  );
}

class _AdmissionNotifier extends ValueNotifier<GalleryWorkAdmission> {
  _AdmissionNotifier() : super(GalleryWorkAdmission.all);
  bool get observed => hasListeners;
}
