import 'dart:async';

import 'package:flutter/foundation.dart';

class DeviceSyncBusy implements Exception {
  const DeviceSyncBusy();
  @override
  String toString() => 'Device synchronization is busy';
}

abstract interface class AccountWorkBackend {
  AccountWorkGate get accountWorkGate;
}

abstract interface class AccountScheduleAdmissionBackend {
  Future<bool> automaticAccountHasLocalHistory(String accountId);
}

/// A synchronous, non-waiting admission decision spans the whole async job.
class AccountWorkGate extends ChangeNotifier {
  final Object _zoneKey = Object();
  final Object _transferZoneKey = Object();
  int _normal = 0;
  DeviceAccountPermit? _device;
  DeviceTransferPermit? _transfer;
  bool _recovery = false;
  final _startupBarriers = <AccountStartupBarrier>{};
  bool get busy =>
      transferActive ||
      _device != null ||
      _recovery ||
      _startupBarriers.isNotEmpty;
  bool get transferActive => _transfer != null;
  bool get recoveryRequired => _recovery;

  /// A lifecycle owner retains this independently of coordinator compensation.
  /// Resolving one recovery can never admit work during close or initialization.
  AccountStartupBarrier holdStartup() {
    final barrier = AccountStartupBarrier._(this);
    _startupBarriers.add(barrier);
    notifyListeners();
    return barrier;
  }

  AccountWorkPermit normalPermit() {
    if (busy) throw const DeviceSyncBusy();
    _normal++;
    return AccountWorkPermit._(this);
  }

  Future<T> normal<T>(Future<T> Function() work) async {
    final inherited = Zone.current[_zoneKey];
    if (inherited is AccountWorkPermit && inherited._active) return work();
    final permit = normalPermit();
    try {
      return await permit.run(work);
    } finally {
      permit.release();
    }
  }

  DeviceAccountPermit device() {
    // Account steps of the owning transfer still need their existing permit.
    if (_device != null ||
        _recovery ||
        _startupBarriers.isNotEmpty ||
        _normal != 0 ||
        (transferActive &&
            !identical(Zone.current[_transferZoneKey], _transfer))) {
      throw const DeviceSyncBusy();
    }
    return _admitDevice();
  }

  DeviceTransferPermit holdTransfer() {
    if (busy || _normal != 0) throw const DeviceSyncBusy();
    final permit = DeviceTransferPermit._(this);
    _transfer = permit;
    notifyListeners();
    return permit;
  }

  DeviceAccountPermit recoveryPermit() {
    if (_device != null || _normal != 0) throw const DeviceSyncBusy();
    _recovery = true;
    return _admitDevice();
  }

  DeviceAccountPermit _admitDevice() {
    final permit = DeviceAccountPermit._(this);
    _device = permit;
    notifyListeners();
    return permit;
  }

  bool ownsDevice(DeviceAccountPermit permit) =>
      identical(_device, permit) && permit._active;

  void holdRecovery() {
    _recovery = true;
    notifyListeners();
  }

  void resolveRecovery() {
    _recovery = false;
    notifyListeners();
  }

  void _releaseDevice(DeviceAccountPermit permit) {
    if (!identical(_device, permit)) return;
    _device = null;
    notifyListeners();
  }

  void _releaseStartup(AccountStartupBarrier barrier) {
    if (_startupBarriers.remove(barrier)) notifyListeners();
  }

  void _releaseTransfer(DeviceTransferPermit permit) {
    if (!identical(_transfer, permit)) return;
    _transfer = null;
    notifyListeners();
  }
}

class DeviceTransferPermit {
  DeviceTransferPermit._(this._gate);
  final AccountWorkGate _gate;
  Future<T> run<T>(Future<T> Function() action) {
    if (!identical(_gate._transfer, this)) throw const DeviceSyncBusy();
    return runZoned(action, zoneValues: {_gate._transferZoneKey: this});
  }

  void release() => _gate._releaseTransfer(this);
}

class AccountStartupBarrier {
  AccountStartupBarrier._(this._gate);
  final AccountWorkGate _gate;
  void release() => _gate._releaseStartup(this);
}

class AccountWorkPermit {
  AccountWorkPermit._(this._gate);
  final AccountWorkGate _gate;
  bool _active = true;
  Future<T> run<T>(Future<T> Function() work) {
    if (!_active) throw const DeviceSyncBusy();
    return runZoned(work, zoneValues: {_gate._zoneKey: this});
  }

  void release() {
    if (!_active) return;
    _active = false;
    _gate._normal--;
  }
}

class DeviceAccountPermit {
  DeviceAccountPermit._(this._gate);
  final AccountWorkGate _gate;
  bool _active = true;
  void release() {
    if (!_active) return;
    _active = false;
    _gate._releaseDevice(this);
  }
}
