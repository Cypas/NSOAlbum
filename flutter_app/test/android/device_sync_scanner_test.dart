@Tags(['platform-android'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/ui/device_sync/scanner_page.dart';

import '../device_sync/device_sync_page_test.dart' show reveal;

void main() {
  testWidgets(
    'ML Kit notice precedes enable and browser failure does not block',
    (tester) async {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return false;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      for (final language in ['zh', 'en']) {
        var creations = 0;
        final camera = TestCamera();
        await tester.pumpWidget(
          scannerApp(() {
            creations++;
            return camera;
          }, language: language),
        );
        await tester.tap(find.byKey(const Key('open-scanner')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            language == 'zh' ? '安装标识' : 'installation identifiers',
          ),
          findsOneWidget,
        );
        expect(creations, 0);
        await reveal(tester, find.byKey(const Key('device-scanner-terms')));
        await tester.tap(find.byKey(const Key('device-scanner-terms')));
        await tester.pumpAndSettle();
        expect(calls.last.method, 'launch');
        final arguments = calls.last.arguments as Map;
        expect(arguments['url'], 'https://developers.google.com/ml-kit/terms');
        expect(arguments['useWebView'], isFalse);
        expect(creations, 0);
        await reveal(tester, find.byKey(const Key('device-enable-camera')));
        await tester.tap(find.byKey(const Key('device-enable-camera')));
        await tester.pumpAndSettle();
        expect(camera.starts, 1);
        await tester.tap(find.byKey(const Key('android-page-back')));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('camera needs explicit enable and denied access has a retry', (
    tester,
  ) async {
    final cameras = <TestCamera>[];
    await tester.pumpWidget(
      scannerApp(() {
        final camera = TestCamera()
          ..failure = DeviceCameraFailure.permissionDenied;
        cameras.add(camera);
        return camera;
      }),
    );
    await tester.tap(find.byKey(const Key('open-scanner')));
    await tester.pumpAndSettle();
    expect(cameras, isEmpty);
    await reveal(tester, find.byKey(const Key('device-enable-camera')));
    await tester.tap(find.byKey(const Key('device-enable-camera')));
    await tester.pumpAndSettle();
    expect(cameras.single.starts, 1);
    expect(cameras.single.disposed, isTrue);
    expect(find.textContaining('Camera access was denied'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('device-enable-camera')));
    await tester.tap(find.byKey(const Key('device-enable-camera')));
    await tester.pumpAndSettle();
    expect(cameras.length, 2);
  });

  testWidgets('background releases camera and resume needs another enable', (
    tester,
  ) async {
    final cameras = <TestCamera>[];
    await tester.pumpWidget(
      scannerApp(() {
        final camera = TestCamera();
        cameras.add(camera);
        return camera;
      }),
    );
    await tester.tap(find.byKey(const Key('open-scanner')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('device-enable-camera')));
    await tester.tap(find.byKey(const Key('device-enable-camera')));
    await tester.pumpAndSettle();
    final old = cameras.single;
    final lateCode = old.onCode!;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(old.stops, 1);
    expect(old.disposed, isTrue);
    lateCode('synthetic-late-invitation');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(cameras.length, 1);
    expect(find.byType(DeviceSyncScannerPage), findsOneWidget);
    await reveal(tester, find.byKey(const Key('device-enable-camera')));
    await tester.tap(find.byKey(const Key('device-enable-camera')));
    await tester.pumpAndSettle();
    expect(cameras.length, 2);
    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pumpAndSettle();
    expect(cameras.last.disposed, isTrue);
  });

  testWidgets('one scan is accepted only after owned camera settles', (
    tester,
  ) async {
    final stop = Completer<void>();
    final camera = TestCamera()..stopWait = stop.future;
    final results = <String?>[];
    await tester.pumpWidget(scannerApp(() => camera, onResult: results.add));
    await tester.tap(find.byKey(const Key('open-scanner')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('device-enable-camera')));
    await tester.tap(find.byKey(const Key('device-enable-camera')));
    await tester.pumpAndSettle();
    final deliver = camera.onCode!;
    deliver('synthetic-first-invitation');
    deliver('synthetic-second-invitation');
    await tester.pump();
    expect(results, isEmpty);
    stop.complete();
    await tester.pumpAndSettle();
    expect(results.length, 1);
    expect(results.single == 'synthetic-first-invitation', isTrue);
    expect(camera.disposed, isTrue);
    deliver('synthetic-late-invitation');
    await tester.pump();
    expect(results.length, 1);
  });

  testWidgets('late start after background is stopped again before disposal', (
    tester,
  ) async {
    final started = Completer<void>();
    final camera = TestCamera()..startWait = started.future;
    await tester.pumpWidget(scannerApp(() => camera));
    await tester.tap(find.byKey(const Key('open-scanner')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('device-enable-camera')));
    await tester.tap(find.byKey(const Key('device-enable-camera')));
    await tester.pump();
    await tester.pump();
    expect(camera.starts, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(camera.stops, 1);
    expect(camera.disposed, isFalse);
    started.complete();
    await tester.pumpAndSettle();
    expect(camera.stops, 2);
    expect(camera.running, isFalse);
    expect(camera.disposed, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pumpAndSettle();
  });
}

Widget scannerApp(
  DeviceQrCamera Function() factory, {
  ValueChanged<String?>? onResult,
  String language = 'en',
}) => MaterialApp(
  locale: Locale(language),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        key: const Key('open-scanner'),
        onPressed: () async {
          final result = await Navigator.of(context).push<String>(
            MaterialPageRoute(
              builder: (_) => DeviceSyncScannerPage(cameraFactory: factory),
            ),
          );
          onResult?.call(result);
        },
        child: const Text('Open'),
      ),
    ),
  ),
);

class TestCamera implements DeviceQrCamera {
  int starts = 0, stops = 0;
  bool disposed = false, running = false;
  DeviceCameraFailure? failure;
  Future<void>? stopWait, startWait;
  ValueChanged<String>? onCode;
  VoidCallback? onFailure;
  @override
  Future<void> start() async {
    starts++;
    await startWait;
    if (failure case final value?) throw value;
    running = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    running = false;
    await stopWait;
  }

  @override
  Future<void> dispose() async => disposed = true;
  @override
  Widget preview({
    required ValueChanged<String> onCode,
    required VoidCallback onFailure,
  }) {
    this.onCode = onCode;
    this.onFailure = onFailure;
    return const ColoredBox(color: Colors.black);
  }
}
