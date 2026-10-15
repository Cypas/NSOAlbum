import 'package:flutter/services.dart';

abstract final class SplatNetMacNetwork {
  static const _channel = MethodChannel('io.github.cypas.nsoalbum/splatnet_network');

  static Future<void> configure(Uri? proxy) async {
    final configured = await _channel.invokeMethod<bool>('configure', {
      'host': proxy?.host,
      'port': proxy?.port,
    });
    if (configured != true) {
      throw UnsupportedError('splatnet_proxy_unavailable');
    }
  }

  static Future<void> clear() async {
    await _channel.invokeMethod<bool>('clear');
  }
}
