import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/rust/device_sync/connection.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/ui/device_sync/debug_pairing.dart';
import 'package:squid_album/src/ui/device_sync/device_sync_page.dart';

import 'debug_pairing_test.dart' show request, result, reason;
import 'device_sync_page_test.dart'
    show PageAccess, pageApp, createHost, endPage;
import 'session_panel_test.dart' show PanelSession, endpoint, progress;

void main() {
  testWidgets(
    'mobile background and lock lifecycle refuse injection until resumed',
    (tester) async {
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      final access = _MobileAccess();
      await _openMobile(tester, access);
      final bridge = DeviceSyncPairingDebug.instance;
      final status = result(await request(bridge, 'status'));
      final generation = status['generation'] as int;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        expect(reason(await request(bridge, 'status')), 'unavailable');
        expect(
          reason(
            await request(
              bridge,
              'inject',
              generation: generation,
              invitation: 'must-not-connect',
            ),
          ),
          'unavailable',
        );
        expect(access.received, isEmpty);
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(result(await request(bridge, 'status'))['canInject'], isTrue);
      await _endMobile(tester);
    },
  );

  testWidgets(
    'injected Wi-Fi scan uses the real page and still requires confirmation',
    (tester) async {
      final access = _MobileAccess();
      await _openMobile(tester, access);
      final bridge = DeviceSyncPairingDebug.instance;
      final status = result(await request(bridge, 'status'));
      expect(status['mobile'], isTrue);
      expect(status['transport'], 'wifi');
      final pending = request(
        bridge,
        'inject',
        generation: status['generation'] as int,
        invitation: 'synthetic-sensitive-invitation',
      );
      await tester.pumpAndSettle();
      expect(result(await pending)['accepted'], isTrue);
      expect(access.received, ['synthetic-sensitive-invitation']);
      expect(find.text('123 456'), findsOneWidget);
      expect(find.byKey(const Key('device-confirm-pair')), findsOneWidget);
      final session = access.sessions.single;
      expect(session.confirmedLocally, isFalse);
      expect(session.configurations, isEmpty);
      expect(session.consents, isEmpty);
      expect(session.approvals, isEmpty);
      expect(
        find.textContaining('synthetic-sensitive-invitation'),
        findsNothing,
      );
      expect(
        reason(
          await request(
            bridge,
            'inject',
            generation: status['generation'] as int,
            invitation: 'again',
          ),
        ),
        'unavailable',
      );
      await tester.tap(find.byKey(const Key('device-confirm-pair')));
      await tester.pump();
      expect(session.confirmedLocally, isTrue);
      expect(session.configurations, isEmpty);
      session.update(
        endpoint(
          driver.State.configuring,
          pairing: read.PairingStage.confirmed,
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.byKey(const Key('device-connection-info')), findsNothing);
      session.update(
        endpoint(driver.State.completed, pairing: read.PairingStage.terminal),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.byKey(const Key('device-connection-info')), findsNothing);
      expect(find.byKey(const Key('device-sync-complete')), findsOneWidget);
      await tester.tap(find.byKey(const Key('device-sync-complete')));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceSyncPage), findsNothing);
      expect(session.closed, isTrue);
      expect(reason(await request(bridge, 'status')), 'unavailable');
    },
  );

  testWidgets(
    'USB injection retains the existing directory attempt and failure handling',
    (tester) async {
      final access = _MobileAccess()
        ..invitationUsb = true
        ..connectFailure = StateError('private-synthetic-diagnostic');
      await _openMobile(tester, access);
      final bridge = DeviceSyncPairingDebug.instance;
      final status = result(await request(bridge, 'status'));
      final pending = request(
        bridge,
        'inject',
        generation: status['generation'] as int,
        invitation: 'synthetic-usb-invitation',
      );
      await tester.pumpAndSettle();
      final response = await pending;
      expect(reason(response), 'operation_failed');
      expect(response.errorDetail, isNot(contains('private-synthetic')));
      expect(access.usbAttempts, 1);
      expect(access.usbConnects, 1);
      expect(access.received, ['synthetic-usb-invitation']);
      expect(find.byKey(const Key('device-page-error')), findsOneWidget);
      expect(find.textContaining('private-synthetic'), findsNothing);
      expect(find.byKey(const Key('device-scan-code')), findsOneWidget);
      await _endMobile(tester);
    },
  );

  testWidgets(
    'foreground host exposes only its live unconfirmed one-time code',
    (tester) async {
      final host = _HostSession()..state = _hostView(remaining: 10000);
      final access = PageAccess()..sessionFactory = () => host;
      await tester.pumpWidget(
        pageApp(builder: (_) => DeviceSyncPage(access: access, mobile: false)),
      );
      await tester.tap(find.byKey(const Key('open-page')));
      await tester.pumpAndSettle();
      await createHost(tester);
      await tester.pump();
      final bridge = DeviceSyncPairingDebug.instance;
      final status = result(await request(bridge, 'status'));
      final generation = status['generation'] as int;
      expect(
        result(
          await request(bridge, 'read', generation: generation),
        )['invitation'],
        'synthetic-live-invitation',
      );
      host.update(_hostView(remaining: 0));
      await tester.pump();
      expect(
        reason(await request(bridge, 'read', generation: generation)),
        'unavailable',
      );
      host.update(
        endpoint(
          driver.State.pairing,
          pairing: read.PairingStage.awaitingConfirmation,
        ),
      );
      await tester.pump();
      expect(
        reason(await request(bridge, 'read', generation: generation)),
        'unavailable',
      );
      await endPage(tester);
      expect(reason(await request(bridge, 'status')), 'unavailable');
    },
  );

  testWidgets('covered or recovery-blocked page refuses debug input', (
    tester,
  ) async {
    final access = _MobileAccess();
    await _openMobile(tester, access);
    final bridge = DeviceSyncPairingDebug.instance;
    final status = result(await request(bridge, 'status'));
    access.setReady(false);
    await tester.pump();
    expect(
      reason(
        await request(
          bridge,
          'inject',
          generation: status['generation'] as int,
          invitation: 'input',
        ),
      ),
      'unavailable',
    );
    access.setReady(true);
    await tester.pump();
    final context = tester.element(find.byType(DeviceSyncPage));
    final navigator = Navigator.of(context);
    final closed = navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('Synthetic covering route')),
      ),
    );
    await tester.pumpAndSettle();
    expect(reason(await request(bridge, 'status')), 'unavailable');
    navigator.pop();
    await tester.pumpAndSettle();
    await closed;
    expect(access.received, isEmpty);
    await _endMobile(tester);
  });
}

Future<void> _openMobile(WidgetTester tester, _MobileAccess access) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    pageApp(
      builder: (_) => DeviceSyncPage(
        access: access,
        mobile: true,
        cameraFactory: () =>
            throw StateError('Debug injection must not create a camera'),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-page')));
  await tester.pumpAndSettle();
}

Future<void> _endMobile(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('android-page-back')));
  await tester.pumpAndSettle();
  if (find.byKey(const Key('device-confirm-leave')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const Key('device-confirm-leave')));
    await tester.pumpAndSettle();
  }
}

class _MobileAccess extends PageAccess {
  final received = <String>[];
  int usbAttempts = 0, usbConnects = 0;
  Object? connectFailure;
  bool invitationUsb = false;
  @override
  Future<InvitationConnection> inspectInvitation(String invitation) async =>
      InvitationConnection(usb: invitationUsb);
  Future<DeviceSyncSessionController> _connect(String invitation) async {
    received.add(invitation);
    if (connectFailure case final failure?) throw failure;
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
  }) => _connect(invitation);

  @override
  DeviceUsbAttemptController prepareUsb({
    required String invitation,
    required String name,
  }) {
    usbAttempts++;
    return _UsbAttempt(() {
      usbConnects++;
      return _connect(invitation);
    });
  }
}

class _UsbAttempt implements DeviceUsbAttemptController {
  _UsbAttempt(this.open);
  final Future<DeviceSyncSessionController> Function() open;
  @override
  Future<DeviceSyncSessionController> connect() => open();
  @override
  Future<void> cancel() async {}
}

class _HostSession extends PanelSession {
  @override
  String? get invitation => 'synthetic-live-invitation';
}

read.EndpointRead _hostView({required int remaining}) => read.EndpointRead(
  progress: progress,
  value: read.EndpointView(
    pairing: read.PairingStage.handshaking,
    confirmationAvailable: false,
    invitationRemainingMs: BigInt.from(remaining),
    transport: read.TransportKind.tcp,
    host: true,
    controller: false,
    phoneControlled: true,
    previewApproved: false,
    accountsConsentAuthorized: false,
    stage: driver.State.pairing,
    terminal: false,
    cleanupPending: false,
    localApplyInstalled: false,
    sourceGrantIssued: false,
    transportDetached: false,
    progress: progress,
  ),
);
