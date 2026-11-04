import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/platform/device_sync_network.dart';
import 'package:squid_album/src/rust/device_sync/connection.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/ui/device_sync/debug_pairing.dart';
import 'package:squid_album/src/ui/device_sync/device_sync_page.dart';

import 'debug_pairing_test.dart' show request, result, reason;
import 'device_sync_page_test.dart'
    show PageAccess, pageApp, createHost, endPage, reveal;
import 'session_panel_test.dart' show PanelSession, endpoint;

void main() {
  testWidgets(
    'returning immediately after backgrounding cannot revive a cancelled permission continuation',
    (tester) async {
      final permission = Completer<void>();
      final access = _Access()..wifiWait = permission.future;
      await _open(tester, access);
      final bridge = DeviceSyncPairingDebug.instance;
      final status = result(await request(bridge, 'status'));
      final pending = request(
        bridge,
        'inject',
        generation: status['generation'] as int,
        invitation: 'synthetic-invitation',
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      permission.complete();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(access.wifiConnections, 0);
      expect(reason(await pending), 'operation_failed');
      await _endMobile(tester);
    },
  );

  testWidgets(
    'a normal permission dialog waits for foreground before connecting',
    (tester) async {
      final permission = Completer<void>();
      final access = _Access()..wifiWait = permission.future;
      await _open(tester, access);
      final bridge = DeviceSyncPairingDebug.instance;
      final status = result(await request(bridge, 'status'));
      final pending = request(
        bridge,
        'inject',
        generation: status['generation'] as int,
        invitation: 'synthetic-invitation',
      );
      await tester.pump();
      expect(access.networkReads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      permission.complete();
      await tester.pump();
      expect(access.wifiConnections, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(result(await pending)['accepted'], isTrue);
      expect(access.wifiConnections, 1);
      await _endMobile(tester);
    },
  );

  testWidgets(
    'version mismatch is localized and never requests access or connects',
    (tester) async {
      for (final language in ['zh', 'en']) {
        final access = _Access()
          ..inspectionFailure = const DeviceSyncReadFailure(
            read.ReadError.versionMismatch,
          );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(
          pageApp(
            language: language,
            builder: (_) => DeviceSyncPage(access: access, mobile: true),
          ),
        );
        await tester.tap(find.byKey(const Key('open-page')));
        await tester.pumpAndSettle();
        await _inject(tester, success: false);
        await reveal(tester, find.byKey(const Key('device-page-error')));
        expect(
          find.textContaining(language == 'zh' ? '构建号' : 'build number'),
          findsOneWidget,
        );
        expect(access.networkReads, 0);
        expect(access.wifiConnections + access.usbConnections, 0);
        await _endMobile(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'backgrounding during invitation inspection never requests permission or connects',
    (tester) async {
      final inspected = Completer<void>();
      final access = _Access()..inspectionWait = inspected.future;
      await _open(tester, access);
      final bridge = DeviceSyncPairingDebug.instance;
      final status = result(await request(bridge, 'status'));
      final pending = request(
        bridge,
        'inject',
        generation: status['generation'] as int,
        invitation: 'synthetic-invitation',
      );
      await tester.pump();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      inspected.complete();
      await tester.pumpAndSettle();
      expect(access.networkReads, 0);
      expect(access.wifiConnections, 0);
      expect(reason(await pending), 'operation_failed');
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await _endMobile(tester);
    },
  );

  testWidgets(
    'mobile USB invitation connects without a manual transport control or Wi-Fi access',
    (tester) async {
      final access = _Access()..usbInvitation = true;
      await _open(tester, access);
      expect(find.byKey(const Key('device-usb')), findsNothing);
      expect(find.byKey(const Key('device-wifi')), findsNothing);
      await _inject(tester);
      expect(access.usbConnections, 1);
      expect(access.wifiConnections, 0);
      expect(access.networkReads, 0);
      expect(find.text('USB file transfer'), findsOneWidget);
      expect(access.sessions.single.confirmedLocally, isFalse);
      await _endMobile(tester);
    },
  );

  testWidgets(
    'same, different, missing SSID all preserve Wi-Fi and never fall back to USB',
    (tester) async {
      for (final peer in ['Home', 'Other', null]) {
        final access = _Access()..peerSsid = peer;
        await _open(tester, access);
        await _inject(tester);
        expect(access.wifiConnections, 1);
        expect(access.usbConnections, 0);
        expect(access.requestedPermission, isTrue);
        final expected = peer == 'Home'
            ? 'Wi-Fi names match'
            : peer == null
            ? 'Wi-Fi name unavailable'
            : 'Wi-Fi names differ';
        expect(find.textContaining(expected), findsOneWidget);
        expect(find.byKey(const Key('device-confirm-pair')), findsOneWidget);
        expect(access.sessions.single.confirmedLocally, isFalse);
        await _endMobile(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'invalid invitation does not request permissions or open any transport',
    (tester) async {
      final access = _Access()
        ..inspectionFailure = StateError('private invitation');
      await _open(tester, access);
      final response = await _inject(tester, success: false);
      expect(reason(response), 'operation_failed');
      expect(access.networkReads, 0);
      expect(access.usbConnections, 0);
      expect(access.wifiConnections, 0);
      expect(find.byKey(const Key('device-page-error')), findsOneWidget);
      expect(find.textContaining('private invitation'), findsNothing);
      await _endMobile(tester);
    },
  );

  testWidgets(
    'desktop shows its selected transport and only sends the selected interface SSID',
    (tester) async {
      final access = _Access();
      await tester.pumpWidget(
        pageApp(builder: (_) => DeviceSyncPage(access: access, mobile: false)),
      );
      await tester.tap(find.byKey(const Key('open-page')));
      await tester.pumpAndSettle();
      await createHost(tester);
      expect(access.hostSsid, 'Home');
      await reveal(tester, find.byKey(const Key('device-connection-info')));
      expect(find.textContaining('Wi-Fi: Home'), findsOneWidget);
      await endPage(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      final wired = _Access()..localAddress = '192.168.55.5';
      await tester.pumpWidget(
        pageApp(builder: (_) => DeviceSyncPage(access: wired, mobile: false)),
      );
      await tester.tap(find.byKey(const Key('open-page')));
      await tester.pumpAndSettle();
      await createHost(tester);
      expect(wired.hostSsid, isNull);
      await reveal(tester, find.byKey(const Key('device-connection-info')));
      expect(find.textContaining('Local network'), findsWidgets);
      await endPage(tester);
    },
  );
}

Future<void> _open(WidgetTester tester, _Access access) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    pageApp(builder: (_) => DeviceSyncPage(access: access, mobile: true)),
  );
  await tester.tap(find.byKey(const Key('open-page')));
  await tester.pumpAndSettle();
}

Future<ServiceExtensionResponse> _inject(
  WidgetTester tester, {
  bool success = true,
}) async {
  final bridge = DeviceSyncPairingDebug.instance;
  final status = result(await request(bridge, 'status'));
  final pending = request(
    bridge,
    'inject',
    generation: status['generation'] as int,
    invitation: 'synthetic-invitation',
  );
  await tester.pumpAndSettle();
  final response = await pending;
  if (success) expect(result(response)['accepted'], isTrue);
  return response;
}

Future<void> _endMobile(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('android-page-back')));
  await tester.pumpAndSettle();
  if (find.byKey(const Key('device-confirm-leave')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const Key('device-confirm-leave')));
    await tester.pumpAndSettle();
  }
}

class _Access extends PageAccess {
  bool usbInvitation = false, requestedPermission = false;
  int networkReads = 0, wifiConnections = 0, usbConnections = 0;
  String? peerSsid = 'Home', hostSsid;
  String localAddress = '192.168.5.1';
  Object? inspectionFailure;
  Future<void>? inspectionWait;
  Future<void>? wifiWait;

  @override
  Future<InvitationConnection> inspectInvitation(String invitation) async {
    await inspectionWait;
    if (inspectionFailure case final error?) throw error;
    return InvitationConnection(
      usb: usbInvitation,
      wifiSsid: usbInvitation ? null : peerSsid,
    );
  }

  @override
  Future<DeviceWifiSnapshot> wifiInfo({bool requestPermission = false}) async {
    networkReads++;
    requestedPermission = requestPermission;
    await wifiWait;
    return DeviceWifiSnapshot(ssid: 'Home', address: localAddress);
  }

  @override
  Future<DeviceSyncSessionController> host({
    required bool usb,
    required String name,
    String? address,
    String? wifiSsid,
  }) {
    hostSsid = wifiSsid;
    return super.host(usb: usb, name: name, address: address);
  }

  PanelSession _session() {
    final session = PanelSession()
      ..state = endpoint(
        driver.State.pairing,
        pairing: read.PairingStage.awaitingConfirmation,
      );
    sessions.add(session);
    return session;
  }

  @override
  Future<DeviceSyncSessionController> joinWifi({
    required String invitation,
    required String name,
  }) async {
    wifiConnections++;
    return _session();
  }

  @override
  DeviceUsbAttemptController prepareUsb({
    required String invitation,
    required String name,
  }) => _UsbAttempt(() {
    usbConnections++;
    return _session();
  });
}

class _UsbAttempt implements DeviceUsbAttemptController {
  _UsbAttempt(this.open);
  final PanelSession Function() open;
  @override
  Future<DeviceSyncSessionController> connect() async => open();
  @override
  Future<void> cancel() async {}
}
