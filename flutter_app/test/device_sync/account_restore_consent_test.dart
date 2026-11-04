import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/rust/device_sync/headless.dart';
import 'package:squid_album/src/rust/frb_generated.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeBoundary native;
  late _StorageBoundary storage;
  late AccountWorkGate gate;
  late DeviceAccountCoordinator coordinator;
  setUp(() {
    native = _NativeBoundary();
    RustLib.initMock(api: native);
    storage = _StorageBoundary();
    gate = AccountWorkGate();
    coordinator = DeviceAccountCoordinator(
      library: 'owned-library',
      storage: storage,
      gate: gate,
      invalidate: (_) async {},
      publish: (_) {},
    );
  });
  tearDown(RustLib.dispose);

  test('account ownership requires local consent before any protected material read', () async {
    native.external = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    await expectLater(
      coordinator.previewRestore('cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
      throwsA(isA<AccountConsentRequired>()),
    );
    expect(storage.reads, isEmpty);
    expect(native.previewCalls, 0);
    expect(gate.busy, isFalse);
    final permit = gate.normalPermit();
    permit.release();
  });

  test('library-only restore preview defaults to no protected read', () async {
    final shown = await coordinator.previewRestore(
      'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    );
    expect(shown.includesAccounts, isFalse);
    expect(storage.reads, isEmpty);
    expect(native.previewCalls, 1);
    expect(gate.busy, isFalse);
    await coordinator.discardRestorePreview(shown);
    expect(native.closedRestores, ['owned-restore']);
  });
}

class _StorageBoundary extends MemoryAccountStorage {
  final reads = <String>[];
  @override
  Future<String?> read(String key) async {
    reads.add(key);
    return super.read(key);
  }
}

class _NativeBoundary implements RustLibApi {
  String? external;
  int previewCalls = 0;
  final closedRestores = <String>[];
  @override
  Future<LibraryInfo> crateBridgeDeviceSyncLibraryInfo({
    required String library_,
  }) async => LibraryInfo(
    handle: library_,
    libraryUuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    generation: BigInt.zero,
  );

  @override
  Future<JournalInfo> crateBridgeDeviceSyncBackupJournal({
    required String library_,
    required String backup,
  }) async => JournalInfo(
    operation: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    library_: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    backup: backup,
    external_: external,
    stage: 'finalized',
  );

  @override
  Future<RestoreInfo> crateBridgeDeviceSyncPreviewRestore({
    required String library_,
    required String backup,
  }) async {
    previewCalls++;
    return RestoreInfo(
      handle: 'owned-restore',
      operation: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      library_: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      binding: 'binding',
      currentDigest: 'current',
      restoredDigest: 'restored',
    );
  }

  @override
  Future<void> crateBridgeDeviceSyncCloseRestore({
    required String restore,
  }) async {
    closedRestores.add(restore);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation ${invocation.memberName}');
}
