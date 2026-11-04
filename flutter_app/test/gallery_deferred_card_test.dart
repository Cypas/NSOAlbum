import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/gallery_deferred_card.dart';
import 'package:squid_album/src/ui/gallery_drag_loading.dart';

void main() {
  testWidgets(
    'viewport enlargement wakes dormant cards without changing scroll pixels',
    (tester) async {
      final experiment = GalleryLoadExperiment(enabled: true)
        ..setMode(GalleryLoadMode.settled);
      final scroll = ScrollController();
      var show = false;
      var height = 200.0;
      final built = <int>[];
      Widget host() => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: height,
            child: GalleryDragLoadRegion(
              controller: scroll,
              experiment: experiment,
              child: ListView(
                controller: scroll,
                scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
                children: [
                  if (show)
                    for (var i = 0; i < 12; i++)
                      SizedBox(
                        height: 100,
                        child: GalleryDeferredCard(
                          placeholderBuilder: (_) => const SizedBox.expand(),
                          builder: (_) {
                            built.add(i);
                            return Text('Full $i');
                          },
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(host());
      final drag = tester
          .widget<GalleryPreviewLoadScope>(find.byType(GalleryPreviewLoadScope))
          .notifier!;
      drag.begin();
      drag.moved();
      show = true;
      await tester.pumpWidget(host());
      drag.end();
      await tester.pumpAndSettle();
      expect(built, [0, 1]);
      expect(scroll.offset, 0);
      height = 500;
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(built.where((i) => i >= 2), [2, 3, 4]);
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
    },
  );

  testWidgets(
    'B to A after release clears dormant card gates without a new drag',
    (tester) async {
      final experiment = GalleryLoadExperiment(enabled: true)
        ..setMode(GalleryLoadMode.settled);
      final drag = GalleryDragLoadController(experiment)
        ..begin()
        ..moved();
      final built = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              height: 200,
              child: GalleryPreviewLoadScope(
                controller: drag,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var i = 0; i < 8; i++)
                        SizedBox(
                          height: 100,
                          child: GalleryDeferredCard(
                            placeholderBuilder: (_) => const SizedBox.expand(),
                            builder: (_) {
                              built.add(i);
                              return Text('Full $i');
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      drag.end();
      await tester.pumpAndSettle();
      expect(built, [0, 1]);
      expect(drag.held, false);
      experiment.setMode(GalleryLoadMode.immediate);
      await tester.pumpAndSettle();
      expect(built, unorderedEquals(List.generate(8, (i) => i)));
      await tester.pumpWidget(const SizedBox.shrink());
      drag.dispose();
    },
  );

  testWidgets(
    'moving B never builds new card contents; settle hydrates three per frame without resizing',
    (tester) async {
      final experiment = GalleryLoadExperiment(enabled: true)
        ..setMode(GalleryLoadMode.settled);
      final drag = GalleryDragLoadController(experiment)
        ..begin()
        ..moved();
      final built = <int>[];
      await tester.pumpWidget(
        _host(drag, [
          for (var i = 0; i < 5; i++)
            SizedBox(
              key: ValueKey('slot-$i'),
              width: 240,
              height: 100,
              child: GalleryDeferredCard(
                placeholderBuilder: (_) => const ColoredBox(color: Colors.grey),
                builder: (_) {
                  built.add(i);
                  return Text('Card $i tag');
                },
              ),
            ),
        ]),
      );
      final before = tester.getRect(find.byKey(const ValueKey('slot-0')));
      expect(built, isEmpty);
      expect(find.textContaining(' tag'), findsNothing);
      await tester.pump(const Duration(milliseconds: 49));
      expect(built, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(built.length, lessThanOrEqualTo(3));
      await tester.pump();
      expect(built, [0, 1, 2]);
      await tester.pump();
      expect(built, [0, 1, 2, 3, 4]);
      expect(tester.getRect(find.byKey(const ValueKey('slot-0'))), before);
      await tester.pumpWidget(const SizedBox.shrink());
      drag.dispose();
    },
  );

  testWidgets('complete card keeps its element and state when moving resumes', (
    tester,
  ) async {
    final experiment = GalleryLoadExperiment(enabled: true)
      ..setMode(GalleryLoadMode.settled);
    final drag = GalleryDragLoadController(experiment);
    await tester.pumpWidget(
      _host(drag, [
        GalleryDeferredCard(
          placeholderBuilder: (_) => const SizedBox(),
          builder: (_) => const _StatefulCard(),
        ),
      ]),
    );
    final state = tester.state(find.byType(_StatefulCard));
    drag.begin();
    drag.moved();
    await tester.pump();
    expect(tester.state(find.byType(_StatefulCard)), same(state));
    drag.end();
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(_StatefulCard)), same(state));
    await tester.pumpWidget(const SizedBox.shrink());
    drag.dispose();
  });

  testWidgets(
    'resuming movement pauses pending restoration and release finishes it',
    (tester) async {
      final experiment = GalleryLoadExperiment(enabled: true)
        ..setMode(GalleryLoadMode.settled);
      final drag = GalleryDragLoadController(experiment)
        ..begin()
        ..moved();
      var builds = 0;
      await tester.pumpWidget(
        _host(drag, [
          for (var i = 0; i < 4; i++)
            SizedBox(
              height: 80,
              child: GalleryDeferredCard(
                placeholderBuilder: (_) => const SizedBox.expand(),
                builder: (_) {
                  builds++;
                  return Text('Full $i');
                },
              ),
            ),
        ]),
      );
      drag.end();
      await tester.pump();
      await tester.pump();
      expect(builds, 3);
      drag.begin();
      drag.moved();
      await tester.pump();
      expect(builds, 3);
      drag.end();
      await tester.pumpAndSettle();
      expect(builds, 4);
      await tester.pumpWidget(const SizedBox.shrink());
      drag.dispose();
    },
  );

  testWidgets(
    'offscreen pending cards do not build or keep idle frames scheduled',
    (tester) async {
      final experiment = GalleryLoadExperiment(enabled: true)
        ..setMode(GalleryLoadMode.settled);
      final drag = GalleryDragLoadController(experiment)
        ..begin()
        ..moved();
      final scroll = ScrollController();
      final built = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: GalleryPreviewLoadScope(
            controller: drag,
            child: SizedBox(
              height: 600,
              child: ListView(
                controller: scroll,
                children: [
                  for (var i = 0; i < 12; i++)
                    SizedBox(
                      height: 100,
                      child: GalleryDeferredCard(
                        placeholderBuilder: (_) => const SizedBox.expand(),
                        builder: (_) {
                          built.add(i);
                          return Text('Full $i');
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      drag.end();
      await tester.pumpAndSettle();
      expect(built, [0, 1, 2, 3, 4, 5]);
      scroll.jumpTo(600);
      drag.viewportChanged();
      await tester.pumpAndSettle();
      expect(built, unorderedEquals(List.generate(12, (i) => i)));
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
      drag.dispose();
    },
  );

  testWidgets(
    'departed pending cards never restore and mode switch releases remaining work',
    (tester) async {
      final experiment = GalleryLoadExperiment(enabled: true)
        ..setMode(GalleryLoadMode.settled);
      final drag = GalleryDragLoadController(experiment)
        ..begin()
        ..moved();
      var built = 0;
      Widget pending() => SizedBox(
        height: 80,
        child: GalleryDeferredCard(
          placeholderBuilder: (_) => const SizedBox(),
          builder: (_) {
            built++;
            return const Text('Full');
          },
        ),
      );
      await tester.pumpWidget(_host(drag, [pending()]));
      await tester.pumpWidget(_host(drag, const []));
      drag.end();
      await tester.pumpAndSettle();
      expect(built, 0);
      drag.begin();
      drag.moved();
      await tester.pumpWidget(_host(drag, [pending()]));
      expect(built, 0);
      experiment.setMode(GalleryLoadMode.immediate);
      await tester.pumpAndSettle();
      expect(built, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      drag.dispose();
    },
  );

  testWidgets('A and explicit bypass build real controls without delay', (
    tester,
  ) async {
    for (final bypass in [false, true]) {
      final experiment = GalleryLoadExperiment(enabled: true);
      if (bypass) experiment.setMode(GalleryLoadMode.settled);
      final drag = GalleryDragLoadController(experiment)
        ..begin()
        ..moved();
      await tester.pumpWidget(
        _host(drag, [
          GalleryDeferredCard(
            enabled: !bypass,
            placeholderBuilder: (_) => const SizedBox(),
            builder: (_) => const Text('Select and edit'),
          ),
        ]),
      );
      expect(find.text('Select and edit'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      drag.dispose();
    }
  });
}

Widget _host(GalleryDragLoadController drag, List<Widget> children) =>
    MaterialApp(
      home: GalleryPreviewLoadScope(
        controller: drag,
        child: Column(children: children),
      ),
    );

class _StatefulCard extends StatefulWidget {
  const _StatefulCard();
  @override
  State<_StatefulCard> createState() => _StatefulCardState();
}

class _StatefulCardState extends State<_StatefulCard> {
  @override
  Widget build(BuildContext context) => const Text('Stateful tag');
}
