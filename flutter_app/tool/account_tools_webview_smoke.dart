// Standalone native lifecycle probe. Never initializes Rust, storage or accounts.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:squid_album/src/platform/splatnet_mac_network.dart';
import 'package:squid_album/src/platform/splatnet_windows_environment.dart';
import 'package:squid_album/src/ui/account_tools/native_webview_lifecycle.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
  runApp(const MaterialApp(home: _Probe()));
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  SplatNetWindowsEnvironment? environment;
  Directory? directory;
  NativeWebViewLifecycle nativeView = NativeWebViewLifecycle();
  Future<void>? closing;
  int round = 0;
  bool show = false;
  bool evaluating = false;
  bool failed = false;
  String result = 'Preparing native WebView';
  Timer? timeout;

  void phase(String value) {
    stdout.writeln('ACCOUNT_TOOLS_WEBVIEW_SMOKE round=$round $value');
    if (mounted) setState(() => result = value);
  }

  @override
  void initState() {
    super.initState();
    unawaited(startRound());
  }

  Future<void> startRound() async {
    try {
      round++;
      closing = null;
      evaluating = false;
      nativeView = NativeWebViewLifecycle();
      phase('initializing');
      timeout?.cancel();
      timeout = Timer(const Duration(seconds: 45), () {
        failed = true;
        phase('FAIL timeout');
      });
      if (Platform.isWindows) {
        final version = await WebViewEnvironment.getAvailableVersion();
        if (version == null) throw StateError('WebView2 unavailable');
        // The launcher selects the approved build-root TEMP. Do not create a
        // probe profile beside real application sessions or account caches.
        directory = await Directory.systemTemp.createTemp('splatnet-smoke-');
        environment = await SplatNetWindowsEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: directory!.path),
        );
      }
      if (Platform.isMacOS) await SplatNetMacNetwork.configure(null);
      if (!mounted || failed) return;
      phase('creating');
      setState(() => show = true);
      if (round == 2) {
        // Leave when the creation frame is submitted, even if onCreated is late.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!failed) unawaited(closeRound());
        });
      }
    } catch (error) {
      failed = true;
      phase('FAIL initializing ${error.runtimeType}');
    }
  }

  Future<void> loaded(
    NativeWebViewLifecycle owner,
    InAppWebViewController controller,
  ) async {
    if (!identical(owner, nativeView) ||
        round == 2 ||
        closing != null ||
        evaluating ||
        failed) {
      return;
    }
    evaluating = true;
    try {
      phase('evaluating');
      final value = await controller.evaluateJavascript(source: '21 * 2');
      if (value != 42) throw StateError('JavaScript evaluation failed');
      final callback = Completer<void>();
      final expectedRound = round;
      controller.addJavaScriptHandler(
        handlerName: 'lifecycleProbe',
        callback: (arguments) {
          if (arguments.length == 1 &&
              arguments.single == expectedRound &&
              !callback.isCompleted) {
            callback.complete();
          }
          return null;
        },
      );
      phase('callback');
      await controller.evaluateJavascript(
        source:
            '''
(function () {
  const invoke = function () {
    window.flutter_inappwebview.callHandler("lifecycleProbe", $expectedRound);
  };
  if (window.flutter_inappwebview) invoke();
  else window.addEventListener("flutterInAppWebViewPlatformReady", invoke, {once: true});
})();
''',
      );
      await callback.future.timeout(const Duration(seconds: 10));
      await closeRound();
    } catch (error) {
      failed = true;
      phase('FAIL evaluation ${error.runtimeType}');
    }
  }

  Future<void> closeRound() => closing ??= () async {
    try {
      phase(round == 2 ? 'closing-during-creation' : 'closing');
      await nativeView.close(() async {
        phase('detaching');
        if (mounted) setState(() => show = false);
        await WidgetsBinding.instance.endOfFrame;
      });
      phase('native-destroyed');
      if (environment != null) {
        phase('environment-disposal');
        await environment!.dispose().timeout(const Duration(seconds: 15));
        environment = null;
      }
      if (Platform.isMacOS) await SplatNetMacNetwork.clear();
      final created = directory;
      if (created != null) {
        phase('profile-cleanup');
        // Only this probe's createTemp directory, never a supplied path.
        for (var attempt = 0; attempt < 8; attempt++) {
          try {
            await created.delete(recursive: true);
            break;
          } on FileSystemException {
            if (attempt == 7) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
        directory = null;
      }
      timeout?.cancel();
      if (failed || !mounted) return;
      if (round < 3) {
        scheduleMicrotask(() => unawaited(startRound()));
      } else {
        phase('PASS');
        stdout.writeln(
          'ACCOUNT_TOOLS_WEBVIEW_SMOKE PASS '
          'create/evaluate/callback/destroy/environment/early-close/recreate',
        );
      }
    } catch (error) {
      failed = true;
      phase('FAIL cleanup ${error.runtimeType}');
    }
  }();

  @override
  void dispose() {
    timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final owner = nativeView;
    return Scaffold(
      appBar: AppBar(title: Text(result)),
      body: show && owner.beginCreation()
          ? InAppWebView(
              key: ValueKey(round),
              keepAlive: owner.keepAlive,
              webViewEnvironment: environment?.webViewEnvironment,
              initialSettings: InAppWebViewSettings(
                allowFileAccess: false,
                allowContentAccess: false,
                javaScriptCanOpenWindowsAutomatically: false,
                cacheEnabled: Platform.isMacOS,
                incognito: Platform.isWindows,
              ),
              onWebViewCreated: (controller) {
                final active = owner.created(
                  nativeViewId: controller.getViewId() as String?,
                );
                phase('created');
                if (active && identical(owner, nativeView) && !failed) {
                  // Windows can finish initialData before Dart registers events.
                  unawaited(
                    controller.loadData(
                      data: '<html><body>Native lifecycle probe</body></html>',
                    ),
                  );
                }
              },
              onLoadStop: (controller, _) => loaded(owner, controller),
            )
          : Center(child: Text(result)),
    );
  }
}
