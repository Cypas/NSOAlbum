import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/backend/device_sync/usb_saf_owner.dart';
import 'package:squid_album/src/platform/device_sync_saf.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/read_model.dart';
import 'package:squid_album/src/rust/device_sync/usb.dart';
import 'package:squid_album/src/rust/frb_generated.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;

/// Test-only capabilities reuse the exact private peer/OS fixture and its
/// diagnostics. Importing this library never invokes its main/old tests.
typedef UsbPeerFixture = ({
  Process process,
  Directory root,
  Future<String> invitation,
  void Function(String) grant,
  Future<Map<String, dynamic>> Function() finish,
  String Function() diagnostics,
});

Future<UsbPeerFixture> startUsbPeerFixture(String executable) async {
  final peer = await _Peer.start(executable);
  return (
    process: peer.process,
    root: peer.root,
    invitation: peer.invitation.future,
    grant: peer.grant,
    finish: peer.finish,
    diagnostics: () =>
        'peerExit=${peer.exited} stderrBytes=${peer.stderrBytes} stderrKind=${peer.stderrKind}',
  );
}

typedef UsbDirectoryFixture = ({
  Future<Object?> Function(MethodCall) call,
  List<String> methods,
  String Function() diagnostics,
});

UsbDirectoryFixture usbDirectoryFixture(Directory root) {
  final boundary = _DirectoryBoundary(root);
  return (
    call: boundary.call,
    methods: boundary.methods,
    diagnostics: () =>
        'completed=${boundary.completed} boundaryFailures=${boundary.failures}',
  );
}

final class _Peer {
  _Peer(this.process, this.root);
  final Process process;
  final Directory root;
  final invitation = Completer<String>();
  final done = Completer<Map<String, dynamic>>();
  late Future<void> output;
  late Future<void> errors;
  int stderrBytes = 0;
  String stderrKind = 'none';
  int? exited;

  static Future<_Peer> start(
    String executable, {
    bool failFinalAck = false,
  }) async {
    final root = await Directory.systemTemp.createTemp('nsoalbum-5a3-peer-');
    final process = await Process.start(
      executable,
      [
        '--exact',
        'device_sync::usb_tests::usb_frb_peer',
        '--ignored',
        '--nocapture',
        '--test-threads=1',
      ],
      environment: {
        'NSOALBUM_DEVICE_SYNC_USB_PEER_ROOT': root.path,
        'NSOALBUM_DEVICE_SYNC_USB_PEER_FAIL_FINAL_ACK': failFinalAck
            ? '1'
            : '0',
      },
    );
    final peer = _Peer(process, root);
    debugPrint(
      'USB synthetic peer root=${root.uri.pathSegments.where((part) => part.isNotEmpty).last}',
    );
    unawaited(
      process.exitCode.then((value) {
        peer.exited = value;
      }),
    );
    peer.output = peer._readOutput();
    peer.errors = peer._drainErrors();
    return peer;
  }

  Future<void> _readOutput() async {
    var total = 0;
    final line = <int>[];
    try {
      await for (final bytes in process.stdout) {
        total += bytes.length;
        if (total > 32768) throw StateError('Test peer output limit');
        for (final byte in bytes) {
          if (byte == 10) {
            final text = utf8.decode(line);
            line.clear();
            const prefix = 'NSOALBUM_USB_PEER ';
            final prefixAt = text.indexOf(prefix);
            if (prefixAt < 0) continue;
            final event = jsonDecode(
              text.substring(prefixAt + prefix.length),
            ) as Map<String, dynamic>;
            if (event['kind'] == 'invitation' && !invitation.isCompleted) {
              invitation.complete(event['value'] as String);
            } else if (event['kind'] == 'done' && !done.isCompleted) {
              done.complete(event['value'] as Map<String, dynamic>);
            }
          } else {
            if (line.length >= 12288) throw StateError('Test peer line limit');
            line.add(byte);
          }
        }
      }
    } catch (_) {
      process.kill();
    }
    if (!invitation.isCompleted) {
      invitation.completeError(
        StateError('Test peer did not create invitation'),
      );
    }
    if (!done.isCompleted) done.complete({'state': 'TestPeerEnded'});
  }

  Future<void> _drainErrors() async {
    var total = 0;
    await for (final bytes in process.stderr) {
      total += bytes.length;
      stderrBytes = total;
      final text = utf8.decode(bytes, allowMalformed: true);
      if (text.contains('invalid bounded child grant')) {
        stderrKind = 'invalid-grant';
      } else if (text.contains('PermissionDenied')) {
        stderrKind = 'permission-denied';
      }
      if (total > 16384) process.kill();
    }
  }

  void grant(String command) => process.stdin.writeln(command);

  Future<Map<String, dynamic>> finish() async {
    final exit = await process.exitCode.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        process.kill();
        throw StateError('Test peer exit deadline');
      },
    );
    await output;
    await errors;
    expect(exit, 0, reason: 'Controlled synthetic peer must exit cleanly');
    return done.future;
  }
}

/// Only the slow OS boundary is replaced. Both peers retain their real Rust
/// Session/Driver/MailboxPump, while this moves opaque bytes in fresh TEMP.
enum _ReadFault { none, missingFile, corruptTls }

final class _BoundaryFailure {
  const _BoundaryFailure({
    required this.method,
    required this.type,
    required this.fileSystemException,
    required this.osCode,
    required this.platformCode,
  });
  final String method;
  final Type type;
  final bool fileSystemException;
  final int? osCode;
  final String? platformCode;
  @override
  String toString() =>
      'method=$method type=$type osCode=$osCode platformCode=$platformCode';
}

final class _DirectoryBoundary {
  _DirectoryBoundary(this.root, {this.readFault = _ReadFault.none});
  final Directory root;
  final _ReadFault readFault;
  int readFaultsInjected = 0;
  String? operation, session, ownerToken;
  final receipts = <String, Uint8List>{};
  final methods = <String>[];
  final retiredTokens = <String>[];
  final failures = <_BoundaryFailure>[];
  final completed = <String>[];
  bool deny = false;
  bool failClose = false;
  bool hangRead = false;
  File? pendingRead;
  final readEntered = Completer<void>();
  final delayedRead = Completer<Uint8List>();

  Directory folder(String direction) =>
      Directory('${root.path}/exchange/s-$session/$direction');

  Future<Object?> call(MethodCall call) async {
    try {
      final result = await _call(call);
      if (call.method != 'listBlocks') {
        completed.add(call.method);
        if (completed.length > 8) completed.removeAt(0);
      }
      return result;
    } catch (failure) {
      // Synthetic OS boundary diagnostics only: never exception messages,
      // filesystem paths, scope tokens or ciphertext/account contents.
      final osCode = failure is FileSystemException
          ? failure.osError?.errorCode
          : null;
      final platformCode = failure is PlatformException
          ? switch (failure.code) {
              'DEVICE_SYNC_UNAVAILABLE' ||
              'DIRECTORY_NOT_AUTHORIZED' ||
              'BUSY' => failure.code,
              _ => 'other',
            }
          : null;
      final summary = _BoundaryFailure(
        method: call.method,
        type: failure.runtimeType,
        fileSystemException: failure is FileSystemException,
        osCode: osCode,
        platformCode: platformCode,
      );
      if (failures.length < 8) {
        failures.add(summary);
        debugPrint('USB synthetic boundary exception $summary');
      }
      rethrow;
    }
  }

  Future<Object?> _call(MethodCall call) async {
    methods.add(call.method);
    final args = call.arguments as Map<Object?, Object?>;
    if (call.method == 'cancel' || call.method == 'close') {
      if (args['operationId'] != operation ||
          args['sessionId'] != session ||
          args['ownerToken'] != ownerToken) {
        return null;
      }
      if (call.method == 'close' && failClose) {
        throw PlatformException(code: 'DEVICE_SYNC_UNAVAILABLE');
      }
      retiredTokens.add(ownerToken!);
      operation = session = ownerToken = null;
      receipts.clear();
      return null;
    }
    if (call.method == 'openSession') {
      if (operation != null) throw PlatformException(code: 'BUSY');
      if (deny) throw PlatformException(code: 'DIRECTORY_NOT_AUTHORIZED');
      operation = args['operationId'] as String;
      session = args['sessionId'] as String;
      ownerToken = args['ownerToken'] as String;
      for (final d in ['desktop', 'mobile']) {
        await folder(d).create(recursive: true);
      }
      return null;
    }
    expect(args['operationId'], operation);
    expect(args['sessionId'], session);
    expect(args['ownerToken'], ownerToken);
    final direction = args['direction'] as String? ?? 'mobile';
    final directory = folder(direction);
    final name = args['name'] as String?;
    switch (call.method) {
      case 'listBlocks':
        final names = await directory
            .list()
            .where((entry) => !entry.path.endsWith('.part'))
            .map((entry) => entry.uri.pathSegments.last)
            .toList();
        names.sort();
        expect(names.length, lessThanOrEqualTo(128));
        return names;
      case 'readBlock':
        if (readFault == _ReadFault.missingFile && readFaultsInjected == 0) {
          readFaultsInjected++;
          final missing = File('${directory.path}/diagnostic-missing.block');
          expect(await missing.exists(), isFalse);
          // An actual failed filesystem operation, not a forged exception.
          return missing.readAsBytes();
        }
        if (hangRead) {
          pendingRead = File('${directory.path}/$name');
          if (!readEntered.isCompleted) readEntered.complete();
          final bytes = await delayedRead.future;
          receipts[name!] = Uint8List.fromList(bytes);
          return bytes;
        }
        final bytes = await File('${directory.path}/$name').readAsBytes();
        expect(bytes.length, inInclusiveRange(29, 8 * 1024 * 1024));
        expect(bytes.take(8), [78, 83, 79, 85, 83, 66, 51, 0]);
        if (readFault == _ReadFault.corruptTls && readFaultsInjected == 0) {
          readFaultsInjected++;
          // Keep the v3 header and per-drain length intact. Alter TLS only.
          bytes[bytes.length - 1] ^= 1;
        }
        receipts[name!] = Uint8List.fromList(bytes);
        return bytes;
      case 'writeCiphertextBlock':
        final bytes = args['bytes'] as Uint8List;
        expect(bytes.length, inInclusiveRange(29, 8 * 1024 * 1024));
        expect(bytes.take(8), [78, 83, 79, 85, 83, 66, 51, 0]);
        final target = File('${directory.path}/$name');
        expect(await target.exists(), isFalse);
        final partial = File('${target.path}.part');
        await partial.writeAsBytes(bytes, flush: true);
        await partial.rename(target.path);
        return null;
      case 'acknowledgeBlock':
        final prefix = receipts.keys.where((key) => key.compareTo(name!) <= 0).toList()..sort();
        expect(prefix.length, inInclusiveRange(1, 8));
        for (final block in prefix) {
          final file = File('${directory.path}/$block');
          expect(listEquals(await file.readAsBytes(), receipts.remove(block)), isTrue);
          await file.delete();
        }
        return null;
      default:
        throw StateError('Unexpected OS action');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dll = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];
  final executable = Platform.environment['NSOALBUM_DEVICE_SYNC_USB_PEER'];
  final enabled = dll != null && executable != null;
  const channel = MethodChannel('device-sync-usb-owner-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUpAll(() async {
    if (enabled) {
      await RustLib.init(externalLibrary: ExternalLibrary.open(dll));
    }
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  var phase = 'starting';
  String? observingEndpoint;
  _DirectoryBoundary? observingBoundary;
  _Peer? observingPeer;
  Future<void> waitFor(Future<bool> Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!await ready()) {
      if ((!DateTime.now().isBefore(deadline) ||
              observingPeer?.exited != null) &&
          observingEndpoint != null) {
        final view = await native.deviceSyncReadEndpoint(
          endpoint: observingEndpoint!,
        );
        final usb = await native.deviceSyncUsbView(
          endpoint: observingEndpoint!,
        );
        final methods = observingBoundary?.methods ?? [];
        debugPrint(
          'USB bounded diagnostic phase=$phase stage=${view.value?.stage} pairing=${view.value?.pairing} closed=${usb.closed} error=${usb.error} lastMethods=${methods.skip(methods.length > 8 ? methods.length - 8 : 0).toList()} completed=${observingBoundary?.completed} boundaryFailures=${observingBoundary?.failures} peerExit=${observingPeer?.exited} stderrBytes=${observingPeer?.stderrBytes} stderrKind=${observingPeer?.stderrKind}',
        );
        expect(
          observingPeer?.exited,
          isNull,
          reason: 'Synthetic peer ended before the authorized stage',
        );
      }
      expect(
        DateTime.now().isBefore(deadline),
        isTrue,
        reason: 'Bounded USB owner wait',
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  for (final fault in [_ReadFault.missingFile, _ReadFault.corruptTls]) {
    test(
      'real FRB USB diagnostic control distinguishes ${fault.name}',
      () async {
        final peer = await _Peer.start(executable!);
        final target = await Directory.systemTemp.createTemp(
          'nsoalbum-5a3-diagnostic-',
        );
        final library = (await native.deviceSyncOpenLibrary(
          libraryRoot: target.path,
        )).handle;
        final endpoint = await native.deviceSyncClientUsb(
          library_: library,
          invitation: await peer.invitation.future.timeout(
            const Duration(seconds: 10),
          ),
          name: 'Synthetic diagnostic phone',
        );
        final boundary = _DirectoryBoundary(peer.root, readFault: fault);
        messenger.setMockMethodCallHandler(channel, boundary.call);
        try {
          final result = await DeviceSyncUsbSafOwner(
            endpoint: endpoint,
            saf: DeviceSyncSaf(channel: channel),
          ).run().timeout(const Duration(seconds: 5));
          expect(boundary.readFaultsInjected, 1);
          expect(result.closed, isTrue);
          expect(result.reason, UsbCloseReason.failure);
          expect(result.error, ReadError.unavailable);
          final view = (await native.deviceSyncReadEndpoint(endpoint: endpoint))
              .value!;
          expect(view.stage, driver.State.failed);
          expect(view.pairing, PairingStage.terminal);
          final successfulReads = boundary.completed
              .where((method) => method == 'readBlock')
              .length;
          if (fault == _ReadFault.missingFile) {
            expect(boundary.failures, hasLength(1));
            final failure = boundary.failures.single;
            expect(failure.method, 'readBlock');
            expect(failure.fileSystemException, isTrue);
            expect(failure.osCode, 2); // ENOENT / ERROR_FILE_NOT_FOUND.
            expect(failure.platformCode, isNull);
            expect(successfulReads, 0);
          } else {
            expect(boundary.failures, isEmpty);
            expect(successfulReads, 1);
          }
          expect(boundary.methods.where((method) => method == 'cancel'), [
            'cancel',
          ]);
          expect(
            boundary.methods.where(
              (method) => method == 'acknowledgeBlock' || method == 'close',
            ),
            isEmpty,
          );
          debugPrint(
            'USB diagnostic control=${fault.name} boundaryFailures=${boundary.failures} successfulReads=$successfulReads error=${result.error}',
          );
          peer.grant('cancel');
          final done = await peer.finish();
          // The child snapshots its business state before awaiting shutdown.
          // Its clean exit, not that early snapshot, proves fixture retirement.
          expect(done['source_protected'], isFalse);
        } finally {
          await native.deviceSyncCloseEndpoint(endpoint: endpoint);
          await native.deviceSyncCloseLibrary(library_: library);
          peer.process.kill();
          await peer.process.exitCode;
        }
      },
      skip: enabled
          ? false
          : 'Requires explicit fresh native DLL and cfg(test) USB peer',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  for (final failure in ['none', 'close', 'finalAck', 'libraryOnly']) {
    final failClose = failure == 'close';
    final failFinalAck = failure == 'finalAck';
    final accounts = failure != 'libraryOnly';
    test(
      'real FRB USB original coordinator and directory completion: $failure',
      () async {
        final peer = await _Peer.start(executable!, failFinalAck: failFinalAck);
        final target = await Directory.systemTemp.createTemp(
          'nsoalbum-5a3-mobile-',
        );
        if (failure == 'none') await native.initCore(libraryRoot: target.path);
        final library = (await native.deviceSyncOpenLibrary(
          libraryRoot: target.path,
        )).handle;
        final endpoint = await native.deviceSyncClientUsb(
          library_: library,
          invitation: await peer.invitation.future.timeout(
            const Duration(seconds: 10),
          ),
          name: 'Synthetic phone',
        );
        final boundary = _DirectoryBoundary(peer.root)..failClose = failClose;
        observingEndpoint = endpoint;
        observingBoundary = boundary;
        observingPeer = peer;
        messenger.setMockMethodCallHandler(channel, boundary.call);
        final owner = DeviceSyncUsbSafOwner(
          endpoint: endpoint,
          saf: DeviceSyncSaf(channel: channel),
        );
        final running = owner.run();
        final storage = MemoryAccountStorage(
          values: {
            accountTokensKey: '{"old":"synthetic-old"}',
            selectedAccountKey: 'old',
          },
        );
        storage.denyReads = !accounts;
        final coordinator = DeviceAccountCoordinator(
          library: library,
          storage: storage,
          gate: AccountWorkGate(),
          invalidate: (_) async {},
          publish: (_) {},
        );
        try {
          await expectLater(
            native.deviceSyncDrain(endpoint: endpoint),
            throwsA(anything),
          );
          phase = 'awaiting-confirmation';
          await waitFor(
            () async =>
                (await native.deviceSyncReadEndpoint(endpoint: endpoint))
                    .value
                    ?.pairing ==
                PairingStage.awaitingConfirmation,
          );
          peer.grant('confirm');
          await native.deviceSyncConfirm(endpoint: endpoint);
          phase = 'both-confirmed';
          await waitFor(
            () async =>
                (await native.deviceSyncReadEndpoint(endpoint: endpoint))
                    .value
                    ?.pairing ==
                PairingStage.confirmed,
          );
          if (accounts) {
            await coordinator.authorizeTarget(endpoint, authorized: true);
          } else {
            await coordinator.decline(endpoint);
          }
          peer.grant(accounts ? 'configure_accounts' : 'configure_library');
          phase = 'preview';
          await waitFor(
            () async =>
                (await native.deviceSyncStatus(endpoint: endpoint)).state ==
                'AwaitingApproval',
          );
          final preview = accounts ? await coordinator.preview(endpoint) : null;
          expect(
            (await native.deviceSyncReadPreview(endpoint: endpoint))
                .value!
                .media
                .added,
            BigInt.one,
          );
          final before = await native.deviceSyncLibraryInfo(library_: library);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(
            (await native.deviceSyncLibraryInfo(library_: library)).generation,
            before.generation,
          );
          if (preview != null) {
            await coordinator.approve(preview, authorized: true);
            phase = 'target-account-final';
            await waitFor(
              () async =>
                  (await native.deviceSyncStatus(endpoint: endpoint)).state ==
                  'AwaitingTargetAccountFinal',
            );
            await coordinator.authorizeFinalTarget(endpoint);
            peer.grant('source_final');
            phase = 'external';
            await waitFor(
              () async =>
                  (await native.deviceSyncStatus(endpoint: endpoint)).state ==
                  'AwaitingExternal',
            );
            expect(
              (await native.deviceSyncLibraryInfo(library_: library))
                  .pendingOperation,
              preview.operation,
            );
            if (failure == 'none') {
              await expectLater(
                native.createTag(name: 'blocked-during-real-pending'),
                throwsA(anything),
              );
            }
            final applied = await coordinator.applyPending(endpoint);
            expect(applied.finalized, isTrue);
          } else {
            await native.deviceSyncApprove(endpoint: endpoint);
          }
          final result = await running.timeout(const Duration(seconds: 40));
          final businessState = (await native.deviceSyncStatus(
            endpoint: endpoint,
          )).state;
          if (result.reason == UsbCloseReason.failure &&
              !failClose &&
              !failFinalAck) {
            debugPrint(
              'USB terminal diagnostic error=${result.error} business=$businessState lastMethods=${boundary.methods.skip(boundary.methods.length > 8 ? boundary.methods.length - 8 : 0).toList()} peerExit=${peer.exited} stderrKind=${peer.stderrKind}',
            );
          }
          expect(
            result.reason,
            failClose || failFinalAck
                ? UsbCloseReason.failure
                : UsbCloseReason.success,
          );
          expect(
            result.error,
            failClose
                ? ReadError.unavailable
                : failFinalAck
                ? ReadError.timeout
                : null,
          );
          expect(
            storage.values[accountTokensKey],
            accounts ? '{"new":"synthetic-new"}' : '{"old":"synthetic-old"}',
          );
          expect(coordinator.gate.busy, isFalse);
          if (preview != null) {
            expect(
              (await native.deviceSyncJournal(
                library_: library,
                operation: preview.operation,
              ))!.stage,
              'finalized',
            );
          }
          final done = await peer.finish();
          expect(done['state'], 'Completed');
          expect(done['source_protected'], accounts);
          expect(done['final_ack_failed'], failFinalAck);
          expect(
            boundary.methods.where((m) => m == 'close').length,
            failFinalAck ? 0 : 1,
          );
          expect(
            boundary.methods.where((m) => m == 'cancel').length,
            failFinalAck ? 1 : 0,
          );
          expect(
            (await native.deviceSyncStatus(endpoint: endpoint)).state,
            'Completed',
          );
        } finally {
          await native.deviceSyncCloseEndpoint(endpoint: endpoint);
          await native.deviceSyncCloseLibrary(library_: library);
          peer.process.kill();
          await peer.process.exitCode;
        }
      },
      skip: enabled
          ? false
          : 'Requires explicit fresh native DLL and cfg(test) USB peer',
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test(
    'real FRB SAF directory withdrawal is typed and ends only this owner',
    () async {
      final peer = await _Peer.start(executable!);
      final root = await Directory.systemTemp.createTemp(
        'nsoalbum-5a3-denied-',
      );
      final library = (await native.deviceSyncOpenLibrary(
        libraryRoot: root.path,
      )).handle;
      final endpoint = await native.deviceSyncClientUsb(
        library_: library,
        invitation: await peer.invitation.future.timeout(
          const Duration(seconds: 10),
        ),
        name: 'Denied phone',
      );
      final boundary = _DirectoryBoundary(peer.root)..deny = true;
      messenger.setMockMethodCallHandler(channel, boundary.call);
      try {
        final result = await DeviceSyncUsbSafOwner(
          endpoint: endpoint,
          saf: DeviceSyncSaf(channel: channel),
        ).run().timeout(const Duration(seconds: 5));
        expect(result.reason, UsbCloseReason.failure);
        expect(result.error, ReadError.permissionDenied);
        expect(boundary.methods, ['openSession']);
        peer.grant('cancel');
        await peer.finish();
      } finally {
        await native.deviceSyncCloseEndpoint(endpoint: endpoint);
        await native.deviceSyncCloseLibrary(library_: library);
        peer.process.kill();
        await peer.process.exitCode;
      }
    },
    skip: enabled
        ? false
        : 'Requires explicit fresh native DLL and cfg(test) USB peer',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final sharedSaf in [false, true]) {
    test(
      'real FRB second Busy owner cleanup leaves the first SAF owner running: ${sharedSaf ? 'shared' : 'separate'} SAF',
      () async {
        final peer = await _Peer.start(executable!);
        final target = await Directory.systemTemp.createTemp(
          'nsoalbum-5a3-busy-',
        );
        final firstLibrary = (await native.deviceSyncOpenLibrary(
          libraryRoot: '${target.path}/first',
        )).handle;
        final secondLibrary = (await native.deviceSyncOpenLibrary(
          libraryRoot: '${target.path}/second',
        )).handle;
        final invitation = await peer.invitation.future.timeout(
          const Duration(seconds: 10),
        );
        final first = await native.deviceSyncClientUsb(
          library_: firstLibrary,
          invitation: invitation,
          name: 'First synthetic phone',
        );
        final second = await native.deviceSyncClientUsb(
          library_: secondLibrary,
          invitation: invitation,
          name: 'Second synthetic phone',
        );
        final boundary = _DirectoryBoundary(peer.root)..hangRead = true;
        messenger.setMockMethodCallHandler(channel, boundary.call);
        final firstSaf = DeviceSyncSaf(channel: channel);
        final firstRunning = DeviceSyncUsbSafOwner(
          endpoint: first,
          saf: firstSaf,
        ).run();
        try {
          await boundary.readEntered.future.timeout(
            const Duration(seconds: 10),
          );
          final firstToken = boundary.ownerToken;
          final secondOwner = DeviceSyncUsbSafOwner(
            endpoint: second,
            saf: sharedSaf ? firstSaf : DeviceSyncSaf(channel: channel),
          );
          try {
            final result = await secondOwner.run().timeout(
              const Duration(seconds: 5),
            );
            expect(result.reason, UsbCloseReason.failure);
            expect(result.error, ReadError.busy);
          } on DeviceSyncSafFailure catch (failure) {
            expect(failure.code, DeviceSyncSafError.busy);
          }
          await secondOwner.cancel();
          await secondOwner.settleOwnedIo();
          expect(boundary.retiredTokens, isEmpty);
          expect(boundary.ownerToken, firstToken);
          expect(
            (await native.deviceSyncUsbView(endpoint: first)).closed,
            isFalse,
          );
          boundary.hangRead = false;
          boundary.delayedRead.complete(
            await boundary.pendingRead!.readAsBytes(),
          );
          observingEndpoint = first;
          observingBoundary = boundary;
          observingPeer = peer;
          phase = 'first-owner-survived-second-busy';
          await waitFor(
            () async =>
                (await native.deviceSyncReadEndpoint(endpoint: first))
                    .value
                    ?.pairing ==
                PairingStage.awaitingConfirmation,
          );
          await native.deviceSyncCancelSignal(endpoint: first);
          expect(
            (await firstRunning.timeout(const Duration(seconds: 2))).reason,
            UsbCloseReason.cancelled,
          );
          expect(boundary.retiredTokens, [firstToken]);
          peer.grant('cancel');
          await peer.finish();
        } finally {
          await native.deviceSyncCloseEndpoint(endpoint: first);
          await native.deviceSyncCloseEndpoint(endpoint: second);
          await native.deviceSyncCloseLibrary(library_: firstLibrary);
          await native.deviceSyncCloseLibrary(library_: secondLibrary);
          peer.process.kill();
          await peer.process.exitCode;
        }
      },
      skip: enabled
          ? false
          : 'Requires explicit fresh native DLL and cfg(test) USB peer',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'real FRB old owner OS settlement cannot retire a reused SAF owner',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'nsoalbum-fix1-reused-saf-',
      );
      final library = (await native.deviceSyncOpenLibrary(
        libraryRoot: root.path,
      )).handle;
      final saf = DeviceSyncSaf(channel: channel);
      DeviceSyncUsbSafOwner? old;
      for (var index = 0; index < 2; index++) {
        final peer = await _Peer.start(executable!);
        final invitation = await peer.invitation.future.timeout(
          const Duration(seconds: 10),
        );
        final endpoint = await native.deviceSyncClientUsb(
          library_: library,
          invitation: invitation,
          name: 'Synthetic phone',
        );
        final boundary = _DirectoryBoundary(peer.root)..hangRead = true;
        messenger.setMockMethodCallHandler(channel, boundary.call);
        final owner = DeviceSyncUsbSafOwner(endpoint: endpoint, saf: saf);
        final running = owner.run();
        try {
          await boundary.readEntered.future.timeout(
            const Duration(seconds: 10),
          );
          final token = boundary.ownerToken;
          if (old != null) {
            await old.settleOwnedIo();
            expect(boundary.retiredTokens, isEmpty);
            expect(boundary.ownerToken, token);
            expect(
              (await native.deviceSyncUsbView(endpoint: endpoint)).closed,
              isFalse,
            );
          }
          await owner.cancel();
          final ended = await running.timeout(const Duration(seconds: 2));
          expect(ended.closed, isTrue);
          expect(boundary.retiredTokens, [token]);
          old = owner;
          peer.grant('cancel');
          await peer.finish();
        } finally {
          if (!boundary.delayedRead.isCompleted) {
            boundary.delayedRead.complete(Uint8List(0));
          }
          await native.deviceSyncCloseEndpoint(endpoint: endpoint);
          peer.process.kill();
          await peer.process.exitCode;
        }
      }
      await native.deviceSyncCloseLibrary(library_: library);
    },
    skip: enabled
        ? false
        : 'Requires explicit fresh native DLL and cfg(test) USB peer',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final closeLibrary in [false, true]) {
    test(
      'Rust ${closeLibrary ? 'library close' : 'cancel signal'} independently cancels a pending SAF read',
      () async {
        final peer = await _Peer.start(executable!);
        final target = await Directory.systemTemp.createTemp(
          'nsoalbum-5a3-cancel-',
        );
        final library = (await native.deviceSyncOpenLibrary(
          libraryRoot: target.path,
        )).handle;
        final endpoint = await native.deviceSyncClientUsb(
          library_: library,
          invitation: await peer.invitation.future.timeout(
            const Duration(seconds: 10),
          ),
          name: 'Pending phone',
        );
        final boundary = _DirectoryBoundary(peer.root)..hangRead = true;
        messenger.setMockMethodCallHandler(channel, boundary.call);
        final running = DeviceSyncUsbSafOwner(
          endpoint: endpoint,
          saf: DeviceSyncSaf(channel: channel),
        ).run();
        try {
          await boundary.readEntered.future.timeout(
            const Duration(seconds: 10),
          );
          if (closeLibrary) {
            await native.deviceSyncCloseLibrary(library_: library);
          } else {
            await native.deviceSyncCancelSignal(endpoint: endpoint);
          }
          final result = await running.timeout(const Duration(seconds: 2));
          expect(result.reason, UsbCloseReason.cancelled);
          expect(boundary.methods.where((m) => m == 'cancel').length, 1);
          boundary.delayedRead.complete(Uint8List.fromList([1, 2, 3]));
          await Future<void>.delayed(Duration.zero);
          peer.grant('cancel');
          await peer.finish();
        } finally {
          if (!closeLibrary) {
            await native.deviceSyncCloseEndpoint(endpoint: endpoint);
            await native.deviceSyncCloseLibrary(library_: library);
          }
          peer.process.kill();
          await peer.process.exitCode;
        }
      },
      skip: enabled
          ? false
          : 'Requires explicit fresh native DLL and cfg(test) USB peer',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
