import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:async';

import '../../rust/bridge.dart' as native;
import '../../rust/device_sync/headless.dart';
import '../../rust/device_sync/read_model.dart' as read;
import 'account_gate.dart';
import 'account_storage.dart';
import 'command_admission.dart';

const accountCoordinationIndexKey = 'nintendo.device_sync.index.v1';
const _maxMaterials = 128;
const _maxMaterialBytes = 32 * 1024 * 1024;
const _maxRestorePreviews = 16;
String accountMaterialKey(String external) =>
    'nintendo.device_sync.$external.v1';

class AccountPreviewChanged implements Exception {
  @override
  String toString() => 'The confirmed account or library preview changed';
}

class AccountRecoveryRequired implements Exception {
  AccountRecoveryRequired(this.code);
  final String code;
  @override
  String toString() => 'Account recovery is required ($code)';
}

class AccountStorageFailure implements Exception {
  @override
  String toString() => 'Protected account storage could not be verified';
}

class AccountApplyResult {
  const AccountApplyResult({
    required this.finalized,
    this.cleanupPending = false,
  });
  final bool finalized;
  final bool cleanupPending;
}

class AccountRecoveryState {
  const AccountRecoveryState(this.status, {this.operation});
  final String status;
  final String? operation;
  bool get ready => status == 'ready';
}

class AccountPreview {
  AccountPreview._(
    this.endpoint,
    this.session,
    this.operation,
    this.library,
    this.binding,
    this.change,
  );
  final String endpoint, session, operation, library, binding;
  final AccountChange change;
}

/// A single-use confirmation capability for the exact state shown to the user.
/// Discard it when its UI closes; a changed state requires another preview.
class AccountRestorePreview {
  AccountRestorePreview._(
    this.backup,
    this._native,
    this._selected,
    this.change,
  );
  final String backup;
  final RestoreInfo _native;
  final _Material? _selected;
  final AccountChange? change;
  String get operation => _native.operation;
  String get library => _native.library_;
  String get binding => _native.binding;
  String get currentLibraryDigest => _native.currentDigest;
  String get restoredLibraryDigest => _native.restoredDigest;
  String? get targetAccountDigest => change?.before.digest;
  String? get restoredAccountDigest =>
      _selected == null ? null : rawAccountDigest(_selected.old);
  bool get includesAccounts => _selected != null;
  @override
  String toString() => 'AccountRestorePreview([REDACTED])';
}

class _Material {
  _Material({
    required this.external,
    required this.library,
    required this.operation,
    required this.old,
    required this.candidate,
    required this.binding,
    this.stage = 'prepared',
    this.backup,
  });
  final String external, library, operation, binding;
  final Map<String, String?> old, candidate;
  String stage;
  String? backup;
  final switchSequence = DeviceCommandSequence();
  Map<String, dynamic> json() => {
    'version': 1,
    'external': external,
    'library': library,
    'operation': operation,
    'binding': binding,
    'stage': stage,
    'backup': backup,
    'old': old,
    'candidate': candidate,
  };
}

class _Pending {
  _Pending(this.material);
  final _Material material;
  DeviceAccountPermit? permit;
  bool reserved = false;
}

/// The only replaceable boundary is OS secure storage. Rust calls below always
/// use the generated FRB and its real journal/library services.
class DeviceAccountCoordinator {
  DeviceAccountCoordinator({
    required this.library,
    required this.storage,
    required this.gate,
    required this.invalidate,
    required this.publish,
  });
  final String library;
  final AccountSecureStorage storage;
  final AccountWorkGate gate;
  final Future<void> Function(Set<String>) invalidate;
  final void Function(Set<String>) publish;
  final _sources = <String, AccountSnapshot>{};
  final _targets = <String, AccountSnapshot>{};
  final _sourcePermits = <String, DeviceAccountPermit>{};
  final _pending = <String, _Pending>{};
  final _restorePreviews = <AccountRestorePreview>{};
  // Confirmation eligibility is single-use. Retirement ownership survives
  // consuming it, failed discard and failed reads until exact native success.
  final _restoreRetirements =
      Map<AccountRestorePreview, Future<void>?>.identity();
  bool get restorePreviewsSettled => _restoreRetirements.isEmpty;
  String? _activeRestore;
  bool _restoreCancelled = false;
  Future<void>? _driving;
  final _aborting = <String, Future<void>>{};
  Future<T> _command<T>(String endpoint, Future<T> Function() action) =>
      admittedDeviceCommand(
        action,
        cancelled: () => _aborting.containsKey(endpoint),
      );

  Future<T> _drive<T>(Future<T> Function() action, {String? endpoint}) {
    if (_driving != null ||
        (endpoint != null && _aborting.containsKey(endpoint))) {
      return Future<T>.error(const DeviceSyncBusy());
    }
    final done = Completer<void>();
    _driving = done.future;
    return Future<T>.sync(action).whenComplete(() {
      _driving = null;
      done.complete();
    });
  }

  Future<void> authorizeSource(
    String endpoint, {
    required bool authorized,
  }) async {
    if (!authorized) throw AccountConsentRequired();
    final permit = gate.device();
    try {
      final snapshot = await AccountSnapshot.read(storage, authorized: true);
      await _command(
        endpoint,
        () => native.deviceSyncExportAccounts(
          endpoint: endpoint,
          payload: Uint8List.fromList(utf8.encode(snapshot.payload.toJson())),
          stateDigest: snapshot.digest,
        ),
      );
      _sources[endpoint] = snapshot;
    } finally {
      permit.release();
    }
  }

  Future<void> authorizeTarget(
    String endpoint, {
    required bool authorized,
  }) async {
    if (!authorized) throw AccountConsentRequired();
    final permit = gate.device();
    try {
      final snapshot = await AccountSnapshot.read(storage, authorized: true);
      await _command(
        endpoint,
        () => native.deviceSyncReceiveAccounts(
          endpoint: endpoint,
          stateDigest: snapshot.digest,
        ),
      );
      _targets[endpoint] = snapshot;
    } finally {
      permit.release();
    }
  }

  Future<void> decline(String endpoint) async {
    await _command(
      endpoint,
      () => native.deviceSyncDeclineAccounts(endpoint: endpoint),
    );
    _sources.remove(endpoint);
    _targets.remove(endpoint);
  }

  Future<AccountPreview> preview(String endpoint) async {
    final target = _targets[endpoint];
    if (target == null) throw AccountConsentRequired();
    final permit = gate.device();
    try {
      final status = await native.deviceSyncStatus(endpoint: endpoint);
      if (status.state != 'AwaitingApproval' ||
          !status.includeAccounts ||
          status.source ||
          status.operation == null ||
          status.binding == null ||
          status.targetLibrary == null ||
          rawAccountDigest(await readRawAccountKeys(storage)) !=
              target.digest) {
        throw AccountPreviewChanged();
      }
      final bytes = await _command(
        endpoint,
        () => native.deviceSyncAccountPayload(endpoint: endpoint),
      );
      if (bytes == null) throw AccountPreviewChanged();
      final incoming = AccountPayload.parse(utf8.decode(bytes));
      return AccountPreview._(
        endpoint,
        status.session,
        status.operation!,
        status.targetLibrary!,
        status.binding!,
        AccountChange.preview(target, incoming, overwrite: status.overwrite),
      );
    } finally {
      permit.release();
    }
  }

  Future<void> approve(
    AccountPreview preview, {
    required bool authorized,
  }) async {
    if (!authorized) throw AccountConsentRequired();
    if (_pending.containsKey(preview.endpoint)) throw AccountPreviewChanged();
    final permit = gate.device();
    try {
      final status = await native.deviceSyncStatus(endpoint: preview.endpoint);
      if (status.state != 'AwaitingApproval' ||
          status.session != preview.session ||
          status.operation != preview.operation ||
          status.binding != preview.binding ||
          status.targetLibrary != preview.library ||
          !status.includeAccounts ||
          rawAccountDigest(await readRawAccountKeys(storage)) !=
              preview.change.before.digest) {
        throw AccountPreviewChanged();
      }
      final material = _Material(
        external: _uuid(),
        library: preview.library,
        operation: preview.operation,
        old: preview.change.before.raw,
        candidate: preview.change.candidate,
        binding: preview.binding,
      );
      await _command(
        preview.endpoint,
        () => native.deviceSyncApproveAccounts(
          endpoint: preview.endpoint,
          binding: preview.binding,
          stateDigest: preview.change.before.digest,
          external_: material.external,
        ),
      );
      _pending[preview.endpoint] = _Pending(material);
    } catch (error) {
      if (error is! AccountPreviewChanged &&
          error is! AccountConsentRequired &&
          error is! DeviceSyncBusy) {
        gate.holdRecovery();
      }
      rethrow;
    } finally {
      permit.release();
    }
  }

  Future<void> authorizeFinalTarget(String endpoint) =>
      _drive(() => _authorizeFinalTarget(endpoint), endpoint: endpoint);

  Future<void> _authorizeFinalTarget(String endpoint) async {
    final pending = _pending[endpoint];
    if (pending == null || pending.permit != null) {
      throw AccountPreviewChanged();
    }
    final permit = gate.device();
    var retained = false;
    try {
      final status = await native.deviceSyncStatus(endpoint: endpoint);
      if (status.state != 'AwaitingTargetAccountFinal' ||
          status.operation != pending.material.operation ||
          status.binding != pending.material.binding ||
          rawAccountDigest(await readRawAccountKeys(storage)) !=
              rawAccountDigest(pending.material.old)) {
        throw AccountPreviewChanged();
      }
      if (!pending.reserved) {
        await _reserve(pending.material);
        pending.reserved = true;
      }
      await _command(
        endpoint,
        () => native.deviceSyncTargetFinal(
          endpoint: endpoint,
          stateDigest: rawAccountDigest(pending.material.old),
        ),
      );
      pending.permit = permit;
      retained = true;
    } catch (error) {
      if (error is! AccountPreviewChanged && error is! DeviceSyncBusy) {
        gate.holdRecovery();
      }
      rethrow;
    } finally {
      if (!retained) permit.release();
    }
  }

  Future<void> authorizeFinalSource(String endpoint) async {
    final before = _sources[endpoint];
    if (before == null || _sourcePermits.containsKey(endpoint)) {
      throw AccountPreviewChanged();
    }
    final permit = gate.device();
    var retained = false;
    try {
      final current = rawAccountDigest(await readRawAccountKeys(storage));
      if (current != before.digest) throw AccountPreviewChanged();
      await _command(
        endpoint,
        () => native.deviceSyncSourceFinal(
          endpoint: endpoint,
          stateDigest: current,
        ),
      );
      _sourcePermits[endpoint] = permit;
      retained = true;
    } finally {
      if (!retained) permit.release();
    }
  }

  Future<void> releaseSource(String endpoint) async {
    var status = await native.deviceSyncStatus(endpoint: endpoint);
    if (!status.terminal) throw const DeviceSyncBusy();
    while (status.cleanupPending) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      status = await native.deviceSyncStatus(endpoint: endpoint);
    }
    _sourcePermits.remove(endpoint)?.release();
    _sources.remove(endpoint);
  }

  Future<AccountApplyResult> applyPending(String endpoint) =>
      _drive(() => _applyPending(endpoint), endpoint: endpoint);

  Future<AccountApplyResult> _applyPending(String endpoint) async {
    final pending = _pending[endpoint];
    if (pending == null || pending.permit == null) {
      throw AccountPreviewChanged();
    }
    final material = pending.material;
    var suspended = false;
    try {
      final status = await native.deviceSyncStatus(endpoint: endpoint);
      if (status.state != 'AwaitingExternal' ||
          status.operation != material.operation ||
          status.binding != material.binding ||
          status.backup == null) {
        throw AccountPreviewChanged();
      }
      return await _switch(
        material,
        status.backup!,
        check: () => _command(
          endpoint,
          () => native.deviceSyncExternalCheck(endpoint: endpoint),
        ),
        step: () => _command(
          endpoint,
          () => native.deviceSyncExternalStep(endpoint: endpoint),
        ),
        finalize: () => _command(
          endpoint,
          () => native.deviceSyncFinalizeAccounts(
            endpoint: endpoint,
            external_: material.external,
          ),
        ),
      );
    } on DeviceCommandBusy {
      // Only definitely unexecuted native admission can suspend this sequence.
      // Earlier OS writes remain protected by the same pending permit/journal.
      suspended = true;
      rethrow;
    } catch (error) {
      gate.holdRecovery();
      await native.deviceSyncCancelSignal(endpoint: endpoint);
      await native.deviceSyncShutdown(endpoint: endpoint);
      final journal = await native.deviceSyncJournal(
        library_: library,
        operation: material.operation,
      );
      if (journal?.stage == 'finalized') {
        publish(_ids(material.candidate));
        gate.resolveRecovery();
        return const AccountApplyResult(finalized: true, cleanupPending: true);
      }
      final state = await _recoverOwned(pending.permit!);
      if (!state.ready) throw AccountRecoveryRequired(state.status);
      rethrow;
    } finally {
      if (!suspended) {
        _pending.remove(endpoint)?.permit?.release();
        _targets.remove(endpoint);
      }
    }
  }

  Future<AccountApplyResult> _switch(
    _Material material,
    String backup, {
    required Future<void> Function() check,
    required Future<void> Function() step,
    required Future<void> Function() finalize,
  }) async {
    final journal = await native.deviceSyncJournal(
      library_: library,
      operation: material.operation,
    );
    if (journal?.stage != 'library_applied' ||
        journal?.external_ != material.external ||
        journal?.library_ != material.library ||
        journal?.backup != backup) {
      throw AccountRecoveryRequired('journal_mismatch');
    }
    final actions = <Future<void> Function()>[
      check,
      () async {
        material.stage = 'library_applied';
        material.backup = backup;
        await _save(material);
      },
      check,
      step,
    ];
    for (final key in accountActiveKeys) {
      actions.addAll([
        check,
        () => _writeVerified(key, material.candidate[key]),
        check,
        step,
      ]);
    }
    actions.addAll([
      check,
      () => invalidate({..._ids(material.old), ..._ids(material.candidate)}),
      check,
      step,
      () async {
        if (rawAccountDigest(await readRawAccountKeys(storage)) !=
            rawAccountDigest(material.candidate)) {
          throw AccountStorageFailure();
        }
      },
      check,
      finalize,
    ]);
    await material.switchSequence.run(actions);
    // Only the real journal's finalized state grants success. Archive cleanup
    // failure afterward cannot roll back an already committed operation.
    final committed = await native.deviceSyncJournal(
      library_: library,
      operation: material.operation,
    );
    if (committed?.stage != 'finalized') {
      throw AccountRecoveryRequired('not_finalized');
    }
    publish(_ids(material.candidate));
    material.stage = 'finalized';
    try {
      await _save(material);
      return const AccountApplyResult(finalized: true);
    } catch (_) {
      return const AccountApplyResult(finalized: true, cleanupPending: true);
    }
  }

  Future<void> abort(String endpoint) {
    final existing = _aborting[endpoint];
    if (existing != null) return existing;
    final aborting = _abortEndpoint(endpoint).whenComplete(() {
      _aborting.remove(endpoint);
    });
    _aborting[endpoint] = aborting;
    return aborting;
  }

  Future<void> _abortEndpoint(String endpoint) async {
    await native.deviceSyncCancelSignal(endpoint: endpoint);
    // An already admitted OS write is not cancellable. Its single driver owns
    // compensation; do not race it with a second recovery or reopen the gate.
    await _driving;
    await native.deviceSyncShutdown(endpoint: endpoint);
    final pending = _pending[endpoint];
    if (pending != null) {
      final permit = pending.permit;
      final state = permit != null && gate.ownsDevice(permit)
          ? await _recoverOwned(permit)
          : await recoverStartup();
      if (!state.ready) throw AccountRecoveryRequired(state.status);
    }
    _pending.remove(endpoint)?.permit?.release();
    _targets.remove(endpoint);
    if (_sourcePermits.containsKey(endpoint)) await releaseSource(endpoint);
  }

  /// Task5 must call before settings/font compatibility writes, token getters,
  /// implicit migration or automatic NSO. Native library identity/journal FIRST.
  Future<AccountRecoveryState> recoverStartup() {
    if (_driving != null) {
      return Future.value(const AccountRecoveryState('busy'));
    }
    return _drive(() async {
      final owned = [
        for (final pending in _pending.values)
          if (pending.permit case final permit?)
            if (gate.ownsDevice(permit)) permit,
      ];
      if (owned.length == 1) {
        // A failed abort retains its own permit. Recovery must keep that
        // ownership until the original compensation proves both domains safe.
        return _recoverOwned(owned.single);
      }
      DeviceAccountPermit? permit;
      try {
        permit = gate.recoveryPermit();
        return await _recoverOwned(permit);
      } on DeviceSyncBusy {
        return const AccountRecoveryState('busy');
      } finally {
        permit?.release();
      }
    });
  }

  Future<AccountRecoveryState> _recoverOwned(DeviceAccountPermit permit) async {
    if (!gate.ownsDevice(permit)) {
      return const AccountRecoveryState('busy');
    }
    gate.holdRecovery();
    String? operation;
    try {
      final actual = await native.deviceSyncLibraryInfo(library_: library);
      operation = actual.pendingOperation;
      if (operation != null) {
        final journal = await native.deviceSyncJournal(
          library_: library,
          operation: operation,
        );
        if (journal == null) throw AccountRecoveryRequired('journal_missing');
        if (journal.external_ == null) {
          return AccountRecoveryState('library_pending', operation: operation);
        }
      }
      final index = await _index();
      final materials = <_Material>[];
      for (final external in index) {
        final material = await _load(external);
        if (material.library == actual.libraryUuid) materials.add(material);
      }
      if (operation != null &&
          !materials.any((m) => m.operation == operation)) {
        throw AccountRecoveryRequired('material_missing');
      }
      for (final material in materials) {
        final journal = await native.deviceSyncJournal(
          library_: library,
          operation: material.operation,
        );
        if (journal == null) {
          if (material.stage == 'rolled_back') continue;
          if (material.stage != 'prepared' ||
              rawAccountDigest(await readRawAccountKeys(storage)) !=
                  rawAccountDigest(material.old)) {
            throw AccountRecoveryRequired('orphan_state_unproven');
          }
          material.stage = 'rolled_back';
          await _save(material);
          continue; // A verified orphan never switched either active state.
        }
        if (journal.library_ != material.library ||
            journal.external_ != material.external) {
          throw AccountRecoveryRequired('journal_mismatch');
        }
        if (journal.stage == 'finalized' || journal.stage == 'rolled_back') {
          continue;
        }
        if (journal.stage != 'prepared' && journal.stage != 'library_applied') {
          throw AccountRecoveryRequired('journal_stage_unknown');
        }
        await invalidate({..._ids(material.old), ..._ids(material.candidate)});
        for (final key in accountActiveKeys) {
          await _writeVerified(key, material.old[key]);
        }
        if (rawAccountDigest(await readRawAccountKeys(storage)) !=
            rawAccountDigest(material.old)) {
          throw AccountStorageFailure();
        }
        await native.deviceSyncCompensate(
          library_: library,
          operation: material.operation,
        );
        material.stage = 'rolled_back';
        await _save(material);
        publish(_ids(material.old));
      }
      if ((await native.deviceSyncLibraryInfo(library_: library))
              .pendingOperation !=
          null) {
        throw AccountRecoveryRequired('library_pending');
      }
      for (final endpoint in _pending.keys.toList()) {
        _pending.remove(endpoint)?.permit?.release();
      }
      gate.resolveRecovery();
      return const AccountRecoveryState('ready');
    } catch (error) {
      return AccountRecoveryState(
        error is AccountRecoveryRequired
            ? error.code
            : 'protected_storage_unavailable',
        operation: operation,
      );
    }
  }

  Future<AccountRestorePreview> previewRestore(
    String backup, {
    bool accountsAuthorized = false,
  }) => _drive(
    () => _previewRestore(backup, accountsAuthorized: accountsAuthorized),
  );

  Future<AccountRestorePreview> _previewRestore(
    String backup, {
    required bool accountsAuthorized,
  }) async {
    if (_restoreRetirements.length >= _maxRestorePreviews) {
      throw const DeviceSyncBusy();
    }
    final permit = gate.device();
    AccountRestorePreview? opened;
    Object? originalFailure;
    StackTrace? originalStack;
    try {
      final actual = await native.deviceSyncLibraryInfo(library_: library);
      final ownership = await native.deviceSyncBackupJournal(
        library_: library,
        backup: backup,
      );
      if (ownership.library_ != actual.libraryUuid ||
          ownership.backup != backup ||
          (ownership.stage != 'finalized' &&
              ownership.stage != 'rolled_back')) {
        throw AccountRecoveryRequired('backup_ownership_unproven');
      }
      _Material? selected;
      final external = ownership.external_;
      if (external != null) {
        if (!accountsAuthorized) throw AccountConsentRequired();
        if (!(await _index()).contains(external)) {
          throw AccountRecoveryRequired('material_missing');
        }
        selected = await _load(external);
        if (selected.library != actual.libraryUuid ||
            selected.backup != backup ||
            selected.operation != ownership.operation) {
          throw AccountRecoveryRequired('backup_material_mismatch');
        }
      }
      final change = selected == null
          ? null
          : AccountChange.preview(
              AccountSnapshot.fromRaw(await readRawAccountKeys(storage)),
              AccountSnapshot.fromRaw(selected.old).payload,
              overwrite: true,
            );
      final info = await native.deviceSyncPreviewRestore(
        library_: library,
        backup: backup,
      );
      final preview = AccountRestorePreview._(backup, info, selected, change);
      opened = preview;
      _restoreRetirements[preview] = null;
      if (info.library_ != actual.libraryUuid) throw AccountPreviewChanged();
      _restorePreviews.add(preview);
      opened = null;
      return preview;
    } catch (failure, stack) {
      originalFailure = failure;
      originalStack = stack;
      rethrow;
    } finally {
      try {
        if (opened != null) {
          try {
            await discardRestorePreview(opened);
          } catch (_) {
            if (originalFailure != null) {
              Error.throwWithStackTrace(originalFailure, originalStack!);
            }
            rethrow;
          }
        }
      } finally {
        permit.release();
      }
    }
  }

  Future<void> discardRestorePreview(AccountRestorePreview preview) {
    _restorePreviews.remove(preview);
    if (!_restoreRetirements.containsKey(preview)) return Future.value();
    final current = _restoreRetirements[preview];
    if (current != null) return current;
    final done = Completer<void>();
    late final Future<void> flight;
    flight = done.future.whenComplete(() {
      if (identical(_restoreRetirements[preview], flight)) {
        _restoreRetirements[preview] = null;
      }
    });
    _restoreRetirements[preview] = flight;
    unawaited(
      () async {
        await native.deviceSyncCloseRestore(restore: preview._native.handle);
        if (identical(_restoreRetirements[preview], flight)) {
          _restoreRetirements.remove(preview);
        }
      }().then(done.complete, onError: done.completeError),
    );
    return flight;
  }

  /// Called only by explicit owner teardown after browser work has drained.
  Future<void> closeRestorePreviews() async {
    Object? first;
    StackTrace? firstStack;
    await Future.wait([
      for (final preview in _restoreRetirements.keys.toList())
        discardRestorePreview(preview)
            .catchError((Object failure, StackTrace stack) {
              first ??= failure;
              firstStack ??= stack;
            }),
    ]);
    if (first != null) Error.throwWithStackTrace(first!, firstStack!);
  }

  Future<read.RestoreSummaryRead> readRestoreSummary(
    AccountRestorePreview preview,
  ) async {
    const changed = read.RestoreSummaryRead(
      error: read.ReadError.previewChanged,
    );
    if (!_restorePreviews.contains(preview)) return changed;
    final result = await native.deviceSyncReadRestoreSummary(
      restore: preview._native.handle,
      binding: preview.binding,
    );
    if (!_restorePreviews.contains(preview)) return changed;
    final value = result.value;
    if (result.error == null &&
        (value == null ||
            value.binding != preview.binding ||
            value.currentDigest != preview.currentLibraryDigest ||
            value.restoredDigest != preview.restoredLibraryDigest ||
            value.includesAccounts != preview.includesAccounts)) {
      return changed;
    }
    return result;
  }

  Future<AccountApplyResult> confirmRestore(
    AccountRestorePreview preview, {
    required bool authorized,
  }) => _drive(() => _confirmRestore(preview, authorized: authorized));

  Future<AccountApplyResult> _confirmRestore(
    AccountRestorePreview preview, {
    required bool authorized,
  }) async {
    if (!authorized) throw AccountConsentRequired();
    // A Busy admission must not consume the confirmation capability.
    final permit = gate.device();
    if (!_restorePreviews.remove(preview)) {
      permit.release();
      throw AccountPreviewChanged();
    }
    _restoreCancelled = false;
    _activeRestore = preview._native.handle;
    _Material? safety;
    Object? originalFailure;
    StackTrace? originalStack;
    try {
      void checkCancelled() {
        if (_restoreCancelled) throw AccountRecoveryRequired('cancelled');
      }

      checkCancelled();
      final actual = await native.deviceSyncLibraryInfo(library_: library);
      if (actual.libraryUuid != preview.library) throw AccountPreviewChanged();
      final selected = preview._selected;
      if (selected != null) {
        if (rawAccountDigest(await readRawAccountKeys(storage)) !=
            preview.targetAccountDigest) {
          throw AccountPreviewChanged();
        }
        // The selected protected backup must still be the same material, not
        // merely another record with a matching account ID or backup label.
        if (!(await _index()).contains(selected.external) ||
            jsonEncode((await _load(selected.external)).json()) !=
                jsonEncode(selected.json())) {
          throw AccountRecoveryRequired('backup_material_mismatch');
        }
      }
      checkCancelled();
      try {
        await native.deviceSyncValidateRestore(
          restore: preview._native.handle,
          binding: preview.binding,
        );
      } catch (_) {
        throw AccountPreviewChanged();
      }
      checkCancelled();
      if (selected == null) {
        await native.deviceSyncApplyRestore(
          restore: preview._native.handle,
          binding: preview.binding,
        );
        return const AccountApplyResult(
          finalized: true,
        ); // No active account key read or write.
      }
      safety = _Material(
        external: _uuid(),
        library: actual.libraryUuid,
        operation: preview.operation,
        old: preview.change!.before.raw,
        candidate: selected.old,
        binding: preview.binding,
      );
      await _reserve(safety);
      checkCancelled();
      final restored = await native.deviceSyncApplyRestore(
        restore: preview._native.handle,
        binding: preview.binding,
        external_: safety.external,
      );
      if (restored.backup == null) {
        throw AccountRecoveryRequired('restore_backup_missing');
      }
      return await _switch(
        safety,
        restored.backup!,
        check: () async {
          checkCancelled();
        },
        step: () async {},
        finalize: () => native.deviceSyncFinalizeRestore(
          restore: preview._native.handle,
          external_: safety!.external,
        ),
      );
    } catch (error, stack) {
      originalFailure = error;
      originalStack = stack;
      if (safety != null) {
        final journal = await native.deviceSyncJournal(
          library_: library,
          operation: safety.operation,
        );
        if (journal?.stage == 'finalized') {
          publish(_ids(safety.candidate));
          return const AccountApplyResult(
            finalized: true,
            cleanupPending: true,
          );
        }
        gate.holdRecovery();
        final state = await _recoverOwned(permit);
        if (!state.ready) throw AccountRecoveryRequired(state.status);
      }
      rethrow;
    } finally {
      _activeRestore = null;
      try {
        try {
          await discardRestorePreview(preview);
        } catch (_) {
          if (originalFailure != null) {
            Error.throwWithStackTrace(originalFailure, originalStack!);
          }
          rethrow;
        }
      } finally {
        permit.release();
      }
    }
  }

  Future<void> cancelRestore({AccountRestorePreview? preview}) async {
    final restore = _activeRestore;
    if (preview != null &&
        (restore == null || restore != preview._native.handle)) {
      return;
    }
    _restoreCancelled = true;
    if (restore != null) await native.deviceSyncCancelRestore(restore: restore);
  }

  Future<List<String>> _index() async {
    final raw = await storage.read(accountCoordinationIndexKey);
    if (raw == null) return [];
    if (raw.length > 65536 || utf8.encode(raw).length > 65536) {
      throw AccountStorageFailure();
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 2 ||
          value['version'] != 1 ||
          value['entries'] is! List ||
          (value['entries'] as List).length > _maxMaterials) {
        throw AccountStorageFailure();
      }
      final ids = (value['entries'] as List).cast<String>();
      if (ids.toSet().length != ids.length ||
          ids.any((id) => !_validUuid(id))) {
        throw AccountStorageFailure();
      }
      return ids;
    } catch (_) {
      throw AccountStorageFailure();
    }
  }

  Future<void> _reserve(_Material material) async {
    final index = await _index();
    if (index.length >= _maxMaterials || index.contains(material.external)) {
      throw AccountStorageFailure();
    }
    // Both full material AND index must be read back before Rust can register
    // the external UUID. Unindexed preparation never switches active keys.
    await _save(material);
    await _writeVerified(
      accountCoordinationIndexKey,
      jsonEncode({
        'version': 1,
        'entries': [...index, material.external],
      }),
    );
  }

  Future<void> _save(_Material material) async {
    var rawBytes = 0;
    for (final raw in [material.old, material.candidate]) {
      for (final value in raw.values) {
        if (value != null) rawBytes += utf8.encode(value).length;
      }
    }
    if (rawBytes * 6 + 4096 > _maxMaterialBytes) throw AccountStorageFailure();
    final json = jsonEncode(material.json());
    if (utf8.encode(json).length > _maxMaterialBytes) {
      throw AccountStorageFailure();
    }
    await _writeVerified(accountMaterialKey(material.external), json);
  }

  Future<_Material> _load(String external) async {
    final raw = await storage.read(accountMaterialKey(external));
    if (raw == null ||
        raw.length > _maxMaterialBytes ||
        utf8.encode(raw).length > _maxMaterialBytes) {
      throw AccountRecoveryRequired('material_missing');
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 9 ||
          value['version'] != 1 ||
          value['external'] != external ||
          value['library'] is! String ||
          !_validUuid(value['library'] as String) ||
          value['operation'] is! String ||
          !_validUuid(value['operation'] as String) ||
          value['binding'] is! String ||
          (value['binding'] as String).length > 256 ||
          ![
            'prepared',
            'library_applied',
            'finalized',
            'rolled_back',
          ].contains(value['stage']) ||
          (value['backup'] != null &&
              (value['backup'] is! String ||
                  !_validUuid(value['backup'] as String)))) {
        throw AccountStorageFailure();
      }
      return _Material(
        external: external,
        library: value['library'] as String,
        operation: value['operation'] as String,
        binding: value['binding'] as String,
        old: _raw(value['old']),
        candidate: _raw(value['candidate']),
        stage: value['stage'] as String,
        backup: value['backup'] as String?,
      );
    } catch (_) {
      throw AccountStorageFailure();
    }
  }

  Future<void> _writeVerified(String key, String? value) async {
    try {
      if (value == null) {
        await storage.delete(key);
      } else {
        await storage.write(key, value);
      }
      if (await storage.read(key) != value) throw AccountStorageFailure();
    } catch (_) {
      throw AccountStorageFailure();
    }
  }
}

Map<String, String?> _raw(dynamic value) {
  if (value is! Map ||
      value.length != accountActiveKeys.length ||
      value.keys.any((key) => !accountActiveKeys.contains(key))) {
    throw AccountStorageFailure();
  }
  final raw = <String, String?>{};
  var bytes = 0;
  for (final key in accountActiveKeys) {
    final field = value[key];
    if (field != null && field is! String) throw AccountStorageFailure();
    if (field is String) {
      bytes += utf8.encode(field).length;
    }
    if (bytes > maxAccountRawBytes) throw AccountStorageFailure();
    raw[key] = field as String?;
  }
  return Map.unmodifiable(raw);
}

Set<String> _ids(Map<String, String?> raw) {
  final value = raw[accountTokensKey];
  if (value == null || value.isEmpty) return {};
  try {
    final tokens = jsonDecode(value);
    if (tokens is! Map<String, dynamic> || tokens.length > maxAccountCount) {
      throw AccountStorageFailure();
    }
    return tokens.keys.toSet();
  } catch (_) {
    throw AccountStorageFailure();
  }
}

bool _validUuid(String value) =>
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(value) &&
    value != '00000000-0000-0000-0000-000000000000';
String _uuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
