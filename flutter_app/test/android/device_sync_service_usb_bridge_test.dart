@Tags(['platform-android'])
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// The operating-system protected-storage boundary alone is replaced.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/backend/rust_backend.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/rust/settings.dart';

import '../device_sync/usb_runtime_bridge_test.dart'
    show startUsbPeerFixture, usbDirectoryFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];
  final executable = Platform.environment['NSOALBUM_DEVICE_SYNC_USB_PEER'];
  test(
    'formal service owns real USB SAF transfer and account automatic finals',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      final oldSecure = FlutterSecureStoragePlatform.instance;
      final secure = _UsbSecureBoundary();
      FlutterSecureStoragePlatform.instance = secure;
      final root = await Directory.systemTemp.createTemp(
        'nsoalbum-5b2-usb-formal-',
      );
      await native.initCore(libraryRoot: root.path);
      await native.saveSettings(
        settings: AppSettings(
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
      await backend.deviceSyncStartup.start();
      expect(backend.deviceSyncStartup.ready, isTrue);
      const channel = MethodChannel('io.github.cypas.nsoalbum/device_sync_saf');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      try {
        final service = backend.deviceSyncStartup.service;
        for (final accounts in [false, true]) {
          final peer = await startUsbPeerFixture(executable!);
          final boundary = usbDirectoryFixture(peer.root);
          var pickers = 0;
          messenger.setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'selectTree') {
              pickers++;
              return null;
            }
            return boundary.call(call);
          });
          DeviceSyncSession? session;
          try {
            secure.forbidActiveReads = !accounts;
            final attempt = service.prepareUsbClient(
              invitation: await peer.invitation.timeout(
                const Duration(seconds: 10),
              ),
              name: 'Synthetic Android',
            );
            expect(pickers, 0);
            session = await attempt.connect();
            expect(pickers, 1);
            expect(
              identical(service, backend.deviceSyncStartup.service),
              isTrue,
            );
            await _wait(
              session,
              (view) => view.confirmationAvailable,
              peer.diagnostics,
              boundary.diagnostics,
            );
            expect(session.confirmedLocally, isFalse);
            await session.confirmPairing();
            peer.grant('confirm');
            await _wait(
              session,
              (view) => view.pairing == read.PairingStage.confirmed,
              peer.diagnostics,
              boundary.diagnostics,
            );
            peer.grant(accounts ? 'configure_accounts' : 'configure_library');
            if (accounts) {
              await _wait(
                session,
                (view) => view.stage == driver.State.awaitingAccountConsent,
                peer.diagnostics,
                boundary.diagnostics,
              );
              expect(session.accountsAuthorized, isFalse);
              await session.consentAccounts(accepted: true);
            }
            await _wait(
              session,
              (view) => view.stage == driver.State.awaitingApproval,
              peer.diagnostics,
              boundary.diagnostics,
            );
            final preview = await session.refreshPreview();
            expect(
              (await backend.listMedia(limit: 20)).length,
              accounts ? 1 : 0,
              reason: 'Receiver preview must not start writing.',
            );
            await session.approvePreview(preview);
            if (accounts) peer.grant('source_final');
            await _wait(
              session,
              (view) => view.stage == driver.State.completed,
              peer.diagnostics,
              boundary.diagnostics,
            );
            final media = await backend.listMedia(limit: 20);
            expect(media.length, 1);
            expect(
              await File(media.single.storagePath).length(),
              256 * 1024 + 13,
            );
            if (accounts) {
              expect(
                secure.values[accountTokensKey],
                '{"new":"synthetic-new"}',
              );
            }
            await session.close();
            expect(session.settled, isTrue);
            final done = await peer.finish();
            expect(done['state'], 'Completed');
            expect(done['source_protected'], accounts);
            expect(backend.accountWorkGate.busy, isFalse);
            expect(backend.deviceSyncStartup.ready, isTrue);
            expect(boundary.methods, contains('openSession'));
            expect(boundary.methods, contains('close'));
            debugPrintSynchronously(
              '5B2 formal service actual USB: accounts=$accounts; picker before '
              'client; original SAF byte owner; explicit pair/receiver approval; '
              'original automatic targetFinal/apply Completed. ${peer.diagnostics()}',
            );
          } finally {
            secure.forbidActiveReads = false;
            await session?.close();
            if (await peer.process.exitCode.timeout(
                  const Duration(seconds: 1),
                  onTimeout: () => -999,
                ) ==
                -999) {
              peer.grant('cancel');
            }
            await peer.finish();
            messenger.setMockMethodCallHandler(channel, null);
          }
        }
      } finally {
        secure.forbidActiveReads = false;
        messenger.setMockMethodCallHandler(channel, null);
        await backend.close();
        FlutterSecureStoragePlatform.instance = oldSecure;
        RustLib.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
    skip: library == null || executable == null
        ? 'Requires current verified DLL/current Cargo JSON peer; synthetic SAF boundary only.'
        : false,
  );
}

Future<void> _wait(
  DeviceSyncSession session,
  bool Function(read.EndpointView) ready,
  String Function() peerDiagnostic,
  String Function() boundaryDiagnostic,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 35));
  while (DateTime.now().isBefore(deadline)) {
    final view = await session.refresh();
    if (view.value != null && ready(view.value!)) return;
    if (view.value?.terminal == true) break;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail(
    'Bounded formal USB wait stage=${session.snapshot?.value?.stage.name} '
    'readError=${session.snapshot?.error?.name}; ${peerDiagnostic()}; ${boundaryDiagnostic()}',
  );
}

class _UsbSecureBoundary extends FlutterSecureStoragePlatform {
  final values = <String, String>{};
  bool forbidActiveReads = false;
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    if (forbidActiveReads && accountActiveKeys.contains(key)) {
      throw StateError('Pure-library USB must not read active protected keys');
    }
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => values[key] = value;
  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => values.remove(key);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected synthetic protected-storage call');
}
