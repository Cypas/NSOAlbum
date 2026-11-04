import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show debugPrintSynchronously, mapEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;

import 'account_bridge_test.dart' show pump;
import 'account_storage_test.dart' show MemoryAccountStorage;

const _old = {
  legacySessionKey: 'synthetic-old-legacy',
  accountTokensKey: '{"b":"synthetic-old"}',
  selectedAccountKey: 'b',
};
const _candidate = {
  accountTokensKey: '{"a":"synthetic-new"}',
  accountProfilesKey: '{"a":{"nickname":"Alice"}}',
  selectedAccountKey: 'a',
};

class FaultAccountStorage extends MemoryAccountStorage {
  FaultAccountStorage() : super(values: _old);
  int mutations = 0;
  int verifiedReads = 0;
  int? failMutation;
  int? mismatchRead;
  bool afterWrite = false;
  bool armed = false;
  bool consumed = false;
  bool failCompensation = false;
  bool compensationConsumed = false;
  final events = <String>[];
  @override
  Future<void> write(String key, String value) =>
      _mutate(key, () => super.write(key, value));
  @override
  Future<void> delete(String key) => _mutate(key, () => super.delete(key));
  Future<void> _mutate(String key, Future<void> Function() action) async {
    if (!armed) return action();
    mutations++;
    events.add('write:$key');
    final fail = !consumed && mutations == failMutation;
    final compensation =
        consumed &&
        failCompensation &&
        !compensationConsumed &&
        key == legacySessionKey;
    if (compensation) {
      compensationConsumed = true;
      throw StateError('synthetic protected-store compensation failure');
    }
    if (fail && !afterWrite) {
      consumed = true;
      throw StateError('synthetic protected-store failure');
    }
    await action();
    if (fail) {
      consumed = true;
      throw StateError('synthetic protected-store acknowledgement failure');
    }
  }

  @override
  Future<String?> read(String key) async {
    final actual = await super.read(key);
    if (armed && events.isNotEmpty && events.last == 'write:$key') {
      verifiedReads++;
      events.add('readback:$key');
      if (!consumed && verifiedReads == mismatchRead) {
        consumed = true;
        return 'synthetic-readback-mismatch';
      }
    }
    return actual;
  }
}

class _Attempt {
  _Attempt(
    this.root,
    this.sourceLibrary,
    this.host,
    this.phone,
    this.source,
    this.target,
    this.storage,
    this.preview,
  );
  final Directory root;
  final String sourceLibrary, host, phone;
  final DeviceAccountCoordinator source, target;
  final FaultAccountStorage storage;
  final AccountPreview preview;
}

Future<_Attempt> _prepare(
  String targetLibrary, {
  FaultAccountStorage? storageOverride,
  bool legacySource = false,
}) async {
  final root = await Directory.systemTemp.createTemp(
    'nsoalbum-4b2-fault-source-',
  );
  final sourceLibrary = await native.deviceSyncOpenLibrary(
    libraryRoot: root.path,
  );
  final invitation = await native.deviceSyncHost(
    library_: sourceLibrary.handle,
    name: 'Source',
    tcpAddress: '127.0.0.1:1',
  );
  final host = invitation.handle;
  final phone = await native.deviceSyncClient(
    library_: targetLibrary,
    invitation: invitation.invitation,
    name: 'Target',
  );
  for (var n = 0; n < 40; n++) {
    await pump(host, phone);
  }
  expect(
    await native.deviceSyncConfirmationCode(endpoint: host),
    await native.deviceSyncConfirmationCode(endpoint: phone),
  );
  await native.deviceSyncConfirm(endpoint: host);
  await native.deviceSyncConfirm(endpoint: phone);
  for (var n = 0; n < 20; n++) {
    await pump(host, phone);
  }
  final storage = storageOverride ?? FaultAccountStorage();
  final source = DeviceAccountCoordinator(
    library: sourceLibrary.handle,
    storage: MemoryAccountStorage(
      values: {
        accountTokensKey: '{"a":"synthetic-new"}',
        accountProfilesKey: '{"a":{"nickname":"Alice"}}',
      },
    ),
    gate: AccountWorkGate(),
    invalidate: (_) async {},
    publish: (_) {},
  );
  final target = DeviceAccountCoordinator(
    library: targetLibrary,
    storage: storage,
    gate: AccountWorkGate(),
    invalidate: (_) async {},
    publish: (_) {},
  );
  if (legacySource) {
    // Simulate the exact canonical v1 bytes emitted by the previous client.
    const legacy =
        '{"version":1,"accounts":[{"account_id":"a","nickname":"Alice","session_token":"synthetic-new"}]}';
    final snapshot = await AccountSnapshot.read(
      source.storage,
      authorized: true,
    );
    await native.deviceSyncExportAccounts(
      endpoint: host,
      payload: Uint8List.fromList(utf8.encode(legacy)),
      stateDigest: snapshot.digest,
    );
  } else {
    await source.authorizeSource(host, authorized: true);
  }
  await target.authorizeTarget(phone, authorized: true);
  await native.deviceSyncConfigure(
    endpoint: host,
    phoneToDesktop: false,
    overwrite: true,
    includeAccounts: true,
  );
  final approvalDeadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(approvalDeadline)) {
    await pump(host, phone);
    if ((await native.deviceSyncStatus(endpoint: phone)).state ==
        'AwaitingApproval') {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(
    (await native.deviceSyncStatus(endpoint: phone)).state,
    'AwaitingApproval',
    reason:
        'Wait for asynchronous snapshot scanning before binding the preview.',
  );
  final preview = await target.preview(phone);
  return _Attempt(
    root,
    sourceLibrary.handle,
    host,
    phone,
    source,
    target,
    storage,
    preview,
  );
}

Future<void> verifyVersionOneAccountPreview(String targetLibrary) async {
  final cleanup = <Future<void>>[];
  final attempt = await _prepare(targetLibrary, legacySource: true);
  try {
    final bytes = await native.deviceSyncAccountPayload(
      endpoint: attempt.phone,
    );
    expect(
      utf8.decode(bytes!),
      '{"version":1,"accounts":[{"account_id":"a","nickname":"Alice","session_token":"synthetic-new"}]}',
    );
    // Receiving a legacy preview must not mutate any protected key.
    _expectActive(attempt.storage, _old);
    await attempt.target.abort(attempt.phone);
    _expectActive(attempt.storage, _old);
    debugPrintSynchronously(
      '4B2 real Bridge legacy v1 canonical bytes and read-only account preview passed',
    );
  } finally {
    await _close(attempt, cleanup);
    await Future.wait(cleanup);
  }
}

class _PausedCandidateStorage extends FaultAccountStorage {
  final started = Completer<void>();
  final release = Completer<void>();
  bool pause = false;
  @override
  Future<void> write(String key, String value) async {
    if (pause && key == accountTokensKey && value == '{"a":"synthetic-new"}') {
      pause = false;
      started.complete();
      await release.future;
    }
    await super.write(key, value);
  }
}

Future<void> verifyAccountOwnerIsolation(String targetLibrary) async {
  final storage = _PausedCandidateStorage();
  final attempt = await _prepare(targetLibrary, storageOverride: storage);
  final normalStarted = Completer<void>();
  final normalRelease = Completer<void>();
  Future<Object?>? applying;
  Future<void>? aborting;
  Future<void>? duplicateAbort;
  final normal = attempt.target.gate.normal(() async {
    normalStarted.complete();
    await normalRelease.future;
  });
  try {
    await normalStarted.future;
    expect(
      (await attempt.target.recoverStartup()).status,
      'busy',
      reason: 'recovery admission must reject an already admitted normal account job',
    );
    normalRelease.complete();
    await normal;
    await attempt.target.approve(attempt.preview, authorized: true);
    await _reachPending(attempt);
    storage.pause = true;
    applying = attempt.target
        .applyPending(attempt.phone)
        .then<Object?>(
          (result) => result,
          onError: (Object error, StackTrace _) => error,
        );
    await storage.started.future;
    await expectLater(
      attempt.target.applyPending(attempt.phone),
      throwsA(isA<DeviceSyncBusy>()),
    );
    var aborted = false;
    aborting = attempt.target.abort(attempt.phone).then((_) {
      aborted = true;
    });
    duplicateAbort = attempt.target.abort(attempt.phone);
    final other = DeviceAccountCoordinator(
      library: targetLibrary,
      storage: storage,
      gate: attempt.target.gate,
      invalidate: (_) async {},
      publish: (_) {},
    );
    expect((await other.recoverStartup()).status, 'busy');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(aborted, isFalse);
    expect(attempt.target.gate.busy, isTrue);
    expect(
      (await native.deviceSyncJournal(
        library_: targetLibrary,
        operation: attempt.preview.operation,
      ))!.stage,
      'library_applied',
    );
    storage.release.complete();
    await applying;
    await aborting;
    await duplicateAbort;
    _expectActive(storage, _old);
    expect(await native.listTags(), ['old library']);
    expect(
      (await native.deviceSyncJournal(
        library_: targetLibrary,
        operation: attempt.preview.operation,
      ))!.stage,
      'rolled_back',
    );
    expect(attempt.target.gate.busy, isFalse);
    debugPrintSynchronously(
      '4B2 fix I1 actual in-flight write, duplicate apply/abort, normal-job and fresh-coordinator recovery admission stayed owned until exact compensation',
    );
  } finally {
    if (!normalRelease.isCompleted) normalRelease.complete();
    if (!storage.release.isCompleted) storage.release.complete();
    await normal;
    await applying;
    await aborting;
    await duplicateAbort;
    await native.deviceSyncShutdown(endpoint: attempt.phone);
    await native.deviceSyncShutdown(endpoint: attempt.host);
    await attempt.source.releaseSource(attempt.host);
    await native.deviceSyncCloseEndpoint(endpoint: attempt.phone);
    await native.deviceSyncCloseEndpoint(endpoint: attempt.host);
    await native.deviceSyncCloseLibrary(library_: attempt.sourceLibrary);
    debugPrintSynchronously(
      'Synthetic fix1 ownership source retained: ${attempt.root.path}',
    );
  }
}

Future<void> verifyRestorePreviewBinding(
  DeviceAccountCoordinator coordinator,
  MemoryAccountStorage storage,
  String library,
  String backup,
) async {
  final observations = <Map<String, bool>>[];
  for (final accounts in [false, true]) {
    // This is the preview the caller has actually displayed before confirming.
    final shown = await coordinator.previewRestore(
      backup,
      accountsAuthorized: true,
    );
    try {
      if (accounts) {
        await coordinator.gate.normal(() async {
          await storage.write(
            accountTokensKey,
            '{"z":"synthetic-legitimate-after-preview"}',
          );
          await storage.write(selectedAccountKey, 'z');
        });
      } else {
        await native.createTag(name: 'legitimate after restore preview');
      }
      final generation = (await native.deviceSyncLibraryInfo(library_: library))
          .generation;
      final active = {
        for (final key in accountActiveKeys) key: storage.values[key],
      };
      final index = storage.values[accountCoordinationIndexKey];
      final allKeys = Map<String, String>.of(storage.values);
      var rejected = false;
      try {
        await coordinator.confirmRestore(shown, authorized: true);
      } on AccountPreviewChanged {
        rejected = true;
      }
      final observed = {
        'rejected': rejected,
        'libraryUnchanged':
            (await native.deviceSyncLibraryInfo(library_: library))
                .generation ==
            generation,
        'activeUnchanged': accountActiveKeys.every(
          (key) => storage.values[key] == active[key],
        ),
        'indexUnchanged': storage.values[accountCoordinationIndexKey] == index,
        'noMaterialWrite': mapEquals(storage.values, allKeys),
        'noJournal':
            await native.deviceSyncJournal(
              library_: library,
              operation: shown.operation,
            ) ==
            null,
      };
      observations.add(observed);
      debugPrintSynchronously(
        '4B2 I4 displayed ${accounts ? 'account' : 'library'} preview confirmation: $observed',
      );
    } finally {
      await coordinator.discardRestorePreview(shown);
    }
  }
  expect(observations, [
    for (var n = 0; n < 2; n++)
      {
        'rejected': true,
        'libraryUnchanged': true,
        'activeUnchanged': true,
        'indexUnchanged': true,
        'noMaterialWrite': true,
        'noJournal': true,
      },
  ]);
}

Future<void> _reachPending(_Attempt attempt) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    await pump(attempt.host, attempt.phone);
    if ((await native.deviceSyncStatus(endpoint: attempt.phone)).state ==
        'AwaitingTargetAccountFinal') {
      await attempt.target.authorizeFinalTarget(attempt.phone);
    }
    if ((await native.deviceSyncStatus(endpoint: attempt.host)).state ==
        'AwaitingAccountFinal') {
      await attempt.source.authorizeFinalSource(attempt.host);
    }
    if ((await native.deviceSyncStatus(endpoint: attempt.phone)).state ==
        'AwaitingExternal') {
      return;
    }
  }
  fail('actual Rust LibraryAppliedPending was not reached');
}

/// Runtime cancellation keeps the original owner and its unresolved permit.
Future<void> verifySameOwnerAbortCompensationRetry(String targetLibrary) async {
  final storage = _RecoveryRetryStorage();
  final attempt = await _prepare(targetLibrary, storageOverride: storage);
  try {
    await attempt.target.approve(attempt.preview, authorized: true);
    await _reachPending(attempt);
    expect(
      (await attempt.source.recoverStartup()).status,
      'busy',
      reason: 'A source permission is not an owned pending target permit.',
    );
    attempt.storage
      ..failMutation = 1
      ..armed = true;
    await expectLater(
      attempt.target.abort(attempt.phone),
      throwsA(isA<AccountRecoveryRequired>()),
    );
    expect(attempt.storage.consumed, isTrue);
    expect(attempt.target.gate.busy, isTrue);
    expect(
      (await native.deviceSyncLibraryInfo(library_: targetLibrary))
          .pendingOperation,
      attempt.preview.operation,
    );
    attempt.storage.armed = false;
    storage.pauseNext = true;
    final restoring = attempt.target.recoverStartup();
    await storage.started.future.timeout(const Duration(seconds: 10));
    expect((await attempt.target.recoverStartup()).status, 'busy');
    final unrelated = DeviceAccountCoordinator(
      library: targetLibrary,
      storage: storage,
      gate: attempt.target.gate,
      invalidate: (_) async {},
      publish: (_) {},
    );
    expect((await unrelated.recoverStartup()).status, 'busy');
    expect(attempt.target.gate.normalPermit, throwsA(isA<DeviceSyncBusy>()));
    storage.release.complete();
    final restored = await restoring;
    expect(
      restored.status,
      'ready',
      reason: 'The original unresolved permit cannot deadlock its own retry.',
    );
    _expectActive(attempt.storage, _old);
    expect(await native.listTags(), ['old library']);
    expect(attempt.target.gate.busy, isFalse);
    expect(
      (await native.deviceSyncJournal(
        library_: targetLibrary,
        operation: attempt.preview.operation,
      ))!.stage,
      'rolled_back',
    );
  } finally {
    if (!storage.release.isCompleted) storage.release.complete();
    await native.deviceSyncShutdown(endpoint: attempt.phone);
    await native.deviceSyncShutdown(endpoint: attempt.host);
    await attempt.source.releaseSource(attempt.host);
    await native.deviceSyncCloseEndpoint(endpoint: attempt.phone);
    await native.deviceSyncCloseEndpoint(endpoint: attempt.host);
    await native.deviceSyncCloseLibrary(library_: attempt.sourceLibrary);
  }
}

class _RecoveryRetryStorage extends FaultAccountStorage {
  bool pauseNext = false;
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write(String key, String value) async {
    if (pauseNext && key == legacySessionKey) {
      pauseNext = false;
      started.complete();
      await release.future;
    }
    return super.write(key, value);
  }
}

Future<void> _close(_Attempt attempt, List<Future<void>> cleanup) async {
  await native.deviceSyncShutdown(endpoint: attempt.phone);
  await native.deviceSyncShutdown(endpoint: attempt.host);
  await native.deviceSyncCloseEndpoint(endpoint: attempt.phone);
  await native.deviceSyncCloseLibrary(library_: attempt.sourceLibrary);
  cleanup.add(() async {
    await attempt.source.releaseSource(attempt.host);
    await native.deviceSyncCloseEndpoint(endpoint: attempt.host);
    try {
      await attempt.root.delete(recursive: true);
    } on FileSystemException catch (error) {
      if (!Platform.isWindows || error.osError?.errorCode != 32) rethrow;
      debugPrintSynchronously(
        'Synthetic TEMP retained until test process exit: ${attempt.root.path}',
      );
    }
  }());
}

void _expectActive(FaultAccountStorage storage, Map<String, String> expected) {
  expect(
    {for (final key in accountActiveKeys) key: storage.values[key]},
    {for (final key in accountActiveKeys) key: expected[key]},
  );
}

/// Actual endpoint/SQLite/journal on every case; only the OS key boundary fails.
Future<String> runSecureStoreFaultMatrix(
  String targetLibrary,
  String targetRoot,
) async {
  final cleanup = <Future<void>>[];
  try {
    final cases = [
      for (var n = 1; n <= 8; n++)
        for (final after in [false, true])
          (mutation: n, after: after, read: null as int?),
      for (var n = 1; n <= 8; n++)
        (mutation: null as int?, after: false, read: n),
    ];
    for (var index = 0; index < cases.length; index++) {
      final scenario = cases[index];
      if ((await native.listTags()).isEmpty) {
        await native.createTag(name: 'old library');
      }
      final attempt = await _prepare(targetLibrary);
      attempt.storage
        ..failMutation = scenario.mutation
        ..afterWrite = scenario.after
        ..mismatchRead = scenario.read
        ..armed = true;
      AccountApplyResult? result;
      Object? failure;
      try {
        await attempt.target.approve(attempt.preview, authorized: true);
        await _reachPending(attempt);
        result = await attempt.target.applyPending(attempt.phone);
      } catch (error) {
        failure = error;
      }
      try {
        expect(
          attempt.storage.consumed,
          isTrue,
          reason: 'fault ${index + 1} must be reached',
        );
        final journal = await native.deviceSyncJournal(
          library_: targetLibrary,
          operation: attempt.preview.operation,
        );
        if (journal?.stage == 'finalized') {
          expect(result?.finalized, isTrue);
          expect(result?.cleanupPending, isTrue);
          _expectActive(attempt.storage, _candidate);
          expect(await native.listTags(), isEmpty);
          final restarted = DeviceAccountCoordinator(
            library: targetLibrary,
            storage: attempt.storage,
            gate: AccountWorkGate(),
            invalidate: (_) async {},
            publish: (_) {},
          );
          expect((await restarted.recoverStartup()).ready, isTrue);
          _expectActive(attempt.storage, _candidate);
          final restore = await attempt.target.previewRestore(
            journal!.backup,
            accountsAuthorized: true,
          );
          await attempt.target.confirmRestore(restore, authorized: true);
        } else {
          expect(failure, isNotNull);
          await native.deviceSyncShutdown(endpoint: attempt.phone);
          final restarted = DeviceAccountCoordinator(
            library: targetLibrary,
            storage: attempt.storage,
            gate: AccountWorkGate(),
            invalidate: (_) async {},
            publish: (_) {},
          );
          expect((await restarted.recoverStartup()).ready, isTrue);
          final recovered = await native.deviceSyncJournal(
            library_: targetLibrary,
            operation: attempt.preview.operation,
          );
          expect(recovered == null || recovered.stage == 'rolled_back', isTrue);
          if (recovered != null) {
            final beforeReads = Map<String, String>.of(attempt.storage.values);
            final page = await native.deviceSyncReadBackups(
              library_: targetLibrary,
              limit: BigInt.from(128),
            );
            expect(page.error, isNull);
            final original = page.value!.items.singleWhere(
              (item) => item.backup == recovered.backup,
            );
            expect(original.unavailableReason, isNull);
            expect(original.includesAccounts, isTrue);
            final internal = page.value!.items.where(
              (item) =>
                  item.unavailableReason ==
                  read.BackupUnavailableReason.internalCompensation,
            );
            expect(internal, isNotEmpty);
            for (final backup in internal) {
              expect(backup.includesAccounts, isNull);
            }
            await expectLater(
              native.deviceSyncPreviewRestore(
                library_: targetLibrary,
                backup: internal.last.backup!,
              ),
              throwsA(anything),
            );
            expect(attempt.storage.values, beforeReads);
          }
        }
        _expectActive(
          attempt.storage,
          journal?.stage == 'finalized'
              ? {
                  ..._old,
                  // An explicit successful restore reverts credentials while
                  // retaining names learned from the completed account apply.
                  accountProfilesKey: '{"a":{"nickname":"Alice"}}',
                }
              : _old,
        );
        expect(await native.listTags(), ['old library']);
        expect(
          (await native.deviceSyncLibraryInfo(library_: targetLibrary))
              .pendingOperation,
          isNull,
        );
        debugPrintSynchronously(
          '4B2 real Bridge fault ${index + 1}/${cases.length}: mutation=${scenario.mutation} after=${scenario.after} readback=${scenario.read}; actual keys/library/journal consistent',
        );
      } finally {
        await _close(attempt, cleanup);
      }
      if ((index + 1) % 8 == 0) {
        await Future.wait(cleanup);
        cleanup.clear();
      }
    }
    // Leave a real unresolved journal by failing both a candidate write and its
    // first compensation, then reconstruct both Dart coordinator and CoreApi.
    final restart = await _prepare(targetLibrary);
    restart.storage
      ..failMutation = 5
      ..failCompensation = true
      ..armed = true;
    await restart.target.approve(restart.preview, authorized: true);
    await _reachPending(restart);
    await expectLater(
      restart.target.applyPending(restart.phone),
      throwsA(isA<AccountRecoveryRequired>()),
    );
    expect(restart.target.gate.busy, isTrue);
    expect(
      (await native.deviceSyncLibraryInfo(library_: targetLibrary))
          .pendingOperation,
      restart.preview.operation,
    );
    await native.deviceSyncShutdown(endpoint: restart.phone);
    await native.deviceSyncCloseLibrary(library_: targetLibrary);
    targetLibrary = (await native.deviceSyncOpenLibrary(
      libraryRoot: targetRoot,
    )).handle;
    final restoredCoordinator = DeviceAccountCoordinator(
      library: targetLibrary,
      storage: restart.storage,
      gate: AccountWorkGate(),
      invalidate: (_) async {},
      publish: (_) {},
    );
    restart.storage.armed = false;
    final protectedIndex = jsonDecode(
      restart.storage.values[accountCoordinationIndexKey]!,
    ) as Map<String, dynamic>;
    final external = (protectedIndex['entries'] as List).last as String;
    final key = accountMaterialKey(external);
    final protectedMaterial = restart.storage.values.remove(key)!;
    expect(
      (await restoredCoordinator.recoverStartup()).status,
      'material_missing',
    );
    expect(restoredCoordinator.gate.busy, isTrue);
    expect(
      (await native.deviceSyncLibraryInfo(library_: targetLibrary))
          .pendingOperation,
      restart.preview.operation,
    );
    restart.storage.values[key] = protectedMaterial;
    expect((await restoredCoordinator.recoverStartup()).ready, isTrue);
    _expectActive(restart.storage, _old);
    expect(await native.listTags(), ['old library']);
    expect(
      (await native.deviceSyncJournal(
        library_: targetLibrary,
        operation: restart.preview.operation,
      ))!.stage,
      'rolled_back',
    );
    debugPrintSynchronously(
      '4B2 real Bridge compensation-failure restart: fresh CoreApi/journal and Dart coordinator restored exact old four-key missing state and old library',
    );
    await _close(restart, cleanup);
    // A legitimate normal account change during transmission cannot be erased
    // by an old preview or a no-journal "rollback".
    final changed = await _prepare(targetLibrary);
    await changed.target.approve(changed.preview, authorized: true);
    await changed.target.gate.normal(() async {
      await changed.storage.write(
        accountTokensKey,
        '{"z":"synthetic-user-change"}',
      );
      await changed.storage.write(selectedAccountKey, 'z');
    });
    for (var n = 0; n < 100; n++) {
      await pump(changed.host, changed.phone);
    }
    expect(
      (await native.deviceSyncStatus(endpoint: changed.phone)).state,
      'AwaitingTargetAccountFinal',
    );
    await expectLater(
      changed.target.authorizeFinalTarget(changed.phone),
      throwsA(isA<AccountPreviewChanged>()),
    );
    expect(
      await native.deviceSyncJournal(
        library_: targetLibrary,
        operation: changed.preview.operation,
      ),
      isNull,
    );
    await changed.target.abort(changed.phone);
    final fresh = DeviceAccountCoordinator(
      library: targetLibrary,
      storage: changed.storage,
      gate: AccountWorkGate(),
      invalidate: (_) async {},
      publish: (_) {},
    );
    expect((await fresh.recoverStartup()).ready, isTrue);
    expect(
      changed.storage.values[accountTokensKey],
      '{"z":"synthetic-user-change"}',
    );
    expect(changed.storage.values[selectedAccountKey], 'z');
    expect(await native.listTags(), ['old library']);
    debugPrintSynchronously(
      '4B2 real Bridge stale final target and no-journal cancellation/restart preserved legitimate transmission-time account edits',
    );
    await _close(changed, cleanup);
    return targetLibrary;
  } finally {
    await Future.wait(cleanup);
  }
}

Future<void> verifyLibraryOnlyBackupDoesNotReadAccounts(
  String targetLibrary,
) async {
  final root = await Directory.systemTemp.createTemp(
    'nsoalbum-4b2-library-only-',
  );
  final source = await native.deviceSyncOpenLibrary(libraryRoot: root.path);
  try {
    final invitation = await native.deviceSyncHost(
      library_: source.handle,
      name: 'Source',
      tcpAddress: '127.0.0.1:1',
    );
    final phone = await native.deviceSyncClient(
      library_: targetLibrary,
      invitation: invitation.invitation,
      name: 'Target',
    );
    try {
      for (var n = 0; n < 40; n++) {
        await pump(invitation.handle, phone);
      }
      await native.deviceSyncConfirm(endpoint: invitation.handle);
      await native.deviceSyncConfirm(endpoint: phone);
      for (var n = 0; n < 20; n++) {
        await pump(invitation.handle, phone);
      }
      await native.deviceSyncConfigure(
        endpoint: invitation.handle,
        phoneToDesktop: false,
        overwrite: true,
        includeAccounts: false,
      );
      final approvalDeadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(approvalDeadline)) {
        await pump(invitation.handle, phone);
        if ((await native.deviceSyncStatus(endpoint: phone)).state ==
            'AwaitingApproval') {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        (await native.deviceSyncStatus(endpoint: phone)).state,
        'AwaitingApproval',
      );
      await native.deviceSyncApprove(endpoint: phone);
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        await pump(invitation.handle, phone);
        if ((await native.deviceSyncStatus(endpoint: invitation.handle))
                .state ==
            'Completed') {
          break;
        }
      }
      final status = await native.deviceSyncStatus(endpoint: phone);
      expect(status.state, 'Completed');
      final storage = MemoryAccountStorage()..denyReads = true;
      final coordinator = DeviceAccountCoordinator(
        library: targetLibrary,
        storage: storage,
        gate: AccountWorkGate(),
        invalidate: (_) async {
          fail('library-only restore must not invalidate accounts');
        },
        publish: (_) {
          fail('library-only restore must not publish accounts');
        },
      );
      final preview = await coordinator.previewRestore(status.backup!);
      expect(preview.includesAccounts, isFalse);
      expect(preview.targetAccountDigest, isNull);
      expect(
        (await coordinator.confirmRestore(preview, authorized: true)).finalized,
        isTrue,
      );
      expect(await native.listTags(), ['old library']);
      debugPrintSynchronously(
        '4B2 real Bridge library-only backup restore completed with every protected-store read forbidden',
      );
    } finally {
      await native.deviceSyncCloseEndpoint(endpoint: phone);
      await native.deviceSyncCloseEndpoint(endpoint: invitation.handle);
    }
  } finally {
    await native.deviceSyncCloseLibrary(library_: source.handle);
    await root.delete(recursive: true);
  }
}
