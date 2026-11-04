part of 'startup_lifecycle.dart';

/// Page capabilities always belong to the recovered application's one owner.
final class DeviceSyncService {
  DeviceSyncService._(this._owner);
  final DeviceSyncStartupLifecycle _owner;
  final _sessions = <DeviceSyncSession>{};
  final _openings = <Future<void>>{};
  _DeviceCloseErrors? _closeErrors;
  final _usbAttempts = <DeviceUsbConnectionAttempt>{};
  final _browsers = <DeviceBackupBrowser>{};
  final _lan = DeviceLanDiscovery();
  int _epoch = 0;
  bool _closing = false;
  bool _workDrained = false;
  final _unsettledAttempts = <DeviceUsbConnectionAttempt>{};

  Future<List<DeviceLanAddress>> wifiAddresses() async {
    _admit();
    final epoch = _epoch;
    final addresses = await _lan.list();
    _admit();
    if (epoch != _epoch) throw const DeviceSyncBusy();
    return addresses;
  }

  Future<DeviceSyncSession> joinWifi({
    required String invitation,
    required String name,
  }) => _open(() async {
    final endpoint = await native.deviceSyncClientTcp(
      library_: _owner._library!,
      invitation: invitation,
      name: name,
    );
    return (endpoint: endpoint, invitation: null);
  });

  Future<DeviceSyncSession> hostWifi({
    required String address,
    required String name,
    String? wifiSsid,
    ApplicationBuild? appBuild,
  }) => _open(() async {
    final host = await native.deviceSyncHostTcp(
      library_: _owner._library!,
      name: name,
      address: '$address:0',
      wifiSsid: wifiSsid,
      appBuild: appBuild,
    );
    return (endpoint: host.handle, invitation: host.invitation);
  });

  Future<DeviceSyncSession> _open(
    Future<({String endpoint, String? invitation})> Function() open, {
    bool Function()? cancelled,
  }) {
    _admit();
    final epoch = _epoch;
    final done = Completer<void>();
    _openings.add(done.future);
    return () async {
      try {
        final opened = await open();
        if (_closing ||
            !_owner.ready ||
            epoch != _epoch ||
            cancelled?.call() == true) {
          try {
            await native.deviceSyncCloseEndpoint(endpoint: opened.endpoint);
          } catch (failure, stack) {
            _closeErrors?.record(failure, stack);
            rethrow;
          }
          throw const DeviceSyncBusy();
        }
        final session = DeviceSyncSession._(
          this,
          opened.endpoint,
          opened.invitation,
        );
        _sessions.add(session);
        session._observeTask();
        return session;
      } finally {
        _openings.remove(done.future);
        done.complete();
      }
    }();
  }

  void _admit({bool existing = false}) {
    if (_closing ||
        !_owner.ready ||
        _owner.isolated ||
        (!existing && _owner._gate.busy)) {
      throw const DeviceSyncBusy();
    }
  }

  void _recordFailure(Object failure) {
    if (failure is! DeviceSyncBusy) {
      _owner._diagnostic('operation_failed', failure);
    }
    if (_owner._gate.recoveryRequired) _owner._requireRecovery(failure);
  }

  Future<void> _quiesceForRecovery() async {
    _epoch++;
    await Future.wait(_usbAttempts.toList().map((attempt) => attempt.cancel()));
    await Future.wait(_browsers.toList().map((browser) => browser.close()));
    await Future.wait(_openings.toList());
    for (final session in _sessions.toList()) {
      try {
        await session.close();
      } on AccountRecoveryRequired {
        // The endpoint has settled; the same coordinator retries its journal.
      }
    }
  }

  Future<void> _close() async {
    _closing = true;
    _epoch++;
    _workDrained = false;
    final errors = _DeviceCloseErrors();
    _closeErrors = errors;
    try {
      final attempts = {..._unsettledAttempts, ..._usbAttempts};
      final browsers = _browsers.toSet();
      final sessions = _sessions.toSet();
      // Start all cancellation groups before waiting on any one of them.
      final stopping = <Future<void>>[
        for (final attempt in attempts)
          errors.wait(() async {
            _unsettledAttempts.add(attempt);
            await attempt.cancel();
            _unsettledAttempts.remove(attempt);
          }),
        for (final browser in browsers) errors.wait(browser.close),
        for (final session in sessions) errors.wait(session.close),
      ];
      await Future.wait([
        ...stopping,
        for (final opening in _openings.toList()) errors.wait(() => opening),
      ]);
      // An already accepted opening/attempt may have produced a late session.
      final lateSessions = _sessions.difference(sessions);
      sessions.addAll(lateSessions);
      await Future.wait([
        for (final session in lateSessions) errors.wait(session.close),
      ]);
      _workDrained =
          _unsettledAttempts.isEmpty &&
          browsers.every((browser) => browser.settled) &&
          sessions.every((session) => session._workDrained);
      errors.rethrowFirst();
    } finally {
      if (identical(_closeErrors, errors)) _closeErrors = null;
    }
  }
}
