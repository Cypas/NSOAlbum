import 'package:flutter/foundation.dart';

import '../../backend/app_backend.dart';
import '../../backend/device_sync/account_gate.dart' show DeviceSyncBusy;
import '../../backend/device_sync/service_contract.dart';
import '../../backend/device_sync/startup_lifecycle.dart';
import '../../platform/device_sync_network.dart';
import '../../platform/device_sync_build.dart';
import '../../rust/bridge.dart' as native;
import '../../rust/device_sync/connection.dart';
import '../../rust/device_sync/read_model.dart' as read;

/// Page-level resource factories, never account storage, roots, or native Core.
abstract class DeviceSyncPageAccess extends ChangeNotifier {
  Future<void> logError(Object error, [StackTrace? stackTrace]) async {}
  bool get ready;
  bool get checking;
  bool get canCheckRecovery;
  Future<void> checkRecovery();
  Future<List<DeviceLanAddress>> wifiAddresses();
  Future<DeviceWifiSnapshot> wifiInfo({bool requestPermission = false});
  Future<InvitationConnection> inspectInvitation(String invitation);
  Future<DeviceSyncSessionController> host({
    required bool usb,
    required String name,
    String? address,
    String? wifiSsid,
  });
  Future<DeviceSyncSessionController> joinWifi({
    required String invitation,
    required String name,
  });
  DeviceUsbAttemptController prepareUsb({
    required String invitation,
    required String name,
  });
  DeviceBackupBrowserController openBackups();
}

final class BackendDeviceSyncPageAccess extends DeviceSyncPageAccess {
  BackendDeviceSyncPageAccess(AppBackend backend)
    : _backend = backend,
      _owner = backend is DeviceSyncStartupBackend
          ? (backend as DeviceSyncStartupBackend).deviceSyncStartup
          : null {
    _owner?.addListener(_changed);
  }
  final DeviceSyncStartupLifecycle? _owner;
  final AppBackend _backend;
  final _network = DeviceNetworkReader();
  bool _disposed = false;
  void _changed() => notifyListeners();
  @override
  Future<void> logError(Object error, [StackTrace? stackTrace]) =>
      _backend.logError('Device sync operation failed', error, stackTrace);
  @override
  bool get ready =>
      !_disposed && _owner?.ready == true && _owner?.isolated == false;
  @override
  bool get checking => _owner?.busy == true;
  @override
  bool get canCheckRecovery =>
      _owner != null &&
      !_owner.isolated &&
      ![
        DeviceStartupPhase.closing,
        DeviceStartupPhase.closed,
      ].contains(_owner.phase);
  DeviceSyncService get _service {
    if (!ready) throw const DeviceSyncBusy();
    return _owner!.service;
  }

  @override
  Future<void> checkRecovery() async {
    if (!canCheckRecovery) throw const DeviceSyncBusy();
    await _owner!.start();
  }

  @override
  Future<List<DeviceLanAddress>> wifiAddresses() => _service.wifiAddresses();
  @override
  Future<DeviceWifiSnapshot> wifiInfo({bool requestPermission = false}) =>
      _network.read(requestPermission: requestPermission);
  @override
  Future<InvitationConnection> inspectInvitation(String invitation) async {
    if (!ready) throw const DeviceSyncBusy();
    try {
      return await native.deviceSyncInspectInvitation(
        invitation: invitation,
        appBuild: await loadDeviceApplicationBuild(),
      );
    } catch (error) {
      if (error == read.ReadError.invalidInput || error is! read.ReadError) {
        throw const DeviceInvitationFailure();
      }
      throw DeviceSyncReadFailure(error);
    }
  }

  @override
  Future<DeviceSyncSessionController> host({
    required bool usb,
    required String name,
    String? address,
    String? wifiSsid,
  }) async {
    final build = await loadDeviceApplicationBuild();
    return usb
        ? _service.hostUsb(name: name, appBuild: build)
        : _service.hostWifi(
            address: address!,
            name: name,
            wifiSsid: wifiSsid,
            appBuild: build,
          );
  }

  @override
  Future<DeviceSyncSessionController> joinWifi({
    required String invitation,
    required String name,
  }) => _service.joinWifi(invitation: invitation, name: name);
  @override
  DeviceUsbAttemptController prepareUsb({
    required String invitation,
    required String name,
  }) => _service.prepareUsbClient(invitation: invitation, name: name);
  @override
  DeviceBackupBrowserController openBackups() => _service.openBackups();
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _owner?.removeListener(_changed);
    super.dispose();
  }
}
