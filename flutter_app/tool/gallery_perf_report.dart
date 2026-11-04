import 'dart:async';

import 'package:vm_service/vm_service.dart';

import 'package:squid_album/src/diagnostics/gallery_work_labels.dart';

/// Fixed failure codes deliberately exclude exception/RPC text.
String captureFailureReason(Object error) => switch (error) {
  GalleryCaptureFailure(:final reason) => reason,
  TimeoutException() => 'request_timeout',
  SentinelException() => 'isolate_unavailable',
  RPCError() => 'rpc_error',
  _ => 'operation_failed',
};

Map<String, Object?> captureFailureSummary(Object error) => {
  'reason': captureFailureReason(error),
  if (error is RPCError) 'rpcCode': error.code,
};

bool? profilerFlagEnabled(FlagList flags) {
  final flag = flags.flags
      ?.where((flag) => flag.name == 'profiler')
      .firstOrNull;
  return switch (flag?.valueAsString) {
    'true' => true,
    'false' => false,
    _ => null,
  };
}

final class GalleryCaptureFailure implements Exception {
  const GalleryCaptureFailure(this.reason);
  final String reason;
  @override
  String toString() => 'GalleryCaptureFailure([redacted])';
}

/// Counts delivery of main-isolate GC events only during the definitive host
/// capture window. VM Event timestamps use a remote epoch clock, not the
/// monotonic Timeline clock, so they are not compared to host wall time.
final class GalleryGcWindow {
  GalleryGcWindow(this._isolateId);
  final String _isolateId;
  bool _active = false;
  int events = 0;

  void start() {
    events = 0;
    _active = true;
  }

  void receive(Event event) {
    if (_active &&
        event.kind == EventKind.kGC &&
        event.isolate?.id == _isolateId) {
      events++;
    }
  }

  void stop() => _active = false;
}

String? _safeSymbol(String? name) {
  // Function names, not script URIs, are sufficient for attribution. Reject
  // path-like native names wholesale rather than trying to redact substrings.
  if (name == null ||
      name.isEmpty ||
      name.length > 180 ||
      name.contains(RegExp(r'[/\\:@]')) ||
      !RegExp(r'^[a-zA-Z0-9_$<>=\[\]. ()?+*,!&-]+$').hasMatch(name)) {
    return null;
  }
  return name;
}

String? _ownerName(dynamic owner, [int depth = 0]) {
  if (depth >= 6) return null;
  if (owner is ClassRef) {
    return _safeSymbol(owner.name) ?? 'redacted_owner';
  }
  if (owner is FuncRef) {
    final name = _safeSymbol(owner.name) ?? 'redacted_owner';
    final parent = _ownerName(owner.owner, depth + 1);
    return parent == null || name.startsWith('$parent.')
        ? name
        : '$parent.$name';
  }
  // LibraryRef.name/uri and source-location metadata are never exported.
  return null;
}

String _functionName(dynamic function) {
  if (function is FuncRef) {
    final name = _safeSymbol(function.name);
    if (name == null) return 'redacted_function';
    final owner = _ownerName(function.owner);
    final qualified = owner == null || name.startsWith('$owner.')
        ? name
        : '$owner.$name';
    return _safeSymbol(qualified) ?? 'redacted_function';
  }
  return function is NativeFunction
      ? _safeSymbol(function.name) ?? 'redacted_function'
      : 'redacted_function';
}

Map<String, Object?> summarizeCpuSamples(
  CpuSamples samples, {
  required bool? profilerEnabled,
  int limit = 100,
  int? requestedOriginMicros,
  int? requestedExtentMicros,
}) {
  final count = samples.sampleCount ?? 0;
  if (profilerEnabled == false || count <= 0) {
    return {
      'reason': profilerEnabled == false ? 'profile_disabled' : 'zero_samples',
      'sampleCount': count < 0 ? 0 : count,
    };
  }
  final rows = [
    for (final function in samples.functions ?? <ProfileFunction>[])
      <String, Object?>{
        'name': _functionName(function.function),
        'kind': function.kind == 'Dart' ? 'Dart' : 'Native',
        'selfTicks': (function.exclusiveTicks ?? 0).clamp(0, count),
        'inclusiveTicks': (function.inclusiveTicks ?? 0).clamp(0, count),
        'selfPercent':
            (function.exclusiveTicks ?? 0).clamp(0, count) * 100 / count,
        'inclusivePercent':
            (function.inclusiveTicks ?? 0).clamp(0, count) * 100 / count,
      },
  ];
  final self = [...rows]
    ..sort((a, b) => (b['selfTicks'] as int).compareTo(a['selfTicks'] as int));
  final inclusive = [...rows]
    ..sort(
      (a, b) =>
          (b['inclusiveTicks'] as int).compareTo(a['inclusiveTicks'] as int),
    );
  return {
    'reason': 'ok',
    'rankingBasis': 'function_table_ticks_unverified',
    'sampleCount': count,
    'samplePeriodMicros': samples.samplePeriod,
    'coveredMicros': samples.timeExtentMicros,
    'topSelf': self.take(limit.clamp(1, 100)).toList(),
    'topInclusive': inclusive.take(limit.clamp(1, 100)).toList(),
    'topDartSelf': self
        .where((row) => row['kind'] == 'Dart')
        .take(limit.clamp(1, 100))
        .toList(),
    'topDartInclusive': inclusive
        .where((row) => row['kind'] == 'Dart')
        .take(limit.clamp(1, 100))
        .toList(),
    'stackRanks': summarizeCpuSampleStacks(
      samples,
      requestedOriginMicros: requestedOriginMicros,
      requestedExtentMicros: requestedExtentMicros,
      limit: limit,
    ),
    'storageCallers': summarizeStorageCallerChains(
      samples,
      requestedOriginMicros: requestedOriginMicros,
      requestedExtentMicros: requestedExtentMicros,
    ),
  };
}

({List<CpuSample> samples, Map<String, Object?> meta}) _cpuWindow(
  CpuSamples data, {
  int? requestedOriginMicros,
  int? requestedExtentMicros,
}) {
  final available = data.samples ?? <CpuSample>[];
  final ranged = requestedOriginMicros != null || requestedExtentMicros != null;
  final validRange =
      !ranged ||
      (requestedOriginMicros != null &&
          requestedOriginMicros >= 0 &&
          requestedExtentMicros != null &&
          requestedExtentMicros > 0);
  final inside = <CpuSample>[];
  int? first, last;
  var outside = 0, missing = 0;
  for (final sample in available) {
    final ts = sample.timestamp;
    if (ts != null && ts >= 0) {
      if (first == null || ts < first) first = ts;
      if (last == null || ts > last) last = ts;
    } else {
      missing++;
    }
    if (!validRange) continue;
    if (ranged &&
        (ts == null ||
            ts < 0 ||
            ts < requestedOriginMicros! ||
            ts > requestedOriginMicros + requestedExtentMicros!)) {
      if (ts != null && ts >= 0) outside++;
      continue;
    }
    inside.add(sample);
  }
  return (
    samples: inside,
    meta: {
      'reason': !validRange
          ? 'invalid_window'
          : available.isEmpty
          ? 'stacks_unavailable'
          : 'ok',
      'availableSamples': available.length,
      'reportedSampleCount': data.sampleCount,
      'withinWindowSamples': inside.length,
      'outsideWindowSamples': outside,
      'missingTimestampSamples': missing,
      'timeWindowApplied': ranged,
      'firstReturnedSampleMicros': first,
      'lastReturnedSampleMicros': last,
      if (ranged) 'requestedOriginMicros': requestedOriginMicros,
      if (ranged) 'requestedExtentMicros': requestedExtentMicros,
    },
  );
}

/// Independently derive ticks from the actual returned stacks and timestamps.
/// Function-table ticks are kept separately because their time-window scope
/// must not be assumed when diagnosing an unexpected native call family.
Map<String, Object?> summarizeCpuSampleStacks(
  CpuSamples samples, {
  int? requestedOriginMicros,
  int? requestedExtentMicros,
  int limit = 100,
}) {
  final window = _cpuWindow(
    samples,
    requestedOriginMicros: requestedOriginMicros,
    requestedExtentMicros: requestedExtentMicros,
  );
  if (window.meta['reason'] != 'ok') return window.meta;
  final functions = samples.functions ?? <ProfileFunction>[];
  final self = List<int>.filled(functions.length, 0);
  final inclusive = List<int>.filled(functions.length, 0);
  var emptyStacks = 0, invalidFrames = 0;
  for (final sample in window.samples) {
    final stack = sample.stack ?? <int>[];
    if (stack.isEmpty) {
      emptyStacks++;
      continue;
    }
    final leaf = stack.first;
    if (leaf >= 0 && leaf < self.length) self[leaf]++;
    final seen = <int>{};
    for (final index in stack) {
      if (index < 0 || index >= inclusive.length) {
        invalidFrames++;
      } else if (seen.add(index)) {
        inclusive[index]++;
      }
    }
  }
  final count = window.samples.length;
  final rows = [
    for (var i = 0; i < functions.length; i++)
      if (self[i] > 0 || inclusive[i] > 0)
        <String, Object?>{
          'name': _functionName(functions[i].function),
          'kind': functions[i].kind == 'Dart' ? 'Dart' : 'Native',
          'selfTicks': self[i],
          'inclusiveTicks': inclusive[i],
          'selfPercent': count == 0 ? 0.0 : self[i] * 100 / count,
          'inclusivePercent': count == 0 ? 0.0 : inclusive[i] * 100 / count,
        },
  ];
  List<Map<String, Object?>> ranked(String field, {bool dartOnly = false}) {
    final ordered =
        rows.where((row) => !dartOnly || row['kind'] == 'Dart').toList()
          ..sort((a, b) {
            final ticks = (b[field] as int).compareTo(a[field] as int);
            return ticks == 0
                ? (a['name'] as String).compareTo(b['name'] as String)
                : ticks;
          });
    return ordered.take(limit.clamp(1, 100)).toList();
  }

  return {
    ...window.meta,
    'basis': 'returned_sample_stacks',
    'emptyStackSamples': emptyStacks,
    'invalidFunctionFrames': invalidFrames,
    'topSelf': ranked('selfTicks'),
    'topInclusive': ranked('inclusiveTicks'),
    'topDartSelf': ranked('selfTicks', dartOnly: true),
    'topDartInclusive': ranked('inclusiveTicks', dartOnly: true),
  };
}

const _storageAnchors = {'DpapiJsonFileMapStorage.load', 'CryptUnprotectData'};

bool _storageAnchorMatch(String name, String target) =>
    name == target || name.startsWith('$target.');

class _StorageCallerTarget {
  int matched = 0, overflow = 0, truncated = 0;
  final chains = <String, _StorageCallerChain>{};
}

class _StorageCallerChain {
  _StorageCallerChain(this.symbols);
  final List<String> symbols;
  int samples = 0, truncated = 0, limited = 0;
}

/// Symbol-only synchronous caller chains for two fixed storage anchors. This
/// does not reconstruct async causal frames across await or infer a caller
/// when the sample ends at VM microtask dispatch.
Map<String, Object?> summarizeStorageCallerChains(
  CpuSamples samples, {
  int? requestedOriginMicros,
  int? requestedExtentMicros,
  int maxPaths = 5,
  int maxFrames = 32,
  int maxUniquePaths = 256,
}) {
  final window = _cpuWindow(
    samples,
    requestedOriginMicros: requestedOriginMicros,
    requestedExtentMicros: requestedExtentMicros,
  );
  if (window.meta['reason'] != 'ok') return window.meta;
  final pathLimit = maxPaths.clamp(1, 5);
  final frameLimit = maxFrames.clamp(1, 32);
  final uniqueLimit = maxUniquePaths.clamp(1, 256);
  final functions = samples.functions ?? <ProfileFunction>[];
  final names = [
    for (final function in functions) _functionName(function.function),
  ];
  final targets = {
    for (final name in _storageAnchors) name: _StorageCallerTarget(),
  };
  for (final sample in window.samples) {
    final stack = sample.stack ?? <int>[];
    final symbols = [
      for (final index in stack)
        index >= 0 && index < names.length ? names[index] : 'redacted_function',
    ];
    for (final target in targets.entries) {
      final anchor = symbols.indexWhere(
        (name) => _storageAnchorMatch(name, target.key),
      );
      if (anchor < 0) continue;
      final tally = target.value;
      tally.matched++;
      if (sample.truncated == true) tally.truncated++;
      final chain = symbols.skip(anchor).take(frameLimit).toList();
      final key = chain.join('\u0000');
      var entry = tally.chains[key];
      if (entry == null) {
        if (tally.chains.length >= uniqueLimit) {
          tally.overflow++;
          continue;
        }
        entry = _StorageCallerChain(chain);
        tally.chains[key] = entry;
      }
      entry.samples++;
      if (sample.truncated == true) entry.truncated++;
      if (symbols.length - anchor > frameLimit) entry.limited++;
    }
  }
  final total = window.samples.length;
  return {
    ...window.meta,
    'basis': 'returned_sample_stacks',
    'limits': {
      'pathsPerTarget': pathLimit,
      'framesPerChain': frameLimit,
      'uniquePathsPerTarget': uniqueLimit,
    },
    'targets': {
      for (final target in targets.entries)
        target.key: {
          'matchedSamples': target.value.matched,
          'truncatedSamples': target.value.truncated,
          'percentOfAllSamples': total == 0
              ? 0.0
              : target.value.matched * 100 / total,
          'overflowPathSamples': target.value.overflow,
          'functionTableTicks': [
            for (var i = 0; i < functions.length; i++)
              if (_storageAnchorMatch(names[i], target.key))
                {
                  'name': names[i],
                  'inclusiveTicks': functions[i].inclusiveTicks,
                  'exclusiveTicks': functions[i].exclusiveTicks,
                },
          ].take(16).toList(),
          'topChains': (() {
            final chains = target.value.chains.values.toList()
              ..sort((a, b) => b.samples.compareTo(a.samples));
            return [
              for (final chain in chains.take(pathLimit))
                {
                  'chain': chain.symbols,
                  'samples': chain.samples,
                  'truncatedSamples': chain.truncated,
                  'frameLimitedSamples': chain.limited,
                  'percentOfMatchedSamples': target.value.matched == 0
                      ? 0.0
                      : chain.samples * 100 / target.value.matched,
                },
            ];
          })(),
        },
    },
  };
}

Map<String, Object?> summarizeTimelineCoverage(
  Timeline timeline, {
  required int requestedOriginMicros,
  required int requestedExtentMicros,
}) {
  final result = <String, Object?>{
    'requestedOriginMicros': requestedOriginMicros,
    'requestedExtentMicros': requestedExtentMicros,
  };
  final origin = timeline.timeOriginMicros;
  final extent = timeline.timeExtentMicros;
  if (origin == null || extent == null || origin < 0 || extent < 0) {
    return {...result, 'reason': 'unavailable'};
  }
  result.addAll({
    'returnedOriginMicros': origin,
    'returnedExtentMicros': extent,
  });
  if (requestedOriginMicros < 0 || requestedExtentMicros <= 0) {
    return {...result, 'reason': 'invalid_request'};
  }
  final start = origin > requestedOriginMicros ? origin : requestedOriginMicros;
  final requestedEnd = requestedOriginMicros + requestedExtentMicros;
  final returnedEnd = origin + extent;
  final end = returnedEnd < requestedEnd ? returnedEnd : requestedEnd;
  final overlap = (end - start).clamp(0, requestedExtentMicros);
  return {
    ...result,
    'reason': overlap == requestedExtentMicros ? 'complete' : 'partial',
    'overlapMicros': overlap,
    'overlapRatio': overlap / requestedExtentMicros,
  };
}

const _timelineNames = {
  'BUILD',
  'LAYOUT',
  'LAYOUT (root)',
  'PAINT',
  'PAINT (root)',
  'SEMANTICS',
  'SEMANTICS (root)',
  'UPDATING COMPOSITING BITS',
  'UPDATING COMPOSITING BITS (root)',
  'FINALIZE TREE',
  'POST_FRAME',
  'Frame',
  'Build',
  'Layout',
  'Paint',
  'Compositing',
  'FinalizeTree',
  'Animator::BeginFrame',
  'Animator::Draw',
  'Rasterizer::Draw',
  'GPURasterizer::Draw',
  'PipelineProduce',
  'PipelineConsume',
  'VsyncProcessCallback',
  'CollectNewGeneration',
  'CollectOldGeneration',
  'CollectAllGarbage',
  'Scavenge',
  'MarkSweep',
  'ConcurrentMark',
};

const _framePhaseLabels = {
  'BUILD': 'build',
  'Build': 'build',
  'LAYOUT': 'layout',
  'LAYOUT (root)': 'layout',
  'Layout': 'layout',
  'PAINT': 'paint',
  'PAINT (root)': 'paint',
  'Paint': 'paint',
  'SEMANTICS': 'semantics',
  'SEMANTICS (root)': 'semantics',
  'UPDATING COMPOSITING BITS': 'compositing',
  'UPDATING COMPOSITING BITS (root)': 'compositing',
  'Compositing': 'compositing',
  'FINALIZE TREE': 'finalize',
  'FinalizeTree': 'finalize',
  'POST_FRAME': 'postFrame',
};

List<Map<String, Object?>> summarizeFrameCpu(CpuSamples samples, List frames) =>
    [
      for (final frame in frames.take(32))
        if (frame is Map &&
            frame['startMicros'] is int &&
            frame['endMicros'] is int &&
            (frame['endMicros'] as int) > (frame['startMicros'] as int))
          {
            'startMicros': frame['startMicros'],
            'endMicros': frame['endMicros'],
            'cpu': summarizeCpuSampleStacks(
              samples,
              requestedOriginMicros: frame['startMicros'] as int,
              requestedExtentMicros:
                  (frame['endMicros'] as int) - (frame['startMicros'] as int),
              limit: 10,
            ),
          },
    ];

num _intervalUnion(List<(num, num)> intervals) {
  intervals.sort((a, b) => a.$1.compareTo(b.$1));
  num total = 0;
  num? end;
  for (final interval in intervals) {
    if (end == null || interval.$1 > end) {
      total += interval.$2 - interval.$1;
      end = interval.$2;
    } else if (interval.$2 > end) {
      total += interval.$2 - end;
      end = interval.$2;
    }
  }
  return total;
}

/// Host-side only. Clipped synchronous framework phases and asynchronous read
/// overlap are separate; an elapsed Future is never counted as CPU work.
Map<String, Object?> summarizeFrameAttribution(
  Iterable<Map<String, dynamic>> events,
  Map<String, dynamic> snapshot,
) {
  final clean = sanitizeGallerySnapshot(snapshot);
  final frames = clean['frameWindows'] as List;
  final work = (clean['work'] as Map)['spans'] as List;
  final intervals = <({String phase, num start, num end})>[];
  final lanes = <String, List<({String? phase, num start})>>{};
  final ordered =
      events
          .where((event) => event['ts'] is num && (event['ts'] as num).isFinite)
          .toList()
        ..sort((a, b) => (a['ts'] as num).compareTo(b['ts'] as num));
  void add(String? phase, num start, num end) {
    if (phase != null && start >= 0 && end.isFinite && end >= start) {
      intervals.add((phase: phase, start: start, end: end));
    }
  }

  for (final event in ordered) {
    final ts = event['ts'] as num;
    final lane = '${event['pid']}/${event['tid']}';
    final phase = _framePhaseLabels[event['name']];
    if (event['ph'] == 'B') {
      (lanes[lane] ??= []).add((phase: phase, start: ts));
    } else if (event['ph'] == 'E') {
      final stack = lanes[lane];
      if (stack != null && stack.isNotEmpty) {
        final begin = stack.removeLast();
        add(begin.phase, begin.start, ts);
      }
    } else if (event['ph'] == 'X' && event['dur'] is num) {
      add(phase, ts, ts + (event['dur'] as num));
    }
  }
  final results = <Map<String, Object?>>[];
  for (final raw in frames) {
    final frame = raw as Map;
    final start = frame['startMicros'] as num, end = frame['endMicros'] as num;
    (num, num)? clip(num a, num b) {
      final left = a > start ? a : start;
      final right = b < end ? b : end;
      return right > left ? (left, right) : null;
    }

    final perPhase = <String, List<(num, num)>>{};
    final all = <(num, num)>[];
    for (final interval in intervals) {
      final piece = clip(interval.start, interval.end);
      if (piece != null) {
        (perPhase[interval.phase] ??= []).add(piece);
        all.add(piece);
      }
    }
    final readIntervals = <(num, num)>[];
    final callers = <String>{};
    for (final rawRead in work) {
      final read = rawRead as Map;
      final piece = clip(read['startMicros'] as num, read['endMicros'] as num);
      if (piece != null) {
        readIntervals.add(piece);
        callers.addAll((read['callers'] as List).cast<String>());
      }
    }
    final accounted = _intervalUnion(all);
    final ui = frame['uiMicros'] as num;
    results.add({
      ...Map<String, Object?>.from(frame),
      'phases': {
        for (final phase in _framePhaseLabels.values.toSet())
          phase: _intervalUnion(perPhase[phase] ?? []),
      },
      'accountedMicros': accounted,
      'unattributedMicros': (ui - accounted).clamp(0, ui),
      'secureReadOverlapMicros': _intervalUnion(readIntervals),
      'secureReadCallers': callers.toList()..sort(),
    });
  }
  final slow =
      results
          .where(
            (frame) =>
                (frame['uiMicros'] as num) > (frame['budgetMicros'] as num),
          )
          .toList()
        ..sort(
          (a, b) => (b['uiMicros'] as num).compareTo(a['uiMicros'] as num),
        );
  return {
    'reason': frames.isEmpty ? 'no_frame_windows' : 'ok',
    'basis': 'clipped_sync_union_async_overlap_not_cpu',
    'sampledFrames': results.length,
    'slowFrameCount': slow.length,
    'phaseTotalsMicros': {
      for (final phase in _framePhaseLabels.values.toSet())
        phase: results.fold<num>(
          0,
          (sum, frame) => sum + ((frame['phases'] as Map)[phase] as num),
        ),
    },
    'slowFrames': slow.take(32).toList(),
  };
}

bool _timelineAllowed(String name) =>
    _timelineNames.contains(name) ||
    [
      for (final prefix in ['gallery.', 'GalleryPerf.'])
        if (name.startsWith(prefix)) name.substring(prefix.length),
    ].any(_metricNames.contains);

const _gcNames = {
  'CollectNewGeneration',
  'CollectOldGeneration',
  'CollectAllGarbage',
  'Scavenge',
  'MarkSweep',
  'ConcurrentMark',
};

/// Aggregate complete slices and paired B/E slices. No args/source names are
/// exported, and unmatched boundaries remain an explicit count.
Map<String, Object?> summarizeTimeline(Iterable<Map<String, dynamic>> events) {
  final stacks = <String, List<({String name, num ts})>>{};
  final asyncStacks = <String, List<({String name, num ts})>>{};
  final stages = <String, ({int count, num total, num max})>{};
  final gcIntervals = <(num, num)>[];
  var seen = 0, ignored = 0, unmatched = 0;
  void add(String name, num duration, num? start) {
    if (!duration.isFinite || duration < 0) return;
    final old = stages[name] ?? (count: 0, total: 0, max: 0);
    stages[name] = (
      count: old.count + 1,
      total: old.total + duration,
      max: old.max > duration ? old.max : duration,
    );
    if (_gcNames.contains(name) && start != null && start.isFinite) {
      gcIntervals.add((start, start + duration));
    }
  }

  // VM Service explicitly does not guarantee timestamp order. Retain original
  // order for ties, while pairing each thread/task by chronological boundary.
  final ordered = events.indexed.toList()
    ..sort((a, b) {
      num time(Map<String, dynamic> event) {
        final value = event['ts'];
        return value is num && value.isFinite ? value : 0;
      }

      final byTime = time(a.$2).compareTo(time(b.$2));
      return byTime == 0 ? a.$1.compareTo(b.$1) : byTime;
    });
  for (final indexed in ordered) {
    final event = indexed.$2;
    seen++;
    final phase = event['ph'], ts = event['ts'];
    // End events may omit their name. Only a previously validated begin can
    // contribute a label, even when end-event args contain arbitrary text.
    if ((phase == 'E' || phase == 'e') && ts is num) {
      final lane = phase == 'E'
          ? '${event['pid']}/${event['tid']}'
          : '${event['pid']}/${event['scope']}/${event['id'] ?? event['id2']}';
      final stack = (phase == 'E' ? stacks : asyncStacks)[lane];
      if (stack == null || stack.isEmpty) {
        unmatched++;
      } else {
        final begin = stack.removeLast();
        if (begin.name.isNotEmpty) add(begin.name, ts - begin.ts, begin.ts);
      }
      continue;
    }
    final name = event['name'];
    if (name is! String || !_timelineAllowed(name)) {
      ignored++;
      // Retain an anonymous placeholder for nested unapproved slices so their
      // end cannot accidentally close an approved outer span.
      if ((phase == 'B' || phase == 'b') && ts is num) {
        final lane = phase == 'B'
            ? '${event['pid']}/${event['tid']}'
            : '${event['pid']}/${event['scope']}/${event['id'] ?? event['id2']}';
        ((phase == 'B' ? stacks : asyncStacks)[lane] ??= []).add((
          name: '',
          ts: ts,
        ));
      }
      continue;
    }
    if (phase == 'X' && event['dur'] is num) {
      add(name, event['dur'] as num, ts is num ? ts : null);
    } else if (phase == 'B' && ts is num) {
      final lane = '${event['pid']}/${event['tid']}';
      (stacks[lane] ??= []).add((name: name, ts: ts));
    } else if (phase == 'b' && ts is num) {
      final lane =
          '${event['pid']}/${event['scope']}/${event['id'] ?? event['id2']}';
      (asyncStacks[lane] ??= []).add((name: name, ts: ts));
    }
  }
  unmatched += stacks.values.fold<int>(0, (sum, stack) => sum + stack.length);
  unmatched += asyncStacks.values.fold<int>(
    0,
    (sum, stack) => sum + stack.length,
  );
  final gc = stages.entries.where((entry) => _gcNames.contains(entry.key));
  gcIntervals.sort((a, b) => a.$1.compareTo(b.$1));
  num gcMicros = 0;
  num? end;
  for (final interval in gcIntervals) {
    if (end == null || interval.$1 > end) {
      gcMicros += interval.$2 - interval.$1;
      end = interval.$2;
    } else if (interval.$2 > end) {
      gcMicros += interval.$2 - end;
      end = interval.$2;
    }
  }
  return {
    'reason': seen == 0 ? 'zero_events' : 'ok',
    'eventCount': seen,
    'ignoredEvents': ignored,
    'unmatchedBoundaries': unmatched,
    'gcSliceCount': gc.fold<int>(0, (sum, row) => sum + row.value.count),
    'gcMicros': gcMicros,
    'gcMicrosBasis': 'union_of_named_slices',
    'stages': {
      for (final entry in stages.entries)
        entry.key: {
          'count': entry.value.count,
          'totalMicros': entry.value.total,
          'maxMicros': entry.value.max,
        },
    },
  };
}

// Host schema intentionally does not import the Flutter recorder (dart:ui).
const _metricNames = {
  'pageWait',
  'filter',
  'group',
  'cardMount',
  'cardDispose',
  'cardBuild',
  'cardLayout',
  'cardDeferred',
  'cardRestored',
  'cardRestoreCancelled',
  'imageMemoryHit',
  'videoMemoryHit',
  'memoryHit',
  'memoryMiss',
  'eviction',
  'coalesced',
  'queued',
  'queueWait',
  'activeJobs',
  'pendingJobs',
  'cancelled',
  'completed',
  'discarded',
  'cachedAfterCancel',
  'failed',
  'rejected',
  'imageDiskHit',
  'videoDiskHit',
  'diskMiss',
  'diskRead',
  'diskBytes',
  'diskIndex',
  'originalRead',
  'originalBytes',
  'imageGenerate',
  'imageDecode',
  'imageOrient',
  'imageResize',
  'imageEncode',
  'cacheWrite',
  'cacheStat',
  'cacheRoot',
  'cacheCleanup',
  'cacheBytes',
  'videoProbe',
  'videoExtract',
  'videoCompact',
  'prefetchQueued',
  'prefetchSkipped',
  'imagePresent',
  'imageSyncHit',
  'imageAsyncFrame',
  'scrollDelta',
  'scrollSpeed',
  'returnTopDistance',
  'returnTopDuration',
  'dragDeferred',
  'dragImageLatency',
  'prefetchDepth',
};
bool _metricAllowed(String name) => _metricNames.contains(name);

Map<String, Object> _numericMap(Object? value, Set<String> allowed) => {
  if (value is Map)
    for (final key in allowed)
      if (value[key] is num && (value[key] as num).isFinite)
        key: value[key] as num,
};

const _distributionFields = {
  'count',
  'stored',
  'total',
  'p50',
  'p95',
  'p99',
  'max',
  'min',
  'dropped',
};
const _galleryFields = {
  'loaded',
  'total',
  'images',
  'videos',
  'columns',
  'viewportWidth',
  'viewportHeight',
  'offset',
  'maxScrollExtent',
  'devicePixelRatio',
  'refreshHz',
  'backgroundTasks',
  'filtered',
  'visible',
  'scrollPixels',
  'scrollExtent',
  'viewport',
  'extent',
  'width',
  'height',
};
const galleryScenarios = {
  'normalDown',
  'fastDown',
  'reverse',
  'returnTop',
  'settle',
  'warmDown',
  'warmReverse',
  'idle',
};
const galleryCoverModes = {'normal', 'placeholder', 'encodedWarm'};

/// The app also enforces fixed diagnostic names. This second boundary keeps
/// unexpected extensions, malformed numbers and added text out of host output.
Map<String, Object?> sanitizeGallerySnapshot(Map<String, dynamic> value) {
  final result = <String, Object?>{};
  bool validInterval(Map row) =>
      row['startMicros'] is num &&
      (row['startMicros'] as num).isFinite &&
      (row['startMicros'] as num) >= 0 &&
      row['endMicros'] is num &&
      (row['endMicros'] as num).isFinite &&
      (row['endMicros'] as num) >= (row['startMicros'] as num);
  final windows = value['frameWindows'];
  result['frameWindows'] = [
    if (windows is List)
      for (final frame in windows.take(512))
        if (frame is Map &&
            validInterval(frame) &&
            ['uiMicros', 'rasterMicros', 'budgetMicros'].every(
              (key) =>
                  frame[key] is num &&
                  (frame[key] as num).isFinite &&
                  (frame[key] as num) >= 0,
            ))
          _numericMap(frame, {
            'startMicros',
            'endMicros',
            'uiMicros',
            'rasterMicros',
            'budgetMicros',
          }),
  ];
  final work = value['work'];
  final spans = work is Map ? work['spans'] : null;
  result['work'] = {
    ..._numericMap(work, {'started', 'completed', 'dropped'}),
    'basis': 'async_elapsed_not_cpu',
    'coverage': 'calls_started_in_window',
    'spans': [
      if (spans is List)
        for (final span in spans.take(256))
          if (span is Map &&
              validInterval(span) &&
              secureReadKeyGroups.contains(span['keyGroup']))
            {
              ..._numericMap(span, {'startMicros', 'endMicros'}),
              'keyGroup': span['keyGroup'],
              'callers': [
                if (span['callers'] is List)
                  for (final caller in (span['callers'] as List).take(12))
                    if (secureReadCallerNames.contains(caller)) caller,
              ],
              'complete': span['complete'] == true,
              'failed': span['failed'] == true,
            },
    ],
  };
  if (const {'immediate', 'settled'}.contains(value['loadingPolicy'])) {
    result['loadingPolicy'] = value['loadingPolicy'];
  }
  if (const {'immediate', 'settled'}.contains(value['selectedLoadingPolicy'])) {
    result['selectedLoadingPolicy'] = value['selectedLoadingPolicy'];
  }
  if (const {'all', 'visible', 'paused'}.contains(value['loadingAdmission'])) {
    result['loadingAdmission'] = value['loadingAdmission'];
  }
  final dragFrames = value['dragFrames'];
  final dragCounters = value['dragCounters'];
  result['dragFrames'] = {
    if (dragFrames is Map)
      for (final phase in const ['idle', 'moving', 'settling'])
        if (dragFrames[phase] is Map)
          phase: {
            ..._numericMap(dragFrames[phase], {
              'count',
              'overBudget',
              'overBudgetRatio',
            }),
            for (final field in const ['ui', 'raster'])
              field: _numericMap(
                (dragFrames[phase] as Map)[field],
                _distributionFields,
              ),
          },
  };
  result['dragCounters'] = {
    if (dragCounters is Map)
      for (final phase in const ['idle', 'moving', 'settling'])
        if (dragCounters[phase] is Map)
          phase: _numericMap(dragCounters[phase], _metricNames),
  };
  for (final field in ['scenario', 'coverMode']) {
    final allowed = field == 'scenario' ? galleryScenarios : galleryCoverModes;
    if (allowed.contains(value[field])) result[field] = value[field];
  }
  for (final field in ['elapsedMicros', 'generation']) {
    if (value[field] is num && (value[field] as num).isFinite) {
      result[field] = value[field];
    }
  }
  final counters = value['counters'];
  result['counters'] = {
    if (counters is Map)
      for (final entry in counters.entries)
        if (entry.key is String &&
            _metricAllowed(entry.key as String) &&
            entry.value is num &&
            (entry.value as num).isFinite)
          entry.key as String: entry.value as num,
  };
  final timings = value['timings'];
  result['timings'] = {
    if (timings is Map)
      for (final entry in timings.entries)
        if (entry.key is String && _metricAllowed(entry.key as String))
          entry.key as String: {
            ..._numericMap(entry.value, _distributionFields),
            if (entry.value is Map &&
                (entry.value as Map)['window'] == 'last_samples')
              'window': 'last_samples',
          },
  };
  result['gallery'] = _numericMap(value['gallery'], _galleryFields);
  final frames = value['frames'];
  result['frames'] = {
    ..._numericMap(frames, {
      'count',
      'overBudget',
      'overBudgetRatio',
      'refreshHz',
      'budgetMicros',
    }),
    if (frames is Map)
      for (final field in ['ui', 'raster', 'total', 'refreshHz', 'budget'])
        if (frames[field] is Map)
          field: _numericMap(frames[field], _distributionFields),
  };
  result['imageCache'] = _numericMap(value['imageCache'], {
    'entries',
    'bytes',
    'live',
    'pending',
    'maxBytes',
    'maxEntries',
  });
  result['background'] = _numericMap(value['background'], {
    'syncBusy',
    'importBusy',
    'syncBusyObserved',
    'importBusyObserved',
    'cacheActive',
    'cachePending',
    'cacheActiveAtStart',
    'cachePendingAtStart',
    'cacheCarryoverFinished',
  });
  final marks = value['marks'];
  result['marks'] = [
    if (marks is List)
      for (final mark in marks.take(128))
        if (mark is Map &&
            galleryScenarios.contains(mark['scenario']) &&
            mark['micros'] is num &&
            (mark['micros'] as num).isFinite)
          {'scenario': mark['scenario'], 'micros': mark['micros']},
  ];
  return result;
}
