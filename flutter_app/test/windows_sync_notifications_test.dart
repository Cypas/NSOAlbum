@Tags(['platform-windows'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group(
    'Windows native notification content',
    () {
      late String executable;
      setUpAll(() async {
        final build = Directory(
          p.join(
            Directory.systemTemp.path,
            'nsoalbum-sync-notification-native',
          ),
        );
        await build.create(recursive: true);
        final studio = await Process.run(
          p.join(
            Platform.environment['ProgramFiles(x86)']!,
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
            p.absolute('test/fixtures/notifications/native'),
            '-B',
            build.path,
            '-A',
            'x64',
            '-DNSOALBUM_RUNNER_DIR=${p.absolute('windows/runner').replaceAll(r'\', '/')}',
          ],
          ['--build', build.path, '--config', 'Debug'],
        ]) {
          final result = await Process.run(cmake, arguments);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
        }
        executable = p.join(
          build.path,
          'Debug',
          'sync_notification_fixture.exe',
        );
      });

      for (final scenario in ['content', 'invalid']) {
        test(
          scenario == 'content'
              ? 'localized summaries are DOM text, including XML delimiters'
              : 'invalid UTF-8, empty and oversized summaries are rejected',
          () async {
            final result = await Process.run(executable, [scenario]);
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}\n${result.stderr}',
            );
            expect(
              result.stdout.toString().trim(),
              'SYNC_NOTIFICATION_NATIVE_PASS $scenario',
            );
          },
        );
      }
      for (final scenario in ['activation', 'retired']) {
        test(
          scenario == 'activation'
              ? 'COM worker callback only queues a payload-free owner activation'
              : 'callbacks retained beyond window retirement become inert',
          () async {
            final result = await Process.run(executable, [
              scenario,
              p.join(p.dirname(executable), 'activation-scope'),
            ]);
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}\n${result.stderr}',
            );
            expect(
              result.stdout.toString().trim(),
              'SYNC_NOTIFICATION_NATIVE_PASS $scenario',
            );
          },
        );
      }
    },
    skip: !Platform.isWindows
        ? 'Requires Windows SDK and native WinRT XML DOM; no toast is sent.'
        : false,
  );
}
