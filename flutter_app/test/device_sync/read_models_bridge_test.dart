import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/rust/frb_generated.dart';

import 'account_bridge_test.dart' show pump;
import 'account_storage_test.dart' show MemoryAccountStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dll = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];
  test(
    'real FRB bounded reads allow mid-scan cancellation and reuse the same restore capability',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(dll!));
      final roots = [
        await Directory.systemTemp.createTemp('nsoalbum-5a1-source-'),
        await Directory.systemTemp.createTemp('nsoalbum-5a1-target-'),
      ];
      String? sourceLibrary, targetLibrary, host, phone;
      Future<void>? driving;
      var stopDriving = false;
      try {
        await native.initCore(libraryRoot: roots[0].path);
        for (var index = 0; index < 4096; index++) {
          await native.createTag(
            name: 'scan-${index.toString().padLeft(5, '0')}',
          );
        }
        sourceLibrary = (await native.deviceSyncOpenLibrary(
          libraryRoot: roots[0].path,
        )).handle;
        targetLibrary = (await native.deviceSyncOpenLibrary(
          libraryRoot: roots[1].path,
        )).handle;

        Future<void> pair() async {
          final invitation = await native.deviceSyncHost(
            library_: sourceLibrary!,
            name: 'Source',
            tcpAddress: '127.0.0.1:1',
          );
          host = invitation.handle;
          phone = await native.deviceSyncClient(
            library_: targetLibrary!,
            invitation: invitation.invitation,
            name: 'Target',
          );
          final initial = await native.deviceSyncReadEndpoint(endpoint: host!);
          expect(initial.error, isNull);
          expect(initial.value!.pairing, read.PairingStage.handshaking);
          expect(initial.value!.peerName, isNull);
          expect(initial.value!.confirmationAvailable, isFalse);
          expect(initial.value!.invitationRemainingMs, isNotNull);
          for (var index = 0; index < 12; index++) {
            await pump(host!, phone!);
          }
          final awaiting = (await native.deviceSyncReadEndpoint(
            endpoint: host!,
          )).value!;
          expect(awaiting.pairing, read.PairingStage.awaitingConfirmation);
          expect(awaiting.peerName, 'Target');
          expect(awaiting.confirmationAvailable, isTrue);
          await native.deviceSyncConfirm(endpoint: host!);
          await native.deviceSyncConfirm(endpoint: phone!);
          for (var index = 0; index < 8; index++) {
            await pump(host!, phone!);
          }
        }

        await pair();
        final before = await native.deviceSyncLibraryInfo(
          library_: sourceLibrary,
        );
        await native.deviceSyncConfigure(
          endpoint: host!,
          phoneToDesktop: false,
          overwrite: false,
          includeAccounts: false,
        );
        Object? driveError;
        driving = Future<void>(() async {
          try {
            while (!stopDriving) {
              await pump(host!, phone!);
            }
          } catch (error) {
            driveError = error;
          }
        });
        var observedMidScan = false;
        for (var index = 0; index < 10000; index++) {
          final status = await native.deviceSyncReadEndpoint(endpoint: host!);
          expect(status.error, anyOf(isNull, read.ReadError.busy));
          if (status.error == read.ReadError.busy &&
              status.progress.workActive &&
              status.progress.scannedItems >= BigInt.from(128) &&
              status.progress.scannedItems < BigInt.from(4096)) {
            observedMidScan = true;
            expect(status.progress.totalItems, isNull);
            expect(status.progress.transferTotalBytes, isNull);
            break;
          }
        }
        expect(
          observedMidScan,
          isTrue,
          reason: 'the real FRB consumer must observe completed pages, not merely an acquired gate',
        );
        await native
            .deviceSyncCancelSignal(endpoint: host!)
            .timeout(const Duration(seconds: 5));
        stopDriving = true;
        await driving.timeout(const Duration(seconds: 15));
        driving = null;
        expect(driveError, isNotNull);
        final cancelled = (await native.deviceSyncReadEndpoint(endpoint: host!))
            .value!;
        expect(cancelled.stage, driver.State.cancelled);
        expect(cancelled.terminal, isTrue);
        expect(cancelled.progress.workActive, isFalse);
        expect(cancelled.progress.transferTotalBytes, isNull);
        final after = await native.deviceSyncLibraryInfo(
          library_: sourceLibrary,
        );
        expect(after.generation, before.generation);
        expect(after.pendingOperation, isNull);
        await native.createTag(name: 'ordinary-write-after-frb-cancel');
        await native.deviceSyncCloseEndpoint(endpoint: host!);
        await native.deviceSyncCloseEndpoint(endpoint: phone!);
        host = phone = null;

        await pair();
        await native.deviceSyncConfigure(
          endpoint: host!,
          phoneToDesktop: false,
          overwrite: true,
          includeAccounts: false,
        );
        var reachedPreview = false;
        for (var index = 0; index < 10000; index++) {
          await pump(host!, phone!);
          final status = await native.deviceSyncReadEndpoint(endpoint: phone!);
          if (status.value?.stage == driver.State.awaitingApproval) {
            reachedPreview = true;
            break;
          }
        }
        expect(reachedPreview, isTrue);
        final preview = (await native.deviceSyncReadPreview(endpoint: phone!))
            .value!;
        expect(preview.media.added, BigInt.zero);
        expect(preview.albums.kept, BigInt.one);
        expect(preview.sourceDevice!.displayName, 'Source');
        expect(preview.space.newStagingBytes, BigInt.zero);
        expect(preview.space.excludesMetadataAndFilesystemOverhead, isTrue);
        final conflicts = await native.deviceSyncReadConflicts(
          endpoint: phone!,
          binding: preview.binding,
          limit: BigInt.from(128),
        );
        expect(conflicts.error, isNull);
        expect(conflicts.value!.items, isEmpty);
        expect(
          (await native.deviceSyncReadConflicts(
            endpoint: phone!,
            binding: 'wrong-binding',
            limit: BigInt.from(128),
          )).error,
          read.ReadError.previewChanged,
        );
        expect(
          (await native.deviceSyncReadConflicts(
            endpoint: phone!,
            binding: preview.binding,
            limit: BigInt.from(129),
          )).error,
          read.ReadError.invalidInput,
        );
        await native.deviceSyncApprove(endpoint: phone!);
        var completed = false;
        for (var index = 0; index < 10000; index++) {
          await pump(host!, phone!);
          final source = (await native.deviceSyncReadEndpoint(endpoint: host!))
              .value!;
          final target = (await native.deviceSyncReadEndpoint(endpoint: phone!))
              .value!;
          if (source.stage == driver.State.completed &&
              target.stage == driver.State.completed) {
            expect(
              source.progress.transferredBytes,
              BigInt.zero,
              reason:
                  'metadata and original reuse are not media transfer bytes',
            );
            expect(target.progress.transferTotalBytes, isNull);
            completed = true;
            break;
          }
        }
        expect(completed, isTrue);
        final backups = (await native.deviceSyncReadBackups(
          library_: targetLibrary,
          limit: BigInt.from(128),
        )).value!;
        expect(backups.items, hasLength(1));
        final backup = backups.items.single;
        expect(backup.createdAt, isNotNull);
        expect(DateTime.parse(backup.createdAt!).isUtc, isTrue);
        expect(backup.includesAccounts, isFalse);
        expect(backup.unavailableReason, isNull);
        final storage = MemoryAccountStorage(
          values: {
            accountTokensKey: '{"local":"synthetic-untouched"}',
            selectedAccountKey: 'local',
          },
        )..denyReads = true;
        final oldKeys = Map<String, String>.from(storage.values);
        DeviceAccountCoordinator coordinator() => DeviceAccountCoordinator(
          library: targetLibrary!,
          storage: storage,
          gate: AccountWorkGate(),
          invalidate: (_) async {},
          publish: (_) {},
        );
        final owner = coordinator();
        final foreign = coordinator();
        final restore = await owner.previewRestore(backup.backup!);
        final generation = await native.deviceSyncLibraryInfo(
          library_: targetLibrary,
        );
        for (var index = 0; index < 20; index++) {
          final summary = await owner.readRestoreSummary(restore);
          expect(summary.error, isNull);
          expect(summary.value!.binding, restore.binding);
          expect(summary.value!.currentDigest, restore.currentLibraryDigest);
          expect(summary.value!.restoredDigest, restore.restoredLibraryDigest);
          expect(summary.value!.includesAccounts, isFalse);
        }
        expect(
          (await foreign.readRestoreSummary(restore)).error,
          read.ReadError.previewChanged,
        );
        expect(
          (await native.deviceSyncLibraryInfo(library_: targetLibrary))
              .generation,
          generation.generation,
        );
        expect(
          (await native.deviceSyncReadBackups(
            library_: targetLibrary,
            limit: BigInt.from(128),
          )).value!.items,
          hasLength(1),
        );
        expect(storage.values, oldKeys);
        await owner.discardRestorePreview(restore);
        expect(
          (await owner.readRestoreSummary(restore)).error,
          read.ReadError.previewChanged,
        );
        final confirmed = await owner.previewRestore(backup.backup!);
        expect(
          (await owner.readRestoreSummary(confirmed)).value!.binding,
          confirmed.binding,
        );
        expect(
          (await owner.confirmRestore(confirmed, authorized: true)).finalized,
          isTrue,
        );
        expect(
          (await owner.readRestoreSummary(confirmed)).error,
          read.ReadError.previewChanged,
        );
        expect(
          storage.values,
          oldKeys,
          reason: 'no-account reads and restore must never read or modify protected keys',
        );
        final afterRestore = (await native.deviceSyncReadBackups(
          library_: targetLibrary,
          limit: BigInt.from(128),
        )).value!;
        final safety = afterRestore.items.singleWhere(
          (item) => item.backup != backup.backup,
        );
        expect(safety.unavailableReason, isNull);
        expect(safety.includesAccounts, isFalse);
        final reverse = await owner.previewRestore(safety.backup!);
        expect(
          (await owner.confirmRestore(reverse, authorized: true)).finalized,
          isTrue,
        );
        expect(storage.values, oldKeys);
        debugPrintSynchronously(
          'Task5A1 real FRB: mid-page cancel, bounded reads, same capability summary and no-account zero secure reads verified',
        );
      } finally {
        stopDriving = true;
        if (host != null) await native.deviceSyncCancelSignal(endpoint: host!);
        if (driving != null) await driving.timeout(const Duration(seconds: 15));
        for (final endpoint in [host, phone]) {
          if (endpoint != null) {
            await native.deviceSyncCloseEndpoint(endpoint: endpoint);
          }
        }
        for (final library in [sourceLibrary, targetLibrary]) {
          if (library != null) {
            await native.deviceSyncCloseLibrary(library_: library);
          }
        }
        RustLib.dispose();
        for (final root in roots) {
          try {
            await root.delete(recursive: true);
          } on FileSystemException catch (error) {
            if (!Platform.isWindows || error.osError?.errorCode != 32) rethrow;
            debugPrintSynchronously(
              'Synthetic TEMP retained until process exit: ${root.path}',
            );
          }
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: dll == null
        ? 'Set NSOALBUM_DEVICE_SYNC_TEST_LIBRARY to the freshly built DLL; only synthetic temp libraries and memory account storage are used'
        : false,
  );
}
