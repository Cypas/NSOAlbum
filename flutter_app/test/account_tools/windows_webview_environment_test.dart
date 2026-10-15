import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
// Characterize the pinned platform implementation at its native boundary.
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/splatnet_windows_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const factoryChannel = MethodChannel(
    'com.pichillilorenzo/flutter_webview_environment',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late InAppWebViewPlatform? previousPlatform;
  final registeredChannels = <MethodChannel>[];
  final created = <String>[];
  final disposed = <String>[];

  setUp(() {
    previousPlatform = InAppWebViewPlatform.instance;
    WindowsInAppWebViewPlatform.registerWith();
    messenger.setMockMethodCallHandler(factoryChannel, (call) async {
      if (call.method != 'create') throw StateError('unexpected factory call');
      final id = (call.arguments as Map)['id'] as String;
      created.add(id);
      final nativeChannel = MethodChannel(
        'com.pichillilorenzo/flutter_webview_environment_$id',
      );
      registeredChannels.add(nativeChannel);
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        expect(call.method, 'dispose');
        disposed.add(id);
        return null;
      });
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(factoryChannel, null);
    for (final channel in registeredChannels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    registeredChannels.clear();
    created.clear();
    disposed.clear();
    if (previousPlatform != null) {
      InAppWebViewPlatform.instance = previousPlatform!;
    }
  });

  test(
    'dispose uses the created native environment ID before recreation',
    () async {
      for (var round = 0; round < 2; round++) {
        final environment = await SplatNetWindowsEnvironment.create();
        await environment.dispose().timeout(const Duration(seconds: 2));
        expect(disposed, created);
        final factoryId = PlatformWebViewEnvironment.static().id;
        // A native event on the dependency's incorrect Dart channel must no
        // longer reach the disposed environment's handler.
        final staleReply = await messenger.handlePlatformMessage(
          'com.pichillilorenzo/flutter_webview_environment_$factoryId',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('probeDisposedEnvironment'),
          ),
          null,
        );
        expect(staleReply, isNull);
      }
      expect(created.toSet(), hasLength(2));
    },
  );

  test(
    'native disposal failure remains failed and does not report cleanup',
    () async {
      final environment = await SplatNetWindowsEnvironment.create();
      final channel = registeredChannels.single;
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'native_dispose_failed');
      });
      await expectLater(
        environment.dispose(),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        environment.dispose(),
        throwsA(isA<PlatformException>()),
      );
      expect(disposed, isEmpty);
    },
  );

  testWidgets('environment disposal timeout remains fail-closed', (
    tester,
  ) async {
    final environment = await SplatNetWindowsEnvironment.create();
    messenger.setMockMethodCallHandler(registeredChannels.single, (call) {
      return Completer<void>().future;
    });
    final closing = environment.dispose();
    final failure = expectLater(closing, throwsA(isA<TimeoutException>()));
    await tester.pump(const Duration(seconds: 31));
    await failure;
    await expectLater(environment.dispose(), throwsA(isA<TimeoutException>()));
    expect(disposed, isEmpty);
  });
}
