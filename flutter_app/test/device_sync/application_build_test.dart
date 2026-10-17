import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:squid_album/src/platform/device_sync_build.dart';

void main() {
  test(
    'device pairing reads both version and build from platform metadata',
    () async {
      PackageInfo.setMockInitialValues(
        appName: 'Synthetic',
        packageName: 'test.synthetic',
        version: '1.2.3',
        buildNumber: '456',
        buildSignature: '',
      );
      final build = await loadDeviceApplicationBuild();
      expect(build.version, '1.2.3');
      expect(build.buildNumber, '456');
    },
  );
  test(
    'missing platform build number never silently becomes a compatible default',
    () async {
      PackageInfo.setMockInitialValues(
        appName: 'Synthetic',
        packageName: 'test.synthetic',
        version: '1.2.3',
        buildNumber: '',
        buildSignature: '',
      );
      await expectLater(
        loadDeviceApplicationBuild(),
        throwsA(isA<StateError>()),
      );
    },
  );
}
