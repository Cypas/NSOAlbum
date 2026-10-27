import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/device_sync_real_noop_controller.dart';

final class _Peer implements RealNoopPeer {
  bool eligible = true, approved = false, closed = false, ambiguousUsb = false;
  String binding = 'synthetic-binding';
  int guards = 0, closeFailures = 0;
  @override
  Future<Map<String, Object>> status() async => {
    'stage': 'awaitingApproval',
    'controller': true,
    'confirmation_code': '123456',
  };
  @override
  Future<void> confirm(String expectedCode) async {
    if (expectedCode != '123456') throw StateError('private-code');
  }

  @override
  Future<void> configure(bool phoneToDesktop) async {}
  @override
  Future<String> preview() async => binding;
  @override
  Future<bool> arm(String binding) async {
    guards++;
    return eligible && binding == this.binding;
  }

  @override
  Future<void> approve() async => approved = true;
  @override
  Future<String?> metrics() async => null;
  @override
  Future<int> prepareUsb() async => 1;
  @override
  Future<bool> selectOnlyUsb() async {
    if (ambiguousUsb) throw const RealNoopAmbiguousUsb();
    return true;
  }

  @override
  Future<void> close() async {
    if (closeFailures > 0) {
      closeFailures--;
      throw StateError('private-cleanup-failure');
    }
    closed = true;
  }

  @override
  bool get settled => closed;
}

RealNoopController _controller(_Peer peer, {bool enabled = true}) =>
    RealNoopController(
      enabled: enabled,
      mobile: true,
      ready: () => true,
      host: (_) async => (peer: peer, invitation: 'private-invitation'),
      join: (_, _) async => peer,
      shutdown: () async {},
    );

void main() {
  test('VM isolate metadata permits status host and close without echoing it',
      () async {
    final peer = _Peer();
    final controller = _controller(peer);
    const isolate = 'isolates/private-debug-isolate';
    final status = await handleRealNoopVmParameters(controller, {
      'op': 'status', 'isolateId': isolate,
    });
    expect(status['ready'], isTrue);
    expect(status.containsKey('error'), isFalse);
    expect(status.toString(), isNot(contains(isolate)));

    final hosted = await handleRealNoopVmParameters(controller, {
      'op': 'host', 'transport': 'wifi', 'isolateId': isolate,
    });
    expect(hosted, {'invitation': 'private-invitation'});
    expect(hosted.toString(), isNot(contains(isolate)));
    final closed = await handleRealNoopVmParameters(controller, {
      'op': 'close', 'isolateId': isolate,
    });
    expect(closed, {'settled': true});
    expect(peer.closed, isTrue);
    expect(closed.toString(), isNot(contains(isolate)));
  });

  test('VM metadata adapter never relaxes the business input whitelist',
      () async {
    final controller = _controller(_Peer());
    expect(await handleRealNoopVmParameters(controller, {
      'op': 'status', 'isolateId': 'isolates/private', 'unknown': 'private-value',
    }), {'error': 'invalid_input'});
    expect(await controller.handle({
      'op': 'status', 'isolateId': 'isolates/private',
    }), {'error': 'invalid_input'});
  });

  test(
    'USB preparation is explicit and ambiguity remains a fixed failure',
    () async {
      final peer = _Peer();
      final controller = _controller(peer);
      await controller.handle({'op': 'host', 'transport': 'usb'});
      expect(await controller.handle({'op': 'prepare_usb'}), {
        'usb_choices': 1,
      });
      peer.ambiguousUsb = true;
      expect(await controller.handle({'op': 'select_usb'}), {
        'error': 'ambiguous_usb',
      });
    },
  );

  test('disabled real-library entry cannot open or expose a session', () async {
    final peer = _Peer();
    final controller = _controller(peer, enabled: false);
    expect(await controller.handle({'op': 'host', 'transport': 'wifi'}), {
      'error': 'disabled',
    });
    expect(peer.closed, isFalse);
  });

  test(
    'no-op rejection and stale binding can never approve a preview',
    () async {
      final peer = _Peer();
      final controller = _controller(peer);
      await controller.handle({'op': 'host', 'transport': 'wifi'});
      await controller.handle({'op': 'preview'});
      expect(await controller.handle({'op': 'approve'}), {
        'error': 'guard_required',
      });
      peer.eligible = false;
      expect(await controller.handle({'op': 'arm', 'binding': peer.binding}), {
        'armed': false,
      });
      expect(await controller.handle({'op': 'approve'}), {
        'error': 'guard_required',
      });
      peer.eligible = true;
      expect(await controller.handle({'op': 'arm', 'binding': 'stale'}), {
        'armed': false,
      });
      expect(peer.approved, isFalse);
      expect(await controller.handle({'op': 'arm', 'binding': peer.binding}), {
        'armed': true,
      });
      expect(await controller.handle({'op': 'approve'}), {'approved': true});
      expect(peer.guards, 3, reason: 'Approval must recheck native authority');
      expect(peer.approved, isTrue);
      expect(await controller.handle({'op': 'approve'}), {
        'error': 'already_approved',
      });
    },
  );

  test(
    'accounts overwrite and unbounded inputs cannot reach real session',
    () async {
      final peer = _Peer();
      final controller = _controller(peer);
      await controller.handle({'op': 'host', 'transport': 'wifi'});
      for (final extra in [
        {'overwrite': 'true'},
        {'include_accounts': 'true'},
      ]) {
        expect(
          await controller.handle({
            'op': 'configure',
            'phone_to_desktop': 'true',
            ...extra,
          }),
          {'error': 'invalid_input'},
        );
      }
      expect(await controller.handle({'op': 'arm', 'binding': 'x' * 8193}), {
        'error': 'invalid_input',
      });
    },
  );

  test(
    'status does not leak invitation and errors never echo private input',
    () async {
      final controller = _controller(_Peer());
      await controller.handle({'op': 'host', 'transport': 'wifi'});
      final status = await controller.handle({'op': 'status'});
      expect(status.toString(), isNot(contains('invitation')));
      final failed = await controller.handle({
        'op': 'confirm',
        'expected_code': 'secret',
      });
      expect(failed, {'error': 'operation_failed'});
      expect(failed.toString(), isNot(contains('secret')));
    },
  );

  test(
    'joining remains cancellable while system authorization is pending',
    () async {
      final peer = _Peer();
      final pending = Completer<RealNoopPeer>();
      final controller = RealNoopController(
        enabled: true,
        mobile: true,
        ready: () => true,
        host: (_) async => (peer: peer, invitation: 'unused'),
        join: (_, _) => pending.future,
        shutdown: () async {},
        cancelJoin: () async {
          pending.complete(peer);
        },
      );
      expect(
        await controller.handle({
          'op': 'join',
          'transport': 'usb',
          'invitation': 'synthetic',
        }),
        {'connecting': true},
      );
      expect((await controller.handle({'op': 'status'}))['connecting'], isTrue);
      expect(await controller.handle({'op': 'close'}), {'settled': true});
      expect(peer.closed, isTrue);
    },
  );

  test('late join cleanup failure remains owned and close can retry', () async {
    final peer = _Peer()..closeFailures = 1;
    final pending = Completer<RealNoopPeer>();
    final controller = RealNoopController(
      enabled: true,
      mobile: true,
      ready: () => true,
      host: (_) async => (peer: peer, invitation: 'unused'),
      join: (_, _) => pending.future,
      shutdown: () async {},
      cancelJoin: () async {
        if (!pending.isCompleted) pending.complete(peer);
      },
    );
    await controller.handle({
      'op': 'join',
      'transport': 'usb',
      'invitation': 'synthetic',
    });
    expect(await controller.handle({'op': 'close'}), {
      'error': 'cleanup_failed',
    });
    final failed = await controller.handle({'op': 'status'});
    expect(failed['active'], isTrue);
    expect(failed['error'], 'cleanup_failed');
    expect(failed.toString(), isNot(contains('private-cleanup-failure')));
    expect(await controller.handle({'op': 'host', 'transport': 'wifi'}), {
      'error': 'busy',
    });
    expect(await controller.handle({'op': 'close'}), {'settled': true});
    expect((await controller.handle({'op': 'status'}))['active'], isFalse);
  });

  test('only platform callback reports manual authorization state', () async {
    final peer = _Peer();
    var waiting = true;
    final controller = RealNoopController(
      enabled: true,
      mobile: true,
      ready: () => true,
      host: (_) async => (peer: peer, invitation: 'unused'),
      join: (_, _) async => peer,
      shutdown: () async {},
      authorizationPending: () => waiting,
    );
    expect(
      (await controller.handle({'op': 'status'}))['blocked_authorization'],
      isTrue,
    );
    waiting = false;
    expect(
      (await controller.handle({'op': 'status'}))['blocked_authorization'],
      isFalse,
    );
  });

  test(
    'pending Wi-Fi connection does not invent manual authorization',
    () async {
      final peer = _Peer();
      final pending = Completer<RealNoopPeer>();
      final controller = RealNoopController(
        enabled: true,
        mobile: true,
        ready: () => true,
        host: (_) async => (peer: peer, invitation: 'unused'),
        join: (_, _) => pending.future,
        shutdown: () async {},
        cancelJoin: () async {
          pending.complete(peer);
        },
      );
      await controller.handle({
        'op': 'join',
        'transport': 'wifi',
        'invitation': 'synthetic',
      });
      final status = await controller.handle({'op': 'status'});
      expect(status['connecting'], isTrue);
      expect(status.containsKey('blocked_authorization'), isFalse);
      await controller.handle({'op': 'close'});
    },
  );
}
