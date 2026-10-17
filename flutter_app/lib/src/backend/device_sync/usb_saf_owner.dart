import 'dart:typed_data';

import '../../platform/device_sync_saf.dart';
import '../../rust/bridge.dart' as native;
import '../../rust/device_sync/read_model.dart';
import '../../rust/device_sync/usb.dart';

/// Serial OS byte I/O for one Rust-owned endpoint. No protocol or library state.
final class DeviceSyncUsbSafOwner {
  DeviceSyncUsbSafOwner({required this.endpoint, required this.saf});

  final String endpoint;
  final DeviceSyncSaf saf;
  static final _active = <String>{};
  static final _safOwners =
      Map<DeviceSyncSaf, DeviceSyncUsbSafOwner>.identity();
  Future<UsbView>? _running;
  Future<void>? _ending;
  int _epoch = 0;
  bool _invalidated = false;

  Future<UsbView> run() {
    final running = _running;
    if (running != null) return running;
    if (_active.length >= 16 ||
        _active.contains(endpoint) ||
        _safOwners.containsKey(saf)) {
      return Future.error(DeviceSyncSafFailure(DeviceSyncSafError.busy));
    }
    _active.add(endpoint);
    _safOwners[saf] = this;
    return _running = _run().whenComplete(() {
      _active.remove(endpoint);
      if (identical(_safOwners[saf], this)) _safOwners.remove(saf);
    });
  }

  void _invalidate() {
    if (!_invalidated) {
      _invalidated = true;
      _epoch++;
    }
  }

  Future<void> _endNative({required bool success}) {
    if (!identical(_safOwners[saf], this)) return Future<void>.value();
    return _ending ??= success ? saf.close() : saf.cancel();
  }

  Future<void> cancel() async {
    _invalidate();
    await native.deviceSyncCancelSignal(endpoint: endpoint);
    try {
      await _endNative(success: false);
    } finally {
      await native.deviceSyncShutdown(endpoint: endpoint);
    }
  }

  /// Wait for this owner's OS cleanup independently of protocol shutdown.
  Future<void> settleOwnedIo() {
    _invalidate();
    return _ending ?? _endNative(success: false);
  }

  Future<UsbView> _run() async {
    UsbView? observed;
    // One independent notification, never queued behind the provider action.
    final watcher = native
        .deviceSyncUsbWaitClosed(endpoint: endpoint)
        .then<void>(
          (view) async {
            observed = view;
            if (view.reason != UsbCloseReason.success) {
              _invalidate();
              try {
                await _endNative(success: false);
              } catch (_) {
                // The Rust result remains authoritative, including finalized SQL.
              }
            }
          },
          onError: (Object _) async {
            _invalidate();
            try {
              await _endNative(success: false);
            } catch (_) {}
          },
        );
    try {
      while (!_invalidated) {
        final action = await native.deviceSyncUsbNext(endpoint: endpoint);
        if (action == null) break;
        final epoch = _epoch;
        var bytes = Uint8List(0);
        var names = <String>[];
        ReadError? error;
        try {
          switch (action.kind) {
            case UsbActionKind.open:
              await saf.openSession(action.operation, action.session);
            case UsbActionKind.list:
              names = await saf.listBlocks(action.direction.name);
            case UsbActionKind.read:
              bytes = await saf.readBlock(action.direction.name, action.name!);
            case UsbActionKind.write:
              await saf.writeCiphertextBlock(action.name!, action.bytes);
            case UsbActionKind.acknowledge:
              await saf.acknowledgeBlock(action.direction.name, action.name!);
            case UsbActionKind.close:
              await _endNative(success: true);
            case UsbActionKind.enumerate:
              error = ReadError.invalidInput;
          }
        } catch (failure) {
          error = failure is DeviceSyncSafFailure
              ? switch (failure.code) {
                  DeviceSyncSafError.busy => ReadError.busy,
                  DeviceSyncSafError.permissionDenied =>
                    ReadError.permissionDenied,
                  DeviceSyncSafError.windowFull => ReadError.windowFull,
                  DeviceSyncSafError.closed => ReadError.disconnected,
                  DeviceSyncSafError.timeout => ReadError.timeout,
                  DeviceSyncSafError.invalidInput => ReadError.invalidInput,
                  DeviceSyncSafError.unavailable => ReadError.unavailable,
                }
              : ReadError.unavailable;
        }
        if (epoch != _epoch) break;
        await native.deviceSyncUsbComplete(
          endpoint: endpoint,
          reply: UsbReply(
            token: action.token,
            generation: action.generation,
            operation: action.operation,
            session: action.session,
            bytes: bytes,
            names: names,
            devices: const [],
            error: error,
          ),
        );
      }
      await watcher;
      return await _retiredView(observed);
    } catch (_) {
      try {
        await native.deviceSyncCancelSignal(endpoint: endpoint);
      } catch (_) {
        // close_library can already have retired this exact endpoint.
      }
      await watcher;
      return await _retiredView(observed);
    }
  }

  Future<UsbView> _retiredView(UsbView? observed) async {
    try {
      var view = await native.deviceSyncUsbView(endpoint: endpoint);
      if (!view.closed) {
        await native.deviceSyncShutdown(endpoint: endpoint);
        view = await native.deviceSyncUsbView(endpoint: endpoint);
      }
      return view;
    } catch (_) {
      return UsbView(
        closed: true,
        reason: observed?.reason ?? UsbCloseReason.failure,
        error: observed?.error ?? ReadError.unavailable,
        devices: const [],
      );
    }
  }
}
