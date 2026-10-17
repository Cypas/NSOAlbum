import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/rust/device_sync/headless.dart';
import 'package:squid_album/src/rust/device_sync/read_model.dart';
import 'package:squid_album/src/rust/frb_generated.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupNativeBoundary native;
  late DeviceSyncStartupLifecycle lifecycle;
  late _StorageBoundary storage;
  late AccountWorkGate gate;
  setUp(() async {
    native = BackupNativeBoundary();
    RustLib.initMock(api: native);
    storage = _StorageBoundary();
    gate = AccountWorkGate();
    lifecycle = DeviceSyncStartupLifecycle(
      gate: gate,
      openLibrary: () async => 'owned-library',
      coordinator: (handle) => DeviceAccountCoordinator(
        library: handle,
        storage: storage,
        gate: gate,
        invalidate: (_) async {},
        publish: (_) {},
      ),
      initialize: () async {},
      isolated: false,
    );
    await lifecycle.start();
    storage.reads.clear();
  });
  tearDown(() async {
    await lifecycle.close();
    RustLib.dispose();
  });

  test(
    'bounded page isolates corrupt entries and preserves unknown account scope',
    () async {
      final browser = lifecycle.service.openBackups();
      final page = await browser.page();
      expect(page.items, hasLength(3));
      expect(
        page.items[0].metadata.unavailableReason,
        BackupUnavailableReason.invalidMetadata,
      );
      expect(page.items[1].metadata.includesAccounts, isNull);
      expect(page.items[2].metadata.includesAccounts, isFalse);
      expect(page.next, 'opaque-next');
      expect(native.pages, [(null, BigInt.from(25))]);
      await browser.page(cursor: page.next);
      expect(native.pages.last, ('opaque-next', BigInt.from(25)));
      expect(storage.reads, isEmpty);
    },
  );

  test('ineligible or unknown entries cannot read protected materials or open restore', () async {
    final browser = lifecycle.service.openBackups();
    final page = await browser.page();
    for (final entry in page.items.take(2)) {
      await expectLater(
        browser.prepareRestore(entry, accountsAuthorized: true),
        throwsA(isA<DeviceBackupUnavailable>()),
      );
    }
    expect(storage.reads, isEmpty);
    expect(native.restoreOpens, 0);
    expect(gate.busy, isFalse);
  });

  test('fresh metadata and coordinator ownership independently enforce account consent', () async {
    final browser = lifecycle.service.openBackups();
    final entry = (await browser.page()).items.last;
    native.accounts = true;
    await expectLater(
      browser.prepareRestore(entry),
      throwsA(isA<AccountPreviewChanged>()),
    );
    expect(storage.reads, isEmpty);
    native.accounts = false;
    native.external = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    await expectLater(
      browser.prepareRestore(entry),
      throwsA(isA<AccountConsentRequired>()),
    );
    expect(storage.reads, isEmpty);
    expect(native.restoreOpens, 0);
    expect(gate.busy, isFalse);
  });

  test('library-only restore requires exact local preview and explicit confirmation', () async {
    final browser = lifecycle.service.openBackups();
    final entry = (await browser.page()).items.last;
    final shown = await browser.prepareRestore(entry);
    expect(native.applies, 0);
    expect(storage.reads, isEmpty);
    expect(shown.accounts, isNull);
    expect(shown.library.media.added, BigInt.one);
    await expectLater(
      browser.confirmRestore(DeviceRestorePreviewView(library: shown.library)),
      throwsA(isA<AccountPreviewChanged>()),
    );
    expect(native.applies, 0);
    final result = await browser.confirmRestore(shown);
    expect(result.finalized, isTrue);
    expect(result.cleanupPending, isFalse);
    expect(native.applies, 1);
    expect(storage.reads, isEmpty);
    expect(native.closedRestores, ['owned-restore-1']);
    expect(gate.busy, isFalse);
    await expectLater(
      browser.confirmRestore(shown),
      throwsA(isA<AccountPreviewChanged>()),
    );
    final fresh = await browser.prepareRestore(entry);
    expect(fresh, isNot(same(shown)));
    await browser.discardPreview();
    expect(native.closedRestores, ['owned-restore-1', 'owned-restore-2']);
    await browser.close();
    expect(browser.closed, isTrue);
    expect(lifecycle.ready, isTrue);
  });
  test('close during busy notification cannot start restore writes', () async {
    final browser = lifecycle.service.openBackups();
    final entry = (await browser.page()).items.last;
    final shown = await browser.prepareRestore(entry);
    Future<void>? closing;
    browser.addListener(() {
      if (browser.busy && browser.preview != null) closing ??= browser.close();
    });
    await expectLater(
      browser.confirmRestore(shown),
      throwsA(isA<DeviceSyncBusy>()),
    );
    await closing;
    expect(native.applies, 0);
    expect(native.closedRestores, ['owned-restore-1']);
    expect(gate.busy, isFalse);
  });

  test(
    'cancel error still waits for the owned active restore to settle',
    () async {
      final browser = lifecycle.service.openBackups();
      final entry = (await browser.page()).items.last;
      final shown = await browser.prepareRestore(entry);
      native.applyRelease = Completer<void>();
      final applying = browser
          .confirmRestore(shown)
          .then<Object?>(
            (value) => value,
            onError: (Object failure) => failure,
          );
      await native.applyEntered.future;
      final cancelFailure = native.cancelFailure = StateError(
        'Synthetic restore cancellation failure',
      );
      var settled = false;
      final closing = browser.close().then<Object?>(
        (_) {
          settled = true;
          return null;
        },
        onError: (Object failure) {
          settled = true;
          return failure;
        },
      );
      await Future<void>.delayed(Duration.zero);
      try {
        expect(
          settled,
          isFalse,
          reason: 'A failed signal cannot abandon the original restore future.',
        );
        expect(native.closedRestores, isEmpty);
      } finally {
        native.applyRelease!.complete();
        expect(await applying, isA<DeviceSyncBusy>());
        expect(await closing, same(cancelFailure));
      }
      expect(native.cancelledRestores, ['owned-restore-1']);
      expect(native.closedRestores, ['owned-restore-1']);
      expect(gate.busy, isFalse);
    },
  );
}

class _StorageBoundary extends MemoryAccountStorage {
  final reads = <String>[];
  @override
  Future<String?> read(String key) async {
    reads.add(key);
    return super.read(key);
  }
}

// Test-only external native boundary reused without importing this file's main.
class BackupNativeBoundary implements RustLibApi {
  final pages = <(String?, BigInt)>[];
  final closedRestores = <String>[];
  bool accounts = false;
  String? external;
  int restoreOpens = 0, applies = 0;
  final applyEntered = Completer<void>();
  Completer<void>? applyRelease;
  Object? cancelFailure;
  Object? restoreCloseFailure;
  Object? summaryFailure;
  int summaryReads = 0;
  Future<void>? restoreCloseWait;
  final restoreCloseEntered = Completer<void>();
  int restoreCloseCalls = 0;
  final cancelledRestores = <String>[];
  static const backup = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  static const library = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  @override
  Future<LibraryInfo> crateBridgeDeviceSyncLibraryInfo({
    required String library_,
  }) async => LibraryInfo(
    handle: library_,
    libraryUuid: library,
    generation: BigInt.zero,
  );

  @override
  Future<BackupPageRead> crateBridgeDeviceSyncReadBackups({
    required String library_,
    String? cursor,
    required BigInt limit,
  }) async {
    expect(library_, 'owned-library');
    pages.add((cursor, limit));
    return BackupPageRead(
      value: BackupPage(
        items: [
          const BackupMetadata(
            unavailableReason: BackupUnavailableReason.invalidMetadata,
          ),
          const BackupMetadata(backup: 'unknown-scope'),
          BackupMetadata(
            backup: backup,
            sourceName: 'Desktop',
            includesAccounts: accounts,
          ),
        ],
        next: 'opaque-next',
      ),
    );
  }

  @override
  Future<JournalInfo> crateBridgeDeviceSyncBackupJournal({
    required String library_,
    required String backup,
  }) async => JournalInfo(
    operation: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    library_: library,
    backup: backup,
    external_: external,
    stage: 'finalized',
  );

  RestoreInfo _restore(String handle) => RestoreInfo(
    handle: handle,
    operation: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    library_: library,
    binding: 'binding-$handle',
    currentDigest: 'current',
    restoredDigest: 'restored',
  );

  @override
  Future<RestoreInfo> crateBridgeDeviceSyncPreviewRestore({
    required String library_,
    required String backup,
  }) async => _restore('owned-restore-${++restoreOpens}');

  @override
  Future<RestoreSummaryRead> crateBridgeDeviceSyncReadRestoreSummary({
    required String restore,
    required String binding,
  }) async {
    summaryReads++;
    if (summaryFailure case final failure?) throw failure;
    return RestoreSummaryRead(
      value: RestoreSummary(
        binding: binding,
        currentDigest: 'current',
        restoredDigest: 'restored',
        includesAccounts: false,
        media: ChangeCounts(
          added: BigInt.one,
          replaced: BigInt.zero,
          removed: BigInt.zero,
          kept: BigInt.zero,
        ),
        albums: ChangeCounts(
          added: BigInt.zero,
          replaced: BigInt.zero,
          removed: BigInt.zero,
          kept: BigInt.zero,
        ),
      ),
    );
  }

  @override
  Future<void> crateBridgeDeviceSyncValidateRestore({
    required String restore,
    required String binding,
  }) async {
    expect(binding, 'binding-$restore');
  }

  @override
  Future<RestoreInfo> crateBridgeDeviceSyncApplyRestore({
    required String restore,
    required String binding,
    String? external_,
  }) async {
    applies++;
    if (!applyEntered.isCompleted) applyEntered.complete();
    await applyRelease?.future;
    expect(external_, isNull);
    return _restore(restore);
  }

  @override
  Future<void> crateBridgeDeviceSyncCancelRestore({
    required String restore,
  }) async {
    cancelledRestores.add(restore);
    if (cancelFailure case final failure?) throw failure;
  }

  @override
  Future<void> crateBridgeDeviceSyncCloseRestore({
    required String restore,
  }) async {
    restoreCloseCalls++;
    if (!restoreCloseEntered.isCompleted) restoreCloseEntered.complete();
    await restoreCloseWait;
    if (restoreCloseFailure case final failure?) throw failure;
    closedRestores.add(restore);
  }

  @override
  Future<void> crateBridgeDeviceSyncCloseLibrary({
    required String library_,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation ${invocation.memberName}');
}
