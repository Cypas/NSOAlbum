import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/app_branding.dart';

void main() {
  test('English product branding and Windows artifacts use NSOAlbum', () {
    expect(appEnglishName, 'NSOAlbum');
    expect(appChineseName, '鱿型相册');
    expect(windowsExecutableName, 'NSOAlbum.exe');
    expect(windowsPackageDirectoryName('0.2.0'), 'NSOAlbum-Windows-x64-0.2.0');
    expect(windowsInstallerName('0.2.0'), 'NSOAlbum-0.2.0-Setup.exe');
  });
}
