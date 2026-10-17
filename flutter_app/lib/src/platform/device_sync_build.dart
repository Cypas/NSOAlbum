import 'package:package_info_plus/package_info_plus.dart';

import '../rust/device_sync/connection.dart';

Future<ApplicationBuild> loadDeviceApplicationBuild() async {
  final info = await PackageInfo.fromPlatform();
  if (info.version.isEmpty || info.buildNumber.isEmpty) {
    throw StateError('Application version metadata is unavailable');
  }
  return ApplicationBuild(version: info.version, buildNumber: info.buildNumber);
}
