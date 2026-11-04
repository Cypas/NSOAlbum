part of 'startup_lifecycle.dart';

extension DeviceSyncBackups on DeviceSyncService {
  DeviceBackupBrowser openBackups() {
    _admit();
    final browser = DeviceBackupBrowser._(this);
    _browsers.add(browser);
    return browser;
  }
}

final class DeviceBackupBrowser extends DeviceBackupBrowserController {
  DeviceBackupBrowser._(this._service) : _epoch = _service._epoch;
  final DeviceSyncService _service;
  final int _epoch;
  final _entries = Map<DeviceBackupEntry, String?>.identity();
  bool _closed = false;
  bool _settled = false;
  Future<void>? _acting, _closing;
  AccountRestorePreview? _accountPreview;
  DeviceRestorePreviewView? _previewView;
  bool _confirming = false;
  @override
  bool get closed => _closed;
  @override
  bool get settled => _settled;
  @override
  bool get busy => _acting != null;
  @override
  DeviceRestorePreviewView? get preview => _previewView;

  void _admit({bool writes = false}) {
    _service._admit(existing: !writes);
    if (closed ||
        _epoch != _service._epoch ||
        !_service._browsers.contains(this)) {
      throw const DeviceSyncBusy();
    }
  }

  Future<T> _act<T>(Future<T> Function() action, {bool writes = false}) {
    _admit(writes: writes);
    if (busy) return Future.error(const DeviceSyncBusy());
    final done = Completer<void>();
    _acting = done.future;
    notifyListeners();
    return Future<T>.sync(() {
          _admit(writes: writes);
          return action();
        })
        .catchError((Object failure, StackTrace stack) {
          _service._recordFailure(failure);
          Error.throwWithStackTrace(failure, stack);
        })
        .whenComplete(() {
          if (identical(_acting, done.future)) _acting = null;
          done.complete();
          if (!closed) notifyListeners();
        });
  }

  Future<T> _project<T>(
    Future<T> Function() observe,
    read.ReadError? Function(T) errorOf,
  ) => readDeviceProjection(
    observe,
    errorOf: errorOf,
    cancelled: () =>
        closed || _epoch != _service._epoch || !_service._owner.ready,
  );

  Future<read.BackupPage> _page(String? cursor) async {
    final result = await _project(
      () => native.deviceSyncReadBackups(
        library_: _service._owner._library!,
        cursor: cursor,
        limit: BigInt.from(25),
      ),
      (value) => value.error,
    );
    if (result.error != null || result.value == null) {
      throw DeviceSyncReadFailure(result.error ?? read.ReadError.unavailable);
    }
    return result.value!;
  }

  @override
  Future<DeviceBackupPageView> page({String? cursor}) => _act(() async {
    await _discard();
    _entries.clear();
    final value = await _page(cursor);
    _admit();
    final entries = [
      for (final metadata in value.items) DeviceBackupEntry(metadata),
    ];
    for (final entry in entries) {
      _entries[entry] = cursor;
    }
    return DeviceBackupPageView(
      items: List.unmodifiable(entries),
      next: value.next,
    );
  });

  bool _eligible(read.BackupMetadata metadata) =>
      metadata.backup != null &&
      metadata.includesAccounts != null &&
      metadata.unavailableReason == null;

  @override
  Future<DeviceRestorePreviewView> prepareRestore(
    DeviceBackupEntry entry, {
    bool accountsAuthorized = false,
  }) => _act(() async {
    if (!_entries.containsKey(entry)) throw AccountPreviewChanged();
    final metadata = entry.metadata;
    if (!_eligible(metadata)) throw const DeviceBackupUnavailable();
    if (metadata.includesAccounts == true && !accountsAuthorized) {
      throw AccountConsentRequired();
    }
    await _discard();
    final current = await _page(_entries[entry]);
    if (!current.items.any((item) => item == metadata && _eligible(item))) {
      throw AccountPreviewChanged();
    }
    _admit(writes: true);
    final coordinator = _service._owner._coordinator!;
    final raw = await coordinator.previewRestore(
      metadata.backup!,
      accountsAuthorized: accountsAuthorized,
    );
    _accountPreview = raw;
    var retained = false;
    Object? originalFailure;
    StackTrace? originalStack;
    try {
      final summary = await _project(
        () => coordinator.readRestoreSummary(raw),
        (value) => value.error,
      );
      _admit();
      if (summary.error != null ||
          summary.value == null ||
          summary.value!.includesAccounts != metadata.includesAccounts) {
        throw AccountPreviewChanged();
      }
      final change = raw.change;
      final shown = DeviceRestorePreviewView(
        library: summary.value!,
        accounts: change == null
            ? null
            : DeviceAccountCounts(
                added: change.added.length,
                replaced: change.replaced.length,
                removed: change.removed.length,
              ),
      );
      _previewView = shown;
      retained = true;
      return shown;
    } catch (failure, stack) {
      originalFailure = failure;
      originalStack = stack;
      rethrow;
    } finally {
      if (!retained) {
        try {
          await _discard();
        } catch (_) {
          if (originalFailure != null) {
            Error.throwWithStackTrace(originalFailure, originalStack!);
          }
          rethrow;
        }
      }
    }
  }, writes: true);

  @override
  Future<DeviceRestoreResult> confirmRestore(DeviceRestorePreviewView shown) =>
      _act(() async {
        final raw = _accountPreview;
        if (raw == null || !identical(shown, _previewView)) {
          throw AccountPreviewChanged();
        }
        var unexecutedBusy = false, consumed = false;
        _confirming = true;
        try {
          final result = await _service._owner._coordinator!.confirmRestore(
            raw,
            authorized: true,
          );
          consumed = true;
          _admit();
          return DeviceRestoreResult(
            finalized: result.finalized,
            cleanupPending: result.cleanupPending,
          );
        } on DeviceSyncBusy {
          unexecutedBusy = !closed && _service._owner.ready;
          rethrow;
        } finally {
          _confirming = false;
          // confirmRestore itself retires its single-use preview. If that
          // cleanup failed, retain ownership for the next explicit cleanup,
          // not an immediate hidden retry or another restore confirmation.
          if (!unexecutedBusy) {
            _previewView = null;
            if (consumed) await _discard();
          }
        }
      }, writes: true);

  Future<void> _discard() async {
    final raw = _accountPreview;
    _previewView = null;
    if (raw != null) {
      await _service._owner._coordinator!.discardRestorePreview(raw);
      if (identical(_accountPreview, raw)) _accountPreview = null;
    }
  }

  @override
  Future<void> discardPreview() => _act(_discard);
  @override
  Future<void> close() {
    if (_closing case final current?) return current;
    if (_settled) return Future.value();
    final done = Completer<void>();
    late final Future<void> flight;
    flight = done.future.whenComplete(() {
      if (identical(_closing, flight)) _closing = null;
    });
    _closing = flight;
    _closed = true;
    _entries.clear();
    unawaited(
      () async {
        final errors = _DeviceCloseErrors();
        await errors.wait(() async {
          final raw = _accountPreview;
          if (_confirming && raw != null) {
            await _service._owner._coordinator!.cancelRestore(preview: raw);
          }
        });
        await errors.wait(() async => await _acting);
        var retired = false;
        await errors.wait(() async {
          await _discard();
          retired = true;
        });
        if (retired) {
          _settled = true;
          _service._browsers.remove(this);
        }
        if (errors.failure case final failure?) {
          _service._recordFailure(failure);
        }
        errors.rethrowFirst();
      }().then(done.complete, onError: done.completeError),
    );
    return flight;
  }

  @override
  String toString() => 'DeviceBackupBrowser([REDACTED])';
}
