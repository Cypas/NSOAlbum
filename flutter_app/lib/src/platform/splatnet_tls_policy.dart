import 'package:flutter_inappwebview/flutter_inappwebview.dart';

Future<ServerTrustAuthResponse?> splatNetServerTrustResponse({
  required String platform,
}) async => platform == 'macos'
    // WKWebView reports ordinary HTTPS challenges here too. Null preserves
    // system trust validation, including rejection of invalid certificates.
    ? null
    : ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.CANCEL);
