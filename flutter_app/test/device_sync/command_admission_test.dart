import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/command_admission.dart';
import 'package:squid_album/src/rust/device_sync/read_model.dart';
import 'package:squid_album/src/rust/device_sync/runtime.dart';

void main() {
  test(
    'typed read Busy retries only the projection then returns real page',
    () async {
      var calls = 0;
      final result = await readDeviceProjection(
        () async {
          calls++;
          return calls < 3
              ? const BackupPageRead(error: ReadError.busy)
              : const BackupPageRead(
                  value: BackupPage(items: [], next: 'opaque-next-page'),
                );
        },
        errorOf: (value) => value.error,
        cancelled: () => false,
      );
      expect(calls, 3);
      expect(result.value?.next, 'opaque-next-page');
    },
  );

  test('projection Busy is finite and does not reinterpret genuine changed binding', () async {
    var calls = 0;
    await expectLater(
      readDeviceProjection(
        () async {
          calls++;
          return const PreviewRead(error: ReadError.busy);
        },
        errorOf: (value) => value.error,
        cancelled: () => false,
      ),
      throwsA(isA<DeviceCommandBusy>()),
    );
    expect(calls, 40);
    calls = 0;
    final changed = await readDeviceProjection(
      () async {
        calls++;
        return const PreviewRead(error: ReadError.previewChanged);
      },
      errorOf: (value) => value.error,
      cancelled: () => false,
    );
    expect(changed.error, ReadError.previewChanged);
    expect(calls, 1);
  });

  test(
    'projection cancellation prevents replay and discards late success',
    () async {
      var calls = 0;
      var cancelled = false;
      await expectLater(
        readDeviceProjection(
          () async {
            calls++;
            cancelled = true;
            return const PreviewRead(error: ReadError.busy);
          },
          errorOf: (value) => value.error,
          cancelled: () => cancelled,
        ),
        throwsA(isA<DeviceCommandBusy>()),
      );
      expect(calls, 1);
      cancelled = false;
      final started = Completer<void>();
      final release = Completer<BackupPageRead>();
      final observing = readDeviceProjection(
        () {
          calls++;
          started.complete();
          return release.future;
        },
        errorOf: (value) => value.error,
        cancelled: () => cancelled,
      );
      final rejected = expectLater(
        observing,
        throwsA(isA<DeviceCommandBusy>()),
      );
      await started.future;
      cancelled = true;
      release.complete(const BackupPageRead(value: BackupPage(items: [])));
      await rejected;
      expect(calls, 2);
    },
  );

  test(
    'only definitely unexecuted queue Busy can retry the same command',
    () async {
      var calls = 0;
      final result = await admittedDeviceCommand(() async {
        calls++;
        if (calls < 3) {
          throw const DeviceCommandError(code: ReadError.busy, executed: false);
        }
        return 17;
      });
      expect(result, 17);
      expect(calls, 3);
      for (final error in [
        const DeviceCommandError(code: ReadError.busy, executed: true),
        const DeviceCommandError(
          code: ReadError.permissionDenied,
          executed: false,
        ),
        StateError('not an admission error'),
      ]) {
        calls = 0;
        await expectLater(
          admittedDeviceCommand(() async {
            calls++;
            throw error;
          }),
          throwsA(same(error)),
        );
        expect(calls, 1);
      }
    },
  );

  test('admission has a finite retry budget and cancellation does not execute again', () async {
    var calls = 0;
    await expectLater(
      admittedDeviceCommand(() async {
        calls++;
        throw const DeviceCommandError(code: ReadError.busy, executed: false);
      }),
      throwsA(isA<DeviceSyncBusy>()),
    );
    expect(calls, 40);
    calls = 0;
    await expectLater(
      admittedDeviceCommand(() async {
        calls++;
        throw const DeviceCommandError(code: ReadError.busy, executed: false);
      }, cancelled: () => calls == 1),
      throwsA(isA<DeviceSyncBusy>()),
    );
    expect(calls, 1);
  });

  test('suspended switch resumes exact action without duplicate OS writes or permit steps', () async {
    for (final blocked in [0, 1, 2, 3, 4]) {
      final sequence = DeviceCommandSequence();
      final completed = <int>[];
      var reject = true;
      final actions = List<Future<void> Function()>.generate(
        5,
        (index) => () async {
          if (index == blocked && reject) {
            reject = false;
            throw const DeviceCommandBusy();
          }
          completed.add(index);
        },
      );
      await expectLater(
        sequence.run(actions),
        throwsA(isA<DeviceCommandBusy>()),
      );
      expect(completed, List.generate(blocked, (index) => index));
      await sequence.run(actions);
      expect(completed, [0, 1, 2, 3, 4]);
    }
    final sequence = DeviceCommandSequence();
    var calls = 0;
    final actions = [
      () async {
        calls++;
        throw const DeviceCommandBusy();
      },
    ];
    for (var attempt = 0; attempt < 4; attempt++) {
      await expectLater(
        sequence.run(actions),
        throwsA(isA<DeviceCommandBusy>()),
      );
    }
    expect(calls, 3, reason: 'the fourth resume cannot execute another action');
  });
}
