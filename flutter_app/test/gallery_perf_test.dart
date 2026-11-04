import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:squid_album/src/ui/gallery_perf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'disabled diagnostics neither record nor accept a service session',
    () async {
      final perf = GalleryPerf(enabled: false);
      perf.increment(GalleryMetric.cardMount);
      final response = await perf.handle(GalleryPerf.extensionName, {
        'action': 'start',
      });
      expect(jsonDecode(response.result!), {'ok': false, 'reason': 'disabled'});
      expect(perf.snapshot()['counters'], isEmpty);
    },
  );

  test('sessions aggregate typed metrics and bound timing storage', () {
    final perf = GalleryPerf(enabled: true, sampleLimit: 4);
    perf.start();
    for (var i = 1; i <= 6; i++) {
      perf.increment(GalleryMetric.cardMount);
      perf.sample(GalleryMetric.cardBuild, i * 100);
    }
    final snapshot = perf.snapshot();
    expect((snapshot['counters'] as Map)['cardMount'], 6);
    final timing = (snapshot['timings'] as Map)['cardBuild'] as Map;
    expect(timing['count'], 6);
    expect(timing['stored'], 4);
    expect(timing['total'], 2100);
    perf.stop();
    perf.increment(GalleryMetric.cardMount);
    expect((perf.snapshot()['counters'] as Map)['cardMount'], 6);
    perf.start();
    expect(perf.snapshot()['counters'], isEmpty);
    perf.stop();
  });

  test(
    'frame deadline follows refresh rate rather than a fixed 60Hz budget',
    () {
      final perf = GalleryPerf(enabled: true);
      perf.start();
      perf.recordFrame(uiMicros: 10000, rasterMicros: 2000, refreshHz: 120);
      perf.recordFrame(uiMicros: 10000, rasterMicros: 2000, refreshHz: 60);
      final frames = perf.snapshot()['frames'] as Map;
      expect(frames['count'], 2);
      expect(frames['overBudget'], 1);
      expect(frames['overBudgetRatio'], .5);
      perf.stop();
    },
  );

  test('capture identifies cache work already active before its window', () {
    final perf = GalleryPerf(enabled: true);
    perf.cacheWork(pendingDelta: 2);
    perf.cacheWork(activeDelta: 1, pendingDelta: -1);
    perf.start();
    var background = perf.snapshot()['background'] as Map;
    expect(background['cacheActiveAtStart'], 1);
    expect(background['cachePendingAtStart'], 1);
    perf.cacheWork(activeDelta: -1, carryoverFinished: true);
    background = perf.snapshot()['background'] as Map;
    expect(background['cacheActive'], 0);
    expect(background['cachePending'], 1);
    expect(background['cacheCarryoverFinished'], 1);
    perf.stop();
    perf.cacheWork(pendingDelta: -1);
    perf.start();
    background = perf.snapshot()['background'] as Map;
    expect(background['cacheActiveAtStart'], 0);
    expect(background['cachePendingAtStart'], 0);
    expect(background['cacheCarryoverFinished'], 0);
    perf.stop();
  });

  test('invalid service input cannot enter diagnostic output', () async {
    final perf = GalleryPerf(enabled: true);
    const secret = r'C:\private\media\personal_name_sha_token';
    final response = await perf.handle(GalleryPerf.extensionName, {
      'action': 'start',
      'scenario': secret,
    });
    expect(response.result, isNot(contains(secret)));
    expect(jsonDecode(response.result!), {
      'ok': false,
      'reason': 'invalid_scenario',
    });
    expect(perf.snapshot().toString(), isNot(contains(secret)));
  });

  test(
    'unknown total replaces a previous query count and stop restores covers',
    () {
      final perf = GalleryPerf(enabled: true);
      perf.gallery(
        loaded: 60,
        images: 30,
        videos: 30,
        columns: 4,
        viewport: 800,
        offset: 0,
        extent: 1000,
        total: 884,
      );
      perf.gallery(
        loaded: 10,
        images: 5,
        videos: 5,
        columns: 4,
        viewport: 800,
        offset: 0,
        extent: 1000,
      );
      expect(perf.snapshot()['gallery'], isNot(contains('total')));
      perf.start(mode: GalleryCoverMode.placeholder);
      expect(perf.stop()['coverMode'], 'placeholder');
      expect(perf.coverMode.value, GalleryCoverMode.normal);
    },
  );

  testWidgets('stop drains batched frames without accepting new work', (
    tester,
  ) async {
    final perf = GalleryPerf(enabled: true)..start();
    perf.recordFrame(uiMicros: 9000, rasterMicros: 2000, refreshHz: 120);
    final drained = perf.stopAndDrain();
    perf.increment(GalleryMetric.cardMount);
    perf.recordFrame(uiMicros: 10000, rasterMicros: 2000, refreshHz: 120);
    await tester.pump(const Duration(milliseconds: 1100));
    final result = await drained;
    expect((result['frames'] as Map)['count'], 2);
    expect(result['counters'], isEmpty);
    perf.recordFrame(uiMicros: 3000, rasterMicros: 2000, refreshHz: 120);
    expect((perf.snapshot()['frames'] as Map)['count'], 2);
  });

  testWidgets(
    'wheel replay uses real scroll position and stops with the session',
    (tester) async {
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: ListView.builder(
            controller: scroll,
            itemExtent: 100,
            itemCount: 100,
            itemBuilder: (_, i) => Text('$i'),
          ),
        ),
      );
      final perf = GalleryPerf(enabled: true);
      final unbind = perf.bindScroll(
        scroll,
        returnToTop: () async => scroll.jumpTo(0),
      );
      perf.start(scenario: GalleryScenario.normalDown);
      perf.replayWheel();
      await tester.pump(const Duration(milliseconds: 200));
      expect(scroll.offset, 120);
      perf.stop();
      await tester.pump(const Duration(seconds: 1));
      expect(scroll.offset, 120);
      unbind();
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );
}
