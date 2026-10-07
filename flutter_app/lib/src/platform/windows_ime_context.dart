import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keeps the Windows runner informed about the lifetime of Flutter's active
/// text client. No text, composing value, or candidate data crosses the
/// channel.
class WindowsImeContextCoordinator {
  WindowsImeContextCoordinator._();

  static final instance = WindowsImeContextCoordinator._();
  static const _channel = MethodChannel('io.squidalbum/ime_context');

  bool _started = false;

  void resetForTesting() {
    if (_started) {
      FocusManager.instance.removeListener(_handleFocusChanged);
    }
    _started = false;
  }

  void start({bool enabled = true}) {
    if (!enabled || !Platform.isWindows) return;
    if (!_started) {
      _started = true;
      FocusManager.instance.addListener(_handleFocusChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleFocusChanged());
  }

  void _handleFocusChanged() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final active =
        focusContext?.widget is EditableText ||
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
    unawaited(_sendState(active));
  }

  Future<void> _sendState(bool active) async {
    try {
      await _channel.invokeMethod<void>('setTextClientActive', active);
    } on MissingPluginException {
      // Widget tests and non-runner embedders do not install the channel.
    } on PlatformException {
      // Input remains usable through Flutter's default path if the runner
      // cannot install a compatibility context.
    }
  }
}
