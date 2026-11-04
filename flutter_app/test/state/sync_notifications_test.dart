import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/sync_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.cypas.nsoalbum/notifications');
  const windowsChannel = MethodChannel('win_toast');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(windowsChannel, null);
  });

  for (final platform in ['android', 'macos']) {
    test(
      '$platform receives localized safe counts without account details',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
        final notifications = SyncNotifications(platform: platform);

        await notifications.show(
          language: 'en',
          downloaded: 5,
          existing: 6,
          failed: 3,
          accountCount: 2,
        );

        expect(calls.length, 1);
        expect(calls.single.method, 'syncCompleted');
        expect(calls.single.arguments, {
          'downloaded': 5,
          'existing': 6,
          'failed': 3,
          'accounts': 2,
          'title': 'NSOAlbum · Automatic sync complete',
          'body': 'Added 5 · Existing 6 · Failed 3 · 2 accounts',
        });
      },
    );
  }

  test(
    'no additions never initializes or requests notification permission',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(windowsChannel, (call) async {
        calls.add(call);
        return null;
      });
      for (final platform in ['android', 'windows', 'macos']) {
        await SyncNotifications(platform: platform).show(
          language: 'zh',
          downloaded: 0,
          existing: 2,
          failed: 1,
          accountCount: 1,
        );
      }
      expect(calls, isEmpty);
    },
  );

  test(
    'Windows submits notifications on the runner channel without plugin events',
    () async {
      final pluginCalls = <String>[];
      final nativeCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(windowsChannel, (call) async {
        pluginCalls.add(call.method);
        return null;
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call);
        return null;
      });

      await SyncNotifications(platform: 'windows').show(
        language: 'en',
        downloaded: 2,
        existing: 5,
        failed: 1,
        accountCount: 2,
      );

      expect(pluginCalls, isEmpty);
      expect(nativeCalls, hasLength(1));
      expect(nativeCalls.single.method, 'syncCompleted');
      expect(nativeCalls.single.arguments, {
        'downloaded': 2,
        'existing': 5,
        'failed': 1,
        'accounts': 2,
        'title': 'NSOAlbum · Automatic sync complete',
        'body': 'Added 2 · Existing 5 · Failed 1 · 2 accounts',
      });
    },
  );

  test(
    'Windows submits each completed round once while a prior reply is pending',
    () async {
      final firstReply = Completer<void>();
      final started = Completer<void>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (calls.length == 1) {
          started.complete();
          await firstReply.future;
        }
        return null;
      });
      final notifications = SyncNotifications(platform: 'windows');
      Future<void> show() => notifications.show(
        language: 'en',
        downloaded: 5,
        existing: 6,
        failed: 3,
        accountCount: 2,
      );
      final first = show();
      await started.future;
      final second = show();
      firstReply.complete();
      await Future.wait([first, second]);

      expect(calls.map((call) => call.method), [
        'syncCompleted',
        'syncCompleted',
      ]);
      for (final call in calls) {
        final args = call.arguments as Map;
        expect(args['title'], 'NSOAlbum · Automatic sync complete');
        expect(args['body'], 'Added 5 · Existing 6 · Failed 3 · 2 accounts');
      }
    },
  );

  test(
    'a native Windows failure does not suppress a later completion',
    () async {
      var attempts = 0;
      var shown = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'syncCompleted') {
          attempts++;
          if (attempts == 1) throw PlatformException(code: 'synthetic-failure');
          shown++;
        }
        return null;
      });
      final notifications = SyncNotifications(platform: 'windows');
      Future<void> show() => notifications.show(
        language: 'zh',
        downloaded: 1,
        existing: 0,
        failed: 0,
        accountCount: 1,
      );

      await expectLater(show(), throwsA(isA<PlatformException>()));
      await show();
      expect(attempts, 2);
      expect(shown, 1);
    },
  );
}
