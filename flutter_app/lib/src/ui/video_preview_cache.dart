import 'dart:async';

class PreviewWork {
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
  }) : assert(maxEntries > 0),
       assert(maxBytes > 0);
  final int maxEntries, maxBytes;
  final int Function(T) sizeOf;
  final _values = <String, (T, int)>{};
  final _jobs = <String, _PreviewJob<T>>{};
  final _pending = <_PreviewJob<T>>[];
  int _bytes = 0;
  bool _running = false;

  T? peek(String key) => _values[key]?.$1;
  void seed(String key, T value) {
    if (!_values.containsKey(key) && !_jobs.containsKey(key)) {
      _retain(key, value);
    }
  }

  PreviewRequest<T> request(
    String key, {
    required Future<T?> Function(PreviewWork) load,
    bool urgent = false,
  }) {
    final hit = _values.remove(key);
    if (hit != null) {
      _values[key] = hit;
      return PreviewRequest(Future.value(hit.$1));
    }
    var job = _jobs[key];
    if (job == null) {
      if (_jobs.length >= maxEntries) {
        if (!urgent || _pending.isEmpty) {
          return PreviewRequest(Future.value(null));
        }
        _retire(_pending.last);
      }
      job = _PreviewJob(key, load);
      _jobs[key] = job;
      _pending.add(job);
    }
    job.users++;
    final owned = job;
    if (urgent && _pending.remove(owned)) _pending.insert(0, owned);
    if (!_running) unawaited(_drain());
    return PreviewRequest(owned.result.future, () {
      owned.users--;
      if (owned.users == 0 && !owned.result.isCompleted) _retire(owned);
    });
  }

  void _retire(_PreviewJob<T> job) {
    if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
    job.work._cancel();
    if (_pending.remove(job) && !job.result.isCompleted) job.result.complete();
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        final job = _pending.removeAt(0);
        try {
          final value = await job.load(job.work);
          if (!job.work.cancelled && value != null) _retain(job.key, value);
          job.result.complete(job.work.cancelled ? null : value);
        } catch (error, stack) {
          if (job.work.cancelled) {
            job.result.complete();
          } else {
            job.result.completeError(error, stack);
          }
        } finally {
          job.work.onCancel = null;
          if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
        }
      }
    } finally {
      _running = false;
    }
  }

  void _retain(String key, T value) {
    final bytes = sizeOf(value).clamp(0, maxBytes + 1);
    if (bytes > maxBytes) return;
    while (_values.isNotEmpty &&
        (_values.length >= maxEntries || _bytes + bytes > maxBytes)) {
      _bytes -= _values.remove(_values.keys.first)!.$2;
    }
    _values[key] = (value, bytes);
    _bytes += bytes;
  }
}

class _PreviewJob<T> {
  _PreviewJob(this.key, this.load);
  final String key;
  final Future<T?> Function(PreviewWork) load;
  final work = PreviewWork();
  final result = Completer<T?>();
  int users = 0;
}
