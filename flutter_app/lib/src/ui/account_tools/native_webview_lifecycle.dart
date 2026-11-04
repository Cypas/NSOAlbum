import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Retain a pending widget until native creation acknowledges its keepAlive ID.
/// Removing a widget alone does not await the plugin's asynchronous disposal.
class NativeWebViewLifecycle {
  NativeWebViewLifecycle({String? platform})
    : _platform = platform ?? Platform.operatingSystem;

  static const _androidDisposal = MethodChannel(
    'io.github.cypas.nsoalbum/splatnet_webview',
  );
  final String _platform;
  final keepAlive = InAppWebViewKeepAlive();
  final _created = Completer<void>();
  bool _started = false;
  bool _closing = false;
  String? _nativeViewId;
  Future<void>? _cleanup;

  bool beginCreation() {
    if (_started) return true;
    if (_closing) return false;
    _started = true;
    return true;
  }

  bool created({String? nativeViewId}) {
    _nativeViewId ??= nativeViewId;
    if (!_created.isCompleted) _created.complete();
    return !_closing;
  }

  Future<void> close(Future<void> Function() detach) {
    _closing = true;
    return _cleanup ??= () async {
      if (_started) {
        // A timeout remains a failed cleanup; it never permits a second page.
        await _created.future.timeout(const Duration(seconds: 30));
      }
      await detach();
      if (_started) {
        if (_platform == 'android') {
          final id = _nativeViewId;
          if (id == null || id.isEmpty) {
            throw StateError('splatnet_native_view_id_missing');
          }
          await _androidDisposal
              .invokeMethod<void>('destroyKeepAlive', {'keepAliveId': id})
              .timeout(const Duration(seconds: 30));
        }
        await InAppWebViewController.disposeKeepAlive(keepAlive)
            .timeout(const Duration(seconds: 30));
      }
    }();
  }
}
