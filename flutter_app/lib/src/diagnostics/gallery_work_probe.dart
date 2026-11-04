import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'gallery_work_labels.dart';
export 'gallery_work_labels.dart' show secureReadCallers;

/// Passive unless explicitly compiled and a local gallery capture is active.
/// Never retains keys, values, error text or an unfiltered stack trace.
class GalleryWorkProbe {
  GalleryWorkProbe({required bool enabled, this.limit = 256})
    : enabled = enabled && !kReleaseMode,
      assert(limit > 0);

  static final instance = GalleryWorkProbe(
    enabled: !kReleaseMode && const bool.fromEnvironment('NSO_GALLERY_PERF'),
  );
  final bool enabled;
  final int limit;
  bool _active = false;
  int _generation = 0, _started = 0, _completed = 0, _dropped = 0;
  int? _stoppedMicros;
  final _spans = <_ReadSpan>[];

  void start() {
    if (!enabled) return;
    _generation++;
    _started = _completed = _dropped = 0;
    _spans.clear();
    _stoppedMicros = null;
    _active = true;
  }

  void stop() {
    if (!_active) return;
    _stoppedMicros = developer.Timeline.now;
    _active = false;
  }

  Future<T> secureRead<T>(String key, Future<T> Function() body) {
    if (!enabled || !_active) return body();
    final generation = _generation;
    final callers = secureReadCallers(StackTrace.current);
    final span = _ReadSpan(
      secureReadKeyGroup(key),
      callers,
      developer.Timeline.now,
    );
    _started++;
    if (_spans.length < limit) {
      _spans.add(span);
    } else {
      _dropped++;
    }
    return () async {
      var failed = true;
      try {
        final result = await body();
        failed = false;
        return result;
      } finally {
        if (_active && generation == _generation) {
          _completed++;
          span.end = developer.Timeline.now;
          span.failed = failed;
        }
      }
    }();
  }

  Map<String, Object> snapshot() {
    final now = _stoppedMicros ?? developer.Timeline.now;
    return {
      'started': _started,
      'completed': _completed,
      'dropped': _dropped,
      'basis': 'async_elapsed_not_cpu',
      'coverage': 'calls_started_in_window',
      'spans': [
        for (final span in _spans)
          {
            'keyGroup': span.keyGroup,
            'callers': span.callers,
            'startMicros': span.start,
            'endMicros': span.end ?? now,
            'complete': span.end != null,
            'failed': span.failed,
          },
      ],
    };
  }
}

class _ReadSpan {
  _ReadSpan(this.keyGroup, this.callers, this.start);
  final String keyGroup;
  final List<String> callers;
  final int start;
  int? end;
  bool failed = false;
}
