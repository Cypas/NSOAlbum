@Tags(['platform-windows'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'temporary IME context restores the original context before destruction',
    () async {
      if (!Platform.isWindows) return;
      final buildRoot =
          Platform.environment['NSOALBUM_BUILD_ROOT'] ??
          Platform.environment['RUNNER_TEMP'] ??
          p.join(Directory.systemTemp.path, 'nsoalbum-native-fixtures');
      final build = p.join(buildRoot, 'tools', 'ime-context-fixture');
      await Directory(build).create(recursive: true);
      final visualStudio = Platform.environment['ProgramFiles(x86)'];
      if (visualStudio == null) {
        fail('Visual Studio is required for the IME association fixture.');
      }
      final studio = await Process.run(
        p.join(
          visualStudio,
          'Microsoft Visual Studio',
          'Installer',
          'vswhere.exe',
        ),
        [
          '-latest',
          '-products',
          '*',
          '-requires',
          'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
          '-property',
          'installationPath',
        ],
      );
      expect(studio.exitCode, 0, reason: '${studio.stderr}');
      final cmake = p.join(
        studio.stdout.toString().trim(),
        'Common7',
        'IDE',
        'CommonExtensions',
        'Microsoft',
        'CMake',
        'CMake',
        'bin',
        'cmake.exe',
      );
      final fixture = p.absolute('test/fixtures/windows/ime_association');
      for (final arguments in [
        [
          '-S',
          fixture,
          '-B',
          build,
          '-A',
          'x64',
          '-DNSOALBUM_RUNNER_DIR=${p.absolute('windows/runner').replaceAll(r'\', '/')}',
        ],
        ['--build', build, '--config', 'Debug'],
      ]) {
        final result = await Process.run(cmake, arguments);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      }
      final result = await Process.run(
        p.join(build, 'Debug', 'ime_context_association_fixture.exe'),
        const [],
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout.toString().trim(), 'IME_ASSOCIATION_PASS restore');
    },
    skip: Platform.isWindows ? false : 'Requires the Windows C++ toolchain; no real IME or user text is used.',
  );
}
