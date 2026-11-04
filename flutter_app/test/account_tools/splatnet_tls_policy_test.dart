import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/splatnet_tls_policy.dart';

void main() {
  test(
    'macOS delegates HTTPS certificate challenges to system validation',
    () async {
      expect(await splatNetServerTrustResponse(platform: 'macos'), isNull);
    },
  );

  test(
    'certificate error callbacks never authorize an untrusted server',
    () async {
      for (final platform in ['windows', 'android']) {
        final response = await splatNetServerTrustResponse(platform: platform);
        expect(response?.action, ServerTrustAuthResponseAction.CANCEL);
      }
    },
  );
}
