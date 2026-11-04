import 'dart:async';

import 'device_sync_real_noop_report.dart';

typedef RealNoopHost = ({RealNoopPeer peer, String invitation});

Future<Map<String, Object>> handleRealNoopVmParameters(
  RealNoopController controller,
  Map<String, String> parameters,
) => controller.handle({
  for (final entry in parameters.entries)
    if (entry.key != 'isolateId') entry.key: entry.value,
});

abstract interface class RealNoopPeer {
  Future<Map<String, Object>> status();
  Future<void> confirm(String expectedCode);
  Future<void> configure(bool phoneToDesktop);
  Future<String> preview();
  Future<bool> arm(String binding);
  Future<void> approve();
  Future<String?> metrics();
  Future<int> prepareUsb();
  Future<bool> selectOnlyUsb();
  Future<void> close();
  bool get settled;
}

final class RealNoopAmbiguousUsb implements Exception {
  const RealNoopAmbiguousUsb();
}

final class RealNoopController {
  RealNoopController({
    required this.enabled,
    required this.mobile,
    required this.ready,
    required this.host,
    required this.join,
    required this.shutdown,
    this.cancelJoin,
    this.authorizationPending,
  });
  final bool enabled, mobile;
  final bool Function() ready;
  final Future<RealNoopHost> Function(String) host;
  final Future<RealNoopPeer> Function(String, String) join;
  final Future<void> Function() shutdown;
  final Future<void> Function()? cancelJoin;
  final bool Function()? authorizationPending;
  RealNoopPeer? _peer;
  Future<void>? _opening, _action;
  String? _binding, _failure;
  bool _armed = false, _approved = false, _closing = false;
  bool _joinCloseFailed = false;
  int _epoch = 0;

  Future<Map<String, Object>> handle(Map<String, String> parameters) async {
    if (!enabled) return _error('disabled');
    final op = parameters['op'];
    if (!_inputs.containsKey(op) ||
        parameters.keys.any((key) => !_inputs[op]!.contains(key))) {
      return _error('invalid_input');
    }
    try {
      if (op == 'status') {
        final peer = _peer;
        return {
          'ready': ready(),
          'active': peer != null,
          'connecting': _opening != null,
          if (authorizationPending case final pending?)
            'blocked_authorization': pending(),
          if (peer != null) ...await peer.status(),
          'error': ?_failure,
        };
      }
      if (op == 'close' || op == 'shutdown') {
        if (_closing) return _error('busy');
        _closing = true;
        try {
          _epoch++;
          await cancelJoin?.call();
          await _opening;
          await _action;
          if (_joinCloseFailed) {
            _joinCloseFailed = false;
            return _error('cleanup_failed');
          }
          final peer = _peer;
          try {
            await peer?.close();
          } catch (_) {
            _failure = 'cleanup_failed';
            return _error('cleanup_failed');
          }
          if (peer != null && !peer.settled) return {'settled': false};
          _peer = null;
          _binding = _failure = null;
          _armed = _approved = false;
          if (op == 'shutdown') await shutdown();
          return {'settled': true};
        } finally {
          _closing = false;
        }
      }
      if (_closing || _action != null) return _error('busy');
      if (!ready()) return _error('not_ready');
      final done = Completer<void>();
      _action = done.future;
      try {
        if (op == 'host' || op == 'join') {
          if (_peer != null || _opening != null) return _error('busy');
          final transport = parameters['transport'];
          if (transport != 'wifi' && transport != 'usb') {
            return _error('invalid_input');
          }
          _failure = null;
          if (op == 'host') {
            final opened = await host(transport!);
            _peer = opened.peer;
            return {'invitation': opened.invitation};
          }
          final invitation = parameters['invitation'];
          if (!_bounded(invitation)) return _error('invalid_input');
          final epoch = _epoch;
          late final Future<void> flight;
          flight = () async {
            RealNoopPeer? opened;
            try {
              final peer = await join(transport!, invitation!);
              opened = peer;
              // Retain ownership before retiring a late result; close may fail.
              _peer = peer;
              if (_closing || epoch != _epoch) {
                await peer.close();
                if (peer.settled) {
                  _peer = null;
                } else {
                  _joinCloseFailed = true;
                  _failure = 'cleanup_failed';
                }
              }
            } catch (_) {
              _joinCloseFailed = opened != null;
              _failure = opened == null
                  ? 'connection_failed'
                  : 'cleanup_failed';
            } finally {
              if (identical(_opening, flight)) _opening = null;
            }
          }();
          _opening = flight;
          return {'connecting': true};
        }
        final peer = _peer;
        if (peer == null) return _error('not_ready');
        switch (op) {
          case 'confirm':
            final expected = parameters['expected_code'];
            if (!_bounded(expected)) return _error('invalid_input');
            await peer.confirm(expected!);
            return {'confirmed': true};
          case 'configure':
            final direction = parameters['phone_to_desktop'];
            if (!mobile || (direction != 'true' && direction != 'false')) {
              return _error('invalid_input');
            }
            await peer.configure(direction == 'true');
            return {'configured': true};
          case 'preview':
            if (_approved) return _error('already_approved');
            _armed = false;
            _binding = await peer.preview();
            return {'binding': _binding!};
          case 'arm':
            final binding = parameters['binding'];
            if (!_bounded(binding)) return _error('invalid_input');
            _armed = false;
            if (_binding != null && binding != _binding) {
              return {'armed': false};
            }
            final armed = await peer.arm(binding!);
            if (armed) {
              _binding = binding;
              _armed = true;
            }
            return {'armed': armed};
          case 'approve':
            if (_approved) return _error('already_approved');
            if (!_armed || _binding == null) return _error('guard_required');
            if (!await peer.arm(_binding!)) {
              _armed = false;
              return _error('guard_required');
            }
            await peer.approve();
            _approved = true;
            return {'approved': true};
          case 'prepare_usb':
            return {'usb_choices': await peer.prepareUsb()};
          case 'select_usb':
            return await peer.selectOnlyUsb()
                ? {'selected': true}
                : _error('not_ready');
          case 'report':
            final record = await peer.metrics();
            if (record == null) return _error('metrics_unavailable');
            final metrics = NoopBenchmarkMetrics.parse(record);
            return {
              'metrics':
                  'device_sync_metrics valid=true '
                  '${metrics.values.entries.map((e) => '${e.key}=${e.value}').join(' ')}',
            };
          default:
            return _error('invalid_input');
        }
      } finally {
        done.complete();
        if (identical(_action, done.future)) _action = null;
      }
    } on RealNoopAmbiguousUsb {
      return _error('ambiguous_usb');
    } catch (_) {
      return _error('operation_failed');
    }
  }

  static Map<String, Object> _error(String code) => {'error': code};
  static bool _bounded(String? value) =>
      value != null && value.isNotEmpty && value.length <= 8192;
  static const _inputs = {
    'status': {'op'},
    'host': {'op', 'transport'},
    'join': {'op', 'transport', 'invitation'},
    'confirm': {'op', 'expected_code'},
    'configure': {'op', 'phone_to_desktop'},
    'preview': {'op'},
    'arm': {'op', 'binding'},
    'approve': {'op'},
    'report': {'op'},
    'prepare_usb': {'op'},
    'select_usb': {'op'},
    'close': {'op'},
    'shutdown': {'op'},
  };
}
