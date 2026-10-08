const String appChineseName = '鱿型相册';
const String appEnglishName = 'NSOAlbum';
const String windowsExecutableName = 'NSOAlbum.exe';

String windowsPackageDirectoryName(String version) =>
    'NSOAlbum-Windows-x64-$version';

String windowsInstallerName(String version) => 'NSOAlbum-$version-Setup.exe';
