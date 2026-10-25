import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;
import 'bridge_fault_matrix.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];
  test(
    'real FRB TLS journal and secure-store coordinator commit then restore account backup',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      final sourceRoot = await Directory.systemTemp.createTemp(
        'nsoalbum-4b2-source-',
      );
      final targetRoot = await Directory.systemTemp.createTemp(
        'nsoalbum-4b2-target-',
      );
      String? sourceLibrary;
      String? targetLibrary;
      String? host;
      String? phone;
      try {
        final source = await native.deviceSyncOpenLibrary(
          libraryRoot: sourceRoot.path,
        );
        final target = await native.deviceSyncOpenLibrary(
          libraryRoot: targetRoot.path,
        );
        sourceLibrary = source.handle;
        targetLibrary = target.handle;
        await native.initCore(libraryRoot: targetRoot.path);
        await native.createTag(name: 'old library');
        final originalBytes = List<int>.generate(1024, (index) => index % 251);
        final input = File('${targetRoot.path}/synthetic-account-backup.jpg');
        await input.writeAsBytes(originalBytes);
        await native.importLocalFiles(paths: [input.path]);
        const gallery = GalleryQuery(
          kind: GalleryKindFilter.all,
          limit: 100,
          offset: 0,
          favoriteOnly: false,
          newestFirst: true,
          gameNames: [],
        );
        final original = (await native.listMedia(query: gallery)).single;
        await native.addTag(mediaId: original.id, tag: 'old library');
        await native.setNote(
          mediaId: original.id,
          note: 'synthetic backup note',
        );
        await native.setFavorite(mediaId: original.id, favorite: true);
        final album = await native.createAlbum(
          name: 'synthetic backup album',
          description: 'preserved description',
          smart: false,
        );
        await native.addMediaToAlbum(albumId: album, mediaId: original.id);
        Future<void> expectOriginalContent() async {
          final media = (await native.listMedia(query: gallery)).single;
          expect(media.sha256, original.sha256);
          expect(media.note, 'synthetic backup note');
          expect(media.favorite, isTrue);
          expect(media.tags, ['old library']);
          expect(await File(media.storagePath).readAsBytes(), originalBytes);
          final members = await native.listMedia(
            query: GalleryQuery(
              kind: GalleryKindFilter.all,
              limit: 100,
              offset: 0,
              favoriteOnly: false,
              newestFirst: true,
              gameNames: [],
              albumId: album,
            ),
          );
          expect(members.single.sha256, original.sha256);
          expect(
            (await native.listAlbums())
                .singleWhere((item) => item.id == album)
                .description,
            'preserved description',
          );
        }

        final invitation = await native.deviceSyncHost(
          library_: source.handle,
          name: 'Source',
          tcpAddress: '127.0.0.1:1',
        );
        host = invitation.handle;
        phone = await native.deviceSyncClient(
          library_: target.handle,
          invitation: invitation.invitation,
          name: 'Target',
        );
        for (var n = 0; n < 40; n++) {
          await pump(host, phone);
        }
        expect(
          await native.deviceSyncConfirmationCode(endpoint: host),
          await native.deviceSyncConfirmationCode(endpoint: phone),
        );
        await native.deviceSyncConfirm(endpoint: host);
        await native.deviceSyncConfirm(endpoint: phone);
        for (var n = 0; n < 20; n++) {
          await pump(host, phone);
        }
        final sourceStore = MemoryAccountStorage(
          values: {
            accountTokensKey: '{"a":"synthetic-new"}',
            accountProfilesKey: '{"a":{"nickname":"Alice","avatar_url":"private-not-exported","name_updated_at":"2026-10-24T00:00:00Z"},"removed-source":{"nickname":"Previous source user","name_updated_at":"2026-10-23T00:00:00Z"}}',
          },
        );
        final targetStore = MemoryAccountStorage(
          values: {
            legacySessionKey: 'synthetic-old-legacy',
            accountTokensKey: '{"b":"synthetic-old"}',
            selectedAccountKey: 'b',
            accountProfilesKey: '{"removed-target":{"nickname":"Previous target user","name_updated_at":"2026-10-22T00:00:00Z"}}',
          },
        );
        final sourceCoordinator = DeviceAccountCoordinator(
          library: source.handle,
          storage: sourceStore,
          gate: AccountWorkGate(),
          invalidate: (_) async {},
          publish: (_) {},
        );
        var cancelNextRestore = false;
        AccountRestorePreview? restoreToCancel;
        Completer<void>? restoreEntered, restoreRelease;
        late DeviceAccountCoordinator targetCoordinator;
        targetCoordinator = DeviceAccountCoordinator(
          library: target.handle,
          storage: targetStore,
          gate: AccountWorkGate(),
          invalidate: (_) async {
            if (restoreEntered != null) {
              if (!restoreEntered.isCompleted) restoreEntered.complete();
              await restoreRelease!.future;
            }
            if (cancelNextRestore) {
              await targetCoordinator.cancelRestore(preview: restoreToCancel);
            }
          },
          publish: (_) {},
        );
        await sourceCoordinator.authorizeSource(host, authorized: true);
        await targetCoordinator.authorizeTarget(phone, authorized: true);
        await native.deviceSyncConfigure(
          endpoint: host,
          phoneToDesktop: false,
          overwrite: true,
          includeAccounts: true,
        );
        final previewDeadline = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(previewDeadline)) {
          await pump(host, phone);
          if ((await native.deviceSyncStatus(endpoint: phone)).state ==
              'AwaitingApproval') {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(
          (await native.deviceSyncStatus(endpoint: phone)).state,
          'AwaitingApproval',
          reason: 'Synthetic account preview must finish its asynchronous scan before confirmation.',
        );
        final preview = await targetCoordinator.preview(phone);
        await targetCoordinator.approve(preview, authorized: true);
        expect(
          targetCoordinator.gate.busy,
          isFalse,
          reason: 'account work stays available during original transfer; final admission must recheck both domains',
        );
        final applyDeadline = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(applyDeadline)) {
          await pump(host, phone);
          if ((await native.deviceSyncStatus(endpoint: phone)).state ==
              'AwaitingTargetAccountFinal') {
            await targetCoordinator.authorizeFinalTarget(phone);
          }
          if ((await native.deviceSyncStatus(endpoint: host)).state ==
              'AwaitingAccountFinal') {
            await sourceCoordinator.authorizeFinalSource(host);
          }
          if ((await native.deviceSyncStatus(endpoint: phone)).state ==
              'AwaitingExternal') {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(
          (await native.deviceSyncStatus(endpoint: phone)).state,
          'AwaitingExternal',
        );
        expect(
          await native.listTags(),
          isEmpty,
          reason: 'actual target SQLite changed while its journal is pending',
        );
        expect(targetStore.values[accountTokensKey], '{"b":"synthetic-old"}');
        final applied = await targetCoordinator.applyPending(phone);
        expect(applied.finalized, isTrue);
        expect(targetStore.values[accountTokensKey], '{"a":"synthetic-new"}');
        expect(targetStore.values[selectedAccountKey], 'a');
        expect(targetStore.values.containsKey(legacySessionKey), isFalse);
        final syncedNames =
            jsonDecode(targetStore.values[accountProfilesKey]!) as Map;
        expect(
          syncedNames['removed-source']['nickname'],
          'Previous source user',
        );
        expect(
          syncedNames['removed-target']['nickname'],
          'Previous target user',
        );
        expect(syncedNames['a']['avatar_url'], isNull);
        final journal = await native.deviceSyncJournal(
          library_: target.handle,
          operation: preview.operation,
        );
        expect(journal!.stage, 'finalized');
        expect(
          (await native.deviceSyncLibraryInfo(library_: target.handle))
              .pendingOperation,
          isNull,
        );
        for (var n = 0; n < 40; n++) {
          await pump(host, phone);
        }
        expect(
          (await native.deviceSyncStatus(endpoint: host)).state,
          'Completed',
        );
        await sourceCoordinator.releaseSource(host);
        targetStore.denyReads = true;
        try {
          await expectLater(
            targetCoordinator.previewRestore(journal.backup),
            throwsA(isA<AccountConsentRequired>()),
            reason:
                'Real account ownership must reject before any protected read.',
          );
        } finally {
          targetStore.denyReads = false;
        }
        expect(targetCoordinator.gate.busy, isFalse);
        final afterDeclinedPreview = targetCoordinator.gate.normalPermit();
        afterDeclinedPreview.release();
        final protectedIndex = targetStore.values.remove(
          accountCoordinationIndexKey,
        )!;
        await expectLater(
          targetCoordinator.previewRestore(
            journal.backup,
            accountsAuthorized: true,
          ),
          throwsA(isA<AccountRecoveryRequired>()),
          reason: 'native account-bearing backup must not become library-only when its secure index is missing',
        );
        expect(await native.listTags(), isEmpty);
        expect(targetStore.values[accountTokensKey], '{"a":"synthetic-new"}');
        targetStore.values[accountCoordinationIndexKey] = protectedIndex;
        await verifyRestorePreviewBinding(
          targetCoordinator,
          targetStore,
          target.handle,
          journal.backup,
        );
        final restore = await targetCoordinator.previewRestore(
          journal.backup,
          accountsAuthorized: true,
        );
        expect(restore.includesAccounts, isTrue);
        expect(restore.change!.added, ['b']);
        expect(restore.change!.removed, ['z']);
        expect(
          restore.targetAccountDigest,
          rawAccountDigest(await readRawAccountKeys(targetStore)),
        );
        final notYetConfirmed = Map<String, String>.of(targetStore.values);
        await expectLater(
          targetCoordinator.confirmRestore(restore, authorized: false),
          throwsA(isA<AccountConsentRequired>()),
        );
        expect(targetStore.values, notYetConfirmed);
        // A normal job may cause Busy, but cannot consume a displayed preview.
        final normal = targetCoordinator.gate.normalPermit();
        await expectLater(
          targetCoordinator.confirmRestore(restore, authorized: true),
          throwsA(isA<DeviceSyncBusy>()),
        );
        normal.release();
        final foreign = DeviceAccountCoordinator(
          library: target.handle,
          storage: targetStore,
          gate: targetCoordinator.gate,
          invalidate: (_) async {},
          publish: (_) {},
        );
        await expectLater(
          foreign.confirmRestore(restore, authorized: true),
          throwsA(isA<AccountPreviewChanged>()),
        );
        final otherPreview = await targetCoordinator.previewRestore(
          journal.backup,
          accountsAuthorized: true,
        );
        restoreEntered = Completer<void>();
        restoreRelease = Completer<void>();
        final restoring = targetCoordinator
            .confirmRestore(restore, authorized: true)
            .then<Object>(
              (value) => value,
              onError: (Object failure) => failure,
            );
        try {
          await restoreEntered.future.timeout(const Duration(seconds: 20));
          await expectLater(
            targetCoordinator.confirmRestore(otherPreview, authorized: true),
            throwsA(isA<DeviceSyncBusy>()),
          );
          // Page A's rejected confirmation owns neither B's active operation
          // nor its cancellation. Even A's discarded old capability is scoped.
          await targetCoordinator.discardRestorePreview(otherPreview);
          await targetCoordinator.cancelRestore(preview: otherPreview);
        } finally {
          restoreRelease.complete();
        }
        final restoreResult = await restoring;
        restoreEntered = restoreRelease = null;
        expect(
          restoreResult,
          isA<AccountApplyResult>().having(
            (result) => result.finalized,
            'finalized',
            isTrue,
          ),
          reason: 'A stale/Busy preview cannot cancel the active restore.',
        );
        await expectLater(
          targetCoordinator.confirmRestore(restore, authorized: true),
          throwsA(isA<AccountPreviewChanged>()),
        );
        expect(await native.listTags(), ['old library']);
        expect(targetStore.values[accountTokensKey], '{"b":"synthetic-old"}');
        expect(targetStore.values[selectedAccountKey], 'b');
        expect(targetStore.values[legacySessionKey], 'synthetic-old-legacy');
        final restoredNames =
            jsonDecode(targetStore.values[accountProfilesKey]!) as Map;
        expect(
          restoredNames['removed-source']['nickname'],
          'Previous source user',
        );
        expect(
          restoredNames['removed-target']['nickname'],
          'Previous target user',
        );
        await expectOriginalContent();
        final records = jsonDecode(
          targetStore.values[accountCoordinationIndexKey]!,
        ) as Map<String, dynamic>;
        final restoreRecord = (records['entries'] as List)
            .cast<String>()
            .map(
              (id) =>
                  jsonDecode(targetStore.values[accountMaterialKey(id)]!)
                      as Map<String, dynamic>,
            )
            .lastWhere((record) => record['operation'] != preview.operation);
        cancelNextRestore = true;
        final cancelPreview = await targetCoordinator.previewRestore(
          restoreRecord['backup'] as String,
          accountsAuthorized: true,
        );
        restoreToCancel = cancelPreview;
        await expectLater(
          targetCoordinator.confirmRestore(cancelPreview, authorized: true),
          throwsA(isA<AccountRecoveryRequired>()),
        );
        cancelNextRestore = false;
        restoreToCancel = null;
        expect(await native.listTags(), ['old library']);
        expect(targetStore.values[accountTokensKey], '{"b":"synthetic-old"}');
        expect(targetStore.values[selectedAccountKey], 'b');
        expect(targetStore.values[legacySessionKey], 'synthetic-old-legacy');
        await expectOriginalContent();
        expect(
          (await native.deviceSyncLibraryInfo(library_: targetLibrary))
              .pendingOperation,
          isNull,
        );
        final savedKeys = Map<String, String>.of(targetStore.values);
        final listed = (await native.deviceSyncReadBackups(
          library_: targetLibrary,
          limit: BigInt.from(128),
        )).value!;
        final internal = listed.items
            .where(
              (item) =>
                  item.unavailableReason ==
                  read.BackupUnavailableReason.internalCompensation,
            )
            .single;
        expect(internal.includesAccounts, isNull);
        await expectLater(
          native.deviceSyncPreviewRestore(
            library_: targetLibrary,
            backup: internal.backup!,
          ),
          throwsA(anything),
        );
        await expectLater(
          targetCoordinator.previewRestore(internal.backup!),
          throwsA(anything),
        );
        expect(targetStore.values, savedKeys);
        // A user-facing safety owns its own complete old account version. The
        // source's current selection cannot change this restore.
        sourceStore.values[selectedAccountKey] = 'unrelated-source-selection';
        final reverse = await targetCoordinator.previewRestore(
          restoreRecord['backup'] as String,
          accountsAuthorized: true,
        );
        await targetCoordinator.confirmRestore(reverse, authorized: true);
        final exactOld = restoreRecord['old'] as Map<String, dynamic>;
        for (final key in accountActiveKeys) {
          expect(targetStore.values[key], exactOld[key]);
        }
        expect(await native.listMedia(query: gallery), isEmpty);
        final returnToOriginal = await targetCoordinator.previewRestore(
          journal.backup,
          accountsAuthorized: true,
        );
        await targetCoordinator.confirmRestore(
          returnToOriginal,
          authorized: true,
        );
        await expectOriginalContent();
        final rolledBackMaterials = jsonDecode(
          targetStore.values[accountCoordinationIndexKey]!,
        ) as Map<String, dynamic>;
        final compensatedNormal = (rolledBackMaterials['entries'] as List)
            .cast<String>()
            .map(
              (id) =>
                  jsonDecode(targetStore.values[accountMaterialKey(id)]!)
                      as Map<String, dynamic>,
            )
            .singleWhere((item) => item['stage'] == 'rolled_back');
        final restartedCoordinator = DeviceAccountCoordinator(
          library: targetLibrary,
          storage: targetStore,
          gate: AccountWorkGate(),
          invalidate: (_) async {},
          publish: (_) {},
        );
        expect((await restartedCoordinator.recoverStartup()).ready, isTrue);
        final normalAfterCompensation = await restartedCoordinator
            .previewRestore(
              compensatedNormal['backup'] as String,
              accountsAuthorized: true,
            );
        await restartedCoordinator.confirmRestore(
          normalAfterCompensation,
          authorized: true,
        );
        final compensatedOld = compensatedNormal['old'] as Map<String, dynamic>;
        for (final key in accountActiveKeys) {
          expect(targetStore.values[key], compensatedOld[key]);
        }
        await expectOriginalContent();
        debugPrintSynchronously(
          '4B2 real Bridge explicit account restore cancellation compensated both actual domains',
        );
        // This line is reached only after real journal/data assertions and the
        // explicit restore completed, before the process-owned global Core drops.
        debugPrintSynchronously(
          '4B2 real Bridge commit and account backup restore assertions complete',
        );
        await native.deviceSyncCloseEndpoint(endpoint: host);
        await native.deviceSyncCloseEndpoint(endpoint: phone);
        host = null;
        phone = null;
        targetLibrary = await runSecureStoreFaultMatrix(
          targetLibrary,
          targetRoot.path,
        );
        await verifyVersionOneAccountPreview(targetLibrary);
        await verifyLibraryOnlyBackupDoesNotReadAccounts(targetLibrary);
        await verifyAccountOwnerIsolation(targetLibrary);
      } catch (error, stack) {
        debugPrintSynchronously(
          'Synthetic account Bridge original failure before strict teardown: $error\n$stack',
        );
        rethrow;
      } finally {
        for (final endpoint in [host, phone]) {
          if (endpoint != null) {
            await native.deviceSyncCloseEndpoint(endpoint: endpoint);
          }
        }
        for (final handle in [sourceLibrary, targetLibrary]) {
          if (handle != null) {
            await native.deviceSyncCloseLibrary(library_: handle);
          }
        }
        RustLib.dispose();
        await sourceRoot.delete(recursive: true);
        try {
          await targetRoot.delete(recursive: true);
        } on FileSystemException catch (error) {
          if (!Platform.isWindows || error.osError?.errorCode != 32) rethrow;
          debugPrintSynchronously(
            'Synthetic TEMP retained until test process exit: ${targetRoot.path}',
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
    skip: library == null
        ? 'Set NSOALBUM_DEVICE_SYNC_TEST_LIBRARY to the freshly built test DLL; no OS storage is accessed'
        : false,
  );
}

Future<void> pump(String host, String phone) async {
  for (final (from, to) in [(host, phone), (phone, host)]) {
    final status = await native.deviceSyncStatus(endpoint: from);
    if (status.terminal && status.state != 'Completed') continue;
    await native.deviceSyncPoll(endpoint: from);
    final bytes = await native.deviceSyncDrain(endpoint: from);
    if (bytes.isNotEmpty) {
      for (var offset = 0; offset < bytes.length; offset += 65536) {
        await native.deviceSyncIngest(
          endpoint: to,
          bytes: Uint8List.sublistView(
            bytes,
            offset,
            (offset + 65536).clamp(0, bytes.length),
          ),
        );
      }
      await native.deviceSyncWritten(
        endpoint: from,
        bytes: BigInt.from(bytes.length),
      );
    }
    await native.deviceSyncFinishSuccess(endpoint: from);
  }
}
