import 'dart:convert';

/// Security policy for the one site allowed to receive a game-web credential.
abstract final class SplatNetPolicy {
  static const origin = 'https://api.lp1.av5ja.srv.nintendo.net';

  static bool isOfficial(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'api.lp1.av5ja.srv.nintendo.net' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;

  static Uri? externalUrl(Uri uri) =>
      uri.scheme == 'https' && uri.host.isNotEmpty && uri.userInfo.isEmpty
      ? Uri(scheme: 'https', host: uri.host, port: uri.port, path: uri.path)
      : null;

  static Uri entryUrl(String language, String country) => Uri.parse(origin)
      .replace(
        path: '/',
        queryParameters: {
          'lang': language == 'zh' ? 'zh-CN' : 'en-US',
          'na_lang': language == 'zh' ? 'zh-CN' : 'en-US',
          'na_country': country,
        },
      );

  // The channel returns no credential. The native caller delivers a token only
  // to this exact top-level origin, with a second check inside the evaluation.
  static const bootstrapScript =
      '''
(function () {
  if (window !== window.top ||
      window.location.origin !== '$origin') return;
  const request = function () {
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('nsoRequestGameWebToken');
    }
  };
  window.requestGameWebToken = request;
  if (window.vh) window.vh.requestGameWebToken = request;
})();
''';

  static String deliverScript(String token) =>
      '''
(function () {
  if (window !== window.top ||
      window.location.origin !== '$origin') return;
  if (typeof window.onGameWebTokenReceive === 'function') {
    window.onGameWebTokenReceive.call(null, ${jsonEncode(token)});
  }
})();
''';
}

class SplatNetPageLease {
  SplatNetPageLease._(this.accountId, this._generation);
  static int _currentGeneration = 0;
  final String accountId;
  final int _generation;
  bool _released = false;

  static SplatNetPageLease acquire(String accountId) =>
      SplatNetPageLease._(accountId, ++_currentGeneration);

  bool validFor(String accountId) =>
      !_released &&
      _generation == _currentGeneration &&
      this.accountId == accountId;

  void release() => _released = true;
}

class SplatNetProxyConfiguration {
  const SplatNetProxyConfiguration._(this.proxy, this.windowsArguments);
  final Uri? proxy;
  final String? windowsArguments;

  static SplatNetProxyConfiguration resolve({
    required String platform,
    required String? proxyUrl,
  }) {
    if (platform == 'android' || proxyUrl == null || proxyUrl.trim().isEmpty) {
      return const SplatNetProxyConfiguration._(null, null);
    }
    final proxy = Uri.tryParse(proxyUrl.trim());
    if (proxy == null ||
        !['http', 'https'].contains(proxy.scheme) ||
        proxy.host.isEmpty ||
        proxy.userInfo.isNotEmpty ||
        proxy.hasQuery ||
        proxy.hasFragment ||
        !['', '/'].contains(proxy.path) ||
        RegExp(r'[\s"\\]').hasMatch(proxy.host) ||
        (platform == 'macos' && proxy.scheme != 'http')) {
      throw UnsupportedError('splatnet_proxy_unsupported');
    }
    final host = proxy.host.contains(':') ? '[${proxy.host}]' : proxy.host;
    return SplatNetProxyConfiguration._(
      proxy,
      platform == 'windows'
          ? '--proxy-server=${proxy.scheme}://$host:${proxy.port}'
          : null,
    );
  }
}
