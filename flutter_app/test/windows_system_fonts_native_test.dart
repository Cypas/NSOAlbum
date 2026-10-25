@Tags(['platform-windows'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'registry-relative fonts resolve user paths before the system fallback',
    () async {
      if (!Platform.isWindows) return;

      final fixture = p.absolute('test/fixtures/windows/system_fonts');
      final root =
          Platform.environment['NSOALBUM_BUILD_ROOT'] ??
          (Platform.environment.containsKey('CI')
              ? Directory.systemTemp.path
              : r'C:\Users\cypas\.codex\tmp\nsoalbum-multiplatform-remainder-20261021');
      final build = p.join(root, 'tools', 'system-fonts-fixture');
      await Directory(build).create(recursive: true);
      final visualStudio = Platform.environment['ProgramFiles(x86)'];
      if (visualStudio == null) {
        fail('Visual Studio is required for the Windows font-path fixture.');
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
      final data = p.join(
        build,
        'fixture-data-${DateTime.now().microsecondsSinceEpoch}',
      );
      final executable = p.join(build, 'Debug', 'system_font_path_fixture.exe');
      final result = await Process.run(executable, [data]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout.toString().trim(), 'SYSTEM_FONT_PATH_PASS all');
    },
    skip: Platform.isWindows
        ? false
        : 'Requires the Windows C++ toolchain; no user font files are read.',
  );
}
