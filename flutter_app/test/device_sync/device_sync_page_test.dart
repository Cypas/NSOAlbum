import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/platform/device_sync_network.dart';
import 'package:squid_album/src/rust/device_sync/connection.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/rust/device_sync/work.dart';
import 'package:squid_album/src/ui/desktop_window_drag_area.dart';
import 'package:squid_album/src/ui/device_sync/invitation_qr.dart';
import 'package:squid_album/src/ui/device_sync/device_sync_page.dart';
import 'package:squid_album/src/ui/device_sync/page_access.dart';

import 'session_panel_test.dart' show PanelSession, endpoint;

void main() {
  testWidgets('Wi-Fi adapters load on entry and default to a 192.168 address', (
    tester,
  ) async {
    final access = _MixedLanAccess();
    await openPage(tester, access);
    expect(find.byKey(const Key('device-address-dropdown')), findsOneWidget);
    await reveal(tester, find.byKey(const Key('device-create-code')));
    await tester.tap(find.byKey(const Key('device-create-code')));
    await tester.pump();
    expect(access.hosts.single.address, '192.168.5.1');
    await endPage(tester);
  });
  testWidgets('pair again reloads Wi-Fi adapters without a manual refresh', (
    tester,
  ) async {
    final access = _MixedLanAccess();
    await openPage(tester, access);
    await reveal(tester, find.byKey(const Key('device-create-code')));
    await tester.tap(find.byKey(const Key('device-create-code')));
    await tester.pump();
    access.sessions.single.update(endpoint(driver.State.completed));
    await tester.pump();
    await reveal(tester, find.byKey(const Key('device-new-pairing')));
    await tester.tap(find.byKey(const Key('device-new-pairing')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-address-dropdown')), findsOneWidget);
    await reveal(tester, find.byKey(const Key('device-create-code')));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('device-create-code')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('device-create-code')));
    await tester.pump();
    expect(access.hosts.last.address, '192.168.5.1');
    await endPage(tester);
  });
  testWidgets(
    'phone controller automatically reviews either transfer direction once',
    (tester) async {
      for (final source in [false, true]) {
        final session = _AutomaticPreviewSession(source: source);
        final access = PageAccess()..sessionFactory = () => session;
        await openPage(tester, access);
        await createHost(tester);
        expect(session.previewReads, 1);
        expect(find.byKey(const Key('device-review-preview')), findsNothing);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(session.previewReads, 1);
        await endPage(tester);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets(
    'invitation expiry display stops at handshake and does not use QR TTL for active transfer',
    (tester) async {
      final access = PageAccess()..sessionFactory = () => _InvitationSession();
      await openPage(tester, access);
      await createHost(tester);
      final session = access.sessions.single;
      session.update(
        endpoint(driver.State.pairing, pairing: read.PairingStage.handshaking),
      );
      await tester.pump();
      expect(find.byType(DeviceInvitationQr), findsOneWidget);
      session.update(endpoint(driver.State.configuring));
      await tester.pump();
      expect(find.byType(DeviceInvitationQr), findsNothing);
      session.update(endpoint(driver.State.transferring));
      await tester.pump();
      expect(find.byType(DeviceInvitationQr), findsNothing);
      await endPage(tester);
    },
  );
  testWidgets(
    'cancel and finish requires confirmation but a failed untouched attempt does not',
    (tester) async {
      final access = PageAccess();
      await openPage(tester, access);
      await createHost(tester);
      await tester.ensureVisible(find.byKey(const Key('device-end-session')));
      await tester.tap(find.byKey(const Key('device-end-session')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device-confirm-leave')), findsOneWidget);
      await tester.tap(find.byKey(const Key('device-confirm-leave')));
      await tester.pumpAndSettle();
      expect(access.sessions.single.closed, isTrue);
      expect(find.byType(DeviceSyncPage), findsOneWidget);
      await endPage(tester);

      final failedAccess = PageAccess()..hostFailure = const DeviceSyncBusy();
      await openPage(tester, failedAccess);
      await createHost(tester);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceSyncPage), findsNothing);
    },
  );
  testWidgets('live pinning observation is progress rather than a Busy error', (
    tester,
  ) async {
    final session = _PinningObservationSession();
    final access = PageAccess()..sessionFactory = () => session;
    await openPage(tester, access);
    await createHost(tester);
    expect(find.text('Verifying library originals'), findsOneWidget);
    expect(find.byKey(const Key('device-page-error')), findsNothing);
    expect(find.byKey(const Key('device-configure')), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.byKey(const Key('device-page-error')), findsNothing);
    session.liveProgress = null;
    session.update(endpoint(driver.State.completed));
    await tester.pump();
    await endPage(tester);
  });
  testWidgets(
    'USB host waits for the scanned phone without a storage selection action',
    (tester) async {
      final access = PageAccess();
      await openPage(tester, access);
      await tester.tap(find.byKey(const Key('device-usb')));
      await tester.pump();
      await reveal(tester, find.byKey(const Key('device-create-code')));
      await tester.tap(find.byKey(const Key('device-create-code')));
      await tester.pump();
      expect(access.hosts.single.usb, isTrue);
      expect(find.byKey(const Key('device-find-usb')), findsNothing);
      expect(find.text('Find phone storage'), findsNothing);
      await endPage(tester);
    },
  );
  testWidgets('desktop uses selected private address and keeps a drag region', (
    tester,
  ) async {
    final access = PageAccess();
    await openPage(tester, access);
    expect(find.byType(DesktopWindowDragArea), findsOneWidget);
    expect(find.text('Connection method'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Connection method')).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('device-wifi'))).dy),
    );
    await tester.tap(find.byKey(const Key('device-load-addresses')));
    await tester.pumpAndSettle();
    await chooseAddress(tester, 1);
    await reveal(tester, find.byKey(const Key('device-create-code')));
    await tester.tap(find.byKey(const Key('device-create-code')));
    await tester.pump();
    expect(access.hosts.length, 1);
    expect(access.hosts.single.usb, isFalse);
    expect(access.hosts.single.address, '192.168.5.2');
    expect(access.sessions.single.confirmedLocally, isFalse);
    await endPage(tester);
  });

  testWidgets(
    'runtime readiness loss prevents opening and offers same recovery',
    (tester) async {
      final access = PageAccess();
      await openPage(tester, access);
      access.setReady(false);
      await tester.pump();
      expect(find.byKey(const Key('device-create-code')), findsNothing);
      expect(find.byKey(const Key('device-check-recovery')), findsOneWidget);
      expect(access.hosts, isEmpty);
      await tester.tap(find.byKey(const Key('device-check-recovery')));
      await tester.pump();
      expect(access.checks, 1);
      expect(find.byKey(const Key('device-load-addresses')), findsOneWidget);
      await endPage(tester);
    },
  );

  testWidgets('desktop new pairing never exposes phone-only account choices', (
    tester,
  ) async {
    final access = PageAccess()..hostConfigured = true;
    await openPage(tester, access);
    await createHost(tester);
    expect(find.byKey(const Key('device-include-accounts')), findsNothing);
    expect(find.byKey(const Key('device-configure')), findsNothing);
    access.sessions.single.update(
      endpoint(driver.State.completed, host: true, controller: false),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(find.byKey(const Key('device-new-pairing')));
    await tester.tap(find.byKey(const Key('device-new-pairing')));
    await tester.pump();
    await createHost(tester);
    expect(find.byKey(const Key('device-include-accounts')), findsNothing);
    expect(find.byKey(const Key('device-confirm-pair')), findsNothing);
    expect(access.sessions.first.closed, isTrue);
    expect(access.sessions.length, 2);
    await endPage(tester);
  });

  testWidgets('back waits a late opening and retires its endpoint', (
    tester,
  ) async {
    final opened = Completer<DeviceSyncSessionController>();
    final access = PageAccess()..opening = opened.future;
    await openPage(tester, access);
    await tester.tap(find.byKey(const Key('device-load-addresses')));
    await tester.pumpAndSettle();
    await chooseAddress(tester, 0);
    await reveal(tester, find.byKey(const Key('device-create-code')));
    await tester.tap(find.byKey(const Key('device-create-code')));
    await tester.pump();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-confirm-leave')));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceSyncPage), findsOneWidget);
    final late = PanelSession();
    opened.complete(late);
    await tester.pumpAndSettle();
    expect(late.closed, isTrue);
    expect(find.byType(DeviceSyncPage), findsNothing);
  });

  testWidgets('desktop network and backup controls fit large text and errors', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in [320.0, 360.0, 412.0]) {
      tester.view.physicalSize = Size(width, 820);
      tester.view.devicePixelRatio = 1;
      for (final language in ['zh', 'en']) {
        for (final brightness in Brightness.values) {
          final access = PageAccess()
            ..interfacePrefix = '合成网络 Synthetic long network interface ' * 4
            ..hostFailure = StateError('synthetic-error-not-for-display-' * 20);
          await tester.pumpWidget(
            pageApp(
              language: language,
              brightness: brightness,
              scale: 2,
              builder: (_) => DeviceSyncPage(access: access, mobile: false),
            ),
          );
          await tester.tap(find.byKey(const Key('open-page')));
          await tester.pumpAndSettle();
          await reveal(tester, find.byKey(const Key('device-load-addresses')));
          await tester.tap(find.byKey(const Key('device-load-addresses')));
          await tester.pumpAndSettle();
          await chooseAddress(tester, 0);
          await reveal(tester, find.byKey(const Key('device-create-code')));
          await tester.tap(find.byKey(const Key('device-create-code')));
          await tester.pumpAndSettle();
          await reveal(tester, find.byKey(const Key('device-page-error')));
          expect(
            find.textContaining('synthetic-error-not-for-display'),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.byTooltip(language == 'zh' ? '返回' : 'Back'));
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
  });

  testWidgets(
    'successful later observation dismisses only its earlier transient Busy',
    (tester) async {
      for (final failure in [
        const DeviceSyncBusy(),
        const DeviceSyncReadFailure(read.ReadError.unavailable),
        StateError('Synthetic observation failure'),
      ]) {
        final session = _RecoveringObservationSession(failure);
        final access = PageAccess()..sessionFactory = () => session;
        await openPage(tester, access);
        await createHost(tester);
        expect(find.byKey(const Key('device-page-error')), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(session.refreshes, greaterThanOrEqualTo(2));
        expect(find.text('Sync did not complete'), findsOneWidget);
        expect(
          find.byKey(const Key('device-page-error')),
          failure is DeviceSyncBusy ? findsNothing : findsOneWidget,
        );
        expect(find.byKey(const Key('device-session-error')), findsOneWidget);
        await endPage(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'unavailable projection cannot dismiss observation Busy before a valid read',
    (tester) async {
      final session = _RecoveringObservationSession(const DeviceSyncBusy())
        ..unavailableProjection = true;
      final access = PageAccess()..sessionFactory = () => session;
      await openPage(tester, access);
      await createHost(tester);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(session.refreshes, greaterThanOrEqualTo(2));
      expect(find.byKey(const Key('device-page-error')), findsOneWidget);
      session.unavailableProjection = false;
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.byKey(const Key('device-page-error')), findsNothing);
      expect(find.text('Sync did not complete'), findsOneWidget);
      await endPage(tester);
    },
  );

  testWidgets(
    'intervening observation Busy cannot replace a retained fatal read error',
    (tester) async {
      final session = _RecoveringObservationSession(
        const DeviceSyncReadFailure(read.ReadError.unavailable),
      )..busyOnSecondRead = true;
      final access = PageAccess()..sessionFactory = () => session;
      await openPage(tester, access);
      await createHost(tester);
      final original = tester
          .widget<Text>(find.byKey(const Key('device-page-error')))
          .data;
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(session.refreshes, 2);
      expect(
        tester.widget<Text>(find.byKey(const Key('device-page-error'))).data,
        original,
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(session.refreshes, 3);
      expect(
        tester.widget<Text>(find.byKey(const Key('device-page-error'))).data,
        original,
      );
      await endPage(tester);
    },
  );

  testWidgets(
    'terminal cleanup keeps observing until the original owner settles',
    (tester) async {
      final session = _CleanupSession();
      final access = PageAccess()..sessionFactory = () => session;
      await openPage(tester, access);
      await createHost(tester);
      expect(
        find.textContaining('safe cleanup or compensation'),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(session.refreshes, greaterThanOrEqualTo(2));
      expect(find.textContaining('safe cleanup or compensation'), findsNothing);
      expect(
        find.text('Result unconfirmed. Check the receiving device.'),
        findsOneWidget,
      );
      await endPage(tester);
    },
  );

  testWidgets(
    'settled close failure allows an explicit second back without releasing recovery',
    (tester) async {
      final finish = Completer<void>();
      final session = PanelSession()
        ..state = endpoint(driver.State.completed)
        ..closeWait = finish.future
        ..closeFailure = const DeviceSyncReadFailure(
          read.ReadError.permissionDenied,
        );
      final access = PageAccess()..sessionFactory = () => session;
      await openPage(tester, access);
      await createHost(tester);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      expect(session.closed, isTrue);
      expect(session.settled, isFalse);
      expect(find.byType(DeviceSyncPage), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      expect(find.byType(DeviceSyncPage), findsOneWidget);
      access.setReady(false);
      finish.complete();
      await tester.pumpAndSettle();
      expect(session.settled, isTrue);
      expect(find.byKey(const Key('device-page-error')), findsOneWidget);
      expect(access.ready, isFalse);
      expect(find.byType(DeviceSyncPage), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceSyncPage), findsNothing);
      expect(access.ready, isFalse);
    },
  );

  testWidgets('unsettled close failure cannot be bypassed by repeated back', (
    tester,
  ) async {
    final session = _UnsettledSession()
      ..state = endpoint(driver.State.completed)
      ..closeFailure = const DeviceSyncReadFailure(read.ReadError.unavailable);
    final access = PageAccess()..sessionFactory = () => session;
    await openPage(tester, access);
    await createHost(tester);
    access.setReady(false);
    for (var attempt = 0; attempt < 3; attempt++) {
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(session.closed, isTrue);
      expect(session.settled, isFalse);
      expect(find.byType(DeviceSyncPage), findsOneWidget);
      expect(find.byKey(const Key('device-page-error')), findsOneWidget);
      expect(access.ready, isFalse);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  // TextField adds its own horizontal Scrollable; scroll the page/dialog,
  // not the editing viewport. Diagnosis is retained in the finite run log.
  final vertical = find
      .byWidgetPredicate(
        (widget) =>
            widget is Scrollable &&
            axisDirectionToAxis(widget.axisDirection) == Axis.vertical,
      )
      .last;
  await tester.scrollUntilVisible(
    finder,
    180,
    scrollable: vertical,
    maxScrolls: 60,
  );
  await tester.pump();
}

Future<void> createHost(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('device-load-addresses')));
  await tester.pumpAndSettle();
  await chooseAddress(tester, 0);
  await reveal(tester, find.byKey(const Key('device-create-code')));
  await tester.tap(find.byKey(const Key('device-create-code')));
  await tester.pump();
}

Future<void> chooseAddress(WidgetTester tester, int index) async {
  final dropdown = find.byKey(const Key('device-address-dropdown'));
  await reveal(tester, dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byKey(Key('device-address-$index')).last,
      matching: find.byType(Text),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> endPage(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Back'));
  await tester.pumpAndSettle();
  if (find.byKey(const Key('device-confirm-leave')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const Key('device-confirm-leave')));
    await tester.pumpAndSettle();
  }
}

Future<void> openPage(WidgetTester tester, PageAccess access) async {
  await tester.pumpWidget(
    pageApp(
      builder: (context) => DeviceSyncPage(access: access, mobile: false),
    ),
  );
  await tester.tap(find.byKey(const Key('open-page')));
  await tester.pumpAndSettle();
}

Widget pageApp({
  required WidgetBuilder builder,
  String language = 'en',
  Brightness brightness = Brightness.light,
  double scale = 1,
}) => MaterialApp(
  locale: Locale(language),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: ThemeData(brightness: brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        key: const Key('open-page'),
        onPressed: () =>
            Navigator.of(context)
                .push<void>(MaterialPageRoute<void>(builder: builder)),
        child: const Text('Open'),
      ),
    ),
  ),
);

class PageAccess extends DeviceSyncPageAccess {
  bool available = true, hostConfigured = false;
  int checks = 0;
  final hosts = <({bool usb, String name, String? address})>[];
  final sessions = <PanelSession>[];
  Future<DeviceSyncSessionController>? opening;
  Object? hostFailure;
  String interfacePrefix = 'LAN';
  PanelSession Function()? sessionFactory;
  void setReady(bool value) {
    available = value;
    notifyListeners();
  }

  @override
  bool get ready => available;
  @override
  bool get checking => false;
  @override
  bool get canCheckRecovery => true;
  @override
  Future<void> checkRecovery() async {
    checks++;
    setReady(true);
  }

  @override
  Future<List<DeviceLanAddress>> wifiAddresses() async => [
    DeviceLanAddress(
      interfaceName: '$interfacePrefix A',
      address: '192.168.5.1',
    ),
    DeviceLanAddress(
      interfaceName: '$interfacePrefix B',
      address: '192.168.5.2',
    ),
  ];
  @override
  Future<DeviceWifiSnapshot> wifiInfo({bool requestPermission = false}) async =>
      const DeviceWifiSnapshot();
  @override
  Future<InvitationConnection> inspectInvitation(String invitation) async =>
      const InvitationConnection(usb: false);
  @override
  Future<DeviceSyncSessionController> host({
    required bool usb,
    required String name,
    String? address,
    String? wifiSsid,
  }) async {
    hosts.add((usb: usb, name: name, address: address));
    if (hostFailure case final failure?) throw failure;
    if (opening != null) return opening!;
    final session =
        sessionFactory?.call() ??
        (PanelSession()
          ..state = endpoint(
            driver.State.configuring,
            host: true,
            controller: false,
          ));
    if (hostConfigured) session.confirmed = true;
    sessions.add(session);
    return session;
  }

  @override
  Future<DeviceSyncSessionController> joinWifi({
    required String invitation,
    required String name,
  }) => throw UnimplementedError();
  @override
  DeviceUsbAttemptController prepareUsb({
    required String invitation,
    required String name,
  }) => throw UnimplementedError();
  @override
  DeviceBackupBrowserController openBackups() => throw UnimplementedError();
}

class _AutomaticPreviewSession extends PanelSession {
  _AutomaticPreviewSession({required bool source}) {
    state = endpoint(driver.State.awaitingApproval, source: source);
  }
  int previewReads = 0;
  @override
  Future<DeviceSyncPreviewView> refreshPreview() async {
    previewReads++;
    return super.refreshPreview();
  }
}

class _InvitationSession extends PanelSession {
  @override
  String? get invitation => 'synthetic-invitation-for-ui-only';
}

class _MixedLanAccess extends PageAccess {
  @override
  Future<List<DeviceLanAddress>> wifiAddresses() async => [
    const DeviceLanAddress(interfaceName: 'VPN', address: '10.0.0.2'),
    ...await super.wifiAddresses(),
  ];
}

class _CleanupSession extends PanelSession {
  _CleanupSession() {
    state = endpoint(
      driver.State.completedUnconfirmed,
      source: true,
      cleanupPending: true,
    );
  }
  int refreshes = 0;
  @override
  Future<read.EndpointRead> refresh() async {
    refreshes++;
    if (refreshes > 1) {
      state = endpoint(driver.State.completedUnconfirmed, source: true);
    }
    return state;
  }
}

class _PinningObservationSession extends PanelSession {
  _PinningObservationSession() {
    state = endpoint(driver.State.configuring, host: true, controller: false);
    liveProgress = read.ProgressView(
      workStage: WorkStage.pinning,
      workActive: true,
      scannedItems: BigInt.zero,
    );
  }
  @override
  Future<read.EndpointRead> refresh() async => throw const DeviceSyncBusy();
}

class _UnsettledSession extends PanelSession {
  @override
  bool get settled => false;
}

class _RecoveringObservationSession extends PanelSession {
  _RecoveringObservationSession(this.firstFailure);
  final Object firstFailure;
  bool unavailableProjection = false;
  bool busyOnSecondRead = false;
  int refreshes = 0;
  @override
  Future<read.EndpointRead> refresh() async {
    refreshes++;
    if (refreshes == 1) throw firstFailure;
    if (refreshes == 2 && busyOnSecondRead) throw const DeviceSyncBusy();
    if (unavailableProjection) {
      state = read.EndpointRead(
        progress: state.progress,
        error: read.ReadError.unavailable,
      );
      return state;
    }
    failure = read.ReadError.disconnected;
    state = endpoint(driver.State.failed, host: true, controller: false);
    return state;
  }
}
