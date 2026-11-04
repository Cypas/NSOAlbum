// The real coordinator/controller run against an in-memory account boundary.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/rust/settings.dart';
import 'package:squid_album/src/state/automatic_sync_coordinator.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/settings_copy.dart';
import 'package:squid_album/src/state/sync_controller.dart';

import '../home_shell_test.dart' show FakeBackend;

final _start = DateTime.utc(2026, 10, 19, 9, 55);

void main() {
  test('a startup barrier outliving the transfer cannot restore the skipped legacy deadline', () {
    fakeAsync((time) {
      final fixture = _Fixture(time, allAccounts: false);
      fixture.start();
      final transfer = fixture.backend.accountWorkGate.holdTransfer();
      final startup = fixture.backend.accountWorkGate.holdStartup();
      time.elapse(const Duration(minutes: 15));
      transfer.release();
      time.flushMicrotasks();
      expect(fixture.backend.calls, isEmpty);
      startup.release();
      time.flushMicrotasks();
      time.elapse(Duration.zero);
      expect(fixture.backend.calls, isEmpty);
      time.elapse(const Duration(minutes: 20));
      expect(fixture.backend.calls, ['a']);
      fixture.dispose();
    });
  });

  test('local history read failure cannot turn a skipped slot into an unhandled timer error', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      fixture.start();
      final transfer = fixture.backend.accountWorkGate.holdTransfer();
      time.elapse(const Duration(minutes: 16));
      fixture.backend.failHistoryRead = true;
      transfer.release();
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 19)); // 10:30.
      expect(fixture.backend.calls, ['b', 'a']);
      fixture.dispose();
    });
  });

  test('a missed 429 retry returns to the normal attempt cadence rather than retry-plus-interval', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      fixture.backend.slots.remove('b');
      time.elapse(const Duration(minutes: 5)); // Original attempt at 10:00.
      fixture.backend.slots['a'] = SyncScheduleStatus(
        sleeping: false,
        intervalMinutes: 30,
        nextSyncAt: DateTime.utc(2026, 10, 19, 10, 1),
      );
      fixture.backend.accountSyncHistories['a'] = SyncRuntimeState(
        latestAttempt: SyncAttemptSummary(
          attemptedAt: DateTime.utc(2026, 10, 19, 10),
          status: 'rate_limited',
          totalFound: BigInt.zero,
          downloaded: BigInt.zero,
          duplicates: BigInt.zero,
          failed: BigInt.one,
        ),
      );
      fixture.start();
      final transfer = fixture.backend.accountWorkGate.holdTransfer();
      time.elapse(const Duration(minutes: 10));
      transfer.release();
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 19, seconds: 59));
      expect(fixture.backend.calls, isEmpty);
      expect(fixture.backend.historyWrites, 0);
      time.elapse(const Duration(seconds: 1)); // 10:30, not 10:31.
      expect(fixture.backend.calls, ['a']);
      fixture.dispose();
    });
  });

  test(
    'selected-account desktop scheduling skips without recording an attempt',
    () {
      fakeAsync((time) {
        final fixture = _Fixture(time, allAccounts: false);
        fixture.start();
        final transfer = fixture.backend.accountWorkGate.holdTransfer();
        time.elapse(const Duration(minutes: 15));
        transfer.release();
        time.flushMicrotasks();
        time.elapse(const Duration(minutes: 19));
        expect(fixture.backend.calls, isEmpty);
        expect(fixture.backend.historyWrites, 0);
        time.elapse(const Duration(minutes: 1));
        expect(fixture.backend.calls, ['a']);
        fixture.dispose();
      });
    },
  );

  test(
    'a transfer winning the timer admission race skips that original slot',
    () {
      fakeAsync((time) {
        final fixture = _Fixture(time);
        fixture.start();
        DeviceTransferPermit? transfer;
        fixture.backend.onSignedIn = () =>
            transfer = fixture.backend.accountWorkGate.holdTransfer();
        time.elapse(const Duration(minutes: 6));
        expect(transfer, isNotNull);
        expect(fixture.backend.calls, isEmpty);
        transfer!.release();
        time.flushMicrotasks();
        time.elapse(const Duration(minutes: 14)); // B 10:15
        expect(fixture.backend.calls, ['b']);
        time.elapse(const Duration(minutes: 15));
        expect(fixture.backend.calls, ['b', 'a']);
        fixture.dispose();
      });
    },
  );

  test('starting the scheduler during a transfer recovers the unclamped local cadence', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      fixture.backend.clampDue = true;
      fixture.backend.accountSyncHistories['a'] = SyncRuntimeState(
        lastSuccessfulSyncAt: DateTime.utc(2026, 10, 19, 9, 30),
      );
      final transfer = fixture.backend.accountWorkGate.holdTransfer();
      fixture.start();
      time.elapse(const Duration(minutes: 15));
      transfer.release();
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 19));
      expect(fixture.backend.calls, ['b']);
      time.elapse(const Duration(minutes: 1));
      expect(fixture.backend.calls, ['b', 'a']);
      fixture.dispose();
    });
  });
  test('transfer skips a due slot without catching up and keeps other accounts cadence', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      fixture.start();
      final transfer = fixture.backend.accountWorkGate.holdTransfer();
      time.elapse(const Duration(minutes: 16)); // 10:11
      expect(fixture.backend.calls, isEmpty);
      expect(fixture.backend.historyWrites, 0);
      transfer.release();
      time.flushMicrotasks();
      expect(fixture.backend.calls, isEmpty);
      time.elapse(const Duration(minutes: 4)); // B's original 10:15
      expect(fixture.backend.calls, ['b']);
      time.elapse(const Duration(minutes: 15)); // A's next original 10:30
      expect(fixture.backend.calls, ['b', 'a']);
      fixture.dispose();
    });
  });

  test('multiple missed rounds are discarded rather than queued', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      fixture.start();
      final transfer = fixture.backend.accountWorkGate.holdTransfer();
      time.elapse(const Duration(minutes: 70)); // 11:05
      transfer.release();
      time.flushMicrotasks();
      expect(fixture.backend.calls, isEmpty);
      expect(fixture.backend.historyWrites, 0);
      time.elapse(const Duration(minutes: 24));
      expect(fixture.backend.calls, isEmpty);
      time.elapse(const Duration(minutes: 1)); // A 11:30
      expect(fixture.backend.calls, ['a']);
      time.elapse(const Duration(minutes: 15)); // B 11:45
      expect(fixture.backend.calls, ['a', 'b']);
      fixture.dispose();
    });
  });

  test('a transfer ending before the deadline does not delay it', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      fixture.start();
      final transfer = fixture.backend.accountWorkGate.holdTransfer();
      time.elapse(const Duration(minutes: 4));
      transfer.release();
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      expect(fixture.backend.calls, ['a']);
      fixture.dispose();
    });
  });

  for (final sleeping in [false, true]) {
    test(
      'skipped ${sleeping ? 'sleeping' : 'rate limit retry'} waits the effective normal interval',
      () {
        fakeAsync((time) {
          final fixture = _Fixture(time);
          fixture.backend.slots.remove('b');
          fixture.backend.slots['a'] = SyncScheduleStatus(
            sleeping: sleeping,
            intervalMinutes: sleeping ? 1440 : 30,
            nextSyncAt: DateTime.utc(2026, 10, 19, 10),
          );
          fixture.start();
          final transfer = fixture.backend.accountWorkGate.holdTransfer();
          time.elapse(const Duration(minutes: 15)); // 10:10
          transfer.release();
          time.flushMicrotasks();
          time.elapse(
            sleeping
                ? const Duration(hours: 23, minutes: 49)
                : const Duration(minutes: 19),
          );
          expect(fixture.backend.calls, isEmpty);
          time.elapse(const Duration(minutes: 1));
          expect(fixture.backend.calls, ['a']);
          expect(fixture.backend.historyWrites, 1);
          fixture.dispose();
        });
      },
    );
  }

  test(
    'startup barrier still resumes overdue work and is not a transfer skip',
    () {
      fakeAsync((time) {
        final fixture = _Fixture(time);
        fixture.start();
        final startup = fixture.backend.accountWorkGate.holdStartup();
        time.elapse(const Duration(minutes: 15));
        startup.release();
        time.flushMicrotasks();
        time.elapse(Duration.zero);
        expect(fixture.backend.calls, ['a']);
        fixture.dispose();
      });
    },
  );

  test('turning automatic sync off while transferring never relaunches it', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      fixture.start();
      final transfer = fixture.backend.accountWorkGate.holdTransfer();
      time.elapse(const Duration(minutes: 15));
      fixture.settings.save(
        copyAppSettings(
          fixture.settings.value,
          syncPolicy: const SyncPolicy(
            enabled: false,
            activeIntervalMinutes: 30,
            sleepAfterHours: 24,
          ),
        ),
      );
      time.flushMicrotasks();
      transfer.release();
      time.flushMicrotasks();
      time.elapse(const Duration(days: 2));
      expect(fixture.backend.calls, isEmpty);
      expect(fixture.backend.historyWrites, 0);
      fixture.dispose();
    });
  });
}

class _Fixture {
  _Fixture(this.time, {bool allAccounts = true}) {
    backend = _Backend(() => _start.add(time.elapsed));
    settings = SettingsController(backend);
    sync = SyncController(backend, allAccounts: allAccounts, now: backend.now);
    coordinator = AutomaticSyncCoordinator(
      backend,
      settings,
      sync,
      now: backend.now,
    );
  }
  final FakeAsync time;
  late final _Backend backend;
  late final SettingsController settings;
  late final SyncController sync;
  late final AutomaticSyncCoordinator coordinator;
  void start() {
    var started = false;
    coordinator.start().then((_) => started = true);
    time.flushMicrotasks();
    expect(started, isTrue);
  }

  void dispose() {
    coordinator.dispose();
    sync.dispose();
    settings.dispose();
  }
}

class _Backend extends FakeBackend
    implements AccountWorkBackend, AccountSyncBackend, SyncScheduleBackend {
  _Backend(this.now) : super(accountSyncHistories: {}) {
    signedIn = true;
    selectedAccount = 'a';
    settings = copyAppSettings(
      settings,
      syncPolicy: const SyncPolicy(
        enabled: true,
        activeIntervalMinutes: 30,
        sleepAfterHours: 24,
      ),
    );
  }
  final DateTime Function() now;
  @override
  final accountWorkGate = AccountWorkGate();
  final calls = <String>[];
  void Function()? onSignedIn;
  bool clampDue = false;
  bool failHistoryRead = false;
  @override
  Future<SyncRuntimeState> loadSyncAccountHistory(String accountId) {
    if (failHistoryRead) {
      throw StateError('synthetic local history read failure');
    }
    return super.loadSyncAccountHistory(accountId);
  }

  @override
  Future<bool> get isSignedIn async {
    final callback = onSignedIn;
    onSignedIn = null;
    callback?.call();
    return signedIn;
  }

  int historyWrites = 0;
  final slots = <String, SyncScheduleStatus>{
    'a': SyncScheduleStatus(
      sleeping: false,
      intervalMinutes: 30,
      nextSyncAt: DateTime.utc(2026, 10, 19, 10),
    ),
    'b': SyncScheduleStatus(
      sleeping: false,
      intervalMinutes: 45,
      nextSyncAt: DateTime.utc(2026, 10, 19, 10, 15),
    ),
  };
  @override
  Future<List<NintendoAccountProfile>> listNintendoAccounts() async => slots
      .keys
      .map((id) => NintendoAccountProfile(accountId: id, nickname: id))
      .toList();
  @override
  Future<SyncScheduleStatus?> loadAccountSyncSchedule(String accountId) async {
    final slot = slots[accountId];
    if (slot == null || !clampDue || slot.nextSyncAt!.isAfter(now())) {
      return slot;
    }
    return SyncScheduleStatus(
      sleeping: slot.sleeping,
      intervalMinutes: slot.intervalMinutes,
      lastSuccessfulSyncAt: slot.lastSuccessfulSyncAt,
      nextSyncAt: now(),
    );
  }

  @override
  Future<SyncScheduleStatus?> loadSyncScheduleStatus() =>
      loadAccountSyncSchedule('a');
  @override
  Future<SyncScheduleStatus?> recordSyncOutcome({
    required bool foundNewMedia,
  }) => recordAccountSyncOutcome('a', foundNewMedia: foundNewMedia);
  @override
  Future<SyncSummary> syncNintendoAlbum() => syncNintendoAccount('a');
  @override
  Future<SyncSummary> syncNintendoAccount(String accountId) async {
    calls.add(accountId);
    return SyncSummary(
      jobId: accountId,
      totalFound: BigInt.zero,
      downloaded: BigInt.zero,
      duplicates: BigInt.zero,
      skippedRemote: BigInt.zero,
      failed: BigInt.zero,
      errors: const [],
    );
  }

  @override
  Future<SyncScheduleStatus?> recordAccountSyncOutcome(
    String accountId, {
    required bool foundNewMedia,
  }) async {
    historyWrites++;
    final previous = slots[accountId]!;
    return slots[accountId] = SyncScheduleStatus(
      sleeping: previous.sleeping,
      intervalMinutes: previous.intervalMinutes,
      lastSuccessfulSyncAt: now(),
      nextSyncAt: now().add(Duration(minutes: previous.intervalMinutes!)),
    );
  }
}
