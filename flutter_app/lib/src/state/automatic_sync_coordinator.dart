import 'dart:async';

import '../backend/app_backend.dart';
import '../rust/settings.dart';
import 'settings_controller.dart';
import 'sync_controller.dart';

class AutomaticSyncCoordinator {
  AutomaticSyncCoordinator(this._backend, this._settings, this._sync);

  final AppBackend _backend;
  final SettingsController _settings;
  final SyncController _sync;
  Timer? _timer;
  SyncState? _lastSyncState;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _lastSyncState = _sync.state;
    _settings.addListener(_settingsChanged);
    _sync.addListener(_syncChanged);
    await reschedule();
  }

  void _settingsChanged() => unawaited(reschedule());

  void _syncChanged() {
    final previous = _lastSyncState;
    final current = _sync.state;
    _lastSyncState = current;
    if (current == SyncState.running || current == SyncState.cancelling) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (previous == SyncState.running || previous == SyncState.cancelling) {
      unawaited(reschedule());
    }
  }

  Future<void> accountChanged() => reschedule();

  Future<void> reschedule() async {
    if (_disposed) return;
    final generation = ++_generation;
    _timer?.cancel();
    _timer = null;
    final policy = _settings.value.syncPolicy;
    if (!policy.enabled ||
        _sync.state == SyncState.running ||
        _sync.state == SyncState.cancelling ||
        !await _backend.isSignedIn) {
      return;
    }

    final SyncScheduleStatus? status = await _sync.refreshScheduleStatus();
    if (_disposed || generation != _generation) return;

    final now = DateTime.now().toUtc();
    final retryDelay = _sync.automaticRetryDelay;
    final due = retryDelay == null
        ? status?.nextSyncAt?.toUtc() ??
              now.add(Duration(minutes: policy.activeIntervalMinutes))
        : now.add(retryDelay);
    final delay = due.isAfter(now) ? due.difference(now) : Duration.zero;
    _timer = Timer(delay, () async {
      if (_disposed || generation != _generation) return;
      if (!_settings.value.syncPolicy.enabled || !await _backend.isSignedIn) {
        await reschedule();
        return;
      }
      await _sync.run();
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _settings.removeListener(_settingsChanged);
    _sync.removeListener(_syncChanged);
  }
}
