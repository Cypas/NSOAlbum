@Tags(['native-android'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final enabled = Platform.environment['NSO_VERIFY_ANDROID_BUILD'] == '1';
  const skipReason =
      'Requires Android SDK/JDK, a prepared Gradle wrapper, and '
      'NSO_VERIFY_ANDROID_BUILD=1';

  test(
    'final Release APK includes INTERNET without requesting broad storage or background privileges',
    () async {
      final wrapper = p.absolute(
        'android',
        Platform.isWindows ? 'gradlew.bat' : 'gradlew',
      );
      expect(
        File(wrapper).existsSync(),
        isTrue,
        reason: 'Prepare the Android Gradle wrapper before native tests.',
      );
      final result = await Process.run(
        wrapper,
        [
          '-Ptarget-platform=android-arm64',
          '--init-script',
          p.absolute('test/fixtures/android/verify_arm64.gradle'),
          'verifyAndroidReleaseApkPermissions',
          '--console=plain',
        ],
        workingDirectory: p.absolute('android'),
        runInShell: Platform.isWindows,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    skip: enabled ? false : skipReason,
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'Release can access Nintendo and NXAPI without debug manifest permissions',
    () async {
      final result = await Process.run(
        p.absolute('android', Platform.isWindows ? 'gradlew.bat' : 'gradlew'),
        [
          '-Ptarget-platform=android-arm64',
          '--init-script',
          p.absolute('test/fixtures/android/verify_arm64.gradle'),
          'verifyAndroidReleaseNetworkPermission',
          '--console=plain',
        ],
        workingDirectory: p.absolute('android'),
        runInShell: Platform.isWindows,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    skip: enabled ? false : skipReason,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'real Android configuration packages and compiles only ARM64',
    () async {
      final wrapper = p.absolute(
        'android',
        Platform.isWindows ? 'gradlew.bat' : 'gradlew',
      );
      expect(
        File(wrapper).existsSync(),
        isTrue,
        reason:
            'Flutter has not prepared the Android Gradle wrapper. '
            'Run flutter build apk --debug --target-platform android-arm64 '
            'before enabling this native configuration test.',
      );
      final result = await Process.run(
        wrapper,
        [
          '-Ptarget-platform=android-arm64',
          '--init-script',
          p.absolute('test/fixtures/android/verify_arm64.gradle'),
          'verifyArm64BuildConfiguration',
          '--console=plain',
        ],
        workingDirectory: p.absolute('android'),
        runInShell: Platform.isWindows,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    skip: enabled ? false : skipReason,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'Android build resolves the NSOAlbum identity to a compiled launcher',
    () async {
      final wrapper = p.absolute(
        'android',
        Platform.isWindows ? 'gradlew.bat' : 'gradlew',
      );
      expect(
        File(wrapper).existsSync(),
        isTrue,
        reason: 'Prepare the Android Gradle wrapper before native tests.',
      );
      final result = await Process.run(
        wrapper,
        [
          '-Ptarget-platform=android-arm64',
          '--init-script',
          p.absolute('test/fixtures/android/verify_arm64.gradle'),
          'verifyAndroidApplicationIdentity',
          '--console=plain',
        ],
        workingDirectory: p.absolute('android'),
        runInShell: Platform.isWindows,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    skip: enabled ? false : skipReason,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'Android linked resources expose localized names and launcher icons',
    () async {
      final wrapper = p.absolute(
        'android',
        Platform.isWindows ? 'gradlew.bat' : 'gradlew',
      );
      expect(
        File(wrapper).existsSync(),
        isTrue,
        reason: 'Prepare the Android Gradle wrapper before native tests.',
      );
      final result = await Process.run(
        wrapper,
        [
          '-Ptarget-platform=android-arm64',
          '--init-script',
          p.absolute('test/fixtures/android/verify_arm64.gradle'),
          'verifyAndroidLocalizedBranding',
          '--console=plain',
        ],
        workingDirectory: p.absolute('android'),
        runInShell: Platform.isWindows,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    skip: enabled ? false : skipReason,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
