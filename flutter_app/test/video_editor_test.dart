import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/video_editor.dart';

void main() {
  testWidgets('video timeline zooms with the mouse wheel', (tester) async {
    var zoom = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 120,
            child: VideoTimeline(
              duration: const Duration(minutes: 1),
              position: const Duration(seconds: 10),
              selectionStart: const Duration(seconds: 5),
              selectionEnd: const Duration(seconds: 40),
              zoom: zoom,
              playing: false,
              onZoomChanged: (value) => zoom = value,
              onSelectionChanged: (_) {},
              onSelectionChangeEnd: (_) {},
              onSeek: (_) {},
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(
      find.byKey(const Key('video-editor-timeline')),
    );
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, -120)),
    );
    await tester.pump();

    expect(zoom, greaterThan(1));
    expect(find.byKey(const Key('video-editor-range')), findsOneWidget);
    expect(find.byKey(const Key('video-editor-start-handle')), findsOneWidget);
    expect(find.byKey(const Key('video-editor-end-handle')), findsOneWidget);
    expect(
      find.byKey(const Key('video-editor-horizontal-scrollbar')),
      findsOneWidget,
    );
  });

  testWidgets('playing timeline follows the playhead near the viewport edge', (
    tester,
  ) async {
    var position = Duration.zero;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 126,
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return VideoTimeline(
                  duration: const Duration(seconds: 100),
                  position: position,
                  selectionStart: const Duration(seconds: 5),
                  selectionEnd: const Duration(seconds: 95),
                  zoom: 4,
                  playing: true,
                  onZoomChanged: (_) {},
                  onSelectionChanged: (_) {},
                  onSelectionChangeEnd: (_) {},
                  onSeek: (_) {},
                );
              },
            ),
          ),
        ),
      ),
    );

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.maxScrollExtent, greaterThan(0));

    update(() => position = const Duration(seconds: 80));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(scrollable.position.pixels, greaterThan(0));
    expect(
      scrollable.position.pixels,
      lessThanOrEqualTo(scrollable.position.maxScrollExtent),
    );
  });

  testWidgets('timeline handle timestamps stay on one line with milliseconds', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 126,
            child: VideoTimeline(
              duration: const Duration(seconds: 30, milliseconds: 666),
              position: Duration.zero,
              selectionStart: Duration.zero,
              selectionEnd: const Duration(seconds: 29, milliseconds: 666),
              zoom: 1,
              playing: false,
              onZoomChanged: (_) {},
              onSelectionChanged: (_) {},
              onSelectionChangeEnd: (_) {},
              onSeek: (_) {},
            ),
          ),
        ),
      ),
    );

    final labels = find.byType(Text).evaluate().where((element) {
      final text = (element.widget as Text).data;
      return text == '00:00.000' || text == '00:29.666';
    });
    expect(labels, hasLength(2));
    for (final element in labels) {
      final text = element.widget as Text;
      expect(text.maxLines, 1);
      expect(text.softWrap, isFalse);
    }
  });
}
