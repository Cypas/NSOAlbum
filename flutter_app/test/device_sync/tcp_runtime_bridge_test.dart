import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/rust/device_sync/runtime.dart';
import 'package:squid_album/src/rust/device_sync/work.dart' as work;
import 'package:squid_album/src/rust/frb_generated.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;

class _PressureObservation {
  const _PressureObservation.failed()
    : stage = null,
      terminal = null,
      phase = null,
      error = null,
      tcpError = null,
      readFailed = true;

  _PressureObservation.fromRead(read.EndpointRead endpoint)
    : stage = endpoint.value?.stage,
      terminal = endpoint.value?.terminal,
      phase = endpoint.tcp?.phase,
      error = endpoint.error,
      tcpError = endpoint.tcp?.error,
      readFailed = false;

  final driver.State? stage;
  final bool? terminal;
  final TcpPhase? phase;
  final read.ReadError? error;
  final read.ReadError? tcpError;
  final bool readFailed;
}

class _PressureOutcome {
  const _PressureOutcome({
    this.error,
    this.stack,
    this.observation,
    this.sampled = false,
  });

  final Object? error;
  final StackTrace? stack;
  final _PressureObservation? observation;
  final bool sampled;

  DeviceCommandError? get commandError =>
      error is DeviceCommandError ? error as DeviceCommandError : null;

  bool get rejectedBusy {
    final command = commandError;
    return command != null &&
        !command.executed &&
        command.code == read.ReadError.busy;
  }

  bool get acceptedRejection {
    final command = commandError;
    if (command == null ||
        command.executed ||
        observation?.readFailed == true ||
        observation?.error != null ||
        observation?.tcpError != null) {
      return false;
    }
    if (command.code == read.ReadError.busy) return true;
    if (command.code != read.ReadError.cancelled &&
        command.code != read.ReadError.disconnected) {
      return false;
    }
    final observed = observation;
    return observed != null &&
        observed.stage == driver.State.completed &&
        observed.terminal == true &&
        observed.phase == TcpPhase.closed &&
        observed.error == null &&
        observed.tcpError == null;
  }
}

class _PressureJobs {
  _PressureJobs({this.observe});

  final Future<read.EndpointRead> Function()? observe;
  final _jobs = <Future<_PressureOutcome>>[];
  final _counts = <(read.ReadError?, bool?), int>{};
  final _sampled = <(read.ReadError?, bool?)>{};
  var busyRejected = 0;
  var diagnosticReadFailures = 0;

  Future<_PressureOutcome> submit(Future<Object?> job) {
    final captured = job.then<_PressureOutcome>(
      (_) => const _PressureOutcome(),
      onError: (Object error, StackTrace stack) async {
        final command = error is DeviceCommandError ? error : null;
        final category = (command?.code, command?.executed);
        _counts.update(category, (count) => count + 1, ifAbsent: () => 1);
        final sampled = _sampled.length < 4 && _sampled.add(category);
        final terminalCandidate =
            command != null &&
            !command.executed &&
            (command.code == read.ReadError.cancelled ||
                command.code == read.ReadError.disconnected);
        _PressureObservation? observation;
        // The read is a later observation, not the command's execution point.
        // Each terminal candidate needs its own read, never a shared sample.
        // Only diagnostic output is sampled; never retain account bytes.
        if (observe != null && (terminalCandidate || sampled)) {
          try {
            observation = _PressureObservation.fromRead(await observe!());
          } catch (_) {
            diagnosticReadFailures++;
            observation = const _PressureObservation.failed();
          }
        }
        final outcome = _PressureOutcome(
          error: error,
          stack: stack,
          observation: observation,
          sampled: sampled,
        );
        if (outcome.rejectedBusy) busyRejected++;
        return outcome;
      },
    );
    _jobs.add(captured);
    return captured;
  }

  Future<void> settle() async {
    await Future.wait(_jobs);
  }

  Future<void> diagnose() async {
    final outcomes = await Future.wait(_jobs);
    final succeeded = outcomes.where((outcome) => outcome.error == null).length;
    debugPrint(
      'I4 pressure policy=success-or-unexecuted-busy; '
      'unexecuted-cancelled/disconnected requires its own Completed/closed read',
    );
    debugPrint(
      'I4 pressure outcomes submitted=${outcomes.length} succeeded=$succeeded '
      'rejected=${outcomes.length - succeeded} '
      'diagnosticReadFailures=$diagnosticReadFailures',
    );
    for (final entry in _counts.entries) {
      debugPrint(
        'I4 pressure count code=${entry.key.$1?.name ?? 'unknown'} '
        'executed=${entry.key.$2 ?? 'unknown'} count=${entry.value}',
      );
    }
    for (final outcome in outcomes) {
      final observation = outcome.observation;
      if (observation == null || !outcome.sampled) continue;
      debugPrint(
        'I4 pressure observation '
        'code=${outcome.commandError?.code.name ?? 'unknown'} '
        'executed=${outcome.commandError?.executed ?? 'unknown'} '
        'stage=${observation.stage?.name ?? 'none'} '
        'terminal=${observation.terminal ?? 'none'} '
        'tcp=${observation.phase?.name ?? 'none'} '
        'readError=${observation.error?.name ?? 'none'} '
        'tcpError=${observation.tcpError?.name ?? 'none'} '
        'readFailed=${observation.readFailed}',
      );
    }
  }

  Future<void> join() async {
    final outcomes = await Future.wait(_jobs);
    for (final outcome in outcomes) {
      if (outcome.error != null && !outcome.acceptedRejection) {
        Error.throwWithStackTrace(outcome.error!, outcome.stack!);
      }
    }
  }
}

class _PressureStorage extends MemoryAccountStorage {
  _PressureStorage()
    : super(
        values: {
          accountTokensKey: '{"old":"synthetic-old"}',
          selectedAccountKey: 'old',
        },
      );
  Future<void> Function()? pressure;
  bool armed = false;
  @override
  Future<void> write(String key, String value) async {
    await super.write(key, value);
    if (armed && !value.contains('"stage":"finalized"')) await pressure?.call();
  }

  @override
  Future<void> delete(String key) async {
    await super.delete(key);
    if (armed) await pressure?.call();
  }
}

read.EndpointRead _pressureRead({
  driver.State stage = driver.State.completed,
  bool terminal = true,
  TcpPhase? phase = TcpPhase.closed,
  read.ReadError? error,
  read.ReadError? tcpError,
  bool includeView = true,
}) {
  final progress = read.ProgressView(
    workStage: work.WorkStage.idle,
    workActive: false,
    scannedItems: BigInt.zero,
    totalItems: BigInt.zero,
    transferredBytes: BigInt.zero,
    transferTotalBytes: BigInt.zero,
  );
  return read.EndpointRead(
    value: includeView
        ? read.EndpointView(
            pairing: read.PairingStage.terminal,
            confirmationAvailable: false,
            transport: read.TransportKind.tcp,
            host: false,
            controller: false,
            phoneControlled: false,
            previewApproved: false,
            accountsConsentAuthorized: false,
            source: false,
            stage: stage,
            terminal: terminal,
            cleanupPending: false,
            localApplyInstalled: false,
            sourceGrantIssued: false,
            transportDetached: false,
            progress: progress,
          )
        : null,
    progress: progress,
    tcp: phase == null ? null : TcpView(phase: phase, error: tcpError),
    error: error,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'pressure outcome collector owns typed errors before final join',
    () async {
      const failure = DeviceCommandError(
        code: read.ReadError.cancelled,
        executed: false,
      );
      final failureStack = StackTrace.current;
      final earlyErrors = <Object>[];
      Object? joinedError;
      StackTrace? joinedStack;
      await runZonedGuarded(() async {
        final pressureJobs = _PressureJobs();
        final pending = Completer<Object?>();
        pressureJobs.submit(pending.future);
        pending.completeError(failure, failureStack);
        await Future<void>.delayed(Duration.zero);
        try {
          await pressureJobs.join();
        } catch (error, stack) {
          joinedError = error;
          joinedStack = stack;
        }
      }, (error, _) => earlyErrors.add(error));
      expect(
        earlyErrors,
        isEmpty,
        reason: 'submitted failures must remain owned until the explicit join',
      );
      expect(joinedError, same(failure));
      expect(joinedStack.toString(), failureStack.toString());
    },
  );
  test(
    'pressure outcome collector preserves unknown error and stack',
    () async {
      final failure = Object();
      final failureStack = StackTrace.current;
      final earlyErrors = <Object>[];
      Object? joinedError;
      StackTrace? joinedStack;
      await runZonedGuarded(() async {
        final pressureJobs = _PressureJobs();
        final pending = Completer<Object?>();
        pressureJobs.submit(pending.future);
        pending.completeError(failure, failureStack);
        await Future<void>.delayed(Duration.zero);
        try {
          await pressureJobs.join();
        } catch (error, stack) {
          joinedError = error;
          joinedStack = stack;
        }
      }, (error, _) => earlyErrors.add(error));
      expect(earlyErrors, isEmpty);
      expect(joinedError, same(failure));
      expect(joinedStack.toString(), failureStack.toString());
    },
  );
  test(
    'pressure outcome collector preserves Busy execution boundary',
    () async {
      final pressureJobs = _PressureJobs();
      pressureJobs.submit(Future<Object?>.value(Uint8List(0)));
      pressureJobs.submit(
        Future<Object?>.error(
          const DeviceCommandError(code: read.ReadError.busy, executed: false),
        ),
      );
      await pressureJobs.join();
      expect(pressureJobs.busyRejected, 1);

      const executedBusy = DeviceCommandError(
        code: read.ReadError.busy,
        executed: true,
      );
      pressureJobs.submit(Future<Object?>.error(executedBusy));
      await expectLater(pressureJobs.join(), throwsA(same(executedBusy)));
    },
  );
  test('pressure outcome collector owns diagnostic read failure without masking command', () async {
    const failure = DeviceCommandError(
      code: read.ReadError.disconnected,
      executed: false,
    );
    final earlyErrors = <Object>[];
    Object? joinedError;
    var readFailures = 0;
    await runZonedGuarded(() async {
      final pressureJobs = _PressureJobs(
        observe: () => Future<read.EndpointRead>.error(Object()),
      );
      pressureJobs.submit(Future<Object?>.error(failure));
      await Future<void>.delayed(Duration.zero);
      try {
        await pressureJobs.join();
      } catch (error) {
        joinedError = error;
      }
      readFailures = pressureJobs.diagnosticReadFailures;
    }, (error, _) => earlyErrors.add(error));
    expect(earlyErrors, isEmpty);
    expect(joinedError, same(failure));
    expect(readFailures, 1);
  });
  test('pressure outcome collector accepts only per-error Completed closed terminal rejections', () async {
    for (final code in [
      read.ReadError.cancelled,
      read.ReadError.disconnected,
    ]) {
      final snapshots = [
        _pressureRead(),
        _pressureRead(),
        _pressureRead(stage: driver.State.awaitingExternal, terminal: false),
      ];
      final pressureJobs = _PressureJobs(
        observe: () async => snapshots.removeAt(0),
      );
      for (var index = 0; index < 2; index++) {
        pressureJobs.submit(
          Future<Object?>.error(
            DeviceCommandError(code: code, executed: false),
          ),
        );
      }
      // The same category's second error needs a second successful read.
      await pressureJobs.join();
      final nonterminal = DeviceCommandError(code: code, executed: false);
      pressureJobs.submit(Future<Object?>.error(nonterminal));
      await expectLater(pressureJobs.join(), throwsA(same(nonterminal)));
    }
  });
  test(
    'pressure outcome collector rejects every non-Completed stage',
    () async {
      for (final stage in driver.State.values) {
        if (stage == driver.State.completed) continue;
        final pressureJobs = _PressureJobs(
          observe: () async => _pressureRead(stage: stage),
        );
        final failure = DeviceCommandError(
          code: read.ReadError.disconnected,
          executed: false,
        );
        pressureJobs.submit(Future<Object?>.error(failure));
        await expectLater(pressureJobs.join(), throwsA(same(failure)));
      }
    },
  );
  test(
    'pressure outcome collector rejects incomplete or failed terminal reads',
    () async {
      final snapshots = [
        _pressureRead(terminal: false),
        _pressureRead(phase: TcpPhase.connected),
        _pressureRead(phase: null),
        _pressureRead(includeView: false),
        _pressureRead(error: read.ReadError.unavailable),
        _pressureRead(tcpError: read.ReadError.disconnected),
      ];
      for (final snapshot in snapshots) {
        final pressureJobs = _PressureJobs(observe: () async => snapshot);
        final failure = DeviceCommandError(
          code: read.ReadError.cancelled,
          executed: false,
        );
        pressureJobs.submit(Future<Object?>.error(failure));
        await expectLater(pressureJobs.join(), throwsA(same(failure)));
      }
    },
  );
  test(
    'pressure outcome collector rejects executed terminal and unrelated errors',
    () async {
      final failures = <Object>[
        for (final code in read.ReadError.values)
          if (code != read.ReadError.busy &&
              code != read.ReadError.cancelled &&
              code != read.ReadError.disconnected)
            DeviceCommandError(code: code, executed: false),
        const DeviceCommandError(
          code: read.ReadError.cancelled,
          executed: true,
        ),
        const DeviceCommandError(
          code: read.ReadError.disconnected,
          executed: true,
        ),
        Object(),
      ];
      for (final failure in failures) {
        final pressureJobs = _PressureJobs(
          observe: () async => _pressureRead(),
        );
        pressureJobs.submit(Future<Object?>.error(failure));
        await expectLater(pressureJobs.join(), throwsA(same(failure)));
      }
    },
  );

  final dll = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];
  final selected =
      Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_TCP_ADDRESS'];
  test(
    'real FRB managed TCP preserves account coordinator under bounded queue pressure',
    () async {
      final interfaces = await NetworkInterface.list();
      expect(
        interfaces.expand((i) => i.addresses).any((a) => a.address == selected),
        isTrue,
        reason: 'the explicitly selected test address must still belong to this machine',
      );
      final ip = InternetAddress(selected!);
      final bind = ip.type == InternetAddressType.IPv6
          ? '[$selected]:0'
          : '$selected:0';
      await RustLib.init(externalLibrary: ExternalLibrary.open(dll!));
      final roots = [
        await Directory.systemTemp.createTemp('nsoalbum-5a2-source-'),
        await Directory.systemTemp.createTemp('nsoalbum-5a2-target-'),
      ];
      String? sourceLibrary, targetLibrary, host, phone;
      final pressureJobs = _PressureJobs(
        observe: () => native.deviceSyncReadEndpoint(endpoint: phone!),
      );
      Future<void> waitFor(Future<bool> Function() ready) async {
        final limit = DateTime.now().add(const Duration(seconds: 30));
        while (!await ready()) {
          expect(
            DateTime.now().isBefore(limit),
            isTrue,
            reason: 'bounded TCP runtime wait',
          );
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      try {
        await native.initCore(libraryRoot: roots[0].path);
        final input = File('${roots[0].path}/stream.jpg');
        await input.writeAsBytes(
          Uint8List(1024 * 1024 + 13)..fillRange(0, 1024 * 1024 + 13, 0x53),
        );
        await native.importLocalFiles(paths: [input.path]);
        sourceLibrary = (await native.deviceSyncOpenLibrary(
          libraryRoot: roots[0].path,
        )).handle;
        targetLibrary = (await native.deviceSyncOpenLibrary(
          libraryRoot: roots[1].path,
        )).handle;
        await expectLater(
          native.deviceSyncHostTcp(
            library_: sourceLibrary,
            name: 'Desktop',
            address: '127.0.0.1:0',
          ),
          throwsA(anything),
        );
        final invitation = await native.deviceSyncHostTcp(
          library_: sourceLibrary,
          name: 'Desktop',
          address: bind,
        );
        host = invitation.handle;
        expect(
          (await native.deviceSyncReadEndpoint(endpoint: host)).tcp!.phase,
          TcpPhase.listening,
        );
        phone = await native.deviceSyncClientTcp(
          library_: targetLibrary,
          invitation: invitation.invitation,
          name: 'Phone',
        );
        for (final endpoint in [host, phone]) {
          await expectLater(
            native.deviceSyncDrain(endpoint: endpoint),
            throwsA(anything),
          );
          await expectLater(
            native.deviceSyncPoll(endpoint: endpoint),
            throwsA(anything),
          );
        }
        await waitFor(
          () async =>
              (await native.deviceSyncReadEndpoint(endpoint: host!))
                      .value
                      ?.pairing ==
                  read.PairingStage.awaitingConfirmation &&
              (await native.deviceSyncReadEndpoint(endpoint: phone!))
                      .value
                      ?.pairing ==
                  read.PairingStage.awaitingConfirmation,
        );
        expect(
          await native.deviceSyncConfirmationCode(endpoint: host),
          await native.deviceSyncConfirmationCode(endpoint: phone),
        );
        await native.deviceSyncConfirm(endpoint: host);
        await native.deviceSyncConfirm(endpoint: phone);
        await waitFor(
          () async =>
              (await native.deviceSyncReadEndpoint(endpoint: host!))
                      .value
                      ?.pairing ==
                  read.PairingStage.confirmed &&
              (await native.deviceSyncReadEndpoint(endpoint: phone!))
                      .value
                      ?.pairing ==
                  read.PairingStage.confirmed,
        );
        final sourceStore = MemoryAccountStorage(
          values: {
            accountTokensKey: '{"new":"synthetic-new"}',
            accountProfilesKey: '{"new":{"nickname":"New"}}',
          },
        );
        final targetStore = _PressureStorage();
        final source = DeviceAccountCoordinator(
          library: sourceLibrary,
          storage: sourceStore,
          gate: AccountWorkGate(),
          invalidate: (_) async {},
          publish: (_) {},
        );
        late Future<void> Function() pressureCallback;
        final target = DeviceAccountCoordinator(
          library: targetLibrary,
          storage: targetStore,
          gate: AccountWorkGate(),
          invalidate: (_) => pressureCallback(),
          publish: (_) {},
        );
        Future<void> pressure() async {
          final endpoint = phone!;
          for (var index = 0; index < 64; index++) {
            pressureJobs.submit(
              native.deviceSyncAccountPayload(endpoint: endpoint),
            );
          }
          // Yield to FRB admission without draining the bounded actor queue.
          await Future<void>.delayed(Duration.zero);
        }

        pressureCallback = pressure;
        targetStore.pressure = pressure;
        await source.authorizeSource(host, authorized: true);
        await target.authorizeTarget(phone, authorized: true);
        await native.deviceSyncConfigure(
          endpoint: host,
          phoneToDesktop: false,
          overwrite: true,
          includeAccounts: true,
        );
        await waitFor(
          () async =>
              (await native.deviceSyncStatus(endpoint: phone!)).state ==
              'AwaitingApproval',
        );
        final preview = await target.preview(phone);
        expect(
          (await native.deviceSyncReadPreview(endpoint: phone))
              .value!
              .media
              .added,
          BigInt.one,
        );
        final before = await native.deviceSyncLibraryInfo(
          library_: targetLibrary,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          (await native.deviceSyncLibraryInfo(library_: targetLibrary))
              .generation,
          before.generation,
        );
        await target.approve(preview, authorized: true);
        await waitFor(() async {
          final state = (await native.deviceSyncStatus(endpoint: phone!)).state;
          return state == 'AwaitingTargetAccountFinal';
        });
        targetStore.armed =
            true; // Includes the secure index reserve before target-final.
        await target.authorizeFinalTarget(phone);
        await waitFor(
          () async =>
              (await native.deviceSyncStatus(endpoint: host!)).state ==
              'AwaitingAccountFinal',
        );
        await source.authorizeFinalSource(host);
        await waitFor(
          () async =>
              (await native.deviceSyncStatus(endpoint: phone!)).state ==
              'AwaitingExternal',
        );
        final applied = await target.applyPending(phone);
        expect(applied.finalized, isTrue);
        targetStore.armed = false;
        // Some diagnostic queue calls can retire after final success closes TLS.
        await pressureJobs.settle();
        expect(pressureJobs.busyRejected, greaterThan(0));
        expect(targetStore.values[accountTokensKey], '{"new":"synthetic-new"}');
        expect(target.gate.busy, isFalse);
        final journal = await native.deviceSyncJournal(
          library_: targetLibrary,
          operation: preview.operation,
        );
        expect(journal!.stage, 'finalized');
        await waitFor(
          () async =>
              (await native.deviceSyncReadEndpoint(endpoint: host!))
                      .tcp!
                      .phase ==
                  TcpPhase.closed &&
              (await native.deviceSyncReadEndpoint(endpoint: phone!))
                      .tcp!
                      .phase ==
                  TcpPhase.closed,
        );
        expect(
          (await native.deviceSyncStatus(endpoint: host)).state,
          'Completed',
        );
        expect(
          (await native.deviceSyncStatus(endpoint: phone)).state,
          'Completed',
        );
        // The runtime owner is closed, but its retained endpoint still exposes
        // Completed. Probe that real admission contract before releasing it.
        final terminalProbe = await pressureJobs.submit(
          native.deviceSyncAccountPayload(endpoint: phone),
        );
        expect(
          terminalProbe.commandError?.code,
          isIn([read.ReadError.cancelled, read.ReadError.disconnected]),
        );
        expect(terminalProbe.commandError?.executed, isFalse);
        expect(terminalProbe.observation?.stage, driver.State.completed);
        expect(terminalProbe.observation?.terminal, isTrue);
        expect(terminalProbe.observation?.phase, TcpPhase.closed);
        expect(terminalProbe.observation?.error, isNull);
        expect(terminalProbe.observation?.tcpError, isNull);
        expect(terminalProbe.observation?.readFailed, isFalse);
        await source.releaseSource(host);
        await native.deviceSyncCloseEndpoint(endpoint: host);
        await native.deviceSyncCloseEndpoint(endpoint: phone);
        host = phone = null;

        // A library-only managed transfer must not read any protected account key.
        final next = await native.deviceSyncHostTcp(
          library_: sourceLibrary,
          name: 'Desktop',
          address: bind,
        );
        host = next.handle;
        phone = await native.deviceSyncClientTcp(
          library_: targetLibrary,
          invitation: next.invitation,
          name: 'Phone',
        );
        final untouched = Map<String, String>.from(targetStore.values);
        targetStore.denyReads = true;
        await waitFor(
          () async =>
              (await native.deviceSyncReadEndpoint(endpoint: host!))
                      .value
                      ?.confirmationAvailable ==
                  true &&
              (await native.deviceSyncReadEndpoint(endpoint: phone!))
                      .value
                      ?.confirmationAvailable ==
                  true,
        );
        await native.deviceSyncConfirm(endpoint: host);
        await native.deviceSyncConfirm(endpoint: phone);
        await waitFor(
          () async =>
              (await native.deviceSyncStatus(endpoint: host!)).state ==
              'Configuring',
        );
        await native.deviceSyncConfigure(
          endpoint: host,
          phoneToDesktop: true,
          overwrite: false,
          includeAccounts: false,
        );
        await waitFor(
          () async =>
              (await native.deviceSyncStatus(endpoint: host!)).state ==
              'AwaitingApproval',
        );
        await native.deviceSyncApprove(endpoint: host);
        await waitFor(
          () async =>
              (await native.deviceSyncReadEndpoint(endpoint: host!))
                      .tcp!
                      .phase ==
                  TcpPhase.closed &&
              (await native.deviceSyncReadEndpoint(endpoint: phone!))
                      .tcp!
                      .phase ==
                  TcpPhase.closed,
        );
        expect(
          (await native.deviceSyncStatus(endpoint: phone)).state,
          'Completed',
        );
        expect(targetStore.values, untouched);
        debugPrint(
          'I4 all original business assertions passed before policy join',
        );
        await pressureJobs.diagnose();
        // Keep rejection after every original business assertion, so
        // classification cannot hide an account/journal/state regression.
        await pressureJobs.join();
      } finally {
        await pressureJobs.settle();
        for (final endpoint in [host, phone]) {
          if (endpoint != null) {
            await native.deviceSyncCancelSignal(endpoint: endpoint);
            await native.deviceSyncCloseEndpoint(endpoint: endpoint);
          }
        }
        for (final library in [sourceLibrary, targetLibrary]) {
          if (library != null) {
            await native.deviceSyncCloseLibrary(library_: library);
          }
        }
        for (final root in roots) {
          try {
            await root.delete(recursive: true);
          } on FileSystemException {
            // Windows can retain SQLite handles until this test process exits.
          }
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: dll == null || selected == null
        ? 'Requires an explicit fresh native library and selected local TCP address'
        : false,
  );
}
