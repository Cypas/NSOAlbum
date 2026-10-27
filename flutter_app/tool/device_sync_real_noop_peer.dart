import 'dart:async';

import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;

import 'device_sync_real_noop_controller.dart';

DeviceLanAddress selectRealNoopWifiAddress(
  List<DeviceLanAddress> choices, {
  String? interfaceName,
}) {
  if (interfaceName != null) {
    final matching = choices
        .where((choice) => choice.interfaceName == interfaceName)
        .toList();
    if (matching.length != 1) {
      throw StateError('Requested LAN interface is unavailable or ambiguous');
    }
    return matching.single;
  }
  final physical = choices
      .where(
        (choice) => !RegExp(
          r'virtual|vethernet|wsl|docker|vpn|tailscale|zerotier|vmware|tunnel',
          caseSensitive: false,
        ).hasMatch(choice.interfaceName),
      )
      .toList();
  if (physical.length != 1) throw StateError('Ambiguous LAN interface');
  return physical.single;
}

final class NativeRealNoopPeer implements RealNoopPeer {
  NativeRealNoopPeer({
    required this.session,
    required this.requireNoop,
    required this.readMetrics,
  });
  final DeviceSyncSessionController session;
  final Future<bool> Function(String) requireNoop;
  final Future<String?> Function() readMetrics;
  DeviceSyncPreviewView? _shown;
  bool _usbSelected = false;
  Future<void> _usbTail = Future.value();
  @override
  bool get settled => session.settled;
  @override
  Future<Map<String, Object>> status() async {
    await session.refresh();
    final value = session.snapshot?.value;
    if (value == null) return {'error': 'not_ready'};
    return {
      'stage': value.stage.name,
      'pairing': value.pairing.name,
      'controller': value.controller,
      'source': value.source == true,
      'terminal': value.terminal,
      'cleanup_pending': value.cleanupPending || session.localCleanupPending,
      'preview_available': value.stage == driver.State.awaitingApproval,
      'confirmed_locally': session.confirmedLocally,
      'confirmation_code': ?session.confirmationCode,
      'error': ?session.issue?.name,
      'transport_error': ?session.transportIssue?.name,
    };
  }

  @override
  Future<void> confirm(String expectedCode) async {
    await session.refresh();
    if (session.confirmationCode != expectedCode) {
      throw StateError('Confirmation changed');
    }
    await session.confirmPairing();
  }

  @override
  Future<void> configure(bool phoneToDesktop) => session.configure(
    phoneToDesktop: phoneToDesktop,
    overwrite: false,
    includeAccounts: false,
  );
  @override
  Future<String> preview() async {
    final shown = await session.refreshPreview();
    _shown = shown;
    return shown.library.binding;
  }

  @override
  Future<bool> arm(String binding) => requireNoop(binding);
  @override
  Future<void> approve() async {
    final shown = _shown;
    if (shown == null) throw StateError('Preview missing');
    await session.approvePreview(shown);
  }

  @override
  Future<String?> metrics() => readMetrics();
  @override
  Future<int> prepareUsb() => _serializeUsb(() async {
    if (_usbSelected) return 0;
    return (await session.usbChoices()).length;
  });
  @override
  Future<bool> selectOnlyUsb() => _serializeUsb(() async {
    if (_usbSelected) return true;
    final choices = await session.usbChoices();
    if (choices.length > 1) throw const RealNoopAmbiguousUsb();
    if (choices.isEmpty) return false;
    await session.selectUsb(choices.single);
    _usbSelected = true;
    return true;
  });

  Future<T> _serializeUsb<T>(Future<T> Function() action) {
    final previous = _usbTail;
    final done = Completer<void>();
    _usbTail = done.future;
    return () async {
      await previous;
      try {
        return await action();
      } finally {
        done.complete();
      }
    }();
  }

  @override
  Future<void> close() => session.close();
}
