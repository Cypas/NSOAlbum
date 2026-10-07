import 'package:package_info_plus/package_info_plus.dart';

String formatPackageVersion(String version, String buildNumber) {
  final normalizedBuild = buildNumber.trim();
  return '$version+${normalizedBuild.isEmpty ? '0' : normalizedBuild}';
}

Future<String> loadApplicationVersion() async {
  final info = await PackageInfo.fromPlatform();
  return formatPackageVersion(info.version, info.buildNumber);
}
