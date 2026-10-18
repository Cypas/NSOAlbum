part of 'startup_lifecycle.dart';

final class DeviceSyncSession extends DeviceSyncSessionController {
  DeviceSyncSession._(this._service, this._endpoint, this._invitation);
  final DeviceSyncService _service;
  final String _endpoint;
  String? _invitation;
  Future<void>? _closing;
  bool _closeRequested = false;
  Future<read.EndpointRead>? _observing;
  final _projections = <Future<void>>{};
  Future<void>? _acting;
  read.EndpointRead? _snapshot;
  String? _confirmationCode;
  int _epoch = 0;
  bool _confirmedLocally = false;
  bool _configured = false;
  DeviceSyncPreviewView? _previewView;
  int? _previewEpoch;
  bool _approved = false;
  read.ReadError? _issue;
  read.ReadError? _transportIssue;
  bool _localCleanupPending = false;
  bool _issueFromPreview = false;
  bool? _accountConsent;
  AccountPreview? _accountPreview;
  String? _publishedAccountPreviewBinding;
  DeviceSyncProposal? _proposal;
  bool _targetFinal = false;
  bool _sourceFinal = false;
  bool _applied = false;
  bool _sourceReleased = false;
  bool _advanceBlocked = false;
  bool _settled = false;
  bool _workDrained = false;
  DeviceSyncUsbSafOwner? _usbOwner;
  Future<void>? _usbRunning;
  Object? _usbFailure;
  StackTrace? _usbFailureStack;
  final _usbChoices =
      Map<DeviceUsbStorageChoice, ({String device, String storage})>.identity();
  @override
  bool get closed => _closeRequested;
  @override
  bool get settled => _settled;
  @override
  bool get busy => _acting != null;
  @override
  bool get confirmedLocally => _confirmedLocally;
  @override
  String? get invitation => _invitation;
  @override
  read.EndpointRead? get snapshot => _snapshot;
  @override
  String? get confirmationCode => _confirmationCode;
  @override
  bool get accountsAuthorized => _accountConsent == true;
  @override
  DeviceSyncProposal? get proposedConfiguration => _proposal;
  @override
  DeviceSyncPreviewView? get preview => _previewView;
  @override
  read.ReadError? get issue => _issue;
  @override
  read.ReadError? get transportIssue => _transportIssue;
  @override
  bool get localCleanupPending => _localCleanupPending;

  @override
  Future<read.EndpointRead> refresh() {
    final observing = _observing;
    if (observing != null) return observing;
    _admit();
    if (_usbFailure case final failure?) {
      if (_usbOwner?.admitted != true) {
        // A rejected OS runner never started a transport. Preserve its exact
        // admission failure instead of replacing it with a native read error.
        Error.throwWithStackTrace(failure, _usbFailureStack!);
      }
    }
    final epoch = _epoch;
    late final Future<read.EndpointRead> flight;
    flight =
        () async {
          final value = await _project(
            () => native.deviceSyncReadEndpoint(endpoint: _endpoint),
            (value) => value.error,
          );
          if (epoch != _epoch || closed) throw const DeviceSyncBusy();
          final view = value.value;
          // Always observe the native domain first. An OS transport failure
          // cannot decide whether the original local operation is installed.
          if (_usbFailure case final failure?) {
            if (view?.localApplyInstalled != true) {
              Error.throwWithStackTrace(failure, _usbFailureStack!);
            }
          }
          final delegatedHostCode =
              view?.phoneControlled == true &&
              view?.host == true &&
              (view?.pairing == read.PairingStage.awaitingConfirmation ||
                  view?.pairing == read.PairingStage.confirmed);
          final showCode =
              view?.terminal == false &&
              (view?.confirmationAvailable == true || delegatedHostCode);
          String? code = showCode ? _confirmationCode : null;
          if (showCode && code == null) {
            try {
              code = await admittedDeviceCommand(
                () => native.deviceSyncConfirmationCode(endpoint: _endpoint),
                cancelled: () => epoch != _epoch || closed,
              );
            } on DeviceCommandError catch (failure) {
              _snapshot = value;
              _setIssue(failure.code);
              rethrow;
            }
          }
          if (view?.pairing == read.PairingStage.confirmed &&
              view?.stage == driver.State.awaitingAccountConsent &&
              view?.terminal == false) {
            final proposed = await _command(
              () => native.deviceSyncStatus(endpoint: _endpoint),
            );
            if (proposed.state == 'AwaitingAccountConsent' &&
                !proposed.terminal) {
              _proposal = DeviceSyncProposal(
                phoneToDesktop: view!.host != proposed.source,
                mode: proposed.overwrite
                    ? plan.SyncMode.overwrite
                    : plan.SyncMode.merge,
                includeAccounts: true,
              );
            }
          }
          if (epoch != _epoch || closed) throw const DeviceSyncBusy();
          _snapshot = value;
          _confirmationCode = code;
          if (view?.terminal == true) _usbChoices.clear();
          if (view?.pairing == read.PairingStage.awaitingConfirmation ||
              view?.pairing == read.PairingStage.confirmed ||
              view?.terminal == true) {
            _invitation = null;
          }
          notifyListeners();
          await _advance(view);
          return value;
        }().whenComplete(() {
          if (identical(_observing, flight)) _observing = null;
        });
    _observing = flight;
    return flight;
  }

  void _admit() {
    _service._admit(existing: true);
    if (closed || !_service._sessions.contains(this)) {
      throw const DeviceSyncBusy();
    }
  }

  Future<T> _act<T>(Future<T> Function() action) {
    _admit();
    if (_acting != null) return Future.error(const DeviceSyncBusy());
    final done = Completer<void>();
    _acting = done.future;
    notifyListeners();
    return Future<T>.sync(action)
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

  void _setIssue(read.ReadError? issue, {bool fromPreview = false}) {
    _issue = issue;
    _issueFromPreview = fromPreview;
  }

  Future<T> _command<T>(Future<T> Function() action) =>
      admittedDeviceCommand(action, cancelled: () => closed);

  Future<T> _project<T>(
    Future<T> Function() observe,
    read.ReadError? Function(T) error,
  ) async {
    _admit();
    final epoch = _epoch;
    final done = Completer<void>();
    _projections.add(done.future);
    try {
      return await readDeviceProjection(
        observe,
        errorOf: error,
        cancelled: () => closed || epoch != _epoch || !_service._owner.ready,
      );
    } finally {
      _projections.remove(done.future);
      done.complete();
    }
  }

  @override
  Future<void> confirmPairing() {
    _admit();
    if (_confirmedLocally) return Future.value();
    return _act(() async {
      if (_snapshot?.value?.confirmationAvailable != true) {
        throw const DeviceSyncBusy();
      }
      final view = _snapshot?.value;
      if (view?.phoneControlled == true && view?.controller != true) {
        throw const DeviceSyncBusy();
      }
      await _command(() => native.deviceSyncConfirm(endpoint: _endpoint));
      if (!closed) _confirmedLocally = true;
    });
  }

  @override
  Future<void> configure({
    required bool phoneToDesktop,
    required bool overwrite,
    bool includeAccounts = false,
  }) => _act(() async {
    final view = (await _project(
      () => native.deviceSyncReadEndpoint(endpoint: _endpoint),
      (value) => value.error,
    )).value;
    if (_configured ||
        !_confirmedLocally ||
        view?.controller != true ||
        view?.pairing != read.PairingStage.confirmed ||
        view?.configuration != null) {
      throw const DeviceSyncBusy();
    }
    await _command(
      () => native.deviceSyncConfigure(
        endpoint: _endpoint,
        phoneToDesktop: phoneToDesktop,
        overwrite: overwrite,
        includeAccounts: includeAccounts,
      ),
    );
    _proposal = DeviceSyncProposal(
      phoneToDesktop: phoneToDesktop,
      mode: overwrite ? plan.SyncMode.overwrite : plan.SyncMode.merge,
      includeAccounts: includeAccounts,
    );
    _configured = true;
  });

  @override
  Future<void> consentAccounts({required bool accepted}) => _act(() async {
    final status = await _command(
      () => native.deviceSyncStatus(endpoint: _endpoint),
    );
    final current = await _project(
      () => native.deviceSyncReadEndpoint(endpoint: _endpoint),
      (value) => value.error,
    );
    final view = current.value;
    if (status.state != 'AwaitingAccountConsent' ||
        status.terminal ||
        view?.pairing != read.PairingStage.confirmed ||
        view?.stage != driver.State.awaitingAccountConsent ||
        view?.terminal != false ||
        !_confirmedLocally ||
        (view?.phoneControlled == true && view?.controller != true) ||
        _approved ||
        closed) {
      throw AccountPreviewChanged();
    }
    if (_accountConsent == accepted) return;
    final coordinator = _service._owner._coordinator!;
    if (view?.phoneControlled == true) {
      if (view?.accountsConsentAuthorized != true) {
        await _command(
          () => native.deviceSyncConsentControlled(
            endpoint: _endpoint,
            accepted: accepted,
          ),
        );
      }
      if (!accepted) {
        _accountConsent = false;
        _previewView = null;
        _accountPreview = null;
        _previewEpoch = null;
        return;
      }
    }
    if (!accepted) {
      await coordinator.decline(_endpoint);
    } else if (status.source) {
      await coordinator.authorizeSource(_endpoint, authorized: true);
    } else {
      await coordinator.authorizeTarget(_endpoint, authorized: true);
    }
    _accountConsent = accepted;
    _previewView = null;
    _accountPreview = null;
    _previewEpoch = null;
  });
  @override
  Future<DeviceSyncPreviewView> refreshPreview() => _act(() async {
    _previewView = null;
    _previewEpoch = null;
    final endpoint = await _project(
      () => native.deviceSyncReadEndpoint(endpoint: _endpoint),
      (value) => value.error,
    );
    final view = endpoint.value;
    final mayReview = view?.phoneControlled == true
        ? view?.controller == true
        : view?.source == false;
    if (view?.stage != driver.State.awaitingApproval || !mayReview) {
      _snapshot = endpoint;
      _setIssue(
        endpoint.error ?? read.ReadError.previewChanged,
        fromPreview: true,
      );
      throw AccountPreviewChanged();
    }
    final accounts = view?.configuration?.includeAccounts == true;
    if (accounts && !accountsAuthorized) {
      throw AccountConsentRequired();
    }
    final summary = await _project(
      () => native.deviceSyncReadPreview(endpoint: _endpoint),
      (value) => value.error,
    );
    if (summary.error != null || summary.value == null || closed) {
      _snapshot = endpoint;
      _setIssue(
        summary.error ?? read.ReadError.previewChanged,
        fromPreview: true,
      );
      throw AccountPreviewChanged();
    }
    AccountPreview? account;
    if (accounts && view?.source == false) {
      account = await _service._owner._coordinator!.preview(_endpoint);
      if (account.binding != summary.value!.binding) {
        throw AccountPreviewChanged();
      }
    }
    final remoteAccounts = summary.value!.accounts;
    if (accounts && view?.phoneControlled == true && remoteAccounts == null) {
      throw AccountPreviewChanged();
    }
    final value = DeviceSyncPreviewView(
      library: summary.value!,
      accounts: account != null
          ? DeviceAccountCounts(
              added: account.change.added.length,
              replaced: account.change.replaced.length,
              removed: account.change.removed.length,
            )
          : accounts && remoteAccounts != null
          ? DeviceAccountCounts(
              added: remoteAccounts.added.toInt(),
              replaced: remoteAccounts.replaced.toInt(),
              removed: remoteAccounts.removed.toInt(),
            )
          : null,
    );
    _accountPreview = account;
    _previewView = value;
    _previewEpoch = _epoch;
    if (_issueFromPreview &&
        !_advanceBlocked &&
        _issue != read.ReadError.recoveryRequired) {
      _setIssue(null);
    }
    return value;
  });
  @override
  Future<void> approvePreview(DeviceSyncPreviewView shown) => _act(() async {
    if (!identical(shown, _previewView) ||
        _previewEpoch != _epoch ||
        _approved) {
      throw AccountPreviewChanged();
    }
    final endpoint = await _project(
      () => native.deviceSyncReadEndpoint(endpoint: _endpoint),
      (value) => value.error,
    );
    final view = endpoint.value;
    final current = await _project(
      () => native.deviceSyncReadPreview(endpoint: _endpoint),
      (value) => value.error,
    );
    final mayApprove = view?.phoneControlled == true
        ? view?.controller == true
        : view?.source == false;
    if (!mayApprove ||
        view?.stage != driver.State.awaitingApproval ||
        current.error != null ||
        current.value?.binding != shown.library.binding) {
      _snapshot = endpoint;
      _setIssue(
        endpoint.error ?? current.error ?? read.ReadError.previewChanged,
        fromPreview: true,
      );
      _previewView = null;
      throw AccountPreviewChanged();
    }
    final accounts = view?.configuration?.includeAccounts == true;
    if (view?.phoneControlled == true) {
      if (accounts && (!accountsAuthorized || shown.accounts == null)) {
        throw AccountConsentRequired();
      }
      if (!view!.previewApproved) {
        await _command(
          () => native.deviceSyncApproveControlled(
            endpoint: _endpoint,
            binding: shown.library.binding,
          ),
        );
      }
      if (accounts && view.source == false) {
        final account = _accountPreview;
        if (account == null || account.binding != shown.library.binding) {
          throw AccountPreviewChanged();
        }
        await _service._owner._coordinator!.approve(account, authorized: true);
      }
    } else if (accounts) {
      final account = _accountPreview;
      if (!accountsAuthorized || account == null) {
        throw AccountConsentRequired();
      }
      await _service._owner._coordinator!.approve(account, authorized: true);
    } else {
      await _command(() => native.deviceSyncApprove(endpoint: _endpoint));
    }
    _approved = true;
  });
  @override
  Future<read.ConflictPageRead> conflicts(
    DeviceSyncPreviewView shown, {
    String? cursor,
  }) async {
    _admit();
    if (!identical(shown, _previewView) || _previewEpoch != _epoch) {
      throw AccountPreviewChanged();
    }
    return _project(
      () => native.deviceSyncReadConflicts(
        endpoint: _endpoint,
        binding: shown.library.binding,
        cursor: cursor,
        limit: BigInt.from(25),
      ),
      (value) => value.error,
    );
  }

  @override
  Future<List<DeviceUsbStorageChoice>> usbChoices() => _readUsbChoices();
  @override
  Future<void> selectUsb(DeviceUsbStorageChoice choice) => _selectUsb(choice);

  void _publish() {
    if (!closed) notifyListeners();
  }

  @override
  Future<void> close() {
    if (_closing case final current?) return current;
    _closeRequested = true;
    _invitation = null;
    _confirmationCode = null;
    _usbChoices.clear();
    _epoch++;
    final flight = () async {
      final errors = _DeviceCloseErrors();
      var transportDrained = _usbOwner == null;
      var nativeSettled = false;
      await errors.wait(() async {
        if (_snapshot?.value?.stage == driver.State.completed &&
            _snapshot?.value?.transport == read.TransportKind.usb) {
          await errors.wait(() async {
            await _usbRunning;
            final ended = await native.deviceSyncUsbWaitClosed(
              endpoint: _endpoint,
            );
            if (!ended.closed ||
                ended.reason != UsbCloseReason.success ||
                ended.error != null) {
              throw DeviceSyncReadFailure(
                ended.error ?? read.ReadError.unavailable,
              );
            }
          });
        }
        await errors.wait(
          () => native.deviceSyncCancelSignal(endpoint: _endpoint),
        );
        await errors.wait(() async {
          await native.deviceSyncShutdown(endpoint: _endpoint);
          nativeSettled = true;
        });
        await errors.wait(() async {
          await _usbOwner?.cancel();
        });
        await errors.wait(() async {
          await _usbOwner?.settleOwnedIo();
          transportDrained = true;
        });
        await errors.wait(() => Future.wait(_projections.toList()));
        await errors.wait(() async => await _acting);
        await errors.wait(() async {
          await _service._owner._coordinator!.abort(_endpoint);
          nativeSettled = true;
        });
        await errors.wait(() async {
          try {
            await _observing;
          } on DeviceSyncBusy {
            // This owner invalidated its own pending observation.
          }
        });
        await errors.wait(() async => await _usbRunning);
        _workDrained =
            transportDrained &&
            nativeSettled &&
            !_service._owner._coordinator!.hasEndpointWork(_endpoint);
        if (_usbFailure case final failure?) {
          await errors.wait(() {
            Error.throwWithStackTrace(failure, _usbFailureStack!);
          });
        }
        await errors.wait(() async {
          if (_workDrained) {
            await native.deviceSyncCloseEndpoint(endpoint: _endpoint);
            _settled = true;
          }
        });
      });
      if (_workDrained) _service._sessions.remove(this);
      if (errors.failure case final failure?) _service._recordFailure(failure);
      errors.rethrowFirst();
    }();
    return _closing = flight.whenComplete(() {
      // Logical close is monotonic. Only the same owner's unfinished cleanup
      // may be retried; no observation, grant or account sequence is restarted.
      if (!_workDrained) _closing = null;
    });
  }

  @override
  String toString() => 'DeviceSyncSession([REDACTED])';
}
