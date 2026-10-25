import 'dart:async';

import '../backend/app_backend.dart';
import '../backend/device_sync/account_gate.dart';
import '../rust/settings.dart';
import 'settings_controller.dart';
import 'sync_controller.dart';

class AutomaticSyncCoordinator {
  AutomaticSyncCoordinator(
    this._backend,
    this._settings,
    this._sync, {
    DateTime Function()? now,
    this.startupDelay = Duration.zero,
  }) : _now = now ?? DateTime.now;

  final AppBackend _backend;
  final SettingsController _settings;
  final SyncController _sync;
  final DateTime Function() _now;
  final Duration startupDelay;
  Timer? _timer;
  Timer? _startupDelayTimer;
  Completer<void>? _startupDelayCompleter;
  SyncState? _lastSyncState;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;
  DateTime? _deadline;
  DateTime? _pausedDeadline;
  bool _transferWasActive = false;
  DateTime? _lastTransferEnd;
  final _slots = <String, _ScheduledSlot>{};
  final _skipFloors = <String, DateTime>{};
  AccountWorkGate? get _accountGate => _backend is AccountWorkBackend
      ? (_backend as AccountWorkBackend).accountWorkGate
      : null;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    if (startupDelay > Duration.zero) {
      final delay = Completer<void>();
      _startupDelayCompleter = delay;
      _startupDelayTimer = Timer(startupDelay, () {
        if (!delay.isCompleted) delay.complete();
      });
      await delay.future;
      _startupDelayTimer = null;
      _startupDelayCompleter = null;
      if (_disposed) return;
    }
    _transferWasActive = _accountGate?.transferActive == true;
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
    final transferring = _accountGate?.transferActive == true;
    if (transferring) {
      _transferWasActive = true;
      _pausedDeadline = null;
    } else if (_transferWasActive) {
      _transferWasActive = false;
      final now = _now().toUtc();
      _lastTransferEnd = now;
      for (final entry in _slots.entries) {
        final slot = entry.value;
        if (!slot.due.isAfter(now)) {
          final normalDue = slot.rateLimitedAt?.add(slot.interval) ?? slot.due;
          slot.due = normalDue.isAfter(now)
              ? normalDue
              : _nextSlot(normalDue, slot.interval, now);
          _skipFloors[entry.key] = slot.due;
        }
      }
      _pausedDeadline = null;
    }
    if (_accountGate?.busy == true) {
      final due = _deadline;
      final cutoff = _lastTransferEnd;
      // A longer-lived startup/recovery barrier must not resurrect a slot
      // that the just-finished transfer has already skipped.
      if (!transferring &&
          due != null &&
          (cutoff == null || due.isAfter(cutoff))) {
        _pausedDeadline ??= due;
      }
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

    final selected = await _backend.selectedNintendoAccountId;
    if (_disposed || generation != _generation) return;
    if (_backend case final AccountScheduleAdmissionBackend admission) {
      if (_disposed || generation != _generation) return;
      if (selected == null ||
          !await admission.automaticAccountHasLocalHistory(selected)) {
        _pausedDeadline = null;
        return;
      }
    }

    final SyncScheduleStatus? status = await _sync.refreshScheduleStatus();
    if (_disposed || generation != _generation) return;
    final now = _now().toUtc();
    final retryDelay = _sync.automaticRetryDelay;
    final key = selected ?? '';
    final retryDue = retryDelay == null || _skipFloors.containsKey(key)
        ? status?.nextSyncAt?.toUtc() ??
              now.add(Duration(minutes: policy.activeIntervalMinutes))
        : now.add(retryDelay);
    final scheduled = await _rememberSlot(
      key,
      status,
      now,
      generation,
      fallbackDue: retryDue,
    );
    if (_disposed || generation != _generation) return;
    var due = _pausedDeadline ?? scheduled;
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
    final now = _now().toUtc();
    final known = _sync.accountSchedules;
    _slots.removeWhere((id, _) => !known.containsKey(id));
    _skipFloors.removeWhere((id, _) => !known.containsKey(id));
    DateTime? earliest;
    for (final entry in known.entries.toList()) {
      if (_sync.authPausedAccountIds.contains(entry.key) ||
          entry.value?.nextSyncAt == null) {
        _slots.remove(entry.key);
        _skipFloors.remove(entry.key);
        continue;
      }
      final due = await _rememberSlot(entry.key, entry.value, now, generation);
      if (_disposed || generation != _generation) return;
      if (earliest == null || due.isBefore(earliest)) earliest = due;
    }
    if (earliest == null && _backend is AccountScheduleAdmissionBackend) {
      _pausedDeadline = null;
      return;
    }
    var due =
        _pausedDeadline ??
        earliest ??
        now.add(Duration(minutes: policy.activeIntervalMinutes));
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

  Future<DateTime> _rememberSlot(
    String id,
    SyncScheduleStatus? status,
    DateTime now,
    int generation, {
    DateTime? fallbackDue,
  }) async {
    final interval = Duration(
      minutes:
          status?.intervalMinutes ??
          (status?.sleeping == true
              ? 1440
              : _settings.value.syncPolicy.activeIntervalMinutes),
    );
    var due = fallbackDue ?? status?.nextSyncAt?.toUtc() ?? now.add(interval);
    final previous = _slots[id];
    if (previous != null &&
        previous.lastSuccess != status?.lastSuccessfulSyncAt) {
      _skipFloors.remove(id);
    }
    // A task may start before the first async schedule read has completed.
    // Recover its unclamped anchor from existing local history, never by
    // writing a synthetic attempt or calling Nintendo.
    final cutoff = _lastTransferEnd;
    SyncRuntimeState? history;
    if (_backend case final SyncHistoryBackend histories) {
      try {
        history = await histories.loadSyncAccountHistory(id);
      } on DeviceSyncBusy {
        rethrow;
      } catch (error, stackTrace) {
        // History refines a retry anchor; it is not permission to discard
        // already captured deadlines or leave an unhandled timer future.
        await _backend.logError(
          '[sync] trigger=automatic stage=local_schedule_history_read_failed',
          error,
          stackTrace,
        );
      }
      if (_disposed ||
          generation != _generation ||
          _accountGate?.busy == true) {
        throw const DeviceSyncBusy();
      }
    }
    final attempt = history?.latestAttempt;
    final rateLimitedAt = attempt != null && attempt.status == 'rate_limited'
        ? attempt.attemptedAt.toUtc()
        : null;
    if (previous == null && cutoff != null) {
      final anchor =
          attempt != null &&
              (attempt.status == 'failure' ||
                  attempt.status == 'cancelled' ||
                  attempt.status == 'rate_limited')
          ? attempt.attemptedAt.toUtc()
          : history?.lastSuccessfulSyncAt?.toUtc();
      if (anchor != null) {
        due = anchor.add(
          attempt?.status == 'rate_limited'
              ? const Duration(minutes: 1)
              : interval,
        );
      }
      if (!due.isAfter(cutoff)) {
        final normalDue = rateLimitedAt?.add(interval) ?? due;
        _skipFloors[id] = normalDue.isAfter(cutoff)
            ? normalDue
            : _nextSlot(normalDue, interval, cutoff);
      }
    }
    final floor = _skipFloors[id];
    if (floor != null && due.isBefore(floor)) due = floor;
    _slots[id] = _ScheduledSlot(
      due,
      interval,
      status?.lastSuccessfulSyncAt,
      rateLimitedAt,
    );
    return due;
  }

  DateTime _nextSlot(DateTime due, Duration interval, DateTime cutoff) {
    final missed =
        cutoff.difference(due).inMicroseconds ~/ interval.inMicroseconds + 1;
    return due.add(Duration(microseconds: interval.inMicroseconds * missed));
  }

  Future<void> _runLegacy(int generation) async {
    if (!await _canRun(generation)) return;
    _slots.clear();
    _skipFloors.clear();
    _lastTransferEnd = null;
    await _sync.run(automatic: true);
  }

  Future<void> _runAccounts(int generation) async {
    try {
      if (!await _canRun(generation)) return;
      final dueIds = await _sync.dueAccountIds(now: _now());
      if (_disposed || generation != _generation || dueIds.isEmpty) {
        await reschedule();
        return;
      }
      final now = _now().toUtc();
      final admitted = dueIds
          .where((id) => _skipFloors[id]?.isAfter(now) != true)
          .toList();
      if (admitted.isEmpty) {
        await reschedule();
        return;
      }
      if (generation != _generation || _accountGate?.busy == true) return;
      for (final id in admitted) {
        _slots.remove(id);
        _skipFloors.remove(id);
      }
      // Existing accounts keep their independent floors; a completed run
      // obtains a new local schedule, not another transfer-skip decision.
      _lastTransferEnd = null;
      await _sync.run(automatic: true, accountIds: admitted);
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
    return !_disposed &&
        generation == _generation &&
        _accountGate?.busy != true;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _startupDelayTimer?.cancel();
    _startupDelayTimer = null;
    final startupDelay = _startupDelayCompleter;
    _startupDelayCompleter = null;
    if (startupDelay != null && !startupDelay.isCompleted) {
      startupDelay.complete();
    }
    _settings.removeListener(_settingsChanged);
    _sync.removeListener(_syncChanged);
    _accountGate?.removeListener(_accountGateChanged);
  }
}

class _ScheduledSlot {
  _ScheduledSlot(this.due, this.interval, this.lastSuccess, this.rateLimitedAt);
  DateTime due;
  final Duration interval;
  final DateTime? lastSuccess;
  final DateTime? rateLimitedAt;
}
