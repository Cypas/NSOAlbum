import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/rust/device_sync/connection.dart';
import 'package:squid_album/src/rust/device_sync/headless.dart';
import 'package:squid_album/src/rust/device_sync/read_model.dart';
import 'package:squid_album/src/rust/frb_generated.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;
import 'controlled_backups_test.dart' show BackupNativeBoundary;
import 'session_panel_test.dart' show endpoint, samePreview;

import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ProjectionBoundary boundary;
  late DeviceSyncStartupLifecycle lifecycle;
  late _FaultStorage storage;
  setUp(() async {
    boundary = _ProjectionBoundary();
    RustLib.initMock(api: boundary);
    final gate = AccountWorkGate();
    storage = _FaultStorage();
    lifecycle = DeviceSyncStartupLifecycle(
      gate: gate,
      openLibrary: () async => 'owned-library',
      coordinator: (library) => DeviceAccountCoordinator(
        library: library,
        storage: storage,
        gate: gate,
        invalidate: (_) async {},
        publish: (_) {},
      ),
      initialize: () async {},
      isolated: false,
    );
    await lifecycle.start();
  });
  tearDown(() async {
    await lifecycle.close();
    RustLib.dispose();
  });

  test('successful preview refresh clears an earlier failed read', () async {
    final session = await lifecycle.service.hostWifi(
      address: '192.168.1.2',
      name: 'Synthetic',
    );
    boundary.previewError = ReadError.unavailable;
    await expectLater(
      session.refreshPreview(),
      throwsA(isA<AccountPreviewChanged>()),
    );
    expect(session.issue, ReadError.unavailable);
    boundary.previewError = null;
    final preview = await session.refreshPreview();
    expect(preview.library.binding, samePreview.library.binding);
    expect(session.issue, isNull);
  });

  test(
    'successful projection does not dismiss recovery-required issue',
    () async {
      final session = await lifecycle.service.hostWifi(
        address: '192.168.1.2',
        name: 'Synthetic',
      );
      boundary.previewError = ReadError.recoveryRequired;
      await expectLater(
        session.refreshPreview(),
        throwsA(isA<AccountPreviewChanged>()),
      );
      boundary.previewError = null;
      await session.refreshPreview();
      expect(session.issue, ReadError.recoveryRequired);
    },
  );

  test('fatal automatic advance remains blocked after successful later observation', () async {
    final session = await lifecycle.service.hostWifi(
      address: '192.168.1.2',
      name: 'Synthetic',
    );
    boundary.stage = driver.State.awaitingAccountConsent;
    storage.failRead = true;
    await session.refresh();
    expect(session.issue, ReadError.internal);
    final reads = storage.activeReads;
    storage.failRead = false;
    await session.refresh();
    expect(session.issue, ReadError.internal);
    expect(
      storage.activeReads,
      reads,
      reason: 'Fatal advancement is not automatically replayed.',
    );
  });
}

// Only the native read/ownership boundary is replaced. Preview retry and issue
// ownership are exercised through the real recovered session/controller.
class _ProjectionBoundary extends BackupNativeBoundary {
  ReadError? previewError;
  driver.State stage = driver.State.awaitingApproval;
  @override
  Future<HostInfo> crateBridgeDeviceSyncHostTcp({
    required String library_,
    required String name,
    required String address,
    String? wifiSsid,
    ApplicationBuild? appBuild,
  }) async =>
      const HostInfo(handle: 'projection-endpoint', invitation: 'synthetic');
  @override
  Future<EndpointRead> crateBridgeDeviceSyncReadEndpoint({
    required String endpoint,
  }) async => endpointView;
  EndpointRead get endpointView => endpoint(
    stage,
    source: stage == driver.State.awaitingAccountConsent,
    accountsConsentAuthorized: stage == driver.State.awaitingAccountConsent,
    configuration: AgreedConfiguration(
      phoneToDesktop: stage == driver.State.awaitingAccountConsent,
      mode: samePreview.library.mode,
      includeAccounts: stage == driver.State.awaitingAccountConsent,
    ),
  );
  @override
  Future<EndpointStatus> crateBridgeDeviceSyncStatus({
    required String endpoint,
  }) async => EndpointStatus(
    state: stage == driver.State.awaitingAccountConsent
        ? 'AwaitingAccountConsent'
        : 'AwaitingApproval',
    terminal: false,
    source: true,
    includeAccounts: true,
    overwrite: false,
    session: 'synthetic-session',
    cleanupPending: false,
    localApplyInstalled: false,
    sourceGrantIssued: false,
    transportDetached: false,
  );
  @override
  Future<PreviewRead> crateBridgeDeviceSyncReadPreview({
    required String endpoint,
  }) async => PreviewRead(
    value: previewError == null ? samePreview.library : null,
    error: previewError,
  );
  @override
  Future<void> crateBridgeDeviceSyncCancelSignal({
    required String endpoint,
  }) async {}
  @override
  Future<void> crateBridgeDeviceSyncShutdown({
    required String endpoint,
  }) async {}
  @override
  Future<void> crateBridgeDeviceSyncCloseEndpoint({
    required String endpoint,
  }) async {}
}

class _FaultStorage extends MemoryAccountStorage {
  bool failRead = false;
  int activeReads = 0;
  @override
  Future<String?> read(String key) {
    if (accountActiveKeys.contains(key)) {
      activeReads++;
      if (failRead) throw StateError('Synthetic protected-storage failure');
    }
    return super.read(key);
  }
}
