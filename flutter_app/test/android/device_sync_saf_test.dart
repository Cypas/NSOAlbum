@Tags(['platform-android'])
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/device_sync_saf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('device-sync-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'one pending provider read rejects another byte action before dispatch',
    () async {
      final delayed = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readBlock') return delayed.future;
        if (call.method == 'listBlocks') return <String>[];
        return null;
      });
      final saf = DeviceSyncSaf(channel: channel);
      await saf.openSession('a' * 32, 'b' * 32);
      final read = saf.readBlock('desktop', '0000000000000000.block');
      try {
        await expectLater(saf.listBlocks('desktop'), throwsStateError);
      } finally {
        delayed.complete(Uint8List.fromList([1, 2, 3]));
        await read;
        await saf.cancel();
      }
    },
  );

  test(
    'successful close retires once and does not turn into cancellation',
    () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return null;
      });
      final saf = DeviceSyncSaf(channel: channel);
      await saf.openSession('a' * 32, 'b' * 32);
      await saf.close();
      await saf.close();
      await saf.cancel();
      expect(methods, ['openSession', 'close']);
    },
  );

  test(
    'typed window rejection keeps the same SAF operation readable',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'writeCiphertextBlock') {
          throw PlatformException(
            code: 'WINDOW_FULL',
            message: 'private-provider-message',
          );
        }
        if (call.method == 'listBlocks') return <String>[];
        return null;
      });
      final saf = DeviceSyncSaf(channel: channel);
      await saf.openSession('a' * 32, 'b' * 32);
      await expectLater(
        saf.writeCiphertextBlock(
          '0000000000000000.block',
          Uint8List.fromList([1]),
        ),
        throwsA(
          isA<DeviceSyncSafFailure>().having(
            (e) => e.code,
            'code',
            DeviceSyncSafError.windowFull,
          ),
        ),
      );
      expect(await saf.listBlocks('desktop'), isEmpty);
      await saf.cancel();
    },
  );

  test(
    'failed second owner cleanup must not cancel the first active operation',
    () async {
      var active = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'openSession') {
          if (active) throw PlatformException(code: 'BUSY');
          active = true;
        } else if (call.method == 'cancel' || call.method == 'close') {
          active = false;
        } else if (call.method == 'listBlocks') {
          if (!active) throw PlatformException(code: 'OPERATION_CLOSED');
          return <String>[];
        }
        return null;
      });
      final first = DeviceSyncSaf(channel: channel);
      final second = DeviceSyncSaf(channel: channel);
      await first.openSession('a' * 32, 'b' * 32);
      await expectLater(
        second.openSession('c' * 32, 'd' * 32),
        throwsA(
          isA<DeviceSyncSafFailure>().having(
            (failure) => failure.code,
            'code',
            DeviceSyncSafError.busy,
          ),
        ),
      );
      // Models owner B's actual failure watcher cleanup.
      await second.cancel();
      expect(await first.listBlocks('desktop'), isEmpty);
      await first.cancel();
    },
  );

  test('cancellation rejects an old completed native response', () async {
    final delayed = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readBlock') return delayed.future;
      return null;
    });
    final saf = DeviceSyncSaf(channel: channel);
    await saf.openSession('a' * 32, 'b' * 32);
    final read = saf.readBlock('desktop', '0000000000000000.block');
    final rejected = expectLater(read, throwsStateError);
    await saf.cancel();
    delayed.complete(Uint8List.fromList([1, 2, 3]));
    await rejected;
    await expectLater(saf.listBlocks('desktop'), throwsStateError);
  });

  test(
    'pending open cancellation carries only its captured owner scope',
    () async {
      final delayed = Completer<Object?>();
      final scopes = <Map<Object?, Object?>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        scopes.add(call.arguments as Map<Object?, Object?>);
        if (call.method == 'openSession') return delayed.future;
        return null;
      });
      final saf = DeviceSyncSaf(channel: channel);
      final opening = saf.openSession('a' * 32, 'b' * 32);
      final rejected = expectLater(opening, throwsStateError);
      await saf.cancel();
      delayed.complete(null);
      await rejected;
      expect(scopes, hasLength(2));
      expect(scopes[1], scopes[0]);
      expect(scopes[0]['ownerToken'], matches(RegExp(r'^[0-9a-f]{32}$')));
    },
  );

  test('reusing protocol IDs creates a fresh cleanup capability', () async {
    final scopes = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      scopes.add(call.arguments as Map<Object?, Object?>);
      return null;
    });
    final saf = DeviceSyncSaf(channel: channel);
    await saf.openSession('a' * 32, 'b' * 32);
    await saf.close();
    await saf.openSession('a' * 32, 'b' * 32);
    await saf.cancel();
    expect(scopes[1], scopes[0]);
    expect(scopes[3], scopes[2]);
    expect(scopes[2]['ownerToken'], isNot(scopes[0]['ownerToken']));
  });

  test('only the selecting instance can cancel its pending picker', () async {
    final selected = Completer<Object?>();
    final methods = <String>[];
    Map<Object?, Object?>? pickerScope;
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'selectTree') {
        pickerScope = call.arguments as Map<Object?, Object?>;
        return selected.future;
      }
      expect(call.arguments, pickerScope);
      selected.completeError(PlatformException(code: 'OPERATION_CLOSED'));
      return null;
    });
    final selecting = DeviceSyncSaf(channel: channel);
    final other = DeviceSyncSaf(channel: channel);
    final selection = selecting.selectTree();
    final rejected = expectLater(selection, throwsStateError);
    await other.cancel();
    expect(methods, ['selectTree']);
    await selecting.cancel();
    await rejected;
    expect(methods, ['selectTree', 'cancel']);
    expect(pickerScope!.keys, ['pickerToken']);
  });

  test('native calls carry current scope and exact bytes without backend initialization', () async {
    Map<Object?, Object?>? write;
    Map<Object?, Object?>? opened;
    Map<Object?, Object?>? closed;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openSession') {
        opened = call.arguments as Map<Object?, Object?>;
      }
      if (call.method == 'cancel') {
        closed = call.arguments as Map<Object?, Object?>;
      }
      if (call.method == 'writeCiphertextBlock') {
        write = call.arguments as Map<Object?, Object?>;
      }
      if (call.method == 'listBlocks') return ['0000000000000000.block'];
      return null;
    });
    final saf = DeviceSyncSaf(channel: channel);
    await saf.openSession('a' * 32, 'b' * 32);
    await saf.writeCiphertextBlock(
      '0000000000000000.block',
      Uint8List.fromList([7, 8, 9]),
    );
    expect(write, {
      'operationId': 'a' * 32,
      'sessionId': 'b' * 32,
      'ownerToken': opened!['ownerToken'],
      'name': '0000000000000000.block',
      'bytes': Uint8List.fromList([7, 8, 9]),
    });
    expect(await saf.listBlocks('mobile'), ['0000000000000000.block']);
    await saf.cancel();
    expect(closed, opened);
    expect(opened!['ownerToken'], matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('invalid operation cannot invoke native I/O', () async {
    var nativeCalls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      nativeCalls++;
      return null;
    });
    final saf = DeviceSyncSaf(channel: channel);
    await expectLater(saf.openSession('../', 'b' * 32), throwsArgumentError);
    expect(nativeCalls, 0);
  });
}
