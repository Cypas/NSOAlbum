@Tags(['platform-android', 'native-android'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'native exchange policy bounds scopes streams acknowledgements and stale callbacks',
    () async {
      final result = await Process.run(
        p.absolute('android', Platform.isWindows ? 'gradlew.bat' : 'gradlew'),
        [
          '-Ptarget-platform=android-arm64',
          '--init-script',
          p.absolute('test/fixtures/android/verify_device_sync.gradle'),
          'verifyDeviceSyncPolicy',
          '--console=plain',
        ],
        workingDirectory: p.absolute('android'),
        runInShell: Platform.isWindows,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('DeviceSyncPolicyTest PASS'));
    },
    skip: Platform.environment['NSO_VERIFY_ANDROID_BUILD'] == '1'
        ? false
        : 'Requires SDK/JDK and NSO_VERIFY_ANDROID_BUILD=1; no concurrent native build',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
