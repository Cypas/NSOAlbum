import 'package:flutter/services.dart';

class AndroidMediaClipboard {
  const AndroidMediaClipboard();

  static const _channel = MethodChannel(
    'io.github.cypas.nsoalbum/media_clipboard',
  );

  Future<void> copyFile(String path) async {
    await _channel.invokeMethod<void>('copyFile', {'path': path});
  }
}
