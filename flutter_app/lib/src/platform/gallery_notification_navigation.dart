import 'dart:async';

import 'package:flutter/services.dart';

/// Receives the payload-free "open gallery" intent from platform notification
/// handlers and lets the active shell return to its library tab.
class GalleryNotificationNavigation {
  GalleryNotificationNavigation({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  static const _defaultChannel = MethodChannel(
    'io.github.cypas.nsoalbum/notifications',
  );

  final MethodChannel _channel;
  final List<void Function()> _listeners = [];
  bool _installed = false;
  bool _pendingOpen = false;

  void addListener(void Function() listener) {
    _listeners.add(listener);
    if (_pendingOpen) {
      _pendingOpen = false;
      scheduleMicrotask(listener);
    }
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void install() {
    if (_installed) return;
    _installed = true;
    _channel.setMethodCallHandler(_handleCall);
    unawaited(_restorePendingIntent());
  }

  Future<void> _restorePendingIntent() async {
    try {
      if (await _channel.invokeMethod<bool>('takePendingGalleryIntent') ==
          true) {
        requestOpenGallery();
      }
    } on MissingPluginException {
      // Desktop runners use notification activation rather than an Android
      // launch-intent mailbox.
    } on PlatformException {
      // A missing native mailbox must not block normal application startup.
    }
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'openGallery' || call.arguments != null) return;
    requestOpenGallery();
    try {
      await _channel.invokeMethod<void>('acknowledgeGalleryIntent');
    } on MissingPluginException {
      // Windows and macOS acknowledge through the activation callback only.
    } on PlatformException {
      // Navigation still succeeds; the next app entry can retry the mailbox.
    }
  }

  void requestOpenGallery() {
    final listeners = List<void Function()>.of(_listeners);
    if (listeners.isEmpty) {
      _pendingOpen = true;
      return;
    }
    for (final listener in listeners) {
      listener();
    }
  }

  Future<void> handleForTest(MethodCall call) => _handleCall(call);

  void dispose() {
    _installed = false;
    _listeners.clear();
    _channel.setMethodCallHandler(null);
  }
}
