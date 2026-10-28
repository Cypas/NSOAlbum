import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
// Replace only the operating-system credential boundary.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/backend/rust_backend.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/runtime.dart';
import 'package:squid_album/src/rust/device_sync/work.dart' as work;
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/rust/settings.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;

class _WaitDiagnostics {
  _WaitDiagnostics(this.label);
  final String? label;
  final samples = <String>[];

  void observe(read.EndpointRead current, bool predicate) {
    final value = current.value;
    final sample =
        'label=${label ?? 'unlabeled'} stage=${value?.stage.name ?? 'none'} '
        'terminal=${value?.terminal ?? 'none'} '
        'pairing=${value?.pairing.name ?? 'none'} '
        'transport=${value?.transport.name ?? 'none'} '
        'source=${value?.source ?? 'none'} '
        'cleanupPending=${value?.cleanupPending ?? 'none'} '
        'tcp=${current.tcp?.phase.name ?? 'none'} '
        'tcpError=${current.tcp?.error?.name ?? 'none'} '
        'readError=${current.error?.name ?? 'none'} predicate=$predicate';
    if (samples.isNotEmpty && samples.last == sample) return;
    if (samples.length == 4) samples.removeAt(0);
    samples.add(sample);
  }

  Never reject(String message) {
    for (final sample in samples) {
      debugPrintSynchronously('5C service diagnostic $sample');
    }
    fail(message);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('controlled service wait', () {
    test('waits for TCP close after legal Completed sample', () async {
      final paused = Completer<void>();
      final resume = Completer<void>();
      final closed = Completer<read.EndpointRead>();
      final session = _WaitObservation(
        (index) => index == 0
            ? Future.value(
                _waitSample(driver.State.completed, TcpPhase.connected),
              )
            : closed.future,
      );
      var ended = false;
      Object? failure;
      final waiting =
          _untilCompletedAndTcpClosed(
            session,
            label: 'regression-completed-and-tcp-closed',
            pause: () {
              paused.complete();
              return resume.future;
            },
          ).then<void>(
            (_) => ended = true,
            onError: (Object error) {
              ended = true;
              failure = error;
            },
          );
      try {
        await Future.any([paused.future, waiting]);
        expect(
          failure,
          isNull,
          reason: 'Legal Completed+Connected must remain pending.',
        );
        expect(ended, isFalse);
        expect(session.reads, 1);
        closed.complete(_waitSample(driver.State.completed, TcpPhase.closed));
        resume.complete();
        await waiting;
        expect(failure, isNull);
        expect(ended, isTrue);
        expect(session.reads, 2);
      } finally {
        if (!closed.isCompleted) {
          closed.complete(_waitSample(driver.State.completed, TcpPhase.closed));
        }
        if (!resume.isCompleted) resume.complete();
        await waiting;
      }
    });
    for (final stage in [
      driver.State.failed,
      driver.State.cancelled,
      driver.State.completedUnconfirmed,
      driver.State.recoveryPending,
    ]) {
      test('rejects ${stage.name} after business completion', () async {
        final session = _WaitObservation(
          (index) async => switch (index) {
            0 => _waitSample(driver.State.completed, TcpPhase.connected),
            1 => _waitSample(stage, TcpPhase.closed),
            _ => _waitSample(driver.State.completed, TcpPhase.closed),
          },
        );
        await expectLater(
          _untilCompletedAndTcpClosed(
            session,
            label: 'regression-other-terminal',
            pause: () async {},
          ),
          throwsA(isA<TestFailure>()),
        );
        expect(session.reads, 2);
      });
    }
    for (final phase in [TcpPhase.connected, TcpPhase.closed]) {
      test(
        'strict approval wait rejects Completed with ${phase.name}',
        () async {
          final session = _WaitObservation(
            (_) async => _waitSample(driver.State.completed, phase),
          );
          await expectLater(
            _until(
              session,
              (value) => value.stage == driver.State.awaitingApproval,
              label: 'regression-strict-awaiting-approval',
            ),
            throwsA(isA<TestFailure>()),
          );
          expect(session.reads, 1);
        },
      );
    }
    test('requires same-read TCP close within original deadline', () async {
      final start = DateTime.utc(2026, 10, 17);
      var clock = start;
      var pauses = 0;
      final session = _WaitObservation(
        (_) async => _waitSample(driver.State.completed, TcpPhase.connected),
        snapshotOverride: _waitSample(driver.State.completed, TcpPhase.closed),
      );
      await expectLater(
        _untilCompletedAndTcpClosed(
          session,
          label: 'regression-same-read-deadline',
          now: () => clock,
          pause: () async {
            pauses++;
            clock = clock.add(const Duration(seconds: 5));
          },
        ),
        throwsA(isA<TestFailure>()),
      );
      expect(session.reads, 4);
      expect(pauses, 4);
      expect(clock.difference(start), const Duration(seconds: 20));
    });
    test(
      'accepts first same-read completion and close without pause',
      () async {
        final session = _WaitObservation(
          (_) async => _waitSample(driver.State.completed, TcpPhase.closed),
          snapshotOverride: _waitSample(
            driver.State.completed,
            TcpPhase.connected,
          ),
        );
        var pauses = 0;
        await _untilCompletedAndTcpClosed(
          session,
          label: 'regression-first-completed-closed',
          pause: () async => pauses++,
        );
        expect(session.reads, 1);
        expect(pauses, 0);
      },
    );
    test(
      'preserves typed refresh failure without further observation',
      () async {
        const failure = DeviceCommandError(
          code: read.ReadError.unavailable,
          executed: false,
        );
        final session = _WaitObservation((_) => Future.error(failure));
        var pauses = 0;
        await expectLater(
          _untilCompletedAndTcpClosed(
            session,
            label: 'regression-refresh-error',
            pause: () async => pauses++,
          ),
          throwsA(same(failure)),
        );
        expect(session.reads, 1);
        expect(pauses, 0);
      },
    );
    test('retains only four most recent changed safe samples', () {
      final diagnostics = _WaitDiagnostics('regression-bounded-diagnostics');
      final first = _waitSample(driver.State.completed, TcpPhase.connecting);
      diagnostics.observe(first, false);
      diagnostics.observe(first, false);
      expect(diagnostics.samples.length, 1);
      diagnostics.observe(
        _waitSample(driver.State.completed, TcpPhase.connected),
        false,
      );
      diagnostics.observe(
        _waitSample(driver.State.completed, TcpPhase.closed),
        true,
      );
      diagnostics.observe(
        _waitSample(driver.State.failed, TcpPhase.closed),
        false,
      );
      diagnostics.observe(
        _waitSample(driver.State.cancelled, TcpPhase.closed),
        false,
      );
      expect(diagnostics.samples.length, 4);
      expect(diagnostics.samples.first, contains('tcp=connected'));
      expect(diagnostics.samples.last, contains('stage=cancelled'));
    });
  });
  final library = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];
  final address = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_TCP_ADDRESS'];
  test(
    'recovered formal backend creates a page-owned real TCP invitation',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      final oldSecureBoundary = FlutterSecureStoragePlatform.instance;
      final secure = _SecureBoundary();
      FlutterSecureStoragePlatform.instance = secure;
      final root = await Directory.systemTemp.createTemp(
        'nsoalbum-5b2-service-',
      );
      await native.initCore(libraryRoot: root.path);
      await native.saveSettings(
        settings: AppSettings(
          dohEnabled: false,
          libraryPath: '${root.path}/media',
          theme: 'ocean',
          language: 'en',
          galleryColumns: 4,
          galleryRows: 3,
          showNotePreview: true,
          showGameTag: true,
          compactTagDisplay: true,
          autoPlayVideo: false,
          autoSyncOnLaunch: false,
          notifyOnAutoSync: true,
          showSplatoonSchedule: true,
          showSplatoonFriendActivity: false,
          closeBehavior: 'ask',
          customFontPaths: const [],
          syncPolicy: const SyncPolicy(
            enabled: false,
            activeIntervalMinutes: 30,
            sleepAfterHours: 24,
          ),
        ),
      );
      final backend = await RustBackend.prepare(
        applicationRoot: root.path,
        storage: const FlutterSecureStorage(),
      );
      expect(
        () => backend.deviceSyncStartup.service,
        throwsA(isA<DeviceSyncBusy>()),
      );
      await backend.deviceSyncStartup.start();
      expect(
        backend.deviceSyncStartup.ready,
        isTrue,
        reason:
            'Synthetic fixture startup: ${backend.deviceSyncStartup.recovery?.status}; '
            '${backend.deviceSyncStartup.error}',
      );
      try {
        final service = backend.deviceSyncStartup.service;
        expect(identical(service, backend.deviceSyncStartup.service), isTrue);
        final session = await service.hostWifi(
          address: address!,
          name: 'Desktop',
        );
        expect(session.invitation, isNotEmpty);
        final lateObservation = session.refresh().then<Object?>(
          (value) => value,
          onError: (Object error) => error,
        );
        await session.close();
        expect(await lateObservation, isA<DeviceSyncBusy>());
        expect(session.closed, isTrue);
        expect(session.invitation, isNull);
        expect(session.confirmationCode, isNull);
        expect(backend.deviceSyncStartup.ready, isTrue);
        await native.createTag(name: 'page close leaves library available');
        expect(await native.listTags(), [
          'page close leaves library available',
        ]);
        final peerRoot = await Directory.systemTemp.createTemp(
          'nsoalbum-5b2-peer-',
        );
        final peer = await native.deviceSyncOpenLibrary(
          libraryRoot: peerRoot.path,
        );
        final paired = await service.hostWifi(
          address: address,
          name: 'Desktop',
        );
        String? phone;
        try {
          phone = await native.deviceSyncClientTcp(
            library_: peer.handle,
            invitation: paired.invitation!,
            name: 'Phone',
          );
          await _until(
            paired,
            (view) => view.pairing == read.PairingStage.awaitingConfirmation,
          );
          expect(paired.confirmationCode, matches(RegExp(r'^\d{6}$')));
          expect(
            paired.confirmationCode,
            await native.deviceSyncConfirmationCode(endpoint: phone),
          );
          await paired.confirmPairing();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(
            (await paired.refresh()).value!.pairing,
            isNot(read.PairingStage.confirmed),
            reason: 'One local confirmation must not confirm the peer.',
          );
          await native.deviceSyncConfirm(endpoint: phone);
          await _until(
            paired,
            (view) => view.pairing == read.PairingStage.confirmed,
          );
          await paired.configure(phoneToDesktop: true, overwrite: true);
          await _until(
            paired,
            (view) => view.stage == driver.State.awaitingApproval,
          );
          expect(await native.listTags(), [
            'page close leaves library available',
          ], reason: 'No receiver confirmation means no library write.');
          final preview = await _preview(paired);
          expect(preview.accounts, isNull);
          expect(preview.library.media.added, BigInt.zero);
          try {
            await paired.approvePreview(preview);
          } on AccountPreviewChanged {
            debugPrintSynchronously(
              '5B2 approval preflight failed: error=${paired.issue?.name} '
              'stage=${paired.snapshot?.value?.stage.name} '
              'source=${paired.snapshot?.value?.source} '
              'readError=${paired.snapshot?.error?.name}',
            );
            rethrow;
          }
          await _until(paired, (view) => view.stage == driver.State.completed);
          expect(await native.listTags(), isEmpty);
        } finally {
          await paired.close();
          if (phone != null) {
            await native.deviceSyncCloseEndpoint(endpoint: phone);
          }
          await native.deviceSyncCloseLibrary(library_: peer.handle);
        }
        debugPrintSynchronously(
          '5B2 actual formal service: same owner, real TCP pair code, '
          'both local confirmations, receiver preview/approval, overwrite, '
          'page close leaves library available.',
        );
        final matrixPeerRoot = await Directory.systemTemp.createTemp(
          'nsoalbum-5b2-matrix-peer-',
        );
        final matrixPeer = await native.deviceSyncOpenLibrary(
          libraryRoot: matrixPeerRoot.path,
        );
        try {
          secure.reads.clear();
          await native.createTag(name: 'shared marker');
          await native.createAlbum(
            name: 'Controlled source album',
            description: '',
            smart: false,
          );
          await _libraryScenario(
            service,
            address,
            matrixPeer.handle,
            diagnosticLabel: 'matrix-desktop-to-phone-merge',
            phoneToDesktop: false,
            overwrite: false,
          );
          expect(
            (await native.listAlbums())
                .singleWhere((album) => album.name == 'Controlled source album')
                .sourceDeviceName,
            'Desktop',
            reason: 'The current generated DTO carries the actual stored source name.',
          );
          expect(
            (await native.listAlbums())
                .singleWhere((album) => album.systemKey == 'favorites')
                .sourceDeviceName,
            isNull,
          );
          expect(await native.listTags(), ['shared marker']);
          await native.createTag(name: 'desktop only');
          await _libraryScenario(
            service,
            address,
            matrixPeer.handle,
            diagnosticLabel: 'matrix-phone-to-desktop-merge',
            phoneToDesktop: true,
            overwrite: false,
          );
          expect(await native.listTags(), ['desktop only', 'shared marker']);
          await _libraryScenario(
            service,
            address,
            matrixPeer.handle,
            diagnosticLabel: 'matrix-phone-to-desktop-overwrite',
            phoneToDesktop: true,
            overwrite: true,
          );
          expect(await native.listTags(), ['shared marker']);
          expect(
            secure.reads.where(accountActiveKeys.contains),
            isEmpty,
            reason: 'Library-only sessions never read protected account keys.',
          );
          debugPrintSynchronously(
            '5B2 actual formal service matrix: desktop->phone merge, '
            'phone->desktop merge/overwrite; source unchanged; '
            'receiver changes observed again through real reverse transfer; '
            'no active account key read.',
          );
          await _accountReceiverScenario(
            service,
            address,
            matrixPeer.handle,
            secure,
          );
          await _accountSenderScenario(
            backend,
            service,
            address,
            matrixPeer.handle,
            secure,
            loseTarget: false,
          );
          await _accountSenderScenario(
            backend,
            service,
            address,
            matrixPeer.handle,
            secure,
            loseTarget: true,
          );
          for (final phoneToDesktop in [false, true]) {
            await _declineAccountsScenario(
              service,
              address,
              matrixPeer.handle,
              secure,
              phoneToDesktop: phoneToDesktop,
            );
          }
          await _runtimeRecoveryScenario(
            backend,
            service,
            address,
            matrixPeer.handle,
            secure,
          );
          await _clientAccountScenario(
            service,
            address,
            matrixPeer.handle,
            secure,
          );
          await _backupServiceScenario(
            backend,
            service,
            address,
            matrixPeer.handle,
            secure,
          );
          await _realPreviewExpiryScenario(service, address, matrixPeer.handle);
        } finally {
          await native.deviceSyncCloseLibrary(library_: matrixPeer.handle);
        }
        await backend.close();
        expect(
          () => backend.deviceSyncStartup.service,
          throwsA(isA<DeviceSyncBusy>()),
        );
      } finally {
        await backend.close();
        RustLib.dispose();
        FlutterSecureStoragePlatform.instance = oldSecureBoundary;
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: library == null || address == null
        ? 'Requires explicit current native DLL and active private LAN address'
        : false,
  );
}

Future<void> _accountSenderScenario(
  RustBackend backend,
  DeviceSyncService service,
  String address,
  String peerLibrary,
  _SecureBoundary secure, {
  required bool loseTarget,
}) async {
  const rollbackMarker = 'synthetic unconfirmed receiver rollback marker';
  if (loseTarget) {
    await native.createTag(name: rollbackMarker);
    await _libraryScenario(
      service,
      address,
      peerLibrary,
      diagnosticLabel: 'account-sender-rollback-setup',
      phoneToDesktop: false,
      overwrite: false,
    );
    final marker = (await native.listTagUsage()).singleWhere(
      (tag) => tag.name == rollbackMarker,
    );
    await native.deleteTag(tagId: marker.id);
  }
  final session = await service.hostWifi(
    address: address,
    name: 'Desktop source',
  );
  final phone = await native.deviceSyncClientTcp(
    library_: peerLibrary,
    invitation: session.invitation!,
    name: 'Phone receiver',
  );
  final storage = MemoryAccountStorage(
    values: {
      accountTokensKey: '{"old-target":"synthetic-old-target"}',
      accountProfilesKey: '{"old-target":{"nickname":"Old target"}}',
      selectedAccountKey: 'old-target',
      legacySessionKey: 'synthetic-target-legacy',
    },
  );
  final oldTarget = Map<String, String>.from(storage.values);
  final sourceTokens = secure.values[accountTokensKey];
  final beforeTags = await native.listTags();
  final target = DeviceAccountCoordinator(
    library: peerLibrary,
    storage: storage,
    gate: AccountWorkGate(),
    invalidate: (_) async {},
    publish: (_) {},
  );
  try {
    await _until(
      session,
      (v) => v.pairing == read.PairingStage.awaitingConfirmation,
    );
    await session.confirmPairing();
    await native.deviceSyncConfirm(endpoint: phone);
    await _until(session, (v) => v.pairing == read.PairingStage.confirmed);
    await session.configure(
      phoneToDesktop: false,
      overwrite: true,
      includeAccounts: true,
    );
    await _until(
      session,
      (v) => v.stage == driver.State.awaitingAccountConsent,
    );
    secure.reads.clear();
    await target.authorizeTarget(phone, authorized: true);
    expect(secure.reads.where(accountActiveKeys.contains), isEmpty);
    await session.consentAccounts(accepted: true);
    await _untilPeer(phone, 'AwaitingApproval');
    final preview = await target.preview(phone);
    await target.approve(preview, authorized: true);
    var targetFinal = false, applied = false;
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      await session.refresh(); // Original service advances sourceFinal itself.
      final remote = await native.deviceSyncStatus(endpoint: phone);
      if (remote.state == 'AwaitingTargetAccountFinal' && !targetFinal) {
        await target.authorizeFinalTarget(phone);
        targetFinal = true;
      }
      if (remote.state == 'AwaitingExternal' && !applied) {
        expect(targetFinal, isTrue);
        if (loseTarget) break;
        expect((await target.applyPending(phone)).finalized, isTrue);
        applied = true;
      }
      if (session.snapshot?.value?.stage == driver.State.completed) break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (!loseTarget) {
      expect(applied, isTrue);
      await _until(session, (v) => v.stage == driver.State.completed);
      expect(storage.values[accountTokensKey], sourceTokens);
      expect(backend.accountWorkGate.busy, isFalse);
    } else {
      expect(
        (await native.deviceSyncStatus(endpoint: phone)).state,
        'AwaitingExternal',
      );
      // No target credential commit is attempted. Original abort compensates
      // its SQL-applied pending operation before the real transport disappears.
      await target.abort(phone);
      expect({
        for (final key in accountActiveKeys) key: storage.values[key],
      }, oldTarget);
      final retainedIndex = jsonDecode(
        storage.values[accountCoordinationIndexKey]!,
      ) as Map<String, dynamic>;
      final retainedId = (retainedIndex['entries'] as List).single as String;
      final retainedMaterial = jsonDecode(
        storage.values[accountMaterialKey(retainedId)]!,
      ) as Map<String, dynamic>;
      expect(
        retainedMaterial['stage'],
        'rolled_back',
        reason: 'Compensation material and its index must be retained.',
      );
      await _until(
        session,
        (v) => v.stage == driver.State.completedUnconfirmed,
      );
      expect(session.snapshot!.value!.cleanupPending, isTrue);
      expect(backend.accountWorkGate.busy, isTrue);
      expect(
        () => service.hostWifi(address: address, name: 'Too early'),
        throwsA(isA<DeviceSyncBusy>()),
      );
      final releaseDeadline = DateTime.now().add(const Duration(seconds: 40));
      while (session.snapshot!.value!.cleanupPending) {
        expect(
          DateTime.now().isBefore(releaseDeadline),
          isTrue,
          reason: 'The original issued source lease must settle.',
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await session.refresh();
      }
      expect(backend.accountWorkGate.busy, isFalse);
      expect({
        for (final key in accountActiveKeys) key: storage.values[key],
      }, oldTarget);
      expect(await native.listTags(), beforeTags);
      final fresh = await service.hostWifi(
        address: address,
        name: 'After source cleanup',
      );
      await fresh.close();
      // Verify the remote SQL rollback through the real controlled protocol,
      // not a Dart database read. The marker existed only on the old target.
      await _libraryScenario(
        service,
        address,
        peerLibrary,
        diagnosticLabel: 'account-sender-rollback-verify',
        phoneToDesktop: true,
        overwrite: true,
      );
      expect(await native.listTags(), contains(rollbackMarker));
      final marker = (await native.listTagUsage()).singleWhere(
        (tag) => tag.name == rollbackMarker,
      );
      await native.deleteTag(tagId: marker.id);
    }
    expect(
      await native.listTags(),
      beforeTags,
      reason: 'Source library is unchanged.',
    );
    debugPrintSynchronously(
      loseTarget
          ? '5B2 actual source CompletedUnconfirmed: target abort restored exact '
                'old keys; original issued lease held cleanup/gate until real expiry; '
                'only then same service admitted a fresh session. USB-specific '
                'unconfirmed completion is not asserted by this TCP case.'
          : '5B2 actual account sender: local consent and original automatic '
                'sourceFinal/release completed; target received the source accounts.',
    );
  } finally {
    await target.abort(phone);
    await session.close();
    await native.deviceSyncCloseEndpoint(endpoint: phone);
  }
}

Future<void> _declineAccountsScenario(
  DeviceSyncService service,
  String address,
  String peerLibrary,
  _SecureBoundary secure, {
  required bool phoneToDesktop,
}) async {
  final session = await service.hostWifi(
    address: address,
    name: 'Desktop decline',
  );
  final phone = await native.deviceSyncClientTcp(
    library_: peerLibrary,
    invitation: session.invitation!,
    name: 'Phone decline',
  );
  final storage = MemoryAccountStorage()..denyReads = true;
  final peer = DeviceAccountCoordinator(
    library: peerLibrary,
    storage: storage,
    gate: AccountWorkGate(),
    invalidate: (_) async {},
    publish: (_) {},
  );
  final beforeKeys = {
    for (final key in accountActiveKeys) key: secure.values[key],
  };
  try {
    await _until(
      session,
      (v) => v.pairing == read.PairingStage.awaitingConfirmation,
    );
    await session.confirmPairing();
    await native.deviceSyncConfirm(endpoint: phone);
    await _until(session, (v) => v.pairing == read.PairingStage.confirmed);
    await session.configure(
      phoneToDesktop: phoneToDesktop,
      overwrite: false,
      includeAccounts: true,
    );
    await _until(
      session,
      (v) => v.stage == driver.State.awaitingAccountConsent,
    );
    secure.reads.clear();
    await session.consentAccounts(accepted: false);
    await peer.decline(phone);
    if (phoneToDesktop) {
      await _until(session, (v) => v.stage == driver.State.awaitingApproval);
      final shown = await _preview(session);
      expect(shown.accounts, isNull);
      expect(session.snapshot?.value?.configuration?.includeAccounts, isFalse);
      await _approve(session, shown);
    } else {
      await _untilPeer(phone, 'AwaitingApproval');
      await native.deviceSyncApprove(endpoint: phone);
    }
    await _until(session, (v) => v.stage == driver.State.completed);
    expect(secure.reads.where(accountActiveKeys.contains), isEmpty);
    expect({
      for (final key in accountActiveKeys) key: secure.values[key],
    }, beforeKeys);
    expect(storage.values, isEmpty);
    debugPrintSynchronously(
      '5B2 actual both-side decline: directionPhoneToDesktop=$phoneToDesktop; '
      'pure-library completion, zero active secure reads and unchanged accounts.',
    );
  } finally {
    await session.close();
    await native.deviceSyncCloseEndpoint(endpoint: phone);
  }
}

Future<void> _realPreviewExpiryScenario(
  DeviceSyncService service,
  String address,
  String peerLibrary,
) async {
  final session = await service.hostWifi(
    address: address,
    name: 'Desktop expiry',
  );
  final oldInvitation = session.invitation!;
  final phone = await native.deviceSyncClientTcp(
    library_: peerLibrary,
    invitation: oldInvitation,
    name: 'Phone expiry',
  );
  try {
    await _until(
      session,
      (v) => v.pairing == read.PairingStage.awaitingConfirmation,
      label: 'preview-expiry:pairing-awaiting-confirmation',
    );
    await session.confirmPairing();
    await native.deviceSyncConfirm(endpoint: phone);
    await _until(
      session,
      (v) => v.pairing == read.PairingStage.confirmed,
      label: 'preview-expiry:pairing-confirmed',
    );
    await session.configure(phoneToDesktop: true, overwrite: true);
    await _until(
      session,
      (v) => v.stage == driver.State.awaitingApproval,
      label: 'preview-expiry:awaiting-approval',
    );
    final shown = await _preview(session);
    final before = await native.listTags();
    expect(session.snapshot?.value?.terminal, isFalse);
    // The production deadline is unchanged. Do not add a clock-bypass Bridge.
    for (var segment = 0; segment < 11; segment++) {
      await Future<void>.delayed(const Duration(seconds: 28));
      debugPrintSynchronously(
        '5B2 real preview expiry wait segment=${segment + 1}/11',
      );
    }
    await session.refresh();
    expect(session.snapshot?.value?.terminal, isTrue);
    expect(session.snapshot?.value?.stage, isNot(driver.State.completed));
    await expectLater(
      session.approvePreview(shown),
      throwsA(isA<AccountPreviewChanged>()),
    );
    expect(
      await native.listTags(),
      before,
      reason: 'Expired preview must not apply changes.',
    );
    await expectLater(
      session.refreshPreview(),
      throwsA(isA<AccountPreviewChanged>()),
    );
    await session.close();
    final fresh = await service.hostWifi(
      address: address,
      name: 'Fresh expiry retry',
    );
    try {
      expect(
        fresh.invitation != oldInvitation,
        isTrue,
        reason: 'Retry needs new authenticated invitation material.',
      );
    } finally {
      await fresh.close();
    }
    debugPrintSynchronously(
      '5B2 actual five-minute binding expiry: real preview existed first; old '
      'approval/refetch refused with unchanged local library; fresh pairing only.',
    );
  } finally {
    await session.close();
    await native.deviceSyncCloseEndpoint(endpoint: phone);
  }
}

Future<void> _backupServiceScenario(
  RustBackend backend,
  DeviceSyncService service,
  String address,
  String peerLibrary,
  _SecureBoundary secure,
) async {
  final browser = service.openBackups();
  try {
    var page = await browser.page();
    final before = {for (final entry in page.items) entry.metadata.backup};
    final internal = page.items
        .where(
          (entry) =>
              entry.metadata.unavailableReason ==
              read.BackupUnavailableReason.internalCompensation,
        )
        .first;
    secure.reads.clear();
    await expectLater(
      browser.prepareRestore(internal, accountsAuthorized: true),
      throwsA(isA<DeviceBackupUnavailable>()),
    );
    expect(secure.reads, isEmpty);
    await native.createTag(name: 'controlled restore sentinel');
    await _libraryScenario(
      service,
      address,
      peerLibrary,
      diagnosticLabel: 'backup-library-restore',
      phoneToDesktop: true,
      overwrite: true,
    );
    expect(await native.listTags(), ['shared marker']);
    page = await browser.page();
    final libraryBackup = page.items.singleWhere(
      (entry) => !before.contains(entry.metadata.backup),
    );
    expect(libraryBackup.metadata.includesAccounts, isFalse);
    secure.reads.clear();
    final shown = await browser.prepareRestore(libraryBackup);
    expect(shown.accounts, isNull);
    expect(shown.library.includesAccounts, isFalse);
    expect(await native.listTags(), ['shared marker']);
    expect(secure.reads, isEmpty);
    final result = await browser.confirmRestore(shown);
    expect(result.finalized, isTrue);
    expect(await native.listTags(), [
      'controlled restore sentinel',
      'shared marker',
    ]);
    expect(secure.reads, isEmpty);
    expect(backend.accountWorkGate.busy, isFalse);
    page = await browser.page();
    expect(
      page.items.length,
      greaterThan(before.length + 1),
      reason: 'Actual restore retains selected backup and creates its safety backup.',
    );
    final accountBackup = page.items.firstWhere(
      (entry) =>
          entry.metadata.includesAccounts == true &&
          entry.metadata.unavailableReason == null,
    );
    final protectedIndex = jsonDecode(
      secure.values[accountCoordinationIndexKey]!,
    ) as Map<String, dynamic>;
    final protectedBackup = (protectedIndex['entries'] as List)
        .cast<String>()
        .map(
          (id) =>
              jsonDecode(secure.values[accountMaterialKey(id)]!)
                  as Map<String, dynamic>,
        )
        .firstWhere((item) => item['backup'] == accountBackup.metadata.backup);
    final expectedKeys = protectedBackup['old'] as Map<String, dynamic>;
    final currentKeys = {
      for (final key in accountActiveKeys) key: secure.values[key],
    };
    secure.reads.clear();
    await expectLater(
      browser.prepareRestore(accountBackup),
      throwsA(isA<AccountConsentRequired>()),
    );
    expect(secure.reads, isEmpty);
    final withAccounts = await browser.prepareRestore(
      accountBackup,
      accountsAuthorized: true,
    );
    expect(withAccounts.library.includesAccounts, isTrue);
    expect(withAccounts.accounts, isNotNull);
    expect(
      {for (final key in accountActiveKeys) key: secure.values[key]},
      currentKeys,
      reason: 'Preview consent is not an execution confirmation.',
    );
    expect((await browser.confirmRestore(withAccounts)).finalized, isTrue);
    for (final key in accountActiveKeys) {
      expect(secure.values[key], expectedKeys[key]);
    }
    expect(backend.accountWorkGate.busy, isFalse);
    final refreshed = await browser.page();
    final reusable = refreshed.items.firstWhere(
      (entry) =>
          entry.metadata.includesAccounts == false &&
          entry.metadata.unavailableReason == null,
    );
    await browser.prepareRestore(reusable);
    await browser.discardPreview();
    expect(browser.preview, isNull);
    expect(backend.accountWorkGate.busy, isFalse);
    debugPrintSynchronously(
      '5B2 actual controlled backups: corrupt/internal item refused before OS '
      'reads; library-only real restore used zero protected reads, restored '
      'sentinel and retained both backup versions; separate account preview '
      'consent plus local confirmation restored exact old four-key state; '
      'same browser reusable/discarded without write permit.',
    );
  } finally {
    await browser.close();
  }
}

Future<void> _clientAccountScenario(
  DeviceSyncService service,
  String address,
  String peerLibrary,
  _SecureBoundary secure,
) async {
  final host = await native.deviceSyncHostTcp(
    library_: peerLibrary,
    address: '$address:0',
    name: 'Desktop peer',
  );
  final source = DeviceAccountCoordinator(
    library: peerLibrary,
    storage: MemoryAccountStorage(
      values: {accountTokensKey: '{"client":"synthetic-client"}'},
    ),
    gate: AccountWorkGate(),
    invalidate: (_) async {},
    publish: (_) {},
  );
  DeviceSyncSession? session;
  try {
    session = await service.joinWifi(
      invitation: host.invitation,
      name: 'Phone role',
    );
    secure.reads.clear();
    await expectLater(
      session.consentAccounts(accepted: true),
      throwsA(isA<AccountPreviewChanged>()),
    );
    expect(secure.reads.where(accountActiveKeys.contains), isEmpty);
    await _until(
      session,
      (view) => view.pairing == read.PairingStage.awaitingConfirmation,
    );
    final shownCode = session.confirmationCode;
    await session.confirmPairing();
    await native.deviceSyncConfirm(endpoint: host.handle);
    await _until(
      session,
      (view) => view.pairing == read.PairingStage.confirmed,
    );
    expect(session.confirmationCode, shownCode);
    await native.deviceSyncConfigure(
      endpoint: host.handle,
      phoneToDesktop: false,
      overwrite: true,
      includeAccounts: true,
    );
    await _until(
      session,
      (view) => view.stage == driver.State.awaitingAccountConsent,
    );
    expect(session.snapshot?.value?.configuration, isNull);
    expect(session.snapshot?.value?.source, isNull);
    expect(session.proposedConfiguration?.phoneToDesktop, isFalse);
    expect(session.proposedConfiguration?.includeAccounts, isTrue);
    expect(secure.reads.where(accountActiveKeys.contains), isEmpty);
    await source.authorizeSource(host.handle, authorized: true);
    await session.consentAccounts(accepted: true);
    await _until(
      session,
      (view) => view.stage == driver.State.awaitingApproval,
    );
    final shown = await _preview(session);
    expect(shown.accounts?.added, 1);
    expect(shown.accounts?.removed, 1);
    await _approve(session, shown);
    var sourceFinal = false;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final value = await session.refresh();
      final remote = await native.deviceSyncStatus(endpoint: host.handle);
      if (remote.state == 'AwaitingAccountFinal' && !sourceFinal) {
        await source.authorizeFinalSource(host.handle);
        sourceFinal = true;
      }
      if (value.value?.stage == driver.State.completed) break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(session.snapshot?.value?.stage, driver.State.completed);
    expect(secure.values[accountTokensKey], '{"client":"synthetic-client"}');
    debugPrintSynchronously(
      '5B2 actual client-role service: wrong-stage consent read no active keys; '
      'first requested-account proposal reachable before agreed data; '
      'local explicit consent and original final/apply reached Completed.',
    );
  } finally {
    await session?.close();
    await native.deviceSyncShutdown(endpoint: host.handle);
    await source.releaseSource(host.handle);
    await native.deviceSyncCloseEndpoint(endpoint: host.handle);
  }
}

Future<void> _runtimeRecoveryScenario(
  RustBackend backend,
  DeviceSyncService service,
  String address,
  String peerLibrary,
  _SecureBoundary secure,
) async {
  await native.createTag(name: 'rollback sentinel');
  final settingsBefore = backend.settings;
  final oldActive = {
    for (final key in accountActiveKeys) key: secure.values[key],
  };
  final session = await service.hostWifi(address: address, name: 'Desktop');
  final phone = await native.deviceSyncClientTcp(
    library_: peerLibrary,
    invitation: session.invitation!,
    name: 'Phone',
  );
  final source = DeviceAccountCoordinator(
    library: peerLibrary,
    storage: MemoryAccountStorage(
      values: {accountTokensKey: '{"next":"synthetic-next"}'},
    ),
    gate: AccountWorkGate(),
    invalidate: (_) async {},
    publish: (_) {},
  );
  Future<Object?>? cancellation;
  void cancelAfterLibraryCommit() {
    if (session.snapshot?.value?.stage == driver.State.awaitingExternal &&
        cancellation == null) {
      secure.failActiveWrites = true;
      cancellation = session.close().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
    }
  }

  session.addListener(cancelAfterLibraryCommit);
  try {
    await _until(
      session,
      (view) => view.pairing == read.PairingStage.awaitingConfirmation,
    );
    await session.confirmPairing();
    await native.deviceSyncConfirm(endpoint: phone);
    await _until(
      session,
      (view) => view.pairing == read.PairingStage.confirmed,
    );
    await session.configure(
      phoneToDesktop: true,
      overwrite: true,
      includeAccounts: true,
    );
    await _until(
      session,
      (view) => view.stage == driver.State.awaitingAccountConsent,
    );
    await source.authorizeSource(phone, authorized: true);
    await session.consentAccounts(accepted: true);
    await _until(
      session,
      (view) => view.stage == driver.State.awaitingApproval,
    );
    final shown = await _preview(session);
    await _approve(session, shown);
    var finalGranted = false;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline) && cancellation == null) {
      await session.refresh();
      final remote = await native.deviceSyncStatus(endpoint: phone);
      if (remote.state == 'AwaitingAccountFinal' && !finalGranted) {
        await source.authorizeFinalSource(phone);
        finalGranted = true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(cancellation, isNotNull);
    expect(await cancellation, isA<AccountRecoveryRequired>());
    expect(backend.deviceSyncStartup.ready, isFalse);
    expect(backend.deviceSyncStartup.phase, DeviceStartupPhase.actionRequired);
    expect(backend.accountWorkGate.recoveryRequired, isTrue);
    expect(
      () => service.hostWifi(address: address, name: 'Not admitted'),
      throwsA(isA<DeviceSyncBusy>()),
    );
    expect(await native.listTags(), ['shared marker']);
    secure.failActiveWrites = false;
    await backend.deviceSyncStartup.start();
    expect(backend.deviceSyncStartup.ready, isTrue);
    expect(backend.accountWorkGate.busy, isFalse);
    expect(identical(settingsBefore, backend.settings), isTrue);
    expect({
      for (final key in accountActiveKeys) key: secure.values[key],
    }, oldActive);
    expect(await native.listTags(), ['rollback sentinel', 'shared marker']);
    expect(() => session.approvePreview(shown), throwsA(isA<DeviceSyncBusy>()));
    final fresh = await service.hostWifi(address: address, name: 'Fresh retry');
    await fresh.close();
    debugPrintSynchronously(
      '5B2 actual runtime recovery: SQL applied before local page cancellation; '
      'OS compensation failure retained pending/gate; historical ready and new '
      'host rejected; same owner recovered exact old keys and tags; settings '
      'initialized once; old session capability rejected; fresh invite available.',
    );
  } finally {
    secure.failActiveWrites = false;
    session.removeListener(cancelAfterLibraryCommit);
    try {
      await session.close();
    } on AccountRecoveryRequired {
      // The test deliberately left the same owner to run explicit recovery.
    }
    await native.deviceSyncShutdown(endpoint: phone);
    await source.releaseSource(phone);
    await native.deviceSyncCloseEndpoint(endpoint: phone);
  }
}

Future<void> _libraryScenario(
  DeviceSyncService service,
  String address,
  String peerLibrary, {
  required String diagnosticLabel,
  required bool phoneToDesktop,
  required bool overwrite,
}) async {
  final session = await service.hostWifi(address: address, name: 'Desktop');
  final phone = await native.deviceSyncClientTcp(
    library_: peerLibrary,
    invitation: session.invitation!,
    name: 'Phone',
  );
  try {
    await _until(
      session,
      (view) => view.pairing == read.PairingStage.awaitingConfirmation,
      label: '$diagnosticLabel:pairing-awaiting-confirmation',
    );
    final first = session.refresh();
    expect(identical(first, session.refresh()), isTrue);
    await first;
    await session.confirmPairing();
    await session.confirmPairing();
    await native.deviceSyncConfirm(endpoint: phone);
    await _until(
      session,
      (view) => view.pairing == read.PairingStage.confirmed,
      label: '$diagnosticLabel:pairing-confirmed',
    );
    await session.configure(
      phoneToDesktop: phoneToDesktop,
      overwrite: overwrite,
    );
    if (phoneToDesktop) {
      await _until(
        session,
        (view) => view.stage == driver.State.awaitingApproval,
        label: '$diagnosticLabel:awaiting-approval',
      );
      final shown = await _preview(session);
      await expectLater(
        session.approvePreview(DeviceSyncPreviewView(library: shown.library)),
        throwsA(isA<AccountPreviewChanged>()),
        reason: 'Constructible display values cannot forge execution approval.',
      );
      await _approve(session, shown);
      await expectLater(
        session.approvePreview(shown),
        throwsA(isA<AccountPreviewChanged>()),
      );
    } else {
      await _untilPeer(phone, 'AwaitingApproval');
      await native.deviceSyncApprove(endpoint: phone);
    }
    await _until(
      session,
      (view) => view.stage == driver.State.completed,
      label: '$diagnosticLabel:completed',
    );
    await _untilPeer(phone, 'Completed');
    await _untilCompletedAndTcpClosed(
      session,
      label: '$diagnosticLabel:completed-and-tcp-closed',
    );
    expect(session.confirmationCode, isNull);
  } finally {
    await session.close();
    await native.deviceSyncCloseEndpoint(endpoint: phone);
  }
}

Future<void> _accountReceiverScenario(
  DeviceSyncService service,
  String address,
  String peerLibrary,
  _SecureBoundary secure,
) async {
  final session = await service.hostWifi(address: address, name: 'Desktop');
  final phone = await native.deviceSyncClientTcp(
    library_: peerLibrary,
    invitation: session.invitation!,
    name: 'Phone',
  );
  final source = DeviceAccountCoordinator(
    library: peerLibrary,
    storage: MemoryAccountStorage(
      values: {accountTokensKey: '{"incoming":"synthetic-incoming"}'},
    ),
    gate: AccountWorkGate(),
    invalidate: (_) async {},
    publish: (_) {},
  );
  try {
    await _until(
      session,
      (view) => view.pairing == read.PairingStage.awaitingConfirmation,
    );
    await session.confirmPairing();
    await native.deviceSyncConfirm(endpoint: phone);
    await _until(
      session,
      (view) => view.pairing == read.PairingStage.confirmed,
    );
    await session.configure(
      phoneToDesktop: true,
      overwrite: true,
      includeAccounts: true,
    );
    await _until(
      session,
      (view) => view.stage == driver.State.awaitingAccountConsent,
    );
    secure.reads.clear();
    await source.authorizeSource(phone, authorized: true);
    await session.refresh();
    expect(secure.reads.where(accountActiveKeys.contains), isEmpty);
    await session.consentAccounts(accepted: true);
    await _until(
      session,
      (view) => view.stage == driver.State.awaitingApproval,
    );
    final shown = await _preview(session);
    expect(shown.accounts?.added, 1);
    expect(shown.accounts?.removed, 0);
    await _approve(session, shown);
    var sourceFinal = false;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final state = await session.refresh();
      final remote = await native.deviceSyncStatus(endpoint: phone);
      if (remote.state == 'AwaitingAccountFinal' && !sourceFinal) {
        await source.authorizeFinalSource(phone);
        sourceFinal = true;
      }
      if (state.value?.stage == driver.State.completed) break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(session.snapshot?.value?.stage, driver.State.completed);
    expect(
      secure.values[accountTokensKey],
      '{"incoming":"synthetic-incoming"}',
    );
    debugPrintSynchronously(
      '5B2 actual account receiver: remote consent alone did not read local '
      'keys; separate local consent, safe counts, receiver approval and '
      'original coordinator final/apply reached real Completed.',
    );
  } finally {
    await session.close();
    await native.deviceSyncShutdown(endpoint: phone);
    await source.releaseSource(phone);
    await native.deviceSyncCloseEndpoint(endpoint: phone);
  }
}

Future<void> _untilPeer(String endpoint, String expected) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    final current = await native.deviceSyncStatus(endpoint: endpoint);
    if (current.state == expected) return;
    if (current.terminal) fail('Peer unexpectedly reached ${current.state}');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('Controlled peer did not reach $expected');
}

Future<DeviceSyncPreviewView> _preview(DeviceSyncSession session) async {
  try {
    return await session.refreshPreview();
  } on AccountPreviewChanged {
    debugPrintSynchronously(
      '5B2 preview preflight failed: error=${session.issue?.name} '
      'stage=${session.snapshot?.value?.stage.name} '
      'source=${session.snapshot?.value?.source} '
      'endpointReadError=${session.snapshot?.error?.name}',
    );
    rethrow;
  }
}

Future<void> _approve(
  DeviceSyncSession session,
  DeviceSyncPreviewView shown,
) async {
  try {
    await session.approvePreview(shown);
  } on AccountPreviewChanged {
    debugPrintSynchronously(
      '5B2 approval preflight failed: error=${session.issue?.name} '
      'stage=${session.snapshot?.value?.stage.name} '
      'source=${session.snapshot?.value?.source} '
      'endpointReadError=${session.snapshot?.error?.name}',
    );
    rethrow;
  }
}

Future<void> _until(
  DeviceSyncSessionController session,
  bool Function(read.EndpointView) predicate, {
  String? label,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  final diagnostics = _WaitDiagnostics(label);
  while (DateTime.now().isBefore(deadline)) {
    late read.EndpointRead current;
    try {
      current = await session.refresh();
    } on DeviceCommandError catch (failure) {
      debugPrintSynchronously(
        '5B2 observation command failed: code=${failure.code.name} '
        'executed=${failure.executed} '
        'preReadStage=${session.snapshot?.value?.stage.name} '
        'preReadTerminal=${session.snapshot?.value?.terminal} '
        'preReadTcp=${session.snapshot?.tcp?.phase.name} '
        'preReadError=${session.snapshot?.error?.name}',
      );
      rethrow;
    }
    if (current.value case final value?) {
      final satisfied = predicate(value);
      diagnostics.observe(current, satisfied);
      if (satisfied) return;
      if (value.terminal) {
        diagnostics.reject('Unexpected terminal ${value.stage}');
      }
    } else {
      diagnostics.observe(current, false);
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  diagnostics.reject(
    'Controlled service did not reach the expected protocol stage',
  );
}

Future<void> _untilCompletedAndTcpClosed(
  DeviceSyncSessionController session, {
  required String label,
  DateTime Function()? now,
  Future<void> Function()? pause,
}) async {
  final clock = now ?? DateTime.now;
  final wait =
      pause ?? () => Future<void>.delayed(const Duration(milliseconds: 25));
  final deadline = clock().add(const Duration(seconds: 20));
  final diagnostics = _WaitDiagnostics(label);
  while (clock().isBefore(deadline)) {
    final current = await session.refresh();
    final value = current.value;
    final satisfied =
        value?.stage == driver.State.completed &&
        current.tcp?.phase == TcpPhase.closed;
    diagnostics.observe(current, satisfied);
    if (satisfied) return;
    if (value?.terminal == true && value?.stage != driver.State.completed) {
      diagnostics.reject('Unexpected terminal ${value!.stage}');
    }
    await wait();
  }
  diagnostics.reject(
    'Controlled service did not reach the expected protocol stage',
  );
}

read.EndpointRead _waitSample(driver.State stage, TcpPhase phase) {
  final progress = read.ProgressView(
    workStage: work.WorkStage.idle,
    workActive: false,
    scannedItems: BigInt.zero,
  );
  return read.EndpointRead(
    value: read.EndpointView(
      pairing: read.PairingStage.confirmed,
      confirmationAvailable: false,
      transport: read.TransportKind.tcp,
      host: true,
      controller: true,
      phoneControlled: false,
      previewApproved: false,
      accountsConsentAuthorized: false,
      source: false,
      stage: stage,
      terminal: true,
      cleanupPending: stage == driver.State.recoveryPending,
      localApplyInstalled: false,
      sourceGrantIssued: false,
      transportDetached: false,
      progress: progress,
    ),
    progress: progress,
    tcp: TcpView(phase: phase),
  );
}

class _WaitObservation implements DeviceSyncSessionController {
  _WaitObservation(this.observe, {this.snapshotOverride});
  final Future<read.EndpointRead> Function(int index) observe;
  final read.EndpointRead? snapshotOverride;
  int reads = 0;
  read.EndpointRead? _snapshot;

  @override
  read.EndpointRead? get snapshot => snapshotOverride ?? _snapshot;

  @override
  Future<read.EndpointRead> refresh() async {
    final current = await observe(reads++);
    _snapshot = current;
    return current;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SecureBoundary extends FlutterSecureStoragePlatform {
  final values = <String, String>{};
  final reads = <String>[];
  bool failActiveWrites = false;
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    reads.add(key);
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (failActiveWrites && accountActiveKeys.contains(key)) {
      throw StateError('Synthetic OS credential write failure');
    }
    values[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    if (failActiveWrites && accountActiveKeys.contains(key)) {
      throw StateError('Synthetic OS credential delete failure');
    }
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected OS credential operation');
}
