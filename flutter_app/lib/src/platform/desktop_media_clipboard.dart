import 'package:flutter/services.dart';

class DesktopMediaClipboard {
  const DesktopMediaClipboard();

  static const _channel = MethodChannel(
    'io.github.cypas.nsoalbum/desktop_media_clipboard',
  );

  Future<void> copyFile(String path) async {
    await _channel.invokeMethod<void>('copyFile', {'path': path});
  }
}
