import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';

void main() {
  test(
    'normal async lifetime makes device preparation Busy without waiting',
    () async {
      final gate = AccountWorkGate();
      final finishing = Completer<void>();
      final started = Completer<void>();
      final work = gate.normal(() async {
        started.complete();
        await finishing.future;
      });
      await started.future;
      expect(() => gate.device(), throwsA(isA<DeviceSyncBusy>()));
      finishing.complete();
      await work;
      final lease = gate.device();
      var changed = false;
      await expectLater(
        gate.normal(() async {
          changed = true;
        }),
        throwsA(isA<DeviceSyncBusy>()),
      );
      expect(changed, isFalse);
      lease.release();
      await gate.normal(() async {
        changed = true;
      });
      expect(changed, isTrue);
    },
  );
  test('normal nested asynchronous work shares its lifetime but not device permission', () async {
    final gate = AccountWorkGate();
    await gate.normal(() async {
      await gate.normal(() async {});
      expect(() => gate.device(), throwsA(isA<DeviceSyncBusy>()));
    });
    final device = gate.device();
    expect(() => gate.normalPermit(), throwsA(isA<DeviceSyncBusy>()));
    device.release();
    expect(gate.busy, isFalse);
  });
}
