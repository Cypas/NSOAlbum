import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'gallery_drag_loading.dart';
import '../diagnostics/gallery_work_probe.dart';

/// Typed names are intentional: no media identity or arbitrary caller string
/// can become a metric label or Timeline argument.
enum GalleryMetric {
  pageWait,
  filter,
  group,
  cardMount,
  cardDispose,
  cardBuild,
  cardLayout,
  cardDeferred,
  cardRestored,
  cardRestoreCancelled,
  imageMemoryHit,
  videoMemoryHit,
  memoryHit,
  memoryMiss,
  eviction,
  coalesced,
  queued,
  queueWait,
  activeJobs,
  pendingJobs,
  cancelled,
  completed,
  discarded,
  failed,
  rejected,
  imageDiskHit,
  videoDiskHit,
  diskMiss,
  diskRead,
  diskBytes,
  diskIndex,
  originalRead,
  originalBytes,
  imageGenerate,
  imageDecode,
  imageOrient,
  imageResize,
  imageEncode,
  cacheWrite,
  cacheBytes,
  cacheStat,
  cacheRoot,
  cacheCleanup,
  cachedAfterCancel,
  videoProbe,
  videoExtract,
  videoCompact,
  prefetchQueued,
  prefetchSkipped,
  imagePresent,
  imageSyncHit,
  imageAsyncFrame,
  scrollDelta,
  scrollSpeed,
  returnTopDistance,
  returnTopDuration,
  dragDeferred,
  dragImageLatency,
  prefetchDepth,
}

enum GalleryCoverMode { normal, placeholder, encodedWarm }

enum GalleryScenario {
  idle,
  normalDown,
  fastDown,
  reverse,
  returnTop,
  settle,
  warmDown,
  warmReverse,
}

class GalleryPerf {
  GalleryPerf({required bool enabled, this.sampleLimit = 8192})
    : enabled = enabled && !kReleaseMode,
      assert(sampleLimit > 0);

  static const compiled =
      !kReleaseMode &&
      bool.fromEnvironment('NSO_GALLERY_PERF', defaultValue: false);
  static const extensionName = 'ext.squid_album.galleryPerf';
  static final instance = GalleryPerf(enabled: compiled);
  final bool enabled;
  final int sampleLimit;
  final coverMode = ValueNotifier(GalleryCoverMode.normal);
  final _counters = <GalleryMetric, int>{};
  final _timings = <GalleryMetric, _Samples>{};
  final _ui = _Samples(8192), _raster = _Samples(8192), _hz = _Samples(8192);
  final _marks = <Map<String, Object>>[];
  final _frameWindows = <Map<String, num>>[];
  final _gallery = <String, num>{};
  final _background = <String, int>{};
  final _watch = Stopwatch();
  ScrollController? _scroll;
  Future<void> Function()? _returnToTop;
  Timer? _driveTimer;
  bool _recording = false,
      _registered = false,
      _draining = false,
      _listening = false;
  int _frameCount = 0, _overBudget = 0, _generation = 0;
  int _captureStartMicros = 0;
  int _captureEndMicros = 0;
  GalleryScenario _scenario = GalleryScenario.idle;
  GalleryLoadMode _sessionLoadingPolicy = GalleryLoadMode.immediate;
  GalleryDragPhase _dragPhase = GalleryDragPhase.idle;
  final _dragPhaseChanges = <(int, GalleryDragPhase)>[];
  final _dragFrames = <GalleryDragPhase, _DragFrameSamples>{};
  final _phaseCounters = <GalleryDragPhase, Map<GalleryMetric, int>>{};
  int? _resumeMicros;
  int _resumeSerial = 0;
  bool get recording => enabled && _recording;
  int get generation => _generation;

  VoidCallback bindScroll(
    ScrollController controller, {
    required Future<void> Function() returnToTop,
  }) {
    if (!enabled) return () {};
    _scroll = controller;
    _returnToTop = returnToTop;
    return () {
      if (!identical(_scroll, controller)) return;
      _driveTimer?.cancel();
      _scroll = null;
      _returnToTop = null;
    };
  }

  /// A diagnostic input replay, not a replacement gallery or a whole-library
  /// animation. pointerScroll is the same ScrollPosition entry used by Flutter
  /// for mouse-wheel signals; existing paging, cards and viewport remain live.
  bool replayWheel() {
    final scroll = _scroll;
    if (!recording || scroll == null || !scroll.hasClients) return false;
    if (_scenario == GalleryScenario.returnTop) {
      final callback = _returnToTop;
      if (callback == null) return false;
      sample(GalleryMetric.returnTopDistance, scroll.offset);
      unawaited(async(GalleryMetric.returnTopDuration, callback));
      return true;
    }
    final direction = switch (_scenario) {
      GalleryScenario.reverse || GalleryScenario.warmReverse => -1,
      GalleryScenario.normalDown ||
      GalleryScenario.warmDown ||
      GalleryScenario.fastDown => 1,
      _ => 0,
    };
    if (direction == 0) return true;
    final fast = _scenario == GalleryScenario.fastDown;
    _driveTimer?.cancel();
    _driveTimer = Timer.periodic(Duration(milliseconds: fast ? 120 : 200), (_) {
      if (!recording || !identical(scroll, _scroll) || !scroll.hasClients) {
        _driveTimer?.cancel();
        return;
      }
      scroll.position.pointerScroll(direction * (fast ? 360.0 : 120.0));
    });
    return true;
  }

  void register() {
    if (!enabled || _registered) return;
    developer.registerExtension(extensionName, handle);
    if (GalleryLoadExperiment.available) {
      GalleryLoadExperiment.instance
        ..onModeChanging = () {
          if (recording || _draining) stop();
        }
        ..onPhase = loadingPhase;
    }
    _registered = true;
  }

  void start({
    GalleryScenario scenario = GalleryScenario.idle,
    GalleryCoverMode mode = GalleryCoverMode.normal,
  }) {
    if (!enabled) return;
    _driveTimer?.cancel();
    if (_listening) SchedulerBinding.instance.removeTimingsCallback(_onFrames);
    _counters.clear();
    _timings.clear();
    _marks.clear();
    _frameWindows.clear();
    GalleryWorkProbe.instance.start();
    _ui.clear();
    _raster.clear();
    _hz.clear();
    _frameCount = _overBudget = 0;
    _dragFrames.clear();
    _phaseCounters.clear();
    _dragPhaseChanges
      ..clear()
      ..add((developer.Timeline.now, _dragPhase));
    _resumeMicros = null;
    // Invalidate both completed and next-resume tickets from the old capture.
    _resumeSerial++;
    _sessionLoadingPolicy = GalleryLoadExperiment.instance.mode;
    _background['syncBusyObserved'] = _background['syncBusy'] ?? -1;
    _background['importBusyObserved'] = _background['importBusy'] ?? -1;
    _background['cacheActiveAtStart'] = _background['cacheActive'] ?? 0;
    _background['cachePendingAtStart'] = _background['cachePending'] ?? 0;
    _background['cacheCarryoverFinished'] = 0;
    _scenario = scenario;
    _generation++;
    _captureStartMicros = developer.Timeline.now;
    _captureEndMicros = 0;
    _watch
      ..reset()
      ..start();
    _recording = true;
    _draining = false;
    coverMode.value = mode;
    SchedulerBinding.instance.addTimingsCallback(_onFrames);
    _listening = true;
  }

  Map<String, Object> stop() {
    _driveTimer?.cancel();
    if (_listening) {
      SchedulerBinding.instance.removeTimingsCallback(_onFrames);
      _listening = false;
    }
    _watch.stop();
    _recording = _draining = false;
    GalleryWorkProbe.instance.stop();
    final captured = snapshot();
    coverMode.value = GalleryCoverMode.normal;
    return captured;
  }

  /// Engines deliver FrameTiming callbacks in batches. Close the work window,
  /// but retain delayed frames whose build started inside that window.
  Future<Map<String, Object>> stopAndDrain() async {
    if (!recording) return stop();
    final generation = _generation;
    _captureEndMicros = developer.Timeline.now;
    GalleryWorkProbe.instance.stop();
    _driveTimer?.cancel();
    _watch.stop();
    _recording = false;
    _draining = true;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    if (generation != _generation) return snapshot();
    return stop();
  }

  void increment(GalleryMetric metric, [int amount = 1]) {
    if (recording) {
      _counters.update(metric, (v) => v + amount, ifAbsent: () => amount);
      (_phaseCounters[_dragPhase] ??= {}).update(
        metric,
        (value) => value + amount,
        ifAbsent: () => amount,
      );
    }
  }

  void loadingPhase(GalleryDragPhase phase) {
    if (_dragPhase == phase) return;
    final previous = _dragPhase;
    _dragPhase = phase;
    if (phase == GalleryDragPhase.moving) {
      _resumeMicros = null;
    } else if (previous == GalleryDragPhase.moving) {
      _resumeSerial++;
      _resumeMicros = developer.Timeline.now;
    }
    if (recording && _dragPhaseChanges.length < sampleLimit) {
      _dragPhaseChanges.add((developer.Timeline.now, phase));
    }
  }

  int? previewTicket({bool thumbActive = false, bool resumed = false}) {
    if (!recording || (!thumbActive && !resumed)) return null;
    if (_dragPhase == GalleryDragPhase.moving) return _resumeSerial + 1;
    return _resumeMicros == null ? null : _resumeSerial;
  }

  void previewPresented([int? ticket]) {
    if (ticket == null || ticket != _resumeSerial) return;
    if (_resumeMicros case final started?) {
      sample(GalleryMetric.dragImageLatency, developer.Timeline.now - started);
    }
  }

  void sample(GalleryMetric metric, num value) {
    if (!recording || !value.isFinite || value < 0) return;
    (_timings[metric] ??= _Samples(sampleLimit)).add(value.toDouble());
  }

  T sync<T>(GalleryMetric metric, T Function() body) {
    if (!recording) return body();
    final watch = Stopwatch()..start();
    try {
      return developer.Timeline.timeSync('gallery.${metric.name}', body);
    } finally {
      sample(metric, watch.elapsedMicroseconds);
    }
  }

  Future<T> async<T>(GalleryMetric metric, Future<T> Function() body) async {
    if (!recording) return body();
    final generation = _generation;
    final watch = Stopwatch()..start();
    final task = developer.TimelineTask()..start('gallery.${metric.name}');
    try {
      return await body();
    } finally {
      task.finish();
      if (generation == _generation) sample(metric, watch.elapsedMicroseconds);
    }
  }

  /// Only numeric, explicitly named geometry/counts cross the VM boundary.
  /// Counts describe the real already-loaded query, never another database read.
  void gallery({
    required int loaded,
    required int images,
    required int videos,
    required int columns,
    required double viewport,
    required double offset,
    required double extent,
    int? total,
  }) {
    if (!enabled) return;
    _gallery
      ..['loaded'] = loaded
      ..['images'] = images
      ..['videos'] = videos
      ..['columns'] = columns
      ..['viewport'] = viewport
      ..['offset'] = offset
      ..['extent'] = extent;
    if (total != null) {
      _gallery['total'] = total;
    } else {
      _gallery.remove('total');
    }
  }

  void background({bool? syncBusy, bool? importBusy}) {
    if (!enabled) return;
    if (syncBusy != null) _background['syncBusy'] = syncBusy ? 1 : 0;
    if (importBusy != null) _background['importBusy'] = importBusy ? 1 : 0;
    if (recording && syncBusy == true) _background['syncBusyObserved'] = 1;
    if (recording && importBusy == true) _background['importBusyObserved'] = 1;
  }

  /// Queue gauges span capture boundaries. Work admitted before a new window
  /// keeps its original metric scope, but must remain visible as carryover.
  void cacheWork({
    int activeDelta = 0,
    int pendingDelta = 0,
    bool carryoverFinished = false,
  }) {
    if (!enabled) return;
    final active = (_background['cacheActive'] ?? 0) + activeDelta;
    final pending = (_background['cachePending'] ?? 0) + pendingDelta;
    assert(active >= 0 && pending >= 0);
    _background['cacheActive'] = active;
    _background['cachePending'] = pending;
    if (recording && carryoverFinished) {
      _background.update(
        'cacheCarryoverFinished',
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
  }

  void recordFrame({
    required int uiMicros,
    required int rasterMicros,
    required double refreshHz,
    GalleryDragPhase? phase,
  }) {
    if ((!recording && !_draining) || refreshHz <= 0 || !refreshHz.isFinite) {
      return;
    }
    _frameCount++;
    final budget = 1000000 / refreshHz;
    if (uiMicros > budget || rasterMicros > budget) _overBudget++;
    _ui.add(uiMicros.toDouble());
    _raster.add(rasterMicros.toDouble());
    _hz.add(refreshHz);
    (_dragFrames[phase ?? _dragPhase] ??= _DragFrameSamples()).add(
      uiMicros,
      rasterMicros,
      budget,
    );
  }

  void _onFrames(List<ui.FrameTiming> timings) {
    final views = ui.PlatformDispatcher.instance.views;
    if (views.isEmpty) return;
    final hz = views.first.display.refreshRate;
    for (final frame in timings) {
      // Engine batches may include frames completed before this session.
      if (frame.timestampInMicroseconds(ui.FramePhase.buildStart) <
          _captureStartMicros) {
        continue;
      }
      if (_captureEndMicros > 0 &&
          frame.timestampInMicroseconds(ui.FramePhase.buildStart) >
              _captureEndMicros) {
        continue;
      }
      recordFrame(
        uiMicros: frame.buildDuration.inMicroseconds,
        rasterMicros: frame.rasterDuration.inMicroseconds,
        refreshHz: hz,
        phase: _dragPhaseChanges
            .lastWhere(
              (entry) =>
                  entry.$1 <=
                  frame.timestampInMicroseconds(ui.FramePhase.buildStart),
              orElse: () => (0, GalleryDragPhase.idle),
            )
            .$2,
      );
      if (_frameWindows.length == 512) _frameWindows.removeAt(0);
      _frameWindows.add({
        'startMicros': frame.timestampInMicroseconds(ui.FramePhase.buildStart),
        'endMicros': frame.timestampInMicroseconds(ui.FramePhase.buildFinish),
        'uiMicros': frame.buildDuration.inMicroseconds,
        'rasterMicros': frame.rasterDuration.inMicroseconds,
        'budgetMicros': 1000000 / hz,
      });
    }
  }

  Map<String, Object> snapshot() => {
    'ok': true,
    'recording': recording,
    'generation': _generation,
    'scenario': _scenario.name,
    'coverMode': coverMode.value.name,
    'loadingPolicy': _sessionLoadingPolicy.name,
    'selectedLoadingPolicy': GalleryLoadExperiment.instance.mode.name,
    'loadingAdmission': GalleryLoadExperiment.instance.admission.value.name,
    'dragFrames': {
      for (final entry in _dragFrames.entries)
        entry.key.name: entry.value.json(),
    },
    'dragCounters': {
      for (final entry in _phaseCounters.entries)
        entry.key.name: {
          for (final metric in entry.value.entries)
            metric.key.name: metric.value,
        },
    },
    'elapsedMicros': _watch.elapsedMicroseconds,
    'counters': {
      for (final entry in _counters.entries) entry.key.name: entry.value,
    },
    'timings': {
      for (final entry in _timings.entries) entry.key.name: entry.value.json(),
    },
    'frameWindows': List<Map<String, num>>.of(_frameWindows),
    'work': GalleryWorkProbe.instance.snapshot(),
    'frames': {
      'count': _frameCount,
      'overBudget': _overBudget,
      'overBudgetRatio': _frameCount == 0 ? 0.0 : _overBudget / _frameCount,
      'ui': _ui.json(),
      'raster': _raster.json(),
      'refreshHz': _hz.json(),
    },
    'gallery': Map<String, num>.of(_gallery),
    'background': Map<String, int>.of(_background),
    'marks': List<Map<String, Object>>.of(_marks),
    'imageCache': {
      'entries': PaintingBinding.instance.imageCache.currentSize,
      'bytes': PaintingBinding.instance.imageCache.currentSizeBytes,
      'live': PaintingBinding.instance.imageCache.liveImageCount,
      'pending': PaintingBinding.instance.imageCache.pendingImageCount,
      'maxBytes': PaintingBinding.instance.imageCache.maximumSizeBytes,
      'maxEntries': PaintingBinding.instance.imageCache.maximumSize,
    },
  };

  Future<developer.ServiceExtensionResponse> handle(
    String method,
    Map<String, String> parameters,
  ) async {
    developer.ServiceExtensionResponse result(Map<String, Object> value) =>
        developer.ServiceExtensionResponse.result(jsonEncode(value));
    developer.ServiceExtensionResponse failure(String reason) =>
        result({'ok': false, 'reason': reason});
    if (!enabled) return failure('disabled');
    if (method != extensionName) return failure('invalid_action');
    final action = parameters['action'];
    final scenario = GalleryScenario.values
        .where((s) => s.name == (parameters['scenario'] ?? 'idle'))
        .firstOrNull;
    if (scenario == null) return failure('invalid_scenario');
    final mode = GalleryCoverMode.values
        .where((m) => m.name == (parameters['coverMode'] ?? 'normal'))
        .firstOrNull;
    if (mode == null) return failure('invalid_cover_mode');
    switch (action) {
      case 'loadingPolicy':
        if (!GalleryLoadExperiment.available) return failure('disabled');
        final policy = GalleryLoadMode.values
            .where((mode) => mode.name == parameters['policy'])
            .firstOrNull;
        if (policy == null) return failure('invalid_loading_policy');
        GalleryLoadExperiment.instance.setMode(policy);
        return result({'ok': true, 'loadingPolicy': policy.name});
      case 'start':
        if (parameters['drive'] != null && parameters['drive'] != 'wheel') {
          return failure('invalid_drive');
        }
        start(scenario: scenario, mode: mode);
        if (parameters['drive'] == 'wheel' && !replayWheel()) {
          stop();
          return failure('drive_unavailable');
        }
      case 'mark':
        if (!recording) return failure('not_recording');
        if (_marks.length < 128) {
          _marks.add({
            'scenario': scenario.name,
            'micros': _watch.elapsedMicroseconds,
          });
        }
        developer.Timeline.instantSync('gallery.${scenario.name}');
      case 'snapshot':
        break;
      case 'stop':
        return result(await stopAndDrain());
      default:
        return failure('invalid_action');
    }
    return result(snapshot());
  }
}

class _DragFrameSamples {
  final ui = _Samples(8192), raster = _Samples(8192);
  int count = 0, over = 0;
  void add(int uiMicros, int rasterMicros, double budget) {
    count++;
    if (uiMicros > budget || rasterMicros > budget) over++;
    ui.add(uiMicros.toDouble());
    raster.add(rasterMicros.toDouble());
  }

  Map<String, Object> json() => {
    'count': count,
    'overBudget': over,
    'overBudgetRatio': count == 0 ? 0.0 : over / count,
    'ui': ui.json(),
    'raster': raster.json(),
  };
}

class _Samples {
  _Samples(this.limit);
  final int limit;
  final _values = <double>[];
  int count = 0;
  double total = 0, max = 0;
  void clear() {
    _values.clear();
    count = 0;
    total = max = 0;
  }

  void add(double v) {
    if (_values.length < limit) {
      _values.add(v);
    } else {
      _values[count % limit] = v;
    }
    count++;
    total += v;
    if (v > max) max = v;
  }

  Map<String, Object> json() {
    final sorted = List<double>.of(_values)..sort();
    double q(double p) =>
        sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).ceil()];
    return {
      'count': count,
      'stored': sorted.length,
      'total': total,
      'max': max,
      'p50': q(.5),
      'p95': q(.95),
      'p99': q(.99),
      'window': 'last_samples',
    };
  }
}

/// Leaves the card and its geometry intact in every cover comparison mode.
class GalleryPerfTile extends StatefulWidget {
  const GalleryPerfTile({super.key, required this.child});
  final Widget child;
  @override
  State<GalleryPerfTile> createState() => _GalleryPerfTileState();
}

class _GalleryPerfTileState extends State<GalleryPerfTile> {
  @override
  void initState() {
    super.initState();
    GalleryPerf.instance.increment(GalleryMetric.cardMount);
  }

  @override
  void dispose() {
    GalleryPerf.instance.increment(GalleryMetric.cardDispose);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _GalleryPerfLayout(child: widget.child);
}

class _GalleryPerfLayout extends SingleChildRenderObjectWidget {
  const _GalleryPerfLayout({required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _GalleryPerfRenderLayout();
}

class _GalleryPerfRenderLayout extends RenderProxyBox {
  @override
  void performLayout() => GalleryPerf.instance.sync(
    GalleryMetric.cardLayout,
    () => super.performLayout(),
  );
}

/// Measures encoded-byte readiness to the first available image frame. It is
/// deliberately not named "decode time": scheduling/cache hits are included.
Widget galleryPerfImageMemory(
  Uint8List bytes, {
  BoxFit? fit,
  int? cacheWidth,
  int? resumeTicket,
  required Widget placeholder,
}) {
  Widget buildImage() => GalleryPerf.compiled
      ? _GalleryPerfImage(
          bytes: bytes,
          fit: fit,
          cacheWidth: cacheWidth,
          resumeTicket: resumeTicket,
          placeholder: placeholder,
        )
      : Image.memory(
          bytes,
          fit: fit,
          cacheWidth: cacheWidth,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => placeholder,
        );
  return GalleryDeferredImage(
    bytes: bytes,
    cacheWidth: cacheWidth,
    placeholder: placeholder,
    builder: buildImage,
  );
}

class _GalleryPerfImage extends StatefulWidget {
  const _GalleryPerfImage({
    required this.bytes,
    this.fit,
    this.cacheWidth,
    this.resumeTicket,
    required this.placeholder,
  });
  final Uint8List bytes;
  final BoxFit? fit;
  final int? cacheWidth;
  final int? resumeTicket;
  final Widget placeholder;
  @override
  State<_GalleryPerfImage> createState() => _GalleryPerfImageState();
}

class _GalleryPerfImageState extends State<_GalleryPerfImage> {
  final _watch = Stopwatch()..start();
  bool _reported = false;
  @override
  void didUpdateWidget(_GalleryPerfImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      _watch
        ..reset()
        ..start();
      _reported = false;
    }
  }

  @override
  Widget build(BuildContext context) => Image.memory(
    widget.bytes,
    fit: widget.fit,
    cacheWidth: widget.cacheWidth,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => widget.placeholder,
    frameBuilder: (context, child, frame, synchronous) {
      if (!_reported && (synchronous || frame != null)) {
        _reported = true;
        GalleryPerf.instance
          ..previewPresented(widget.resumeTicket)
          ..sample(GalleryMetric.imagePresent, _watch.elapsedMicroseconds)
          ..increment(
            synchronous
                ? GalleryMetric.imageSyncHit
                : GalleryMetric.imageAsyncFrame,
          );
      }
      return child;
    },
  );
}
