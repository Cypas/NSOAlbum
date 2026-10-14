import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/rust/settings.dart';
import 'package:squid_album/src/state/automatic_sync_coordinator.dart';
import 'package:squid_album/src/state/settings_copy.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/sync_controller.dart';
import 'package:squid_album/src/state/transfer_controller.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  test('rate limited sync errors request a one minute automatic retry', () {
    expect(
      automaticSyncRetryDelayForError(
        StateError('rate limited: retry after 900 seconds'),
      ),
      const Duration(minutes: 1),
    );
  });

  test('ordinary sync errors do not override the configured schedule', () {
    expect(
      automaticSyncRetryDelayForError(StateError('network unavailable')),
      isNull,
    );
  });

  test(
    'mobile manual sync serializes every account without changing selection',
    () async {
      final backend = _AccountBackend(
        outcomes: {
          'a': _summary('a', downloaded: 1),
          'b': _summary('b', duplicates: 2),
        },
      )..selectedAccount = 'b';
      final controller = SyncController(backend, allAccounts: true);

      await controller.run();

      expect(backend.accountCalls, ['a', 'b']);
      expect(backend.selectedAccount, 'b');
      expect(controller.completedAccounts, 2);
      expect(controller.totalAccounts, 2);
      expect(controller.accountResults.keys, ['a', 'b']);
      expect(controller.state, SyncState.completed);
    },
  );

  test(
    'partial account failure is retained while later accounts continue',
    () async {
      final backend = _AccountBackend(
        outcomes: {
          'a': StateError('network unavailable'),
          'b': _summary('b', downloaded: 1),
        },
      );
      final controller = SyncController(backend, allAccounts: true);

      await controller.run();

      expect(backend.accountCalls, ['a', 'b']);
      expect(controller.accountErrors, contains('a'));
      expect(controller.accountResults, contains('b'));
      expect(controller.completedAccounts, 2);
      expect(controller.state, SyncState.completed);
    },
  );

  test(
    'authentication failure pauses account and does not block later account',
    () async {
      final backend = _AccountBackend(
        outcomes: {
          'a': StateError('authentication token expired'),
          'b': _summary('b'),
        },
      );
      final controller = SyncController(backend, allAccounts: true);

      await controller.run();
      await controller.run(automatic: true, accountIds: ['a', 'b']);

      expect(controller.authPausedAccountIds, {'a'});
      expect(backend.accountCalls, ['a', 'b', 'b']);
    },
  );

  test(
    'rate limited account requests a one minute retry and queue continues',
    () async {
      final backend = _AccountBackend(
        outcomes: {'a': StateError('429 rate limited'), 'b': _summary('b')},
      );
      final controller = SyncController(backend, allAccounts: true);

      await controller.run();

      expect(controller.automaticRetryDelay, const Duration(minutes: 1));
      expect(backend.accountCalls, ['a', 'b']);
      expect(controller.state, SyncState.completed);
    },
  );

  test(
    'cancel during account preparation stops queue and is not completed',
    () async {
      final backend = _AccountBackend(
        outcomes: {'a': _summary('a'), 'b': _summary('b')},
        preparingAccount: 'a',
      );
      final controller = SyncController(backend, allAccounts: true);
      final pending = controller.run();
      await backend.preparationStarted.future;

      await controller.cancel();
      await pending;

      expect(backend.cancelCalls, 1);
      expect(backend.accountCalls, ['a']);
      expect(controller.state, SyncState.cancelled);
      expect(controller.completedAccounts, 0);
    },
  );

  test(
    'cancel retries bounded delivery when registration is not ready',
    () async {
      final backend = _RetryCancelBackend();
      final controller = SyncController(backend, allAccounts: true);
      final pending = controller.run();
      await backend.preparationStarted.future;

      await controller.cancel();
      await pending.timeout(const Duration(seconds: 2));

      expect(backend.cancelCalls, 2);
      expect(controller.state, SyncState.cancelled);
    },
  );

  test(
    'desktop controller retains selected-account backend behavior',
    () async {
      final backend = FakeBackend(
        signedIn: true,
        syncFuture: Future.value(_summary('desktop')),
      );
      final controller = SyncController(backend);

      await controller.run();

      expect(backend.syncCalls, 1);
      expect(controller.totalAccounts, 0);
      expect(controller.state, SyncState.completed);
    },
  );

  test('login enqueues only the newly added account', () async {
    final backend = _LoginAccountBackend();
    final settings = SettingsController(backend);
    final sync = SyncController(backend, allAccounts: true);
    final transfer = TransferController(backend, settings, sync);

    expect(await transfer.completeLogin('callback'), isFalse);
    expect(backend.completeLoginCalls, 0);
    expect(await transfer.beginLogin(), isTrue);
    expect(await transfer.completeLogin('callback'), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(backend.accountCalls, ['new']);
    expect(backend.selectedAccount, 'old');
    transfer.dispose();
    sync.dispose();
    settings.dispose();
  });

  test(
    'automatic coordinator runs only due accounts without a zero-delay loop',
    () async {
      final backend = _ScheduledAccountBackend();
      backend.settings = copyAppSettings(
        backend.settings,
        syncPolicy: const SyncPolicy(
          enabled: true,
          activeIntervalMinutes: 30,
          sleepAfterHours: 24,
        ),
      );
      final settings = SettingsController(backend);
      final sync = SyncController(backend, allAccounts: true);
      final coordinator = AutomaticSyncCoordinator(backend, settings, sync);

      await coordinator.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(backend.accountCalls, ['a']);
      coordinator.dispose();
      sync.dispose();
      settings.dispose();
    },
  );

  test('persisted authentication failure is excluded after restart', () async {
    final backend = _PersistedAuthBackend();
    final sync = SyncController(backend, allAccounts: true);

    final due = await sync.dueAccountIds(now: DateTime.utc(2026, 10, 14, 12));

    expect(sync.authPausedAccountIds, {'a'});
    expect(due, ['b']);
    sync.dispose();
  });

  test(
    'manual sync also excludes accounts paused by persisted auth failure',
    () async {
      final backend = _PersistedAuthBackend();
      final sync = SyncController(backend, allAccounts: true);

      await sync.run();

      expect(backend.accountCalls, ['b']);
      expect(sync.authPausedAccountIds, {'a'});
      sync.dispose();
    },
  );

  test('authenticated account waits for active queue and clears stale result only when starting', () async {
    final backend = _LoginDuringSyncBackend();
    final settings = SettingsController(backend);
    final sync = SyncController(backend, allAccounts: true);
    final transfer = TransferController(backend, settings, sync);
    sync.accountResults['new'] = _summary('stale');
    final active = sync.run(accountIds: ['old']);
    await backend.oldStarted.future;

    await transfer.beginLogin();
    expect(await transfer.completeLogin('callback'), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(backend.accountCalls, ['old']);
    expect(sync.accountResults['new']?.jobId, 'stale');
    backend.releaseOld.complete();
    await backend.newStarted.future;
    expect(sync.accountResults, isNot(contains('new')));
    backend.releaseNew.complete();
    await active;

    expect(backend.accountCalls, ['old', 'new']);
    expect(sync.accountResults['new']?.jobId, 'new');
    transfer.dispose();
    sync.dispose();
    settings.dispose();
  });

  test(
    'cancelling active queue discards pending authenticated account',
    () async {
      final backend = _CancelledPendingAuthBackend();
      final sync = SyncController(backend, allAccounts: true);
      final active = sync.run(accountIds: ['old']);
      await backend.oldStarted.future;
      await sync.enqueueAuthenticatedAccount('new');

      await sync.cancel();
      backend.releaseOld.complete();
      await active;
      await sync.run(accountIds: ['new']);

      expect(backend.accountCalls, ['old']);
      expect(sync.authPausedAccountIds, {'new'});
      sync.dispose();
    },
  );

  test('existing account relogin retries only selected account and keeps others paused', () async {
    final backend = _ExistingReloginBackend();
    final settings = SettingsController(backend);
    final sync = SyncController(backend, allAccounts: true);
    final transfer = TransferController(backend, settings, sync);
    await sync.refreshAccountScheduleStatuses();
    await transfer.refresh();
    expect(sync.authPausedAccountIds, {'a', 'b'});

    await transfer.beginLogin();
    expect(await transfer.completeLogin('callback'), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(backend.accountCalls, ['a']);
    expect(sync.authPausedAccountIds, {'b'});
    transfer.dispose();
    sync.dispose();
    settings.dispose();
  });

  test('disabling automatic sync cancels its active queue', () async {
    final backend = _ScheduledAccountBackend(preparingAccount: 'a');
    backend.settings = copyAppSettings(
      backend.settings,
      syncPolicy: const SyncPolicy(
        enabled: true,
        activeIntervalMinutes: 30,
        sleepAfterHours: 24,
      ),
    );
    final settings = SettingsController(backend);
    final sync = SyncController(backend, allAccounts: true);
    final coordinator = AutomaticSyncCoordinator(backend, settings, sync);
    await coordinator.start();
    await backend.preparationStarted.future;

    await settings.save(
      copyAppSettings(
        settings.value,
        syncPolicy: const SyncPolicy(
          enabled: false,
          activeIntervalMinutes: 30,
          sleepAfterHours: 24,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(backend.cancelCalls, 1);
    expect(sync.state, SyncState.cancelled);
    coordinator.dispose();
    sync.dispose();
    settings.dispose();
  });

  test('late coordinator callbacks are ignored after disposal', () async {
    final backend = _LateSignedInBackend();
    backend.settings = copyAppSettings(
      backend.settings,
      syncPolicy: const SyncPolicy(
        enabled: true,
        activeIntervalMinutes: 30,
        sleepAfterHours: 24,
      ),
    );
    final settings = SettingsController(backend);
    final sync = SyncController(backend, allAccounts: true);
    final coordinator = AutomaticSyncCoordinator(backend, settings, sync);

    final start = coordinator.start();
    coordinator.dispose();
    backend.signedInResult.complete(true);
    await start;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(backend.accountCalls, isEmpty);
    expect(sync.state, SyncState.idle);
    sync.dispose();
    settings.dispose();
  });
}

SyncSummary _summary(
  String id, {
  int downloaded = 0,
  int duplicates = 0,
  int failed = 0,
}) => SyncSummary(
  jobId: id,
  totalFound: BigInt.from(downloaded + duplicates + failed),
  downloaded: BigInt.from(downloaded),
  duplicates: BigInt.from(duplicates),
  skippedRemote: BigInt.zero,
  failed: BigInt.from(failed),
  errors: const [],
);

class _AccountBackend extends FakeBackend implements AccountSyncBackend {
  _AccountBackend({required this.outcomes, this.preparingAccount})
    : super(
        signedIn: true,
        accountProfiles: const [
          NintendoAccountProfile(accountId: 'a', nickname: 'A'),
          NintendoAccountProfile(accountId: 'b', nickname: 'B'),
        ],
      );

  final Map<String, Object> outcomes;
  final String? preparingAccount;
  final preparationStarted = Completer<void>();
  final preparationReleased = Completer<void>();
  final List<String> accountCalls = [];
  int cancelCalls = 0;

  @override
  Future<SyncSummary> syncNintendoAccount(String accountId) async {
    accountCalls.add(accountId);
    if (accountId == preparingAccount) {
      if (!preparationStarted.isCompleted) preparationStarted.complete();
      await preparationReleased.future;
    }
    final outcome = outcomes[accountId]!;
    if (outcome is SyncSummary) return outcome;
    throw outcome;
  }

  @override
  Future<bool> cancelSync() async {
    cancelCalls += 1;
    if (!preparationReleased.isCompleted) preparationReleased.complete();
    return true;
  }

  @override
  Future<SyncScheduleStatus?> loadAccountSyncSchedule(String accountId) async =>
      SyncScheduleStatus(
        sleeping: false,
        nextSyncAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      );

  @override
  Future<SyncScheduleStatus?> recordAccountSyncOutcome(
    String accountId, {
    required bool foundNewMedia,
  }) async => SyncScheduleStatus(
    sleeping: false,
    nextSyncAt: DateTime.now().toUtc().add(const Duration(minutes: 30)),
  );
}

class _LoginAccountBackend extends _AccountBackend {
  _LoginAccountBackend() : super(outcomes: {'new': _summary('new')}) {
    selectedAccount = 'old';
  }

  bool added = false;
  int completeLoginCalls = 0;

  @override
  Future<List<NintendoAccountProfile>> listNintendoAccounts() async => [
    const NintendoAccountProfile(accountId: 'old', nickname: 'Old'),
    if (added) const NintendoAccountProfile(accountId: 'new', nickname: 'New'),
  ];

  @override
  Future<void> completeNintendoLogin(String callbackUrl) async {
    completeLoginCalls += 1;
    added = true;
  }
}

class _ScheduledAccountBackend extends _AccountBackend {
  _ScheduledAccountBackend({super.preparingAccount})
    : super(outcomes: {'a': _summary('a'), 'b': _summary('b')});

  final attemptedAccounts = <String>{};

  @override
  Future<SyncScheduleStatus?> loadAccountSyncSchedule(String accountId) async =>
      SyncScheduleStatus(
        sleeping: false,
        nextSyncAt: accountId == 'a' && !attemptedAccounts.contains(accountId)
            ? DateTime.now().toUtc().subtract(const Duration(seconds: 1))
            : DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

  @override
  Future<SyncScheduleStatus?> recordAccountSyncOutcome(
    String accountId, {
    required bool foundNewMedia,
  }) async {
    attemptedAccounts.add(accountId);
    return super.recordAccountSyncOutcome(
      accountId,
      foundNewMedia: foundNewMedia,
    );
  }
}

class _RetryCancelBackend extends _AccountBackend {
  _RetryCancelBackend()
    : super(
        outcomes: {'a': _summary('a'), 'b': _summary('b')},
        preparingAccount: 'a',
      );

  @override
  Future<bool> cancelSync() async {
    cancelCalls += 1;
    if (cancelCalls == 1) return false;
    if (!preparationReleased.isCompleted) preparationReleased.complete();
    return true;
  }
}

class _PersistedAuthBackend extends _AccountBackend {
  _PersistedAuthBackend()
    : super(outcomes: {'a': _summary('a'), 'b': _summary('b')});

  @override
  Future<SyncScheduleStatus?> loadAccountSyncSchedule(String accountId) async =>
      SyncScheduleStatus(
        sleeping: false,
        nextSyncAt: DateTime.utc(2026, 10, 14, 11),
      );

  @override
  Future<SyncRuntimeState> loadSyncAccountHistory(String accountId) async =>
      SyncRuntimeState(
        latestAttempt: SyncAttemptSummary(
          attemptedAt: DateTime.utc(2026, 10, 14, 10),
          status: accountId == 'a' ? 'authentication_failure' : 'success',
          totalFound: BigInt.zero,
          downloaded: BigInt.zero,
          duplicates: BigInt.zero,
          failed: accountId == 'a' ? BigInt.one : BigInt.zero,
        ),
      );
}

class _LateSignedInBackend extends _AccountBackend {
  _LateSignedInBackend()
    : super(outcomes: {'a': _summary('a'), 'b': _summary('b')});

  final signedInResult = Completer<bool>();

  @override
  Future<bool> get isSignedIn => signedInResult.future;
}

class _LoginDuringSyncBackend extends _AccountBackend {
  _LoginDuringSyncBackend()
    : super(outcomes: {'old': _summary('old'), 'new': _summary('new')}) {
    selectedAccount = 'old';
  }

  bool added = false;
  final oldStarted = Completer<void>();
  final newStarted = Completer<void>();
  final releaseOld = Completer<void>();
  final releaseNew = Completer<void>();

  @override
  Future<List<NintendoAccountProfile>> listNintendoAccounts() async => [
    const NintendoAccountProfile(accountId: 'old', nickname: 'Old'),
    if (added) const NintendoAccountProfile(accountId: 'new', nickname: 'New'),
  ];

  @override
  Future<void> completeNintendoLogin(String callbackUrl) async {
    added = true;
  }

  @override
  Future<SyncSummary> syncNintendoAccount(String accountId) async {
    accountCalls.add(accountId);
    if (accountId == 'old') {
      oldStarted.complete();
      await releaseOld.future;
    } else {
      newStarted.complete();
      await releaseNew.future;
    }
    return outcomes[accountId]! as SyncSummary;
  }
}

class _ExistingReloginBackend extends _AccountBackend {
  _ExistingReloginBackend()
    : super(outcomes: {'a': _summary('a'), 'b': _summary('b')});

  @override
  Future<SyncRuntimeState> loadSyncAccountHistory(String accountId) async =>
      SyncRuntimeState(
        latestAttempt: SyncAttemptSummary(
          attemptedAt: DateTime.utc(2026, 10, 14, 10),
          status: 'authentication_failure',
          totalFound: BigInt.zero,
          downloaded: BigInt.zero,
          duplicates: BigInt.zero,
          failed: BigInt.one,
        ),
      );

  @override
  Future<void> completeNintendoLogin(String callbackUrl) async {
    selectedAccount = 'a';
  }
}

class _CancelledPendingAuthBackend extends _LoginDuringSyncBackend {
  _CancelledPendingAuthBackend() {
    added = true;
  }

  @override
  Future<SyncRuntimeState> loadSyncAccountHistory(String accountId) async =>
      SyncRuntimeState(
        latestAttempt: SyncAttemptSummary(
          attemptedAt: DateTime.utc(2026, 10, 14, 10),
          status: accountId == 'new' ? 'authentication_failure' : 'success',
          totalFound: BigInt.zero,
          downloaded: BigInt.zero,
          duplicates: BigInt.zero,
          failed: accountId == 'new' ? BigInt.one : BigInt.zero,
        ),
      );
}
