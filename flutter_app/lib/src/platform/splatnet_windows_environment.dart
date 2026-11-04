import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Compatibility for the environment channel-ID defect in Windows 0.6.0.
class SplatNetWindowsEnvironment {
  SplatNetWindowsEnvironment._(this.webViewEnvironment, this._factoryId);

  final WebViewEnvironment webViewEnvironment;
  final String _factoryId;
  Future<void>? _cleanup;

  static Future<SplatNetWindowsEnvironment> create({
    WebViewEnvironmentSettings? settings,
  }) async => SplatNetWindowsEnvironment._(
    await WebViewEnvironment.create(settings: settings),
    PlatformWebViewEnvironment.static().id,
  );

  Future<void> dispose() => _cleanup ??= () async {
    // The pinned create() uses the factory ID for its Dart channel, while
    // native creation registers the returned environment's actual ID.
    await MethodChannel(
          'com.pichillilorenzo/flutter_webview_environment_${webViewEnvironment.id}',
        )
        .invokeMethod<void>('dispose', <String, Object?>{})
        .timeout(const Duration(seconds: 30));
    MethodChannel('com.pichillilorenzo/flutter_webview_environment_$_factoryId')
        .setMethodCallHandler(null);
  }();
}
