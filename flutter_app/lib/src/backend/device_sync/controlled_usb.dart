part of 'startup_lifecycle.dart';

final class DeviceUsbConnectionAttempt implements DeviceUsbAttemptController {
  DeviceUsbConnectionAttempt._(this._service, this._invitation, this._name)
    : _epoch = _service._epoch;
  final DeviceSyncService _service;
  final String _invitation, _name;
  final int _epoch;
  final _saf = DeviceSyncSaf();
  final _cancelled = Completer<void>();
  Future<DeviceSyncSession>? _connecting;
  Future<void>? _cancelling;
  DeviceSyncSession? _session;
  bool _retired = false;

  void _admit() {
    _service._admit();
    if (_retired ||
        _cancelled.isCompleted ||
        _epoch != _service._epoch ||
        !_service._usbAttempts.contains(this)) {
      throw const DeviceSyncBusy();
    }
  }

  @override
  Future<DeviceSyncSession> connect() {
    final connecting = _connecting;
    if (connecting != null) return connecting;
    _admit();
    return _connecting = () async {
      try {
        final selected = await Future.any([
          _saf.selectTree().then((_) => true),
          _cancelled.future.then((_) => false),
        ]);
        if (!selected) throw const DeviceSyncBusy();
        _admit();
        final session = await _service._open(
          () async => (
            endpoint: await native.deviceSyncClientUsb(
              library_: _service._owner._library!,
              invitation: _invitation,
              name: _name,
            ),
            invitation: null,
          ),
          cancelled: () => _cancelled.isCompleted,
        );
        _session = session;
        session._ownUsb(_saf);
        return session;
      } catch (_) {
        // Do not await cancel(): it in turn waits for this connecting future.
        await _saf.cancel();
        rethrow;
      } finally {
        _retired = true;
        _service._usbAttempts.remove(this);
      }
    }();
  }

  @override
  Future<void> cancel() {
    if (_cancelling case final current?) return current;
    _cancelled.complete();
    _retired = true;
    return _cancelling = () async {
      try {
        await _saf.cancel();
      } finally {
        try {
          await _connecting;
        } catch (_) {
          // The connecting caller receives its original failure.
        }
        await _session?.close();
        _service._usbAttempts.remove(this);
      }
    }();
  }

  @override
  String toString() => 'DeviceUsbConnectionAttempt([REDACTED])';
}

extension DeviceSyncUsbService on DeviceSyncService {
  DeviceUsbConnectionAttempt prepareUsbClient({
    required String invitation,
    required String name,
  }) {
    _admit();
    final attempt = DeviceUsbConnectionAttempt._(this, invitation, name);
    _usbAttempts.add(attempt);
    return attempt;
  }

  Future<DeviceSyncSession> hostUsb({
    required String name,
    ApplicationBuild? appBuild,
  }) => _open(() async {
    final host = await native.deviceSyncHostUsb(
      library_: _owner._library!,
      name: name,
      appBuild: appBuild,
    );
    return (endpoint: host.handle, invitation: host.invitation);
  });
}

extension DeviceSyncUsbSession on DeviceSyncSession {
  void _ownUsb(DeviceSyncSaf saf) {
    final owner = _usbOwner = DeviceSyncUsbSafOwner(
      endpoint: _endpoint,
      saf: saf,
      onFailure: _service._owner._diagnostic,
    );
    // Consume both branches immediately, retain unknown failure and its stack,
    // and still let the native runtime decide durable completion.
    _usbRunning = owner.run().then<void>(
      (view) {
        if (!closed && view.error != null) {
          _service._owner._diagnostic(
            'usb_transport',
            DeviceSyncReadFailure(
              view.error!,
              stage: 'USB channel operation',
            ),
          );
          _transportIssue = view.error;
          _publish();
        }
      },
      onError: (Object failure, StackTrace stack) {
        _usbFailure = failure;
        _usbFailureStack = stack;
        if (!closed) {
          _transportIssue = read.ReadError.internal;
          if (!owner.admitted) _setIssue(read.ReadError.internal);
          _publish();
        }
      },
    );
  }

  Future<List<DeviceUsbStorageChoice>> _readUsbChoices() => _act(() async {
    _usbChoices.clear();
    final epoch = _epoch;
    final view = await _project(
      () => native.deviceSyncUsbView(endpoint: _endpoint),
      (value) => value.error,
    );
    if (closed || epoch != _epoch) throw const DeviceSyncBusy();
    _setIssue(view.error);
    if (view.closed || view.error != null) {
      _invitation = null;
      return const [];
    }
    for (final device in view.devices) {
      for (final storage in device.storages) {
        _usbChoices[DeviceUsbStorageChoice(
          deviceName: device.name,
          storageName: storage.name,
          freeBytes: storage.freeBytes,
        )] = (
          device: device.id,
          storage: storage.id,
        );
      }
    }
    return List.unmodifiable(_usbChoices.keys);
  });

  Future<void> _selectUsb(DeviceUsbStorageChoice choice) => _act(() async {
    final identity = _usbChoices[choice];
    if (identity == null || _snapshot?.value?.terminal == true) {
      throw const DeviceSyncBusy();
    }
    final epoch = _epoch;
    final view = await _project(
      () => native.deviceSyncUsbView(endpoint: _endpoint),
      (value) => value.error,
    );
    if (closed ||
        epoch != _epoch ||
        view.closed ||
        view.error != null ||
        !view.devices.any(
          (device) =>
              device.id == identity.device &&
              device.storages.any((storage) => storage.id == identity.storage),
        )) {
      _usbChoices.clear();
      _setIssue(view.error);
      throw const DeviceSyncBusy();
    }
    await _command(
      () => native.deviceSyncUsbSelect(
        endpoint: _endpoint,
        device: identity.device,
        storage: identity.storage,
      ),
    );
    _usbChoices.clear();
  });
}
