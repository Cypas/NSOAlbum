// Explicit Debug real-library benchmark. Never seed, replace, or reconcile data.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:squid_album/main.dart' show DesktopWindowFrame;
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/backend/rust_backend.dart';
import 'package:squid_album/src/platform/device_sync_build.dart';
import 'package:squid_album/src/startup/application_bootstrap.dart';
import 'package:squid_album/src/startup/desktop_startup_close.dart';
import 'package:squid_album/src/startup/startup_options.dart';
import 'package:squid_album/src/ui/device_sync/startup_page.dart';

import 'device_sync_real_noop_controller.dart';
import 'device_sync_real_noop_peer.dart';

const _extension = 'ext.squid_album.realNoopBenchmark';

Future<void> main() async {
  if (!kDebugMode ||
      !const bool.fromEnvironment('DEVICE_SYNC_REAL_NOOP') ||
      !(Platform.isWindows || Platform.isAndroid)) {
    throw StateError('Explicit Windows/Android Debug benchmark required');
  }
  WidgetsFlutterBinding.ensureInitialized();
  final bootstrap = ApplicationBootstrap(
    safeMode: false,
    prepare: RustBackend.prepare,
    initializePresentation: (_) async {},
  );
  final desktopClose = await DesktopStartupClose.protect(
    bootstrap: bootstrap,
    options: const StartupOptions(),
    desktop: Platform.isWindows,
    onError: (_, _) {},
  );
  DeviceUsbConnectionAttempt? usbAttempt;
  DeviceSyncService service() =>
      (bootstrap.backend! as RustBackend).deviceSyncStartup.service;
  final controller = RealNoopController(
    enabled: true,
    mobile: Platform.isAndroid,
    ready: () => bootstrap.phase == BootstrapPhase.ready,
    host: (transport) async {
      if (!Platform.isWindows) throw StateError('Desktop host required');
      final build = await loadDeviceApplicationBuild();
      final DeviceSyncSession session;
      if (transport == 'usb') {
        session = await service().hostUsb(name: 'Desktop', appBuild: build);
      } else {
        final choices = await service().wifiAddresses();
        final address = selectRealNoopWifiAddress(
          choices,
          interfaceName: Platform.environment['NSOALBUM_REAL_NOOP_INTERFACE'],
        );
        session = await service().hostWifi(
          address: address.address,
          name: 'Desktop',
          appBuild: build,
        );
      }
      return (peer: _nativePeer(session), invitation: session.invitation!);
    },
    join: (transport, invitation) async {
      if (!Platform.isAndroid) throw StateError('Phone client required');
      if (transport == 'usb') {
        final attempt = service().prepareUsbClient(
          invitation: invitation,
          name: 'Phone',
        );
        usbAttempt = attempt;
        try {
          return _nativePeer(await attempt.connect());
        } finally {
          if (identical(usbAttempt, attempt)) usbAttempt = null;
        }
      }
      return _nativePeer(
        await service().joinWifi(invitation: invitation, name: 'Phone'),
      );
    },
    cancelJoin: () async {
      await usbAttempt?.cancel();
    },
    shutdown: () async {
      await bootstrap.close();
      Timer(const Duration(milliseconds: 300), () {
        if (Platform.isWindows) {
          unawaited(desktopClose!.closeApplication());
        } else {
          unawaited(SystemNavigator.pop());
        }
      });
    },
  );
  developer.registerExtension(
    _extension,
    (_, parameters) async => developer.ServiceExtensionResponse.result(
      jsonEncode(await handleRealNoopVmParameters(controller, parameters)),
    ),
  );
  runApp(
    DeviceSyncStartupApp(
      controller: bootstrap,
      theme: (_) => ThemeData(useMaterial3: true),
      frame: (child, title) => Platform.isWindows
          ? DesktopWindowFrame(title: title, child: child)
          : child,
      application: (_) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: _BenchmarkPage(controller: controller),
      ),
    ),
  );
}

NativeRealNoopPeer _nativePeer(DeviceSyncSession session) => NativeRealNoopPeer(
  session: session,
  requireNoop: session.benchmarkRequireNoop,
  readMetrics: session.benchmarkMetrics,
);

class _BenchmarkPage extends StatefulWidget {
  const _BenchmarkPage({required this.controller});
  final RealNoopController controller;
  @override
  State<_BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<_BenchmarkPage> {
  Timer? _timer;
  String _phase = 'ready';
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final status = await widget.controller.handle({'op': 'status'});
      if (mounted) {
        setState(() => _phase = status['stage'] as String? ?? 'ready');
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = Scaffold(
      appBar: AppBar(title: const Text('Debug · 真实图库无变化测速')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('只允许无变化融合；不传账号、不覆盖、不删除。'),
            const SizedBox(height: 16),
            Text(_phase),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => widget.controller.handle({'op': 'close'}),
              child: const Text('结束同步'),
            ),
          ],
        ),
      ),
    );
    return Platform.isWindows
        ? DesktopWindowFrame(title: 'NSOAlbum Debug benchmark', child: page)
        : page;
  }
}
