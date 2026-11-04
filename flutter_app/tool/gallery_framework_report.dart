const _phases = {
  'BUILD': 'build',
  'LAYOUT': 'layout',
  'LAYOUT (root)': 'layout',
  'PAINT': 'paint',
  'PAINT (root)': 'paint',
  'SEMANTICS': 'semantics',
  'SEMANTICS (root)': 'semantics',
};

// Widget/render-object type names only. Never emit toString(), keys or args.
const _types = {
  '_MediaCard',
  '_MediaPreview',
  '_HoverMarqueeText',
  '_Tag',
  'ImageThumbnail',
  'VideoThumbnail',
  'GalleryDeferredImage',
  'Card',
  'InkWell',
  'InkResponse',
  'IconButton',
  '_IconButtonM3',
  'Text',
  'RichText',
  'Icon',
  'Tooltip',
  'Padding',
  'Stack',
  'Row',
  'Column',
  'Wrap',
  'Image',
  'Semantics',
  'MouseRegion',
  'Listener',
  'Focus',
  'Material',
  '_MaterialState',
  'AnimatedPhysicalModel',
  'PhysicalShape',
  'RenderFlex',
  'RenderParagraph',
  'RenderImage',
  'RenderConstrainedBox',
  'RenderPadding',
  'RenderStack',
  'RenderWrap',
  'RenderPositionedBox',
  'RenderSemanticsAnnotations',
  'RenderMouseRegion',
  'RenderPointerListener',
  'RenderClipRRect',
  'RenderPhysicalModel',
  'RenderPhysicalShape',
  'RenderCustomPaint',
  'RenderDecoratedBox',
  '_RenderInkFeatures',
  'RenderRepaintBoundary',
  'RenderSliverGrid',
  'RenderViewport',
};

/// Deliberately inclusive: parent widgets contain their descendants. This is
/// a diagnostic overhead mode, never a performance comparison baseline.
Map<String, Object?> summarizeFrameworkComponents(
  Iterable<Map<String, dynamic>> events,
) {
  final lanes = <String, List<({String? name, num start})>>{};
  final spans = <({String name, String lane, num start, num end})>[];
  final ordered =
      events.indexed
          .where(
            (entry) =>
                entry.$2['ts'] is num && (entry.$2['ts'] as num).isFinite,
          )
          .toList()
        ..sort((a, b) {
          final byTime = (a.$2['ts'] as num).compareTo(b.$2['ts'] as num);
          return byTime == 0 ? a.$1.compareTo(b.$1) : byTime;
        });
  void add(String? name, String lane, num start, num end) {
    if (name != null && start >= 0 && end.isFinite && end >= start) {
      spans.add((name: name, lane: lane, start: start, end: end));
    }
  }

  for (final indexed in ordered) {
    final event = indexed.$2;
    final name = event['name'];
    final safeName =
        name is String && (_types.contains(name) || _phases.containsKey(name))
        ? name
        : null;
    final time = event['ts'] as num;
    final lane = '${event['pid']}/${event['tid']}';
    if (event['ph'] == 'B') {
      (lanes[lane] ??= []).add((name: safeName, start: time));
    } else if (event['ph'] == 'E') {
      final stack = lanes[lane];
      if (stack != null && stack.isNotEmpty) {
        final begin = stack.removeLast();
        add(begin.name, lane, begin.start, time);
      }
    } else if (event['ph'] == 'X' && event['dur'] is num) {
      add(safeName, lane, time, time + (event['dur'] as num));
    }
  }
  final roots = spans.where((span) => _phases.containsKey(span.name)).toList();
  final rows = <(String, String), ({int count, num total, num max})>{};
  for (final span in spans.where((span) => _types.contains(span.name))) {
    String phase = 'unattributed';
    num? nearest;
    for (final root in roots) {
      final length = root.end - root.start;
      if (root.lane == span.lane &&
          root.start <= span.start &&
          root.end >= span.end &&
          (nearest == null || length <= nearest)) {
        nearest = length;
        phase = _phases[root.name]!;
      }
    }
    final key = (phase, span.name);
    final duration = span.end - span.start;
    final old = rows[key] ?? (count: 0, total: 0, max: 0);
    rows[key] = (
      count: old.count + 1,
      total: old.total + duration,
      max: duration > old.max ? duration : old.max,
    );
  }
  final ranked = rows.entries.toList()
    ..sort((a, b) => b.value.total.compareTo(a.value.total));
  return {
    'basis': 'inclusive_nested_not_additive',
    'components': [
      for (final entry in ranked.take(128))
        {
          'phase': entry.key.$1,
          'type': entry.key.$2,
          'count': entry.value.count,
          'totalMicros': entry.value.total,
          'maxMicros': entry.value.max,
        },
    ],
  };
}
