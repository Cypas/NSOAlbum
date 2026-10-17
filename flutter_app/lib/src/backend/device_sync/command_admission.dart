import '../../rust/device_sync/runtime.dart';
import '../../rust/device_sync/read_model.dart';
import 'account_gate.dart';

class DeviceCommandBusy extends DeviceSyncBusy {
  const DeviceCommandBusy();
}

Future<T> admittedDeviceCommand<T>(
  Future<T> Function() command, {
  bool Function()? cancelled,
}) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (cancelled?.call() ?? false) throw const DeviceCommandBusy();
    try {
      return await command();
    } on DeviceCommandError catch (error) {
      if (error.executed || error.code != ReadError.busy) rethrow;
      if (attempt == 39) throw const DeviceCommandBusy();
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
  throw const DeviceCommandBusy();
}

/// A typed Busy projection contains no state. Retry only that read, never its
/// consumer's command or a binding calculation, and retain the last shown data.
Future<T> readDeviceProjection<T>(
  Future<T> Function() observe, {
  required ReadError? Function(T) errorOf,
  required bool Function() cancelled,
}) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (cancelled()) throw const DeviceCommandBusy();
    final value = await observe();
    if (cancelled()) throw const DeviceCommandBusy();
    if (errorOf(value) != ReadError.busy) return value;
    if (attempt < 39) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
  throw const DeviceCommandBusy();
}

/// A suspended, known-unexecuted command resumes without replaying completed OS
/// writes or Rust permission steps. Crash recovery still uses the real journal.
class DeviceCommandSequence {
  int _next = 0;
  int _attempts = 0;

  Future<void> run(List<Future<void> Function()> actions) async {
    if (_attempts >= 3) throw const DeviceCommandBusy();
    _attempts++;
    while (_next < actions.length) {
      await actions[_next]();
      _next++;
    }
  }
}
