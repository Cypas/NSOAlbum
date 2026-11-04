import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/account_tools/splatnet_request_gate.dart';

void main() {
  test(
    'a second refresh cannot replace an in-flight session request',
    () async {
      final gate = SplatNetRequestGate();
      final response = Completer<void>();
      var calls = 0;
      final first = gate.run(() async {
        calls++;
        await response.future;
      });
      await gate.run(() async => calls++);
      expect(calls, 1);
      expect(gate.busy, isTrue);
      response.complete();
      await first;
      expect(gate.busy, isFalse);
      await gate.run(() async => calls++);
      expect(calls, 2);
    },
  );

  test('failed session requests release the busy guard', () async {
    final gate = SplatNetRequestGate();
    await expectLater(
      gate.run(() async => throw StateError('network')),
      throwsStateError,
    );
    var refreshed = false;
    await gate.run(() async => refreshed = true);
    expect(refreshed, isTrue);
  });
}
