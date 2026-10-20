@Tags(['platform-android'])
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/device_sync_saf.dart';

import '../../tool/device_sync_saf_benchmark.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.cypas.nsoalbum/device_sync_saf');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'SAF benchmark limits queued blocks and observes their retirement',
    () async {
      final published = <String, Uint8List>{};
      var peak = 0;
      var closed = false;
      var writes = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        switch (call.method) {
          case 'openSession':
            return null;
          case 'writeCiphertextBlock':
            final name = args['name'] as String;
            final bytes = args['bytes'] as Uint8List;
            expect(bytes.length, 65536);
            expect(bytes.take(4), [0, 37, 74, 111]);
            expect(name, '${writes.toRadixString(16).padLeft(16, '0')}.block');
            published[name] = bytes;
            writes++;
            peak = peak < published.length ? published.length : peak;
            return null;
          case 'listBlocks':
            expect(args['direction'], 'mobile');
            // The real remote consumer, not a local write, retires the prefix.
            if (published.length >= 4 || writes == 9) published.clear();
            return published.keys.toList();
          case 'close':
            closed = true;
            return null;
        }
        throw StateError('Unexpected probe call ${call.method}');
      });
      final benchmark = SafTransferBenchmark(DeviceSyncSaf());
      final result = await benchmark.send(blockCount: 9);
      expect(result.verifiedBytes, 9 * 65536);
      expect(writes, 9);
      expect(peak, lessThanOrEqualTo(4));
      expect(published, isEmpty);
      expect(closed, isTrue);
    },
  );

  test(
    'SAF receive rejects corruption without acknowledging the block',
    () async {
      final acknowledged = <String>[];
      var cancelled = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'openSession':
            return null;
          case 'listBlocks':
            return ['0000000000000000.block'];
          case 'readBlock':
            return Uint8List(65536);
          case 'acknowledgeBlock':
            acknowledged.add('unexpected');
            return null;
          case 'cancel':
            cancelled = true;
            return null;
        }
        throw StateError('Unexpected probe call ${call.method}');
      });
      final benchmark = SafTransferBenchmark(DeviceSyncSaf());
      await expectLater(benchmark.receive(blockCount: 1), throwsStateError);
      expect(acknowledged, isEmpty);
      expect(cancelled, isTrue);
    },
  );

  test(
    'SAF receive validates all bytes before acknowledging in sequence',
    () async {
      var next = 0;
      final acknowledged = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'openSession':
          case 'close':
            return null;
          case 'listBlocks':
            return ['${next.toRadixString(16).padLeft(16, '0')}.block'];
          case 'readBlock':
            return Uint8List.fromList(
              List.generate(65536, (i) => (i * 37) & 255),
            );
          case 'acknowledgeBlock':
            acknowledged.add((call.arguments as Map)['name'] as String);
            next++;
            return null;
        }
        throw StateError('Unexpected probe call ${call.method}');
      });
      final result = await SafTransferBenchmark(DeviceSyncSaf())
          .receive(blockCount: 2);
      expect(result.verifiedBytes, 131072);
      expect(acknowledged, [
        '0000000000000000.block',
        '0000000000000001.block',
      ]);
    },
  );

  test('invalid benchmark volume never opens a native session', () async {
    var opened = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      opened = true;
      return null;
    });
    final benchmark = SafTransferBenchmark(DeviceSyncSaf());
    await expectLater(benchmark.send(blockCount: 0), throwsArgumentError);
    await expectLater(benchmark.receive(blockCount: 1025), throwsArgumentError);
    expect(opened, isFalse);
  });

  test(
    'cancellation stops a pending probe without deleting published blocks',
    () async {
      final started = Completer<void>();
      final released = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'writeCiphertextBlock') {
          started.complete();
          await released.future;
        }
        return null;
      });
      final benchmark = SafTransferBenchmark(DeviceSyncSaf());
      final running = benchmark.send(blockCount: 2);
      final stopped = expectLater(running, throwsStateError);
      await started.future;
      await expectLater(benchmark.receive(blockCount: 1), throwsStateError);
      await benchmark.cancel();
      released.complete();
      await stopped;
      expect(
        calls.where((call) => call == 'writeCiphertextBlock'),
        hasLength(1),
      );
      expect(calls, contains('cancel'));
      expect(calls, isNot(contains('acknowledgeBlock')));
      expect(calls, isNot(contains('close')));
    },
  );
}
