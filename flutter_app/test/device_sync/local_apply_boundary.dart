// Controlled native journal boundary; production controller/coordinator/storage
// code is exercised unchanged. This is not a replacement product backend.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/rust/device_sync/connection.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/headless.dart';
import 'package:squid_album/src/rust/device_sync/native_io.dart';
import 'package:squid_album/src/rust/device_sync/planner.dart';
import 'package:squid_album/src/rust/device_sync/read_model.dart';
import 'package:squid_album/src/rust/device_sync/runtime.dart';
import 'package:squid_album/src/rust/device_sync/usb.dart';
import 'package:squid_album/src/rust/device_sync/work.dart';
import 'package:squid_album/src/rust/frb_generated.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;

const localLibrary = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const localOperation = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const localBackup = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const localBinding = 'controlled-local-preview';

class LocalStorage extends MemoryAccountStorage {
  LocalStorage()
    : super(
        values: {
          accountTokensKey: '{"old":"synthetic-old"}',
          selectedAccountKey: 'old',
        },
      );
  Completer<void>? writeEntered, writeRelease;
  int activeMutations = 0;
  int? failActiveMutation;
  bool failArchive = false;
  final readbacks = <String>[];
  @override
  Future<String?> read(String key) async {
    readbacks.add(key);
    return super.read(key);
  }

  Future<void> _before(String key, String? value) async {
    if (accountActiveKeys.contains(key)) {
      activeMutations++;
      if (activeMutations == failActiveMutation) {
        throw StateError('synthetic protected storage failure');
      }
      if (key == accountTokensKey && value?.contains('incoming') == true) {
        writeEntered?.complete();
        await writeRelease?.future;
      }
    }
    if (failArchive &&
        key.startsWith('nintendo.device_sync.') &&
        value?.contains('"stage":"finalized"') == true) {
      throw StateError('synthetic archive write failure');
    }
  }

  @override
  Future<void> write(String key, String value) async {
    await _before(key, value);
    await super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await _before(key, null);
    await super.delete(key);
  }
}

class LocalNativeBoundary implements RustLibApi {
  LocalNativeBoundary(this.storage);
  final LocalStorage storage;
  driver.State stage = driver.State.pairing;
  PairingStage pairing = PairingStage.awaitingConfirmation;
  bool source = false, accounts = true, installed = false, grantIssued = false;
  bool detached = false, cancelled = false, retired = false;
  bool libraryClosed = false;
  bool lostFinalizeReturn = false;
  bool failShutdown = false;
  bool failCompensation = false;
  bool readUnavailable = false;
  String? sourceOperation = localOperation;
  String session = 'same-owned-session';
  String binding = localBinding;
  String? external, journalStage;
  int checked = 0, steps = 0, compensations = 0;
  List<String> libraryRecords = ['old media'];
  final cache = <int>[1, 2, 3, 4];
  final nativeSettled = Completer<void>();
  final usbClosed = Completer<UsbView>();
  bool usbNextFails = false, usbCompleteFails = false;
  Completer<void>? usbNextRelease;
  bool _usbActionIssued = false;
  Map<String, dynamic>? reserved;
  final events = <String>[];
  bool get terminal => [
    driver.State.completed,
    driver.State.completedUnconfirmed,
    driver.State.cancelled,
    driver.State.failed,
    driver.State.recoveryPending,
  ].contains(stage);
  @override
  Future<LibraryInfo> crateBridgeDeviceSyncLibraryInfo({
    required String library_,
  }) async => LibraryInfo(
    handle: library_,
    libraryUuid: localLibrary,
    generation: BigInt.zero,
    pendingOperation: journalStage == 'library_applied' ? localOperation : null,
  );
  @override
  Future<HostInfo> crateBridgeDeviceSyncHostTcp({
    required String library_,
    required String name,
    required String address,
    String? wifiSsid,
    ApplicationBuild? appBuild,
  }) async => const HostInfo(handle: 'local-endpoint', invitation: 'synthetic');
  @override
  Future<String> crateBridgeDeviceSyncClientUsb({
    required String library_,
    required String invitation,
    required String name,
  }) async => 'local-endpoint';
  @override
  Future<String> crateBridgeDeviceSyncConfirmationCode({
    required String endpoint,
  }) async => '123456';
  @override
  Future<void> crateBridgeDeviceSyncConfirm({required String endpoint}) async {
    pairing = PairingStage.confirmed;
    stage = driver.State.configuring;
  }

  @override
  Future<void> crateBridgeDeviceSyncConfigure({
    required String endpoint,
    required bool phoneToDesktop,
    required bool overwrite,
    required bool includeAccounts,
  }) async {
    accounts = includeAccounts;
    stage = accounts
        ? driver.State.awaitingAccountConsent
        : driver.State.awaitingApproval;
  }

  @override
  Future<void> crateBridgeDeviceSyncReceiveAccounts({
    required String endpoint,
    required String stateDigest,
  }) async {
    if (rawAccountDigest(await readRawAccountKeys(storage)) != stateDigest) {
      throw StateError('digest');
    }
    stage = driver.State.awaitingApproval;
  }

  @override
  Future<void> crateBridgeDeviceSyncExportAccounts({
    required String endpoint,
    required List<int> payload,
    required String stateDigest,
  }) async {
    if (rawAccountDigest(await readRawAccountKeys(storage)) != stateDigest) {
      throw StateError('digest');
    }
  }

  @override
  Future<EndpointStatus> crateBridgeDeviceSyncStatus({
    required String endpoint,
  }) async => EndpointStatus(
    state: _stateName(stage),
    terminal: terminal,
    source: source,
    includeAccounts: accounts,
    overwrite: true,
    session: session,
    operation: source ? sourceOperation : localOperation,
    targetLibrary: localLibrary,
    binding: binding,
    backup: journalStage == null ? null : localBackup,
    cleanupPending: false,
    localApplyInstalled: installed,
    sourceGrantIssued: grantIssued,
    transportDetached: detached,
  );
  @override
  Future<EndpointRead> crateBridgeDeviceSyncReadEndpoint({
    required String endpoint,
  }) async {
    final progress = ProgressView(
      workStage: WorkStage.idle,
      workActive: false,
      scannedItems: BigInt.zero,
      transferredBytes: BigInt.from(123),
    );
    if (readUnavailable) {
      return EndpointRead(progress: progress, error: ReadError.unavailable);
    }
    return EndpointRead(
      progress: progress,
      tcp: TcpView(
        phase: detached ? TcpPhase.closed : TcpPhase.connected,
        error: detached ? ReadError.disconnected : null,
      ),
      value: EndpointView(
        pairing: pairing,
        confirmationAvailable: pairing == PairingStage.awaitingConfirmation,
        transport: TransportKind.tcp,
        host: false,
        controller: true,
        phoneControlled: false,
        accountsConsentAuthorized: false,
        previewApproved: false,
        source: source,
        configuration:
            stage == driver.State.pairing || stage == driver.State.configuring
            ? null
            : AgreedConfiguration(
                phoneToDesktop: source,
                mode: SyncMode.overwrite,
                includeAccounts: accounts,
              ),
        stage: stage,
        terminal: terminal,
        cleanupPending: false,
        progress: progress,
        localApplyInstalled: installed,
        sourceGrantIssued: grantIssued,
        transportDetached: detached,
      ),
    );
  }

  @override
  Future<PreviewRead> crateBridgeDeviceSyncReadPreview({
    required String endpoint,
  }) async => PreviewRead(
    value: PreviewSummary(
      binding: binding,
      mode: SyncMode.overwrite,
      media: _counts(),
      albums: _counts(),
      conflicts: ConflictCounts(
        unknownRevision: BigInt.zero,
        equalRevision: BigInt.zero,
        clockSkew: BigInt.zero,
      ),
      space: SpaceEstimate(
        newStagingBytes: BigInt.zero,
        reusableOriginalBytes: BigInt.zero,
        backupOriginalBytes: BigInt.zero,
        backupBytesIfCopied: BigInt.zero,
        conservativeContentBytes: BigInt.zero,
        excludesMetadataAndFilesystemOverhead: true,
      ),
    ),
  );
  @override
  Future<Uint8List?> crateBridgeDeviceSyncAccountPayload({
    required String endpoint,
  }) async => Uint8List.fromList(
    utf8.encode(
      '{"version":1,"accounts":[{"account_id":"incoming","nickname":"Synthetic","session_token":"synthetic-new"}]}',
    ),
  );
  @override
  Future<void> crateBridgeDeviceSyncApproveAccounts({
    required String endpoint,
    required String binding,
    required String stateDigest,
    required String external_,
  }) async {
    external = external_;
    stage = driver.State.awaitingTargetAccountFinal;
  }

  @override
  Future<void> crateBridgeDeviceSyncTargetFinal({
    required String endpoint,
    required String stateDigest,
  }) async {
    final index =
        jsonDecode(storage.values[accountCoordinationIndexKey]!) as Map;
    if (!(index['entries'] as List).contains(external)) {
      throw StateError('unreserved index');
    }
    reserved = jsonDecode(
      storage.values[accountMaterialKey(external!)]!,
    ) as Map<String, dynamic>;
    if (reserved!['operation'] != localOperation ||
        reserved!['binding'] != binding ||
        !storage.readbacks.contains(accountMaterialKey(external!)) ||
        !storage.readbacks.contains(accountCoordinationIndexKey)) {
      throw StateError('unverified reserve');
    }
    installed = true;
    journalStage = 'library_applied';
    libraryRecords = ['incoming media'];
    stage = driver.State.awaitingExternal;
  }

  @override
  Future<void> crateBridgeDeviceSyncSourceFinal({
    required String endpoint,
    required String stateDigest,
  }) async {
    grantIssued = true;
    stage = driver.State.verifying;
  }

  @override
  Future<JournalInfo?> crateBridgeDeviceSyncJournal({
    required String library_,
    required String operation,
  }) async => journalStage == null
      ? null
      : JournalInfo(
          operation: localOperation,
          library_: localLibrary,
          backup: localBackup,
          external_: external,
          stage: journalStage!,
        );
  void _check() {
    if (cancelled || !installed || journalStage != 'library_applied') {
      throw const DeviceCommandError(
        code: ReadError.cancelled,
        executed: false,
      );
    }
  }

  @override
  Future<void> crateBridgeDeviceSyncExternalCheck({
    required String endpoint,
  }) async {
    _check();
    checked++;
  }

  @override
  Future<void> crateBridgeDeviceSyncExternalStep({
    required String endpoint,
  }) async {
    _check();
    steps++;
  }

  @override
  Future<void> crateBridgeDeviceSyncFinalizeAccounts({
    required String endpoint,
    required String external_,
  }) async {
    _check();
    final candidate = (reserved!['candidate'] as Map).cast<String, String?>();
    if (external_ != external ||
        rawAccountDigest(await readRawAccountKeys(storage)) !=
            rawAccountDigest(candidate)) {
      throw StateError('unverified candidate');
    }
    journalStage = 'finalized';
    stage = driver.State.completed;
    if (lostFinalizeReturn) throw StateError('synthetic lost finalized return');
  }

  @override
  Future<void> crateBridgeDeviceSyncCancelSignal({
    required String endpoint,
  }) async {
    events.add('cancel');
    cancelled = true;
    _detach();
  }

  void _detach() {
    detached = true;
    if (!usbClosed.isCompleted) {
      usbClosed.complete(
        UsbView(
          closed: true,
          reason: UsbCloseReason.failure,
          error: ReadError.disconnected,
          devices: const [],
        ),
      );
    }
  }

  @override
  Future<void> crateBridgeDeviceSyncDetachTransport({
    required String endpoint,
  }) async {
    events.add('detach');
    _detach();
  }

  @override
  Future<void> crateBridgeDeviceSyncShutdown({required String endpoint}) async {
    events.add('native-settle');
    if (failShutdown) throw StateError('synthetic native cleanup failure');
    if (!nativeSettled.isCompleted) nativeSettled.complete();
    if (journalStage == 'finalized') {
      stage = driver.State.completed;
    } else {
      stage = journalStage == null
          ? driver.State.cancelled
          : driver.State.recoveryPending;
    }
  }

  @override
  Future<JournalInfo> crateBridgeDeviceSyncCompensate({
    required String library_,
    required String operation,
  }) async {
    if (failCompensation) throw StateError('synthetic compensation failure');
    if (reserved != null &&
        rawAccountDigest(await readRawAccountKeys(storage)) !=
            rawAccountDigest(
              (reserved!['old'] as Map).cast<String, String?>(),
            )) {
      throw StateError('old keys not restored');
    }
    compensations++;
    journalStage = 'rolled_back';
    libraryRecords = ['old media'];
    return (await crateBridgeDeviceSyncJournal(
      library_: library_,
      operation: operation,
    ))!;
  }

  @override
  Future<void> crateBridgeDeviceSyncCloseEndpoint({
    required String endpoint,
  }) async {
    retired = true;
    events.add('retire');
  }

  @override
  Future<void> crateBridgeDeviceSyncCloseLibrary({
    required String library_,
  }) async {
    libraryClosed = true;
    events.add('library-retire');
  }

  @override
  Future<UsbAction?> crateBridgeDeviceSyncUsbNext({
    required String endpoint,
  }) async {
    await usbNextRelease?.future;
    if (usbNextFails) {
      throw StateError('synthetic unknown transport receipt');
    }
    if (usbCompleteFails && !_usbActionIssued) {
      _usbActionIssued = true;
      return UsbAction(
        token: 'owned-action',
        generation: 'owned-generation',
        operation: 'a' * 32,
        session: 'b' * 32,
        kind: UsbActionKind.list,
        direction: Direction.desktop,
        bytes: Uint8List(0),
      );
    }
    return null;
  }

  @override
  Future<void> crateBridgeDeviceSyncUsbComplete({
    required String endpoint,
    required UsbReply reply,
  }) async {
    if (usbCompleteFails) {
      throw StateError('synthetic unknown complete receipt');
    }
  }

  @override
  Future<UsbView> crateBridgeDeviceSyncUsbWaitClosed({
    required String endpoint,
  }) => usbClosed.future;
  @override
  Future<UsbView> crateBridgeDeviceSyncUsbView({
    required String endpoint,
  }) async => UsbView(
    closed: detached,
    reason: detached ? UsbCloseReason.failure : null,
    error: detached ? ReadError.disconnected : null,
    devices: const [],
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected ${invocation.memberName}');
}

ChangeCounts _counts() => ChangeCounts(
  added: BigInt.zero,
  replaced: BigInt.zero,
  removed: BigInt.zero,
  kept: BigInt.zero,
);
String _stateName(driver.State stage) =>
    '${stage.name[0].toUpperCase()}${stage.name.substring(1)}';
