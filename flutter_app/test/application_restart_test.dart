import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/application_restart.dart';

void main() {
  test('starts replacement process before exiting current process', () async {
    final calls = <String>[];

    await restartApplication(
      startNewInstance: () async => calls.add('start'),
      quitCurrentInstance: () async => calls.add('quit'),
    );

    expect(calls, ['start', 'quit']);
  });

  test(
    'keeps current process running when replacement process fails',
    () async {
      var quitCalled = false;

      await expectLater(
        restartApplication(
          startNewInstance: () async => throw StateError('start failed'),
          quitCurrentInstance: () async => quitCalled = true,
        ),
        throwsA(isA<StateError>()),
      );

      expect(quitCalled, isFalse);
    },
  );
}
