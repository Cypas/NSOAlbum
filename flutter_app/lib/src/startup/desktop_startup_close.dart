import 'dart:async';

import 'package:window_manager/window_manager.dart';

import 'application_bootstrap.dart';
import 'startup_options.dart';

/// The native close owner is installed before any core preparation is started.
/// Shell policy may be delegated without relinquishing the native interception.
class DesktopStartupClose with WindowListener {
  DesktopStartupClose(this.bootstrap, {required this.onError, this.onClosed});
  static Future<DesktopStartupClose?> protect({
    required ApplicationBootstrap bootstrap,
    required StartupOptions options,
    required bool desktop,
    required void Function(Object, StackTrace) onError,
    Future<void> Function()? onClosed,
  }) async {
    if (!desktop || options.ciSmoke) return null;
    final owner = DesktopStartupClose(
      bootstrap,
      onError: onError,
      onClosed: onClosed,
    );
    await owner.install();
    return owner;
  }

  final ApplicationBootstrap bootstrap;
  final void Function(Object, StackTrace) onError;
  final Future<void> Function()? onClosed;
  Object? _policyOwner;
  Future<void> Function()? _policy;
  Future<void>? _request;
  Future<void>? _closing;
  Future<void>? _installation;
  bool _closed = false;

  Future<void> install() => _installation ??= () async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
  }();

  void adoptPolicy(Object owner, Future<void> Function() policy) {
    if (_closing != null) return;
    _policyOwner = owner;
    _policy = policy;
  }

  void releasePolicy(Object owner) {
    if (!identical(_policyOwner, owner)) return;
    _policyOwner = null;
    _policy = null;
  }

  @override
  void onWindowClose() {
    if (_request != null) return;
    final done = Completer<void>();
    late final Future<void> request;
    request = done.future.whenComplete(() {
      if (identical(_request, request)) _request = null;
    });
    _request = request;
    unawaited(
      Future<void>.sync(_policy ?? closeApplication).then(
        (_) => done.complete(),
        onError: (Object error, StackTrace stack) {
          if (identical(_request, request)) _request = null;
          done.complete();
          onError(error, stack);
        },
      ),
    );
  }

  Future<void> closeApplication() {
    if (_closing case final current?) return current;
    if (_closed) return Future.value();
    final done = Completer<void>();
    late final Future<void> flight;
    flight = done.future.whenComplete(() {
      if (identical(_closing, flight)) _closing = null;
    });
    _closing = flight;
    unawaited(
      () async {
        try {
          await bootstrap.close();
          await windowManager.setPreventClose(false);
          try {
            await windowManager.close();
          } catch (_) {
            await windowManager.setPreventClose(true);
            rethrow;
          }
          _closed = true;
          windowManager.removeListener(this);
          await onClosed?.call();
        } catch (failure) {
          bootstrap.reportCloseFailure(failure);
          rethrow;
        }
      }().then(done.complete, onError: done.completeError),
    );
    return flight;
  }
}
