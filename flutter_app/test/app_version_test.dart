import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:squid_album/src/app_version.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('formats the platform version with its build number', () {
    expect(formatPackageVersion('0.1.29', '30'), '0.1.29+30');
  });

  test('loads the version and build number from platform metadata', () async {
    PackageInfo.setMockInitialValues(
      appName: 'NSOAlbum',
      packageName: 'io.squidalbum',
      version: '2.4.6',
      buildNumber: '135',
      buildSignature: '',
    );

    expect(await loadApplicationVersion(), '2.4.6+135');
  });
}
