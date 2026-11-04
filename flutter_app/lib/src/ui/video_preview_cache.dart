import 'dart:async';

import 'package:flutter/foundation.dart';

import 'gallery_drag_loading.dart';
import 'gallery_perf.dart';

/// Captured at admission, so an old request finishing during a later capture
/// cannot attribute its bytes, cleanup, or evictions to that new session.
class PreviewPerfScope {
  PreviewPerfScope([GalleryPerf? diagnostics])
    : _perf = diagnostics ?? GalleryPerf.instance,
      _generation = (diagnostics ?? GalleryPerf.instance).generation,
      _recording = (diagnostics ?? GalleryPerf.instance).recording;
  final GalleryPerf _perf;
  final int _generation;
  final bool _recording;
  bool get current =>
      _recording && _perf.recording && _generation == _perf.generation;
  void increment(GalleryMetric metric, [int amount = 1]) {
    if (current) _perf.increment(metric, amount);
  }

  void sample(GalleryMetric metric, num value) {
    if (current) _perf.sample(metric, value);
  }

  Future<T> async<T>(GalleryMetric metric, Future<T> Function() body) =>
      current ? _perf.async(metric, body) : body();
}

class PreviewWork {
  PreviewWork._(this.diagnostics);
  final PreviewPerfScope diagnostics;
  bool _cancelled = false;
  void Function()? _onCancel;
  bool get cancelled => _cancelled;
  set onCancel(void Function()? action) {
    _onCancel = action;
    if (_cancelled) action?.call();
  }

  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }
}

class PreviewRequest<T> {
  PreviewRequest(this.future, [this._release]);
  final Future<T?> future;
  void Function()? _release;
  void cancel() {
    final release = _release;
    _release = null;
    release?.call();
  }
}

/// Single decoder, bounded pending work and byte-budgeted LRU results. Cancel
/// releases one consumer, not another page's shared request.
class PreviewCache<T> {
  PreviewCache({
    required this.maxEntries,
    required this.maxBytes,
    required this.sizeOf,
    this.maxConcurrent = 1,
    GalleryPerf? diagnostics,
    this.memoryHitMetric,
    this.admission,
  }) : _perf = diagnostics ?? GalleryPerf.instance,
       assert(maxEntries > 0),
       assert(maxBytes > 0),
       assert(maxConcurrent > 0);
  final int maxEntries, maxBytes;
  final int Function(T) sizeOf;
  final int maxConcurrent;
  final GalleryPerf _perf;
  final GalleryMetric? memoryHitMetric;
  final ValueListenable<GalleryWorkAdmission>? admission;
  bool _admissionListening = false;
  final _values = <String, (T, int)>{};
  final _jobs = <String, _PreviewJob<T>>{};
  final _pending = <_PreviewJob<T>>[];
  int _bytes = 0;
  int _active = 0;

  T? peek(String key) => _values[key]?.$1;
  void seed(String key, T value, {PreviewPerfScope? diagnostics}) {
    if (!_values.containsKey(key) && !_jobs.containsKey(key)) {
      _retain(key, value, diagnostics: diagnostics);
    }
  }

  PreviewRequest<T> request(
    String key, {
    required Future<T?> Function(PreviewWork) load,
    bool urgent = false,
  }) {
    final hit = _values.remove(key);
    if (hit != null) {
      _perf.increment(GalleryMetric.memoryHit);
      if (memoryHitMetric case final metric?) _perf.increment(metric);
      _values[key] = hit;
      return PreviewRequest(Future.value(hit.$1));
    }
    _perf.increment(GalleryMetric.memoryMiss);
    var job = _jobs[key];
    if (job == null) {
      if (_jobs.length >= maxEntries) {
        if (!urgent || _pending.isEmpty) {
          _perf.increment(GalleryMetric.rejected);
          return PreviewRequest(Future.value(null));
        }
        _retire(_pending.last);
      }
      job = _PreviewJob(
        key,
        load,
        _perf.recording ? (Stopwatch()..start()) : null,
        _perf.generation,
        PreviewPerfScope(_perf),
      );
      _jobs[key] = job;
      _pending.add(job);
      _perf.cacheWork(pendingDelta: 1);
      _perf.increment(GalleryMetric.queued);
      _perf.sample(GalleryMetric.pendingJobs, _pending.length);
    } else {
      _perf.increment(GalleryMetric.coalesced);
    }
    job.users++;
    if (urgent) job.urgentUsers++;
    final owned = job;
    if (urgent && _pending.remove(owned)) _pending.insert(0, owned);
    _pump();
    return PreviewRequest(owned.result.future, () {
      owned.users--;
      if (urgent) owned.urgentUsers--;
      if (owned.users == 0 && !owned.result.isCompleted) {
        if (owned.started &&
            admission != null &&
            admission!.value != GalleryWorkAdmission.all) {
          return;
        }
        _retire(owned);
      }
    });
  }

  void _retire(_PreviewJob<T> job) {
    if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
    if (!job.work.cancelled && job.generation == _perf.generation) {
      _perf.increment(GalleryMetric.cancelled);
    }
    job.work._cancel();
    if (_pending.remove(job)) {
      _perf.cacheWork(pendingDelta: -1);
      if (!job.result.isCompleted) job.result.complete();
    }
    _updateAdmissionListener();
  }

  void _updateAdmissionListener() {
    final listen = _pending.isNotEmpty && admission != null;
    if (listen == _admissionListening) return;
    _admissionListening = listen;
    if (listen) {
      admission!.addListener(_pump);
    } else {
      admission?.removeListener(_pump);
    }
  }

  void _pump() {
    while (_active < maxConcurrent && _pending.isNotEmpty) {
      final state = admission?.value ?? GalleryWorkAdmission.all;
      final index = _pending.indexWhere(
        (job) =>
            state == GalleryWorkAdmission.all ||
            (state == GalleryWorkAdmission.visible && job.urgent),
      );
      if (index < 0) break;
      final job = _pending.removeAt(index);
      job.started = true;
      _active++;
      _perf.cacheWork(activeDelta: 1, pendingDelta: -1);
      if (job.generation == _perf.generation) {
        final wait = job.wait;
        if (wait != null) {
          _perf.sample(GalleryMetric.queueWait, wait.elapsedMicroseconds);
        }
        _perf.sample(GalleryMetric.activeJobs, _active);
        _perf.sample(GalleryMetric.pendingJobs, _pending.length);
      }
      unawaited(_runJob(job));
    }
    _updateAdmissionListener();
  }

  Future<void> _runJob(_PreviewJob<T> job) async {
    try {
      try {
        final value = await job.load(job.work);
        if (job.generation == _perf.generation) {
          if (job.work.cancelled) {
            if (value != null) _perf.increment(GalleryMetric.discarded);
          } else {
            _perf.increment(GalleryMetric.completed);
          }
        }
        if (!job.work.cancelled && value != null) {
          _retain(job.key, value, diagnostics: job.work.diagnostics);
        }
        job.result.complete(job.work.cancelled ? null : value);
      } catch (error, stack) {
        if (!job.work.cancelled && job.generation == _perf.generation) {
          _perf.increment(GalleryMetric.failed);
        }
        if (job.work.cancelled) {
          job.result.complete();
        } else {
          job.result.completeError(error, stack);
        }
      } finally {
        job.work.onCancel = null;
        if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
      }
    } finally {
      _active--;
      _perf.cacheWork(
        activeDelta: -1,
        carryoverFinished: job.generation != _perf.generation,
      );
      _perf.sample(GalleryMetric.activeJobs, _active);
      if (_pending.isNotEmpty) _pump();
    }
  }

  void _retain(String key, T value, {PreviewPerfScope? diagnostics}) {
    final bytes = sizeOf(value).clamp(0, maxBytes + 1);
    if (bytes > maxBytes) return;
    while (_values.isNotEmpty &&
        (_values.length >= maxEntries || _bytes + bytes > maxBytes)) {
      _bytes -= _values.remove(_values.keys.first)!.$2;
      (diagnostics ?? PreviewPerfScope(_perf)).increment(
        GalleryMetric.eviction,
      );
    }
    _values[key] = (value, bytes);
    _bytes += bytes;
  }
}

class _PreviewJob<T> {
  _PreviewJob(
    this.key,
    this.load,
    this.wait,
    this.generation,
    PreviewPerfScope diagnostics,
  ) : work = PreviewWork._(diagnostics);
  final String key;
  final Future<T?> Function(PreviewWork) load;
  final Stopwatch? wait;
  final int generation;
  final PreviewWork work;
  final result = Completer<T?>();
  int users = 0;
  int urgentUsers = 0;
  bool get urgent => urgentUsers > 0;
  bool started = false;
}
