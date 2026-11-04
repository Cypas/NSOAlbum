import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Debug-only VM Service seam for the real page, not another pairing protocol.
/// Invitation material must stay in the authenticated debugger's memory.
final class DeviceSyncPairingDebug {
  DeviceSyncPairingDebug({bool enabled = kDebugMode})
    : _enabled = kDebugMode && enabled;

  static final instance = DeviceSyncPairingDebug();
  static const extensionName = 'ext.squid_album.deviceSyncPairing';
  final bool _enabled;
  bool _registered = false, _injecting = false;
  int _generation = 0;
  _DebugPairingTarget? _target;

  DeviceSyncPairingDebugBinding bind({
    required bool mobile,
    required bool Function() active,
    required String Function() transport,
    required bool Function() canInject,
    required String? Function() readInvitation,
    required Future<void> Function(String) inject,
  }) {
    if (!_enabled) return DeviceSyncPairingDebugBinding._(null);
    final target = _DebugPairingTarget(
      generation: ++_generation,
      mobile: mobile,
      active: active,
      transport: transport,
      canInject: canInject,
      readInvitation: readInvitation,
      inject: inject,
    );
    _target = target;
    return DeviceSyncPairingDebugBinding._(() {
      if (identical(_target, target)) _target = null;
    });
  }

  void register() {
    if (!_enabled || _registered) return;
    developer.registerExtension(extensionName, handle);
    _registered = true;
  }

  /// The exact handler registered with the VM, also exercised without a VM.
  Future<developer.ServiceExtensionResponse> handle(
    String method,
    Map<String, String> parameters,
  ) async {
    if (!_enabled) return _failure('disabled');
    final action = parameters['action'];
    if (method != extensionName ||
        !const {'status', 'read', 'inject'}.contains(action)) {
      return _failure('invalid_action');
    }
    try {
      final target = _target;
      if (target == null || !target.active()) return _failure('unavailable');
      if (action == 'status') {
        return _success({
          'generation': target.generation,
          'mobile': target.mobile,
          'transport': target.transport(),
          'canInject': target.mobile && !_injecting && target.canInject(),
          'canRead': !target.mobile && target.readInvitation() != null,
        });
      }
      if (int.tryParse(parameters['generation'] ?? '') != target.generation) {
        return _failure('stale_page');
      }
      if (action == 'read') {
        if (target.mobile) return _failure('unavailable');
        final invitation = target.readInvitation();
        if (invitation == null || !_bounded(invitation)) {
          return _failure('unavailable');
        }
        return _success({
          'generation': target.generation,
          'invitation': invitation,
        });
      }
      if (!target.mobile || !target.canInject()) {
        return _failure('unavailable');
      }
      if (_injecting) return _failure('busy');
      final invitation = parameters['invitation'];
      if (invitation == null || !_bounded(invitation)) {
        return _failure('invalid_input');
      }
      _injecting = true;
      try {
        // Uses the same page action as a returned camera scan. It cannot
        // confirm pairing, select accounts or approve a receiving preview.
        await target.inject(invitation);
        if (!identical(_target, target) || !target.active()) {
          return _failure('stale_page');
        }
        return _success({'accepted': true, 'generation': target.generation});
      } finally {
        _injecting = false;
      }
    } catch (_) {
      // Neither parser/native errors nor caller input enter diagnostics.
      return _failure('operation_failed');
    }
  }

  bool _bounded(String value) =>
      value.isNotEmpty &&
      value.length <= 8192 &&
      utf8.encode(value).length <= 8192;

  developer.ServiceExtensionResponse _success(Map<String, Object> value) =>
      developer.ServiceExtensionResponse.result(jsonEncode(value));

  developer.ServiceExtensionResponse _failure(String reason) =>
      developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        jsonEncode({'reason': reason}),
      );
}

final class DeviceSyncPairingDebugBinding {
  DeviceSyncPairingDebugBinding._(this._release);
  VoidCallback? _release;

  void dispose() {
    _release?.call();
    _release = null;
  }
}

final class _DebugPairingTarget {
  const _DebugPairingTarget({
    required this.generation,
    required this.mobile,
    required this.active,
    required this.transport,
    required this.canInject,
    required this.readInvitation,
    required this.inject,
  });
  final int generation;
  final bool mobile;
  final bool Function() active, canInject;
  final String Function() transport;
  final String? Function() readInvitation;
  final Future<void> Function(String) inject;
}
