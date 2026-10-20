import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_coordinator.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/account_storage.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/device_sync/connection.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/rust/frb_generated.dart';

import 'account_storage_test.dart' show MemoryAccountStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];
  final address = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_TCP_ADDRESS'];
  test(
    'phone-only real service controls both directions and separately consents to accounts',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      try {
        for (final phoneToDesktop in [false, true]) {
          for (final accounts in [false, true]) {
            final root = await Directory.systemTemp.createTemp(
              'nsoalbum-phone-controller-',
            );
            final desktopRoot = Directory('${root.path}/desktop');
            final phoneRoot = Directory('${root.path}/phone');
            final desktopStorage = _ObservedStorage('desktop');
            final phoneStorage = _ObservedStorage('phone');
            final desktopGate = AccountWorkGate();
            final desktop = await _start(
              desktopRoot,
              desktopStorage,
              gate: desktopGate,
            );
            final mobile = await _start(phoneRoot, phoneStorage);
            DeviceSyncSession? host, phone;
            try {
              host = await desktop.service.hostWifi(
                address: address!,
                name: 'Synthetic desktop',
                appBuild: const ApplicationBuild(
                  version: '0.2.14',
                  buildNumber: '47',
                ),
              );
              phone = await mobile.service.joinWifi(
                invitation: host.invitation!,
                name: 'Synthetic phone',
              );
              await _until(
                host,
                phone,
                () =>
                    phone!.snapshot?.value?.confirmationAvailable == true &&
                    host!.snapshot?.value?.pairing ==
                        read.PairingStage.awaitingConfirmation,
              );
              expect(host.snapshot!.value!.controller, isFalse);
              expect(phone.snapshot!.value!.controller, isTrue);
              expect(host.confirmationCode, isNotNull);
              expect(host.confirmationCode, phone.confirmationCode);
              await expectLater(
                host.confirmPairing(),
                throwsA(isA<DeviceSyncBusy>()),
              );
              await phone.confirmPairing();
              await _until(
                host,
                phone,
                () =>
                    host!.snapshot?.value?.pairing ==
                        read.PairingStage.confirmed &&
                    phone!.snapshot?.value?.pairing ==
                        read.PairingStage.confirmed,
              );
              expect(host.confirmedLocally, isFalse);
              await expectLater(
                host.configure(
                  phoneToDesktop: phoneToDesktop,
                  overwrite: false,
                ),
                throwsA(isA<DeviceSyncBusy>()),
              );
              await phone.configure(
                phoneToDesktop: phoneToDesktop,
                overwrite: true,
                includeAccounts: accounts,
              );
              if (accounts) {
                await _until(
                  host,
                  phone,
                  () =>
                      phone!.snapshot?.value?.stage ==
                      driver.State.awaitingAccountConsent,
                );
                expect(desktopStorage.activeReads, 0);
                expect(phoneStorage.activeReads, 0);
                expect(
                  desktopGate.normalPermit,
                  throwsA(isA<DeviceSyncBusy>()),
                  reason:
                      'An active transfer also excludes ordinary account '
                      'work while waiting for separate account consent.',
                );
                await phone.consentAccounts(accepted: true);
              }
              await _until(
                host,
                phone,
                () =>
                    phone!.snapshot?.value?.stage ==
                        driver.State.awaitingApproval &&
                    host!.snapshot?.value?.stage ==
                        driver.State.awaitingApproval,
              );
              DeviceSyncPreviewView? preview;
              final previewDeadline = DateTime.now().add(
                const Duration(seconds: 20),
              );
              while (preview == null &&
                  DateTime.now().isBefore(previewDeadline)) {
                try {
                  preview = await phone.refreshPreview();
                } on AccountPreviewChanged {
                  await Future<void>.delayed(const Duration(milliseconds: 50));
                  await host.refresh();
                  await phone.refresh();
                }
              }
              expect(preview, isNotNull);
              expect(preview!.library.receiverBudget, isNotNull);
              expect(preview.accounts != null, accounts);
              if (accounts) {
                expect(preview.accounts!.added, 1);
                expect(preview.accounts!.removed, 1);
              }
              expect(
                host.snapshot!.value!.stage,
                driver.State.awaitingApproval,
                reason: 'No application before the phone confirms its preview.',
              );
              expect(preview.library.media.added, BigInt.zero);
              await phone.approvePreview(preview);
              await _until(
                host,
                phone,
                () =>
                    host!.snapshot?.value?.stage == driver.State.completed &&
                    phone!.snapshot?.value?.stage == driver.State.completed,
                allowCompleted: true,
              );
              final sourceStorage = phoneToDesktop
                  ? phoneStorage
                  : desktopStorage;
              final targetStorage = phoneToDesktop
                  ? desktopStorage
                  : phoneStorage;
              if (accounts) {
                expect(
                  jsonDecode(targetStorage.values[accountTokensKey]!),
                  jsonDecode(sourceStorage.values[accountTokensKey]!),
                );
              } else {
                expect(desktopStorage.activeReads, 0);
                expect(phoneStorage.activeReads, 0);
              }
              expect(
                host.issue,
                isNull,
                reason: 'Successful retry/completion replaces temporary Busy.',
              );
              expect(phone.issue, isNull);
            } finally {
              await host?.close();
              await phone?.close();
              await desktop.close();
              await mobile.close();
              await root.delete(recursive: true);
            }
          }
        }
      } finally {
        RustLib.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: library == null || address == null
        ? 'Requires current native Debug library and an active private LAN address'
        : false,
  );
}

Future<DeviceSyncStartupLifecycle> _start(
  Directory root,
  MemoryAccountStorage storage, {
  AccountWorkGate? gate,
}) async {
  final selectedGate = gate ?? AccountWorkGate();
  final lifecycle = DeviceSyncStartupLifecycle(
    gate: selectedGate,
    isolated: false,
    openLibrary: () async =>
        (await native.deviceSyncOpenLibrary(libraryRoot: root.path)).handle,
    coordinator: (library) => DeviceAccountCoordinator(
      library: library,
      storage: storage,
      gate: selectedGate,
      invalidate: (_) async {},
      publish: (_) {},
    ),
    initialize: () async {},
  );
  await lifecycle.start();
  expect(lifecycle.ready, isTrue, reason: '${lifecycle.error}');
  return lifecycle;
}

Future<void> _until(
  DeviceSyncSession host,
  DeviceSyncSession phone,
  bool Function() predicate, {
  bool allowCompleted = false,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(deadline)) {
    await host.refresh();
    await phone.refresh();
    if (predicate()) return;
    for (final session in [host, phone]) {
      if (session.snapshot?.value?.terminal == true &&
          !(allowCompleted &&
              session.snapshot?.value?.stage == driver.State.completed)) {
        fail(
          'Unexpected stage ${session.snapshot?.value?.stage.name}; '
          'issue=${session.issue?.name}; '
          'TCP=${session.snapshot?.tcp?.error?.name}',
        );
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail(
    'Timed out: host=${host.snapshot?.value?.stage.name}, '
    'phone=${phone.snapshot?.value?.stage.name}; '
    'issues=${host.issue?.name}/${phone.issue?.name}',
  );
}

class _ObservedStorage extends MemoryAccountStorage {
  _ObservedStorage(String id)
    : super(
        values: {
          accountTokensKey: jsonEncode({id: 'synthetic-session-$id'}),
          accountProfilesKey: jsonEncode({
            id: {'nickname': 'Synthetic $id'},
          }),
          selectedAccountKey: id,
        },
      );
  int activeReads = 0;
  @override
  Future<String?> read(String key) {
    if (accountActiveKeys.contains(key)) activeReads++;
    return super.read(key);
  }
}
