import 'package:squid_album/src/backend/app_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/rust/settings.dart';
import 'package:squid_album/src/state/automatic_sync_coordinator.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/settings_copy.dart';
import 'package:squid_album/src/state/sync_controller.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  test('expired original timer resumes once after device pause without resetting deadline', () async {
    final backend = _ScheduledBackend();
    final settings = SettingsController(backend);
    final sync = SyncController(backend);
    final coordinator = AutomaticSyncCoordinator(backend, settings, sync);
    try {
      await coordinator.start();
      final device = backend.accountWorkGate.device();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(backend.calls, 0);
      expect(sync.state, SyncState.idle);
      device.release();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(backend.calls, 1);
      expect(backend.historyWrites, 1);
    } finally {
      coordinator.dispose();
      sync.dispose();
      settings.dispose();
    }
  });
  test('imported selection without local schedule cannot inherit an old overdue account timer', () async {
    final backend = _ScheduledBackend();
    final settings = SettingsController(backend);
    final sync = SyncController(backend);
    final coordinator = AutomaticSyncCoordinator(backend, settings, sync);
    try {
      await coordinator.start();
      final device = backend.accountWorkGate.device();
      backend.selectedAccount = 'new-imported';
      await Future<void>.delayed(const Duration(milliseconds: 150));
      device.release();
      await coordinator.accountChanged();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(backend.calls, 0);
      expect(backend.historyWrites, 0);
      expect(sync.state, SyncState.idle);
      expect(sync.error, isNull);
    } finally {
      coordinator.dispose();
      sync.dispose();
      settings.dispose();
    }
  });
  test('Busy admission preserves visible result and does not publish running or failure', () async {
    final backend = _Backend();
    final sync = SyncController(backend);
    await sync.run();
    final previous = sync.summary;
    final lease = backend.accountWorkGate.device();
    var notifications = 0;
    sync.addListener(() => notifications++);
    await sync.run(automatic: true);
    expect(sync.state, SyncState.completed);
    expect(identical(sync.summary, previous), isTrue);
    expect(sync.error, isNull);
    expect(notifications, 0);
    expect(backend.calls, 1);
    lease.release();
    sync.dispose();
  });
}

class _ScheduledBackend extends _Backend
    implements SyncScheduleBackend, AccountScheduleAdmissionBackend {
  _ScheduledBackend() {
    signedIn = true;
    selectedAccount = 'old';
    settings = copyAppSettings(
      settings,
      syncPolicy: const SyncPolicy(
        enabled: true,
        activeIntervalMinutes: 30,
        sleepAfterHours: 24,
      ),
    );
  }
  final originalDeadline = DateTime.now().toUtc().add(
    const Duration(milliseconds: 80),
  );
  int historyWrites = 0;
  @override
  Future<bool> automaticAccountHasLocalHistory(String accountId) async =>
      accountId == 'old';
  @override
  Future<SyncScheduleStatus?> loadSyncScheduleStatus() async =>
      SyncScheduleStatus(
        sleeping: false,
        nextSyncAt: historyWrites != 0
            ? DateTime.now().toUtc().add(const Duration(hours: 1))
            : selectedAccount == 'old'
            ? originalDeadline
            : DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
      );
  @override
  Future<SyncScheduleStatus?> recordSyncOutcome({
    required bool foundNewMedia,
  }) async {
    historyWrites++;
    return loadSyncScheduleStatus();
  }
}

class _Backend extends FakeBackend implements AccountWorkBackend {
  @override
  final accountWorkGate = AccountWorkGate();
  int calls = 0;
  @override
  Future<SyncSummary> syncNintendoAlbum() async {
    calls++;
    return SyncSummary(
      jobId: 'synthetic',
      totalFound: BigInt.zero,
      downloaded: BigInt.zero,
      duplicates: BigInt.zero,
      skippedRemote: BigInt.zero,
      failed: BigInt.zero,
      errors: const [],
    );
  }
}
