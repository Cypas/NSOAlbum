import 'dart:io';

import 'package:squid_album/src/startup/ci_smoke_contract.dart';

/// Every diagnostic run owns a fresh root; callers cannot redirect to a library.
Future<Directory> createDeviceSyncQaRoot() async {
  final root = await Directory.systemTemp.createTemp('nsoalbum-device-qa-');
  final canonical = Directory(await root.resolveSymbolicLinks());
  await CiSmokeRoot.claim(canonical.path);
  return canonical;
}
