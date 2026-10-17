@Tags(['platform-windows'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _NativeChild {
  _NativeChild(this.process) {
    unawaited(process.stdin.done.catchError((Object _) {}));
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add)
        .asFuture<void>();
    final errors = process.stderr.transform(utf8.decoder).join();
    ended = () async {
      final code = await process.exitCode;
      await output;
      diagnostics = await errors;
      status = code;
      return code;
    }();
  }
  final Process process;
  final lines = <String>[];
  late final Future<int> ended;
  int? status;
  String diagnostics = '';
  Future<void> waitFor(String text) async {
    final until = DateTime.now().add(const Duration(seconds: 10));
    while (!lines.contains(text)) {
      if (status != null || DateTime.now().isAfter(until)) {
        fail('Missing $text: $lines; exit=$status; $diagnostics');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> stop() async {
    if (status != null) return;
    try {
      process.stdin.writeln('close');
    } on SocketException {
      // The child can exit between the status snapshot and this owned pipe.
    }
    try {
      await ended.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
      await ended;
    }
  }
}

void main() {
  group(
    'native pre-engine instance owner',
    () {
      late String executable;
      late Directory scope;
      final children = <_NativeChild>[];
      setUpAll(() async {
        final root = await Directory.systemTemp.createTemp(
          'nsoalbum-native-instance-',
        );
        stdout.writeln('Retained native fixture: ${root.path}');
        final vswhere = p.join(
          Platform.environment['ProgramFiles(x86)']!,
          'Microsoft Visual Studio',
          'Installer',
          'vswhere.exe',
        );
        final studio = await Process.run(vswhere, [
          '-latest',
          '-products',
          '*',
          '-requires',
          'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
          '-property',
          'installationPath',
        ]);
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
        final build = p.join(root.path, 'build');
        for (final args in [
          [
            '-S',
            p.absolute('test/fixtures/desktop_instance/native'),
            '-B',
            build,
            '-A',
            'x64',
            '-DNSOALBUM_RUNNER_DIR=${p.absolute('windows/runner').replaceAll(r'\', '/')}',
          ],
          ['--build', build, '--config', 'Debug'],
        ]) {
          final result = await Process.run(
            cmake,
            args,
          ).timeout(const Duration(seconds: 60));
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
        }
        executable = p.join(build, 'Debug', 'instance_fixture.exe');
      });
      setUp(() async {
        scope = await Directory.systemTemp.createTemp('nsoalbum-native-scope-');
      });
      tearDown(() async {
        for (final child in children.reversed) {
          await child.stop();
        }
        children.clear();
      });
      Future<_NativeChild> start([String mode = 'hidden']) async {
        final child = _NativeChild(
          await Process.start(executable, [scope.path, mode]),
        );
        children.add(child);
        return child;
      }

      for (final mode in ['hidden', 'minimized']) {
        test(
          '$mode owner is restored without a second business initialization',
          () async {
            final first = await start(mode);
            await first.waitFor('business-started');
            final second = await start();
            expect(await second.ended, 0, reason: second.diagnostics);
            expect(second.lines, ['secondary']);
            await first.waitFor('activated');
            await first.waitFor('restored');
            expect(
              first.lines.where((s) => s == 'business-started'),
              hasLength(1),
            );
            expect(first.status, isNull);
          },
        );
      }
      test(
        'simultaneous launches elect one owner before business begins',
        () async {
          final launched = await Future.wait(
            List.generate(5, (_) => start('delayed')),
          );
          final until = DateTime.now().add(const Duration(seconds: 10));
          while (launched
                  .where((c) => c.lines.contains('business-started'))
                  .isEmpty &&
              DateTime.now().isBefore(until)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          final owners = launched
              .where((c) => c.lines.contains('business-started'))
              .toList();
          expect(owners, hasLength(1));
          for (final child in launched.where(
            (c) => !identical(c, owners.single),
          )) {
            expect(await child.ended, 0, reason: child.diagnostics);
            expect(child.lines, ['secondary']);
          }
        },
      );
      test(
        'OS releases owner after crash without deleting the lock file',
        () async {
          final first = await start();
          await first.waitFor('business-started');
          first.process.kill();
          await first.ended;
          expect(File(p.join(scope.path, 'owner.lock')).existsSync(), isTrue);
          final replacement = await start();
          await replacement.waitFor('business-started');
        },
      );
      test('normal close permits a later owner', () async {
        final first = await start();
        await first.waitFor('business-started');
        await first.stop();
        expect(await first.ended, 0);
        await (await start()).waitFor('business-started');
      });
      test(
        'held lock without a live window fails closed before business',
        () async {
          final first = await start('holder');
          await first.waitFor('primary');
          final second = await start();
          expect(await second.ended, 73);
          expect(second.lines, isEmpty);
          expect(first.status, isNull);
        },
      );
    },
    skip: Platform.isWindows
        ? false
        : 'Requires the actual Win32 instance owner and C++ toolchain',
  );
}
