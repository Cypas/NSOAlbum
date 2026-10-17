import 'dart:async';

import '../backend/app_backend.dart';
import '../backend/device_sync/account_gate.dart';
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
  DateTime? _deadline;
  DateTime? _pausedDeadline;
  AccountWorkGate? get _accountGate => _backend is AccountWorkBackend
      ? (_backend as AccountWorkBackend).accountWorkGate
      : null;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _lastSyncState = _sync.state;
    _settings.addListener(_settingsChanged);
    _sync.addListener(_syncChanged);
    _accountGate?.addListener(_accountGateChanged);
    await reschedule();
  }

  void _accountGateChanged() {
    if (_disposed) return;
    // Revoke callbacks synchronously, before the caller begins secure reads.
    _generation++;
    _timer?.cancel();
    _timer = null;
    if (_accountGate?.busy == true) {
      _pausedDeadline ??= _deadline;
    } else {
      unawaited(reschedule());
    }
  }

  void _settingsChanged() => unawaited(_applySettingsChange());

  Future<void> _applySettingsChange() async {
    if (!_settings.value.syncPolicy.enabled &&
        _sync.automaticRun &&
        _sync.running) {
      await _sync.cancel(suppressAutomaticRelaunch: false);
    }
    await reschedule();
  }

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
      final suppressed = _sync.consumeAutomaticRelaunchSuppression();
      unawaited(
        reschedule(
          notBefore: suppressed
              ? Duration(
                  minutes: _settings.value.syncPolicy.activeIntervalMinutes,
                )
              : null,
        ),
      );
    }
  }

  Future<void> accountChanged() => reschedule();

  Future<void> reschedule({Duration? notBefore}) async {
    try {
      await _reschedule(notBefore: notBefore);
    } on DeviceSyncBusy {
      // Admission is retried by the gate transition, never as an auth failure.
    }
  }

  Future<void> _reschedule({Duration? notBefore}) async {
    if (_disposed) return;
    final generation = ++_generation;
    _timer?.cancel();
    _timer = null;
    if (_accountGate?.busy == true) return;
    final policy = _settings.value.syncPolicy;
    if (!policy.enabled ||
        _sync.running ||
        _sync.hasPendingAuthenticatedAccounts ||
        !await _backend.isSignedIn) {
      return;
    }
    if (_disposed || generation != _generation) return;

    if (_sync.allAccounts && _backend is AccountSyncBackend) {
      await _scheduleAccounts(generation, policy, notBefore: notBefore);
      return;
    }

    if (_backend case final AccountScheduleAdmissionBackend admission) {
      final selected = await _backend.selectedNintendoAccountId;
      if (_disposed || generation != _generation) return;
      if (selected == null ||
          !await admission.automaticAccountHasLocalHistory(selected)) {
        _pausedDeadline = null;
        return;
      }
    }

    final SyncScheduleStatus? status = await _sync.refreshScheduleStatus();
    if (_disposed || generation != _generation) return;
    final now = DateTime.now().toUtc();
    final retryDelay = _sync.automaticRetryDelay;
    var due =
        _pausedDeadline ??
        (retryDelay == null
            ? status?.nextSyncAt?.toUtc() ??
                  now.add(Duration(minutes: policy.activeIntervalMinutes))
            : now.add(retryDelay));
    if (notBefore != null) {
      final floor = now.add(notBefore);
      if (due.isBefore(floor)) due = floor;
    }
    _deadline = due;
    _pausedDeadline = null;
    _timer = Timer(_delayUntil(due, now), () => _runLegacy(generation));
  }

  Future<void> _scheduleAccounts(
    int generation,
    SyncPolicy policy, {
    Duration? notBefore,
  }) async {
    await _sync.refreshAccountScheduleStatuses();
    if (_disposed || generation != _generation) return;
    final now = DateTime.now().toUtc();
    final dueIds = await _sync.dueAccountIds(now: now);
    if (_disposed || generation != _generation) return;
    if (dueIds.isEmpty &&
        _sync.nextAccountSyncAt == null &&
        _backend is AccountScheduleAdmissionBackend) {
      _pausedDeadline = null;
      return;
    }
    var due =
        _pausedDeadline ??
        (dueIds.isNotEmpty
            ? now
            : _sync.nextAccountSyncAt ??
                  now.add(Duration(minutes: policy.activeIntervalMinutes)));
    if (notBefore != null) {
      final floor = now.add(notBefore);
      if (due.isBefore(floor)) due = floor;
    }
    _deadline = due;
    _pausedDeadline = null;
    _timer = Timer(_delayUntil(due, now), () => _runAccounts(generation));
  }

  Duration _delayUntil(DateTime due, DateTime now) =>
      due.isAfter(now) ? due.difference(now) : Duration.zero;

  Future<void> _runLegacy(int generation) async {
    if (!await _canRun(generation)) return;
    await _sync.run(automatic: true);
  }

  Future<void> _runAccounts(int generation) async {
    try {
      if (!await _canRun(generation)) return;
      final dueIds = await _sync.dueAccountIds();
      if (_disposed || generation != _generation || dueIds.isEmpty) {
        await reschedule();
        return;
      }
      await _sync.run(automatic: true, accountIds: dueIds);
    } on DeviceSyncBusy {
      // No visible result or persisted schedule belongs to a rejected attempt.
    }
  }

  Future<bool> _canRun(int generation) async {
    if (_disposed || generation != _generation || _accountGate?.busy == true) {
      return false;
    }
    try {
      if (!_settings.value.syncPolicy.enabled || !await _backend.isSignedIn) {
        await reschedule();
        return false;
      }
    } on DeviceSyncBusy {
      return false;
    }
    return !_disposed && generation == _generation;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _settings.removeListener(_settingsChanged);
    _sync.removeListener(_syncChanged);
    _accountGate?.removeListener(_accountGateChanged);
  }
}
