import 'dart:async';

import 'package:flutter/foundation.dart';

import '../backend/app_backend.dart';
import '../rust/models.dart';
import '../rust/settings.dart';

enum SyncState { idle, running, completed, failed, cancelling }

Duration? automaticSyncRetryDelayForError(Object error) {
  final message = error.toString().toLowerCase();
  if (message.contains('rate limited')) {
    return const Duration(minutes: 1);
  }
  return null;
}

class SyncController extends ChangeNotifier {
  SyncController(this._backend);

  final AppBackend _backend;
  SyncState state = SyncState.idle;
  SyncSummary? summary;
  SyncProgress? progress;
  Object? error;
  SyncScheduleStatus? scheduleStatus;
  Duration? automaticRetryDelay;
  bool _polling = false;
  bool _progressRequestPending = false;
  bool _disposed = false;
  Timer? _progressTimer;

  Future<void> run() async {
    if (state == SyncState.running || state == SyncState.cancelling) return;
    automaticRetryDelay = null;
    state = SyncState.running;
    summary = null;
    progress = null;
    error = null;
    notifyListeners();
    _polling = true;
    unawaited(_refreshProgress());
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => unawaited(_refreshProgress()),
    );
    try {
      final result = await _backend.syncNintendoAlbum();
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
      final synchronized =
          result.downloaded + result.duplicates + result.skippedRemote;
      progress = SyncProgress(
        jobId: result.jobId,
        status: result.failed == BigInt.zero
            ? 'completed'
            : 'completed_with_errors',
        totalItems: result.totalFound,
        processedItems: synchronized + result.failed,
        synchronizedItems: synchronized,
        failedItems: result.failed,
      );
      state = SyncState.completed;
    } catch (exception, stackTrace) {
      error = exception;
      automaticRetryDelay = automaticSyncRetryDelayForError(exception);
      state = SyncState.failed;
      await _backend.logError(
        'Nintendo album synchronization failed',
        exception,
        stackTrace,
      );
    } finally {
      _polling = false;
      _progressTimer?.cancel();
      _progressTimer = null;
    }
    if (!_disposed) notifyListeners();
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
      if (!_disposed) notifyListeners();
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

  Future<void> _refreshProgress() async {
    if (!_polling || _progressRequestPending) return;
    _progressRequestPending = true;
    try {
      final next = await _backend.currentSyncProgress();
      if (_polling && next != null && next != progress) {
        progress = next;
        if (!_disposed) notifyListeners();
      }
    } catch (_) {
      // Progress reporting must never make the actual sync fail.
    } finally {
      _progressRequestPending = false;
    }
  }

  Future<void> cancel() async {
    if (state != SyncState.running) return;
    state = SyncState.cancelling;
    notifyListeners();
    await _backend.cancelSync();
  }

  @override
  void dispose() {
    _disposed = true;
    _polling = false;
    _progressTimer?.cancel();
    _progressTimer = null;
    super.dispose();
  }
}
