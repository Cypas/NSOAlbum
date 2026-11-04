import 'dart:async';

class VideoViewerLifecycle {
  VideoViewerLifecycle({
    required bool initiallyActive,
    required this._pause,
    required this._play,
    required this.disposePlayer,
  }) : _active = initiallyActive;

  final Future<void> Function() _pause;
  final Future<void> Function() _play;
  final Future<void> Function() disposePlayer;
  bool _active;
  bool disposed = false;
  Future<void>? _disposing;
  Future<void> _commands = Future<void>.value();
  Completer<void>? _warming;
  int _activityGeneration = 0;

  Future<void> _enqueue(Future<void> Function() action) {
    final command = _commands.then((_) => action());
    // A failed player command must not prevent a later pause or disposal.
    _commands = command.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return command;
  }

  void _interruptWarm() {
    final warming = _warming;
    if (warming != null && !warming.isCompleted) warming.complete();
  }

  Future<void> runCommand(Future<void> Function() action) {
    if (disposed || !_active) return Future<void>.value();
    final generation = _activityGeneration;
    return _enqueue(() async {
      if (!disposed && _active && generation == _activityGeneration) {
        await action();
      }
    });
  }

  Future<void> play() => runCommand(_play);

  Future<void> prewarm(Future<void> Function(Future<void> interrupted) warm) {
    if (disposed || _active || _warming != null) {
      return Future<void>.value();
    }
    final interrupted = Completer<void>();
    final generation = _activityGeneration;
    _warming = interrupted;
    return _enqueue(() async {
      try {
        if (!disposed && !_active && generation == _activityGeneration) {
          await warm(interrupted.future);
        }
      } finally {
        if (identical(_warming, interrupted)) _warming = null;
        if (!disposed) await _pause();
      }
    });
  }

  Future<void> pause() {
    if (disposed) return Future<void>.value();
    return _enqueue(() async {
      if (!disposed) await _pause();
    });
  }

  Future<void> updateActive(bool active, {required bool autoPlay}) {
    if (disposed || _active == active) return Future<void>.value();
    _interruptWarm();
    final generation = ++_activityGeneration;
    _active = active;
    return _enqueue(() async {
      if (disposed) return;
      if (!active) {
        await _pause();
        return;
      }
      if (generation != _activityGeneration || _active != active) return;
      if (autoPlay) await _play();
    });
  }

  Future<void> dispose() {
    if (_disposing != null) return _disposing!;
    disposed = true;
    _activityGeneration++;
    _interruptWarm();
    return _disposing = _enqueue(() async {
      try {
        await _pause();
      } finally {
        await disposePlayer();
      }
    });
  }
}
