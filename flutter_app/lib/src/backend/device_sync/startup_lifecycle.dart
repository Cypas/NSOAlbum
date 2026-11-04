import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../rust/bridge.dart' as native;
import '../../rust/device_sync/read_model.dart' as read;
import '../../rust/device_sync/driver.dart' as driver;
import '../../rust/device_sync/connection.dart' show ApplicationBuild;
import '../../rust/device_sync/planner.dart' as plan;
import '../../rust/device_sync/runtime.dart' show DeviceCommandError;
import '../../rust/device_sync/usb.dart' show UsbCloseReason;
import '../../platform/device_sync_saf.dart';
import 'account_coordinator.dart';
import 'account_gate.dart';
import 'account_storage.dart' show AccountConsentRequired;
import 'command_admission.dart';
import 'service_contract.dart';
import 'usb_saf_owner.dart';
import 'lan_addresses.dart';

part 'controlled_service.dart';
part 'controlled_session.dart';
part 'controlled_progress.dart';
part 'controlled_usb.dart';
part 'controlled_backups.dart';
part 'benchmark_debug.dart';

enum DeviceStartupPhase {
  unchecked,
  checking,
  restoring,
  actionRequired,
  failed,
  ready,
  deferred,
  closing,
  closed,
}

/// Teardown reports its first failure only after every owned wait has run.
final class _DeviceCloseErrors {
  Object? failure;
  StackTrace? stack;
  void record(Object error, StackTrace trace) {
    failure ??= error;
    stack ??= trace;
  }

  Future<void> wait(FutureOr<void> Function() action) async {
    try {
      await action();
    } catch (error, trace) {
      record(error, trace);
    }
  }

  void rethrowFirst() {
    if (failure case final error?) {
      Error.throwWithStackTrace(error, stack!);
    }
  }
}

abstract interface class DeviceSyncStartupBackend {
  DeviceSyncStartupLifecycle get deviceSyncStartup;
  Future<void> close();
}

/// One backend owns this for its entire lifetime, independently of page routes.
/// Credentials, filesystem roots and native core objects stay behind the owner.
class DeviceSyncStartupLifecycle extends ChangeNotifier {
  DeviceSyncStartupLifecycle({
    required AccountWorkGate gate,
    required Future<String> Function() openLibrary,
    required DeviceAccountCoordinator Function(String) coordinator,
    required Future<void> Function() initialize,
    required this.isolated,
    this.onDiagnostic,
  }) : _gate = gate,
       // ignore: prefer_initializing_formals
       _openLibrary = openLibrary,
       _coordinatorFactory = coordinator,
       // ignore: prefer_initializing_formals
       _initialize = initialize {
    _barrier = gate.holdStartup();
  }

  final AccountWorkGate _gate;
  final Future<String> Function() _openLibrary;
  final DeviceAccountCoordinator Function(String) _coordinatorFactory;
  final Future<void> Function() _initialize;
  final bool isolated;
  final Future<void> Function(String stage, Object error)? onDiagnostic;

  void _diagnostic(String stage, Object failure) {
    final callback = onDiagnostic;
    if (callback != null) {
      unawaited(
        Future<void>.sync(() => callback(stage, failure))
            .catchError((Object _) {}),
      );
    }
  }

  AccountStartupBarrier? _barrier;
  String? _library;
  DeviceAccountCoordinator? _coordinator;
  Future<void>? _flight;
  Future<void>? _closing;
  DeviceSyncService? _service;
  bool _initialized = false;
  DeviceStartupPhase phase = DeviceStartupPhase.unchecked;
  AccountRecoveryState? recovery;
  Object? error;
  bool interruptedRecovery = false;
  bool get ready =>
      phase == DeviceStartupPhase.ready && !_gate.recoveryRequired;
  bool get deferred => phase == DeviceStartupPhase.deferred;
  bool get busy => _flight != null;
  bool get _closed =>
      phase == DeviceStartupPhase.closing || phase == DeviceStartupPhase.closed;

  DeviceSyncService get service {
    if (!ready || isolated || _closed) throw const DeviceSyncBusy();
    return _service ??= DeviceSyncService._(this);
  }

  void defer() {
    if (phase != DeviceStartupPhase.unchecked || isolated) {
      throw const DeviceSyncBusy();
    }
    phase = DeviceStartupPhase.deferred;
    notifyListeners();
  }

  Future<void> start() {
    if (_closed) return Future.error(const DeviceSyncBusy());
    if (phase == DeviceStartupPhase.ready && _gate.recoveryRequired) {
      _requireRecovery();
    }
    if (ready) return Future.value();
    final current = _flight;
    if (current != null) return current;
    final done = Completer<void>();
    late final Future<void> flight;
    flight = done.future.whenComplete(() {
      if (identical(_flight, flight)) {
        _flight = null;
        notifyListeners();
      }
    });
    _flight = flight;
    unawaited(_run().then(done.complete, onError: done.completeError));
    return flight;
  }

  Future<void> _run() async {
    error = null;
    interruptedRecovery = false;
    recovery = null;
    _set(DeviceStartupPhase.checking);
    if (_closed) return;
    try {
      await _service?._quiesceForRecovery();
      if (_closed) return;
      if (!isolated) {
        _library ??= await _openLibrary();
        if (_closed) return;
        _coordinator ??= _coordinatorFactory(_library!);
        final before = await native.deviceSyncLibraryInfo(library_: _library!);
        if (_closed) return;
        final interrupted = before.interruptedSessions ?? const <String>[];
        if (before.pendingOperation != null || interrupted.isNotEmpty) {
          interruptedRecovery = true;
          _set(DeviceStartupPhase.restoring);
        }
        if (_closed) return;
        void detectedRecovery() {
          interruptedRecovery = true;
          _set(DeviceStartupPhase.restoring);
        }

        var result = await _coordinator!.recoverStartup(
          onRecoveryDetected: detectedRecovery,
        );
        if (_closed) return;
        if (result.status == 'library_pending') {
          recovery = result;
          _set(DeviceStartupPhase.restoring);
          if (_closed) return;
          final operation = result.operation;
          if (operation == null) {
            throw AccountRecoveryRequired('journal_missing');
          }
          final journal = await native.deviceSyncJournal(
            library_: _library!,
            operation: operation,
          );
          if (_closed) return;
          if (journal == null || journal.external_ != null) {
            throw AccountRecoveryRequired('journal_mismatch');
          }
          await native.deviceSyncCompensate(
            library_: _library!,
            operation: operation,
          );
          if (_closed) return;
          result = await _coordinator!.recoverStartup(
            onRecoveryDetected: detectedRecovery,
          );
          if (_closed) return;
        }
        recovery = result;
        if (!result.ready) {
          _set(DeviceStartupPhase.actionRequired);
          return;
        }
        if (interrupted.isNotEmpty) {
          await native.deviceSyncRecoverInterruptedSessions(
            library_: _library!,
            sessions: interrupted,
          );
          if (_closed) return;
        }
      }
      if (!_initialized) {
        await _initialize();
        _initialized = true;
      }
      if (_closed) return;
      _barrier?.release();
      _barrier = null;
      _set(DeviceStartupPhase.ready);
    } catch (failure) {
      error = failure;
      if (!_closed) _set(DeviceStartupPhase.failed);
    }
  }

  void _requireRecovery([Object? failure]) {
    if (_closed) return;
    phase = DeviceStartupPhase.actionRequired;
    error = failure;
    recovery = AccountRecoveryState(
      failure is AccountRecoveryRequired
          ? failure.code
          : 'protected_storage_unavailable',
    );
    _barrier ??= _gate.holdStartup();
    notifyListeners();
  }

  void _set(DeviceStartupPhase value) {
    if (_closed) return;
    phase = value;
    notifyListeners();
  }

  Future<void> close() {
    final existing = _closing;
    if (existing != null) return existing;
    if (phase == DeviceStartupPhase.closed) return Future.value();
    final done = Completer<void>();
    late final Future<void> flight;
    flight = done.future.whenComplete(() {
      if (identical(_closing, flight)) _closing = null;
    });
    _closing = flight;
    _barrier ??= _gate.holdStartup();
    phase = DeviceStartupPhase.closing;
    notifyListeners();
    unawaited(
      () async {
        final errors = _DeviceCloseErrors();
        await errors.wait(() async => await _flight);
        await errors.wait(() async => await _service?._close());
        // Endpoint retirement can be taken over by the native library sweep.
        // Restore previews live in a different registry and must retire first.
        if (_service?._workDrained ?? true) {
          await errors.wait(
            () async => await _coordinator?.closeRestorePreviews(),
          );
        }
        final library = _library;
        if ((_service?._workDrained ?? true) &&
            (_coordinator?.restorePreviewsSettled ?? true)) {
          var retired = library == null;
          if (library != null) {
            await errors.wait(() async {
              await native.deviceSyncCloseLibrary(library_: library);
              retired = true;
            });
          }
          if (retired) {
            phase = DeviceStartupPhase.closed;
            notifyListeners();
          }
        }
        errors.rethrowFirst();
        if (phase != DeviceStartupPhase.closed) throw const DeviceSyncBusy();
      }().then(done.complete, onError: done.completeError),
    );
    return flight;
  }
}
