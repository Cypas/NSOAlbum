import 'package:flutter/foundation.dart';

import '../../rust/device_sync/read_model.dart' as read;
import '../../rust/device_sync/planner.dart' as plan;

/// Display values are freely constructible; they are never execution permits.
class DeviceAccountCounts {
  const DeviceAccountCounts({
    required this.added,
    required this.replaced,
    required this.removed,
  });
  final int added, replaced, removed;
}

class DeviceSyncPreviewView {
  const DeviceSyncPreviewView({required this.library, this.accounts});
  final read.PreviewSummary library;
  final DeviceAccountCounts? accounts;
}

class DeviceSyncProposal {
  const DeviceSyncProposal({
    required this.phoneToDesktop,
    required this.mode,
    required this.includeAccounts,
  });
  final bool phoneToDesktop;
  final plan.SyncMode mode;
  final bool includeAccounts;
}

/// Safe display data, not a native device identity or an execution permit.
class DeviceUsbStorageChoice {
  const DeviceUsbStorageChoice({
    required this.deviceName,
    required this.storageName,
    required this.freeBytes,
  });
  final String deviceName, storageName;
  final BigInt freeBytes;
}

class DeviceLanAddress {
  const DeviceLanAddress({required this.interfaceName, required this.address});
  final String interfaceName, address;
}

abstract class DeviceSyncSessionController extends ChangeNotifier {
  bool get closed;
  bool get settled;
  bool get busy;
  bool get confirmedLocally;
  bool get accountsAuthorized;
  String? get invitation;
  String? get confirmationCode;
  read.EndpointRead? get snapshot;
  DeviceSyncProposal? get proposedConfiguration;
  DeviceSyncPreviewView? get preview;
  read.ReadError? get issue;
  Future<read.EndpointRead> refresh();
  Future<void> confirmPairing();
  Future<void> configure({
    required bool phoneToDesktop,
    required bool overwrite,
    bool includeAccounts = false,
  });
  Future<void> consentAccounts({required bool accepted});
  Future<DeviceSyncPreviewView> refreshPreview();
  Future<void> approvePreview(DeviceSyncPreviewView shown);
  Future<read.ConflictPageRead> conflicts(
    DeviceSyncPreviewView shown, {
    String? cursor,
  });
  Future<List<DeviceUsbStorageChoice>> usbChoices();
  Future<void> selectUsb(DeviceUsbStorageChoice choice);
  Future<void> close();
}

abstract interface class DeviceUsbAttemptController {
  Future<DeviceSyncSessionController> connect();
  Future<void> cancel();
}

class DeviceBackupEntry {
  const DeviceBackupEntry(this.metadata);
  final read.BackupMetadata metadata;
}

class DeviceBackupPageView {
  const DeviceBackupPageView({required this.items, this.next});
  final List<DeviceBackupEntry> items;
  final String? next;
}

class DeviceRestorePreviewView {
  const DeviceRestorePreviewView({required this.library, this.accounts});
  final read.RestoreSummary library;
  final DeviceAccountCounts? accounts;
}

class DeviceRestoreResult {
  const DeviceRestoreResult({
    required this.finalized,
    required this.cleanupPending,
  });
  final bool finalized, cleanupPending;
}

final class DeviceBackupUnavailable implements Exception {
  const DeviceBackupUnavailable();
  @override
  String toString() => 'This backup is not available for restoration';
}

final class DeviceSyncReadFailure implements Exception {
  const DeviceSyncReadFailure(this.code);
  final read.ReadError code;
  @override
  String toString() => 'Device synchronization read failed (${code.name})';
}

abstract class DeviceBackupBrowserController extends ChangeNotifier {
  bool get closed;

  /// All this browser's admitted work and exact native previews have retired.
  /// A close signal/error or an idle recovery gate alone is not this proof.
  bool get settled;
  bool get busy;
  DeviceRestorePreviewView? get preview;
  Future<DeviceBackupPageView> page({String? cursor});
  Future<DeviceRestorePreviewView> prepareRestore(
    DeviceBackupEntry entry, {
    bool accountsAuthorized = false,
  });
  Future<DeviceRestoreResult> confirmRestore(DeviceRestorePreviewView shown);
  Future<void> discardPreview();
  Future<void> close();
}
