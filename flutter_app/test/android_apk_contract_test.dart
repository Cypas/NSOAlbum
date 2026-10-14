import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'Android APK contract rejects unsafe native payloads and manifests',
    () async {
      final result = await Process.run('pwsh', [
        '-NoProfile',
        '-File',
        p.absolute('test/fixtures/android/apk_contract_test.ps1'),
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('Android APK contract tests passed'));
    },
  );
}
