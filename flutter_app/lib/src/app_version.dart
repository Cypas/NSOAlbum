import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

String formatApplicationVersionForDisplay(
  String version, {
  bool debugMode = kDebugMode,
}) => debugMode ? '$version Debug' : version;

String formatPackageVersion(String version, String buildNumber) {
  final normalizedBuild = buildNumber.trim();
  return '$version+${normalizedBuild.isEmpty ? '0' : normalizedBuild}';
}

Future<String> loadApplicationVersion() async {
  final info = await PackageInfo.fromPlatform();
  return formatPackageVersion(info.version, info.buildNumber);
}
