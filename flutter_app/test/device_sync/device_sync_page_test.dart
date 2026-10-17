import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/platform/device_sync_network.dart';
import 'package:squid_album/src/rust/device_sync/connection.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/ui/desktop_window_drag_area.dart';
import 'package:squid_album/src/ui/device_sync/device_sync_page.dart';
import 'package:squid_album/src/ui/device_sync/page_access.dart';

import 'session_panel_test.dart' show PanelSession, endpoint;

void main() {
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
    await tester.tap(find.byKey(const Key('device-address-1')));
    await tester.pump();
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
    await tester.tap(find.byKey(const Key('device-address-0')));
    await tester.pump();
    await reveal(tester, find.byKey(const Key('device-create-code')));
    await tester.tap(find.byKey(const Key('device-create-code')));
    await tester.pump();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-confirm-leave')));
    await tester.pump();
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
          await reveal(tester, find.byKey(const Key('device-address-0')));
          await tester.tap(find.byKey(const Key('device-address-0')));
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
  await tester.tap(find.byKey(const Key('device-address-0')));
  await tester.pump();
  await reveal(tester, find.byKey(const Key('device-create-code')));
  await tester.tap(find.byKey(const Key('device-create-code')));
  await tester.pump();
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

class _UnsettledSession extends PanelSession {
  @override
  bool get settled => false;
}
