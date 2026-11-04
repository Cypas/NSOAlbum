import 'dart:async';

import 'package:flutter/services.dart';
// Exercise the pinned native implementation rather than a fake controller.
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/account_tools/native_webview_lifecycle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_manager',
  );
  const androidChannel = MethodChannel(
    'io.github.cypas.nsoalbum/splatnet_webview',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(WindowsInAppWebViewPlatform.registerWith);
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(androidChannel, null);
  });

  test('late creation is awaited before detach and native disposal', () async {
    final lifecycle = NativeWebViewLifecycle();
    final nativeDisposal = Completer<void>();
    final events = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'disposeKeepAlive');
      expect(
        (call.arguments as Map)['keepAliveId'],
        isA<String>().having(
          (id) => id.isNotEmpty,
          'nonempty native keepAlive ID',
          isTrue,
        ),
      );
      events.add('dispose');
      await nativeDisposal.future;
      events.add('disposed');
      return null;
    });
    expect(lifecycle.beginCreation(), isTrue);
    final closing = lifecycle.close(() async => events.add('detach'));
    var finished = false;
    unawaited(closing.then((_) => finished = true));
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    expect(
      lifecycle.beginCreation(),
      isTrue,
      reason: 'keep the existing pending widget mounted during shutdown',
    );
    expect(lifecycle.created(), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['detach', 'dispose']);
    expect(finished, isFalse);
    nativeDisposal.complete();
    await closing;
    await lifecycle.close(() async => events.add('duplicate detach'));
    expect(events, ['detach', 'dispose', 'disposed']);
    expect(lifecycle.created(), isFalse);
  });

  test('closing before a native build prevents later creation', () async {
    final lifecycle = NativeWebViewLifecycle();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    await lifecycle.close(() async {});
    expect(lifecycle.beginCreation(), isFalse);
    expect(calls, isEmpty);
  });

  test('native disposal error is retained for every later close', () async {
    final lifecycle = NativeWebViewLifecycle();
    var attempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      attempts++;
      throw PlatformException(code: 'dispose_failed');
    });
    lifecycle.beginCreation();
    expect(lifecycle.created(), isTrue);
    await expectLater(
      lifecycle.close(() async {}),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(
      lifecycle.close(() async {}),
      throwsA(isA<PlatformException>()),
    );
    expect(attempts, 1);
  });

  testWidgets(
    'creation timeout preserves failure and never detaches or clears',
    (tester) async {
      final lifecycle = NativeWebViewLifecycle();
      var detached = false;
      lifecycle.beginCreation();
      final closing = lifecycle.close(() async => detached = true);
      final failure = expectLater(closing, throwsA(isA<TimeoutException>()));
      await tester.pump(const Duration(seconds: 31));
      await failure;
      await expectLater(
        lifecycle.close(() async => detached = true),
        throwsA(isA<TimeoutException>()),
      );
      expect(detached, isFalse);
      expect(lifecycle.created(), isFalse);
    },
  );

  test(
    'Android waits for owned native destruction before plugin cleanup',
    () async {
      final lifecycle = NativeWebViewLifecycle(platform: 'android');
      final destroyed = Completer<void>();
      final events = <String>[];
      messenger.setMockMethodCallHandler(androidChannel, (call) async {
        expect(call.method, 'destroyKeepAlive');
        expect(call.arguments, {'keepAliveId': 'owned-view'});
        events.add('destroy');
        await destroyed.future;
        events.add('destroyed');
        return null;
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'disposeKeepAlive');
        events.add('plugin-cleanup');
        return null;
      });
      lifecycle.beginCreation();
      lifecycle.created(nativeViewId: 'owned-view');
      final closing = lifecycle.close(() async => events.add('detach'));
      await Future<void>.delayed(Duration.zero);
      expect(events, ['detach', 'destroy']);
      destroyed.complete();
      await closing;
      expect(events, ['detach', 'destroy', 'destroyed', 'plugin-cleanup']);
    },
  );

  test('Android destruction failure cannot reach later data cleanup', () async {
    final lifecycle = NativeWebViewLifecycle(platform: 'android');
    var cleared = false;
    messenger.setMockMethodCallHandler(androidChannel, (call) async {
      throw PlatformException(code: 'SPLATNET_DISPOSE_FAILED');
    });
    lifecycle.beginCreation();
    lifecycle.created(nativeViewId: 'owned-view');
    Future<void> release() async {
      await lifecycle.close(() async {});
      cleared = true;
    }

    await expectLater(release(), throwsA(isA<PlatformException>()));
    await expectLater(release(), throwsA(isA<PlatformException>()));
    expect(cleared, isFalse);
  });
}
