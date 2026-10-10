@Tags(['platform-windows'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/windows_ime_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(WindowsImeContextCoordinator.instance.resetForTesting);

  group('[Windows] IME context', () {
    testWidgets('reports editable text client focus without sending text', (
      tester,
    ) async {
      WindowsImeContextCoordinator.instance.resetForTesting();
      const channel = MethodChannel('io.squidalbum/ime_context');
      final states = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'setTextClientActive');
            expect(call.arguments, isA<bool>());
            states.add(call.arguments as bool);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      WindowsImeContextCoordinator.instance.start();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: TextField(key: Key('editor'))),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('editor')));
      await tester.pump();

      expect(states, contains(true));

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      expect(states.last, isFalse);
    });

    testWidgets('refreshes the IME context when switching editable fields', (
      tester,
    ) async {
      WindowsImeContextCoordinator.instance.resetForTesting();
      const channel = MethodChannel('io.squidalbum/ime_context');
      final states = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            states.add(call.arguments as bool);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      WindowsImeContextCoordinator.instance.start();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextField(key: Key('first-editor')),
                TextField(key: Key('second-editor')),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('first-editor')));
      await tester.pumpAndSettle();
      final firstTrueCount = states.where((value) => value).length;
      await tester.tap(find.byKey(const Key('second-editor')));
      await tester.pumpAndSettle();
      final secondTrueCount = states.where((value) => value).length;

      expect(firstTrueCount, greaterThanOrEqualTo(1));
      expect(secondTrueCount, greaterThan(firstTrueCount));
    });
  }, skip: Platform.isWindows ? false : 'Requires Windows IME context bridge');
}
