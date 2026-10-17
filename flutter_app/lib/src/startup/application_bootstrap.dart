import 'dart:async';

import 'package:flutter/foundation.dart';

import '../backend/app_backend.dart';
import '../backend/device_sync/startup_lifecycle.dart';

enum BootstrapPhase {
  unchecked,
  preparing,
  timedOut,
  recovering,
  localOnly,
  ready,
  failed,
  closing,
  closed,
}

/// Owns every prepare/recovery future until it settles. The preparation deadline
/// changes feedback only; it never abandons a native or protected-storage write.
class ApplicationBootstrap extends ChangeNotifier {
  ApplicationBootstrap({
    required this.prepare,
    required this.initializePresentation,
    required this.safeMode,
    this.preparationLimit = const Duration(seconds: 30),
  });
  final Future<AppBackend> Function() prepare;
  final Future<void> Function(AppBackend) initializePresentation;
  final bool safeMode;
  final Duration preparationLimit;
  BootstrapPhase phase = BootstrapPhase.unchecked;
  AppBackend? backend;
  Object? error;
  Object? closeError;
  Future<void>? _flight;
  Future<void>? _close;
  bool _presentationInitialized = false;
  bool _resumeRequested = false;
  bool get busy => _flight != null;
  bool get _closed =>
      phase == BootstrapPhase.closing || phase == BootstrapPhase.closed;
  DeviceSyncStartupLifecycle? get startup => backend is DeviceSyncStartupBackend
      ? (backend as DeviceSyncStartupBackend).deviceSyncStartup
      : null;

  Future<void> start() {
    if (_closed) return Future.value();
    if (phase == BootstrapPhase.ready) return Future.value();
    final current = _flight;
    if (current != null) return current;
    final done = Completer<void>();
    _flight = done.future;
    unawaited(
      _run().then(
        (_) {
          _flight = null;
          if (!_closed) notifyListeners();
          done.complete();
        },
        onError: (Object failure, StackTrace stack) {
          _flight = null;
          done.completeError(failure, stack);
        },
      ),
    );
    return done.future;
  }

  Future<void> resumeRecovery() {
    if (busy || _closed) return _flight ?? Future.value();
    _resumeRequested = true;
    return start();
  }

  Future<void> _run() async {
    error = null;
    try {
      if (backend == null) {
        _set(BootstrapPhase.preparing);
        if (_closed) return;
        var timedOut = false;
        final deadline = Timer(preparationLimit, () {
          if (_closed) return;
          timedOut = true;
          error = TimeoutException('Core preparation did not finish in time');
          _set(BootstrapPhase.timedOut);
        });
        AppBackend prepared;
        try {
          prepared = await prepare();
        } finally {
          deadline.cancel();
        }
        backend = prepared;
        startup?.addListener(_changed);
        if (_closed) {
          // close() owns the late result after waiting for this factory flight.
          // Do not spend a second retirement attempt within the same exit.
          return;
        }
        if (timedOut) {
          if (prepared case final DeviceSyncStartupBackend owner) {
            await owner.close();
          }
          if (timedOut && !_closed) {
            startup?.removeListener(_changed);
            backend = null;
          }
          return;
        }
      }
      if (_closed) return;
      final recovery = startup;
      if (safeMode && !_resumeRequested && recovery != null) {
        recovery.defer();
        _set(BootstrapPhase.localOnly);
        return;
      }
      _set(BootstrapPhase.recovering);
      if (_closed) return;
      if (recovery != null) {
        await recovery.start();
        if (_closed) return;
        if (!recovery.ready) {
          error = recovery.error ?? recovery.recovery;
          _set(BootstrapPhase.failed);
          return;
        }
      }
      if (!_presentationInitialized) {
        await initializePresentation(backend!);
        if (_closed) return;
        _presentationInitialized = true;
      }
      _set(BootstrapPhase.ready);
    } catch (failure) {
      error = failure;
      if (!_closed && phase != BootstrapPhase.timedOut) {
        _set(BootstrapPhase.failed);
      }
    }
  }

  void _changed() {
    if (!_closed) notifyListeners();
  }

  void _set(BootstrapPhase value) {
    if (_closed) return;
    phase = value;
    notifyListeners();
  }

  void reportCloseFailure(Object failure) {
    closeError = failure;
    notifyListeners();
  }

  Future<void> close() {
    final closing = _close;
    if (closing != null) return closing;
    if (phase == BootstrapPhase.closed) return Future.value();
    final done = Completer<void>();
    late final Future<void> flight;
    flight = done.future.whenComplete(() {
      if (identical(_close, flight)) _close = null;
    });
    _close = flight;
    phase = BootstrapPhase.closing;
    notifyListeners();
    startup?.removeListener(_changed);
    final owner = backend;
    unawaited(
      () async {
        Object? first;
        StackTrace? firstStack;
        Future<void> wait(FutureOr<void> Function() action) async {
          try {
            await action();
          } catch (failure, stack) {
            first ??= failure;
            firstStack ??= stack;
          }
        }

        await wait(() async {
          if (owner is DeviceSyncStartupBackend) {
            await (owner as DeviceSyncStartupBackend).close();
          }
        });
        // A failed stopper does not abandon preparation/presentation already
        // accepted by this owner, including a late factory result.
        await wait(() async => await _flight);
        startup?.removeListener(_changed);
        if (!identical(owner, backend) && backend is DeviceSyncStartupBackend) {
          await wait(() => (backend as DeviceSyncStartupBackend).close());
        }
        if (first == null) {
          phase = BootstrapPhase.closed;
          notifyListeners();
        } else {
          reportCloseFailure(first!);
          Error.throwWithStackTrace(first!, firstStack!);
        }
      }().then(done.complete, onError: done.completeError),
    );
    return flight;
  }
}
