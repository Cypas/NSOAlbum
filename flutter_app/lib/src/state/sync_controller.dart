import 'dart:async';

import 'package:flutter/foundation.dart';

import '../backend/app_backend.dart';
import '../backend/device_sync/account_gate.dart';
import '../backend/sync_failure_status.dart';
import '../rust/models.dart';
import '../rust/settings.dart';

enum SyncState { idle, running, completed, failed, cancelling, cancelled }

Duration? automaticSyncRetryDelayForError(Object error) =>
    syncFailureStatus(error) == 'rate_limited'
    ? const Duration(minutes: 1)
    : null;

class SyncController extends ChangeNotifier {
  SyncController(
    this._backend, {
    this.allAccounts = false,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AppBackend _backend;
  final DateTime Function() _now;
  final bool allAccounts;
  SyncState state = SyncState.idle;
  SyncSummary? summary;
  SyncProgress? progress;
  Object? error;
  SyncScheduleStatus? scheduleStatus;
  Duration? automaticRetryDelay;
  String? currentAccountId;
  int completedAccounts = 0;
  int totalAccounts = 0;
  final Map<String, SyncSummary> accountResults = {};
  final Map<String, Object> accountErrors = {};
  final Map<String, DateTime> accountAttemptedAt = {};
  final Map<String, SyncScheduleStatus?> accountSchedules = {};
  final Set<String> authPausedAccountIds = {};
  final Set<String> _pendingAuthenticatedAccountIds = {};
  final Set<String> _authenticationOverrides = {};
  bool automaticRun = false;
  bool suppressAutomaticRelaunch = false;
  bool _cancelRequested = false;
  bool _polling = false;
  bool _progressRequestPending = false;
  bool _disposed = false;
  Timer? _progressTimer;
  Timer? _cancellationTimer;
  bool _cancellationRequestPending = false;
  bool _drainingAuthenticatedAccounts = false;

  bool get running =>
      state == SyncState.running || state == SyncState.cancelling;
  bool get hasPendingAuthenticatedAccounts =>
      _pendingAuthenticatedAccountIds.isNotEmpty;

  Future<void> run({bool automatic = false, List<String>? accountIds}) async {
    if (running || _disposed) return;
    AccountWorkPermit? permit;
    if (_backend case final AccountWorkBackend backend) {
      try {
        permit = backend.accountWorkGate.normalPermit();
      } on DeviceSyncBusy {
        return;
      }
    }
    try {
      if (permit != null) {
        await permit.run(
          () => _runAdmitted(automatic: automatic, accountIds: accountIds),
        );
      } else {
        await _runAdmitted(automatic: automatic, accountIds: accountIds);
      }
    } finally {
      permit?.release();
    }
  }

  Future<void> _runAdmitted({
    required bool automatic,
    List<String>? accountIds,
  }) async {
    automaticRun = automatic;
    suppressAutomaticRelaunch = false;
    _cancelRequested = false;
    automaticRetryDelay = null;
    state = SyncState.running;
    summary = null;
    progress = null;
    error = null;
    currentAccountId = null;
    completedAccounts = 0;
    totalAccounts = 0;
    _notify();
    _startPolling();
    try {
      if (allAccounts && _backend is AccountSyncBackend) {
        await _runAccountQueue(automatic: automatic, accountIds: accountIds);
      } else {
        await _runLegacySync();
        if (summary != null) {
          await _notifySyncCompletion([summary!]);
        }
      }
    } catch (exception, stackTrace) {
      if (_disposed) return;
      if (_cancelRequested || syncFailureStatus(exception) == 'cancelled') {
        state = SyncState.cancelled;
      } else {
        error = exception;
        automaticRetryDelay = automaticSyncRetryDelayForError(exception);
        state = SyncState.failed;
        await _backend.logError(
          '[sync] trigger=${automatic ? 'automatic' : 'manual'} stage=queue_failed',
          exception,
          stackTrace,
        );
      }
    } finally {
      _stopPolling();
      _stopCancellationDelivery();
      currentAccountId = null;
      automaticRun = false;
      if (_cancelRequested && state != SyncState.cancelled) {
        state = SyncState.cancelled;
      }
      if (state == SyncState.cancelled) {
        _authenticationOverrides.removeAll(_pendingAuthenticatedAccountIds);
        _pendingAuthenticatedAccountIds.clear();
      }
      _notify();
    }
    if (!_disposed && state != SyncState.cancelled) {
      await _drainAuthenticatedAccounts();
    }
  }

  Future<void> _runLegacySync() async {
    final result = await _backend.syncNintendoAlbum();
    if (_cancelRequested || _disposed) return;
    summary = result;
    if (_backend case final SyncScheduleBackend backend) {
      try {
        scheduleStatus = await backend.recordSyncOutcome(
          foundNewMedia: result.downloaded > BigInt.zero,
        );
      } catch (exception, stackTrace) {
        await _backend.logError(
          'Failed to persist Nintendo sync schedule state',
          exception,
          stackTrace,
        );
      }
    }
    progress = _completedProgress(result);
    state = SyncState.completed;
  }

  Future<void> _runAccountQueue({
    required bool automatic,
    required List<String>? accountIds,
  }) async {
    final backend = _backend as AccountSyncBackend;
    final profiles = await _backend.listNintendoAccounts();
    if (_cancelRequested || _disposed) return;
    final available = profiles.map((profile) => profile.accountId).toSet();
    accountSchedules.removeWhere((id, _) => !available.contains(id));
    var queue = accountIds == null
        ? profiles.map((profile) => profile.accountId).toList()
        : accountIds.where(available.contains).toSet().toList();
    await refreshAccountScheduleStatuses(accountIds: queue);
    if (_cancelRequested || _disposed) return;
    queue = queue
        .where(
          (id) =>
              !authPausedAccountIds.contains(id) ||
              _authenticationOverrides.contains(id),
        )
        .toList();
    if (automatic) {
      final now = _now().toUtc();
      queue = queue.where((id) {
        if (authPausedAccountIds.contains(id)) return false;
        final due = accountSchedules[id]?.nextSyncAt?.toUtc();
        return due != null && !due.isAfter(now);
      }).toList();
    }
    totalAccounts = queue.length;
    _notify();
    for (final accountId in queue) {
      if (_cancelRequested || _disposed) break;
      accountResults.remove(accountId);
      accountErrors.remove(accountId);
      _authenticationOverrides.remove(accountId);
      currentAccountId = accountId;
      accountAttemptedAt[accountId] = _now();
      progress = null;
      _notify();
      try {
        final result = await backend.syncNintendoAccount(accountId);
        if (_cancelRequested || _disposed) break;
        accountResults[accountId] = result;
        accountErrors.remove(accountId);
        authPausedAccountIds.remove(accountId);
        summary = _combinedAccountResults(queue);
        progress = _completedProgress(result);
        try {
          accountSchedules[accountId] = await backend.recordAccountSyncOutcome(
            accountId,
            foundNewMedia: result.downloaded > BigInt.zero,
          );
        } catch (exception, stackTrace) {
          await _backend.logError(
            'Failed to persist Nintendo account sync schedule state',
            exception,
            stackTrace,
          );
        }
        completedAccounts += 1;
      } catch (exception, stackTrace) {
        if (_disposed) break;
        if (_cancelRequested || syncFailureStatus(exception) == 'cancelled') {
          _cancelRequested = true;
          break;
        }
        accountErrors[accountId] = exception;
        error ??= exception;
        final failure = syncFailureStatus(exception);
        if (failure == 'authentication_failure') {
          authPausedAccountIds.add(accountId);
        } else if (failure == 'rate_limited') {
          automaticRetryDelay = const Duration(minutes: 1);
        }
        try {
          accountSchedules[accountId] = await backend.loadAccountSyncSchedule(
            accountId,
          );
        } catch (_) {
          // The account error remains the useful result for this queue item.
        }
        completedAccounts += 1;
        await _backend.logError(
          '[sync] trigger=${automatic ? 'automatic' : 'manual'} account_slot=${queue.indexOf(accountId) + 1} stage=account_failed',
          exception,
          stackTrace,
        );
      }
      _notify();
    }
    summary = _combinedAccountResults(queue);
    state = _cancelRequested ? SyncState.cancelled : SyncState.completed;
    await _notifySyncCompletion(
      queue
          .map((id) => accountResults[id])
          .whereType<SyncSummary>()
          .toList(growable: false),
      failedAccountCount: queue.where(accountErrors.containsKey).length,
    );
  }

  SyncSummary? _combinedAccountResults(Iterable<String> accountIds) {
    final results = accountIds
        .map((id) => accountResults[id])
        .whereType<SyncSummary>()
        .toList(growable: false);
    if (results.isEmpty) return null;
    return SyncSummary(
      jobId: results.last.jobId,
      totalFound: results.fold(
        BigInt.zero,
        (total, value) => total + value.totalFound,
      ),
      downloaded: results.fold(
        BigInt.zero,
        (total, value) => total + value.downloaded,
      ),
      duplicates: results.fold(
        BigInt.zero,
        (total, value) => total + value.duplicates,
      ),
      skippedRemote: results.fold(
        BigInt.zero,
        (total, value) => total + value.skippedRemote,
      ),
      failed: results.fold(BigInt.zero, (total, value) => total + value.failed),
      errors: results.expand((value) => value.errors).toList(growable: false),
    );
  }

  Future<void> _notifySyncCompletion(
    List<SyncSummary> results, {
    int failedAccountCount = 0,
  }) async {
    final notifier = _backend is SyncNotificationBackend
        ? _backend as SyncNotificationBackend
        : null;
    if (!_disposed &&
        !_cancelRequested &&
        _backend.settings.notifyOnAutoSync &&
        notifier != null) {
      final downloaded = results.fold<BigInt>(
        BigInt.zero,
        (sum, value) => sum + value.downloaded,
      );
      if (downloaded > BigInt.zero) {
        final existing = results.fold<BigInt>(
          BigInt.zero,
          (sum, value) => sum + value.duplicates + value.skippedRemote,
        );
        final failed = results.fold<BigInt>(
          BigInt.zero,
          (sum, value) => sum + value.failed,
        );
        try {
          await notifier.notifyAutomaticSyncCompleted(
            downloaded: downloaded.toInt(),
            existing: existing.toInt(),
            failed: failed.toInt(),
            accountCount: results.length + failedAccountCount,
            failedAccountCount: failedAccountCount,
          );
        } catch (exception, stackTrace) {
          try {
            await _backend.logError(
              '[sync] trigger=sync stage=notification_failed',
              exception,
              stackTrace,
            );
          } catch (_) {
            // Notification diagnostics must not change a completed sync.
          }
        }
      }
    }
  }

  SyncProgress _completedProgress(SyncSummary result) {
    final synchronized =
        result.downloaded + result.duplicates + result.skippedRemote;
    return SyncProgress(
      jobId: result.jobId,
      status: result.failed == BigInt.zero
          ? 'completed'
          : 'completed_with_errors',
      totalItems: result.totalFound,
      processedItems: synchronized + result.failed,
      synchronizedItems: synchronized,
      failedItems: result.failed,
    );
  }

  Future<SyncScheduleStatus?> refreshScheduleStatus() async {
    final SyncScheduleBackend backend;
    if (_backend case final SyncScheduleBackend scheduleBackend) {
      backend = scheduleBackend;
    } else {
      return null;
    }
    try {
      scheduleStatus = await backend.loadSyncScheduleStatus();
      _notify();
      return scheduleStatus;
    } catch (exception, stackTrace) {
      await _backend.logError(
        'Failed to load Nintendo sync schedule state',
        exception,
        stackTrace,
      );
      return null;
    }
  }

  Future<Map<String, SyncScheduleStatus?>> refreshAccountScheduleStatuses({
    List<String>? accountIds,
  }) async {
    if (!allAccounts || _backend is! AccountSyncBackend) {
      return accountSchedules;
    }
    final backend = _backend as AccountSyncBackend;
    final ids =
        accountIds ??
        (await _backend.listNintendoAccounts())
            .map((profile) => profile.accountId)
            .toList();
    if (accountIds == null) {
      accountSchedules.removeWhere((id, _) => !ids.contains(id));
    }
    for (final id in ids) {
      try {
        accountSchedules[id] = await backend.loadAccountSyncSchedule(id);
        if (_backend case final AccountScheduleAdmissionBackend admission) {
          if (!await admission.automaticAccountHasLocalHistory(id)) {
            accountSchedules[id] = null;
          }
        }
        if (_backend case final SyncHistoryBackend histories) {
          final history = await histories.loadSyncAccountHistory(id);
          final status = history.latestAttempt?.status;
          if (status == 'authentication_failure' &&
              !_authenticationOverrides.contains(id)) {
            authPausedAccountIds.add(id);
          } else if (status != null) {
            authPausedAccountIds.remove(id);
          }
        }
      } catch (exception, stackTrace) {
        await _backend.logError(
          'Failed to load Nintendo account sync schedule state',
          exception,
          stackTrace,
        );
      }
    }
    _notify();
    return accountSchedules;
  }

  Future<List<String>> dueAccountIds({DateTime? now}) async {
    if (!allAccounts || _backend is! AccountSyncBackend) return const [];
    final profiles = await _backend.listNintendoAccounts();
    final ids = profiles.map((profile) => profile.accountId).toList();
    accountSchedules.removeWhere((id, _) => !ids.contains(id));
    await refreshAccountScheduleStatuses(accountIds: ids);
    final instant = (now ?? _now()).toUtc();
    return ids.where((id) {
      if (authPausedAccountIds.contains(id)) return false;
      final due = accountSchedules[id]?.nextSyncAt?.toUtc();
      return due != null && !due.isAfter(instant);
    }).toList();
  }

  DateTime? get nextAccountSyncAt {
    DateTime? earliest;
    for (final entry in accountSchedules.entries) {
      if (authPausedAccountIds.contains(entry.key)) continue;
      final due = entry.value?.nextSyncAt?.toUtc();
      if (due != null && (earliest == null || due.isBefore(earliest))) {
        earliest = due;
      }
    }
    return earliest;
  }

  Future<void> enqueueAuthenticatedAccount(String accountId) async {
    if (_disposed || accountId.isEmpty) return;
    _authenticationOverrides.add(accountId);
    _pendingAuthenticatedAccountIds.add(accountId);
    authPausedAccountIds.remove(accountId);
    _notify();
    if (!running) await _drainAuthenticatedAccounts();
  }

  Future<void> _drainAuthenticatedAccounts() async {
    if (_drainingAuthenticatedAccounts || running || _disposed) return;
    _drainingAuthenticatedAccounts = true;
    try {
      while (_pendingAuthenticatedAccountIds.isNotEmpty && !_disposed) {
        final ids = _pendingAuthenticatedAccountIds.toList();
        _pendingAuthenticatedAccountIds.removeAll(ids);
        await run(accountIds: ids);
        if (state == SyncState.cancelled) {
          _pendingAuthenticatedAccountIds.clear();
          break;
        }
      }
    } finally {
      _drainingAuthenticatedAccounts = false;
    }
  }

  void _startPolling() {
    _polling = true;
    unawaited(_refreshProgress());
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => unawaited(_refreshProgress()),
    );
  }

  void _stopPolling() {
    _polling = false;
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  Future<void> _refreshProgress() async {
    if (!_polling || _progressRequestPending) return;
    _progressRequestPending = true;
    try {
      final next = await _backend.currentSyncProgress();
      if (_polling && next != null && next != progress) {
        progress = next;
        _notify();
      }
    } catch (_) {
      // Progress reporting must never make the actual sync fail.
    } finally {
      _progressRequestPending = false;
    }
  }

  Future<void> cancel({bool suppressAutomaticRelaunch = true}) async {
    if (!running) return;
    _cancelRequested = true;
    _authenticationOverrides.removeAll(_pendingAuthenticatedAccountIds);
    _pendingAuthenticatedAccountIds.clear();
    this.suppressAutomaticRelaunch = suppressAutomaticRelaunch;
    state = SyncState.cancelling;
    _notify();
    final delivered = await _requestCancellation();
    if (!delivered && running) {
      _cancellationTimer ??= Timer.periodic(
        const Duration(milliseconds: 300),
        (_) => unawaited(_retryCancellation()),
      );
    }
  }

  Future<bool> _requestCancellation() async {
    if (_cancellationRequestPending) return false;
    _cancellationRequestPending = true;
    try {
      return await _backend.cancelSync();
    } catch (_) {
      return false;
    } finally {
      _cancellationRequestPending = false;
    }
  }

  Future<void> _retryCancellation() async {
    if (!running || _disposed) {
      _stopCancellationDelivery();
      return;
    }
    if (await _requestCancellation()) _stopCancellationDelivery();
  }

  void _stopCancellationDelivery() {
    _cancellationTimer?.cancel();
    _cancellationTimer = null;
  }

  bool consumeAutomaticRelaunchSuppression() {
    final value = suppressAutomaticRelaunch;
    suppressAutomaticRelaunch = false;
    return value;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPolling();
    _stopCancellationDelivery();
    super.dispose();
  }
}
