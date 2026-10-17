import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/device_sync/debug_pairing.dart';

Future<ServiceExtensionResponse> request(
  DeviceSyncPairingDebug bridge,
  String action, {
  int? generation,
  String? invitation,
}) => bridge.handle(DeviceSyncPairingDebug.extensionName, {
  'action': action,
  if (generation != null) 'generation': '$generation',
  'invitation': ?invitation,
});

Map<String, dynamic> result(ServiceExtensionResponse response) {
  expect(response.isError(), isFalse, reason: response.errorDetail);
  return jsonDecode(response.result!) as Map<String, dynamic>;
}

String reason(ServiceExtensionResponse response) {
  expect(response.isError(), isTrue);
  return (jsonDecode(response.errorDetail!) as Map<String, dynamic>)['reason']
      as String;
}

void main() {
  test('disabled bridge never exposes or accepts an invitation', () async {
    final bridge = DeviceSyncPairingDebug(enabled: false);
    bridge.bind(
      mobile: true,
      active: () => true,
      transport: () => 'wifi',
      canInject: () => true,
      readInvitation: () => 'sensitive-synthetic-invitation',
      inject: (_) async => fail('Disabled input must not reach the page'),
    );
    expect(reason(await request(bridge, 'status')), 'disabled');
    expect(reason(await request(bridge, 'read', generation: 1)), 'disabled');
    expect(
      reason(
        await request(bridge, 'inject', generation: 1, invitation: 'secret'),
      ),
      'disabled',
    );
  });

  test('only the current active page generation can receive input', () async {
    final bridge = DeviceSyncPairingDebug();
    var active = true;
    final accepted = <String>[];
    final first = bridge.bind(
      mobile: true,
      active: () => active,
      transport: () => 'usb',
      canInject: () => true,
      readInvitation: () => null,
      inject: (value) async => accepted.add(value),
    );
    final firstGeneration =
        result(await request(bridge, 'status'))['generation'] as int;
    active = false;
    expect(reason(await request(bridge, 'status')), 'unavailable');
    active = true;
    final second = bridge.bind(
      mobile: true,
      active: () => true,
      transport: () => 'wifi',
      canInject: () => true,
      readInvitation: () => null,
      inject: (value) async => accepted.add('new:$value'),
    );
    first.dispose();
    final secondGeneration =
        result(await request(bridge, 'status'))['generation'] as int;
    expect(secondGeneration, greaterThan(firstGeneration));
    expect(
      reason(
        await request(
          bridge,
          'inject',
          generation: firstGeneration,
          invitation: 'old',
        ),
      ),
      'stale_page',
    );
    expect(
      result(
        await request(
          bridge,
          'inject',
          generation: secondGeneration,
          invitation: 'new',
        ),
      ),
      {'accepted': true, 'generation': secondGeneration},
    );
    expect(accepted, ['new:new']);
    second.dispose();
    expect(reason(await request(bridge, 'status')), 'unavailable');
  });

  test(
    'empty oversized and multibyte oversized input never reaches the page',
    () async {
      final bridge = DeviceSyncPairingDebug();
      final lease = bridge.bind(
        mobile: true,
        active: () => true,
        transport: () => 'wifi',
        canInject: () => true,
        readInvitation: () => null,
        inject: (_) async => fail('Invalid input reached the connection path'),
      );
      final generation =
          result(await request(bridge, 'status'))['generation'] as int;
      for (final input in [null, '', 'x' * 8193, '图' * 3000]) {
        final response = await request(
          bridge,
          'inject',
          generation: generation,
          invitation: input,
        );
        expect(reason(response), 'invalid_input');
        expect(response.errorDetail, isNot(contains('图')));
      }
      lease.dispose();
    },
  );

  test(
    'single in-flight request is bounded and errors never echo its contents',
    () async {
      final bridge = DeviceSyncPairingDebug();
      final finish = Completer<void>();
      final lease = bridge.bind(
        mobile: true,
        active: () => true,
        transport: () => 'wifi',
        canInject: () => true,
        readInvitation: () => null,
        inject: (_) => finish.future,
      );
      final generation =
          result(await request(bridge, 'status'))['generation'] as int;
      final first = request(
        bridge,
        'inject',
        generation: generation,
        invitation: 'secret-one',
      );
      final blocked = await request(
        bridge,
        'inject',
        generation: generation,
        invitation: 'secret-two',
      );
      expect(reason(blocked), 'busy');
      finish.completeError(StateError('secret-one'));
      final failed = await first;
      expect(reason(failed), 'operation_failed');
      expect(failed.errorDetail, isNot(contains('secret-one')));
      lease.dispose();
    },
  );

  test(
    'desktop reads a live invitation but cannot inject or authorize transfer',
    () async {
      final bridge = DeviceSyncPairingDebug();
      String? invitation = 'one-use-synthetic-invitation';
      final lease = bridge.bind(
        mobile: false,
        active: () => true,
        transport: () => 'usb',
        canInject: () => false,
        readInvitation: () => invitation,
        inject: (_) async => fail('Desktop must not accept scanned input'),
      );
      final status = result(await request(bridge, 'status'));
      final generation = status['generation'] as int;
      expect(status['transport'], 'usb');
      expect(status.toString(), isNot(contains('one-use-synthetic')));
      expect(
        result(
          await request(bridge, 'read', generation: generation),
        )['invitation'],
        invitation,
      );
      expect(
        reason(
          await request(
            bridge,
            'inject',
            generation: generation,
            invitation: 'secret',
          ),
        ),
        'unavailable',
      );
      for (final action in [
        'confirm',
        'configure',
        'approve',
        'consentAccounts',
      ]) {
        expect(reason(await request(bridge, action)), 'invalid_action');
      }
      invitation = null;
      expect(
        reason(await request(bridge, 'read', generation: generation)),
        'unavailable',
      );
      lease.dispose();
    },
  );

  test(
    'a retiring request cannot be acknowledged against a newer page',
    () async {
      final bridge = DeviceSyncPairingDebug();
      final finish = Completer<void>();
      final old = bridge.bind(
        mobile: true,
        active: () => true,
        transport: () => 'usb',
        canInject: () => true,
        readInvitation: () => null,
        inject: (_) => finish.future,
      );
      final generation =
          result(await request(bridge, 'status'))['generation'] as int;
      final pending = request(
        bridge,
        'inject',
        generation: generation,
        invitation: 'old',
      );
      old.dispose();
      final replacement = bridge.bind(
        mobile: true,
        active: () => true,
        transport: () => 'wifi',
        canInject: () => true,
        readInvitation: () => null,
        inject: (_) async {},
      );
      finish.complete();
      expect(reason(await pending), 'stale_page');
      expect(result(await request(bridge, 'status'))['transport'], 'wifi');
      replacement.dispose();
    },
  );
}
