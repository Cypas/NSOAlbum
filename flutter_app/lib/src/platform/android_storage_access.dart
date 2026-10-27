import 'package:flutter/services.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';

enum AndroidStorageAccessState {
  unavailable,
  notRequired,
  denied,
  allowed,
  busy,
}

bool androidStorageStartupEnabled({
  required bool isAndroid,
  required bool isTest,
  required bool safeMode,
  required bool ciSmoke,
}) => isAndroid && !isTest && !safeMode && !ciSmoke;

/// Optional shared-storage access. Private libraries remain usable without it.
class AndroidStorageAccess {
  AndroidStorageAccess({
    MethodChannel? channel,
    this._permissions,
  }) : _channel =
           channel ?? const MethodChannel('io.github.cypas.nsoalbum/storage');

  final MethodChannel _channel;
  final PermissionHandlerPlatform? _permissions;
  Future<AndroidStorageAccessState>? _request;

  Future<_AccessStatus> _read() async {
    final value = await _channel.invokeMethod<Object?>('allFilesAccessStatus');
    if (value is! Map ||
        value['supported'] is! bool ||
        value['allowed'] is! bool ||
        value['requested'] is! bool) {
      throw const FormatException('Invalid storage permission status');
    }
    return _AccessStatus(
      supported: value['supported'] as bool,
      allowed: value['allowed'] as bool,
      requested: value['requested'] as bool,
    );
  }

  Future<AndroidStorageAccessState> status() async {
    try {
      return (await _read()).state;
    } catch (_) {
      return AndroidStorageAccessState.unavailable;
    }
  }

  Future<AndroidStorageAccessState> request({bool automatic = false}) {
    final active = _request;
    if (active != null) return active;
    late final Future<AndroidStorageAccessState> operation;
    operation = _requestOnce(automatic).whenComplete(() {
      if (identical(_request, operation)) _request = null;
    });
    _request = operation;
    return operation;
  }

  Future<AndroidStorageAccessState> _requestOnce(bool automatic) async {
    var ownsRequest = false;
    try {
      final before = await _read();
      if (!before.supported ||
          before.allowed ||
          (automatic && before.requested)) {
        return before.state;
      }
      // Android records the one-time request before leaving the app, while
      // holding the same prompt owner used by native notification requests.
      ownsRequest =
          await _channel.invokeMethod<bool>('beginAllFilesAccessRequest', {
            'automatic': automatic,
          }) ==
          true;
      if (!ownsRequest) {
        final latest = await _read();
        return !latest.supported ||
                latest.allowed ||
                (automatic && latest.requested)
            ? latest.state
            : AndroidStorageAccessState.busy;
      }
      await (_permissions ?? PermissionHandlerPlatform.instance)
          .requestPermissions([Permission.manageExternalStorage]);
      // A successfully opened settings page is not a grant.
      return (await _read()).state;
    } catch (_) {
      return AndroidStorageAccessState.unavailable;
    } finally {
      if (ownsRequest) {
        try {
          await _channel.invokeMethod<void>('endAllFilesAccessRequest');
        } catch (_) {
          // Activity teardown also retires its prompt owner.
        }
      }
    }
  }
}

class _AccessStatus {
  const _AccessStatus({
    required this.supported,
    required this.allowed,
    required this.requested,
  });

  final bool supported;
  final bool allowed;
  final bool requested;

  AndroidStorageAccessState get state => !supported
      ? AndroidStorageAccessState.notRequired
      : allowed
      ? AndroidStorageAccessState.allowed
      : AndroidStorageAccessState.denied;
}
