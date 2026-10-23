@Tags(['common'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final bash = Platform.isWindows
      ? r'C:\Program Files\Git\bin\bash.exe'
      : '/bin/bash';
  final skip = File(bash).existsSync()
      ? false
      : 'Requires Bash for synthetic macOS packaging command-order tests';
  late Directory root;
  late Directory project;
  late Directory app;
  late File log;
  late Map<String, String> environment;
  String shellPath(String value) {
    final normalized = value.replaceAll(r'\', '/');
    if (Platform.isWindows && normalized.length > 2 && normalized[1] == ':') {
      return '/${normalized[0].toLowerCase()}${normalized.substring(2)}';
    }
    return normalized;
  }

  Future<File> write(String relative, String content) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    return file.writeAsString(content);
  }

  setUp(() async {
    final tempRoot = Directory(
      Platform.environment['NSO_TEST_TEMP_ROOT'] ?? Directory.systemTemp.path,
    );
    root = await tempRoot.createTemp('nso-mac-mtp-synthetic-');
    project = Directory(p.join(root.path, 'flutter_app'));
    app = Directory(
      p.join(project.path, 'build/macos/Build/Products/Release/NSOAlbum.app'),
    );
    log = File(p.join(root.path, 'commands.log'));
    for (final script in [
      'package_macos.sh',
      'sign_macos_app.sh',
      'macos_rpaths.sh',
      'configure_macos_renderer.sh',
      'build_macos_cached.sh',
      'build_macos_mtp_worker.sh',
    ]) {
      final source = await File(p.absolute('tool', script)).readAsString();
      await write(
        'flutter_app/tool/$script',
        source
            .replaceAll('/usr/libexec/PlistBuddy', 'PlistBuddy')
            .replaceAll('/usr/bin/plutil', 'plutil'),
      );
    }
    await write(
      'flutter_app/tool/run_release_smoke.dart',
      '// OS boundary fixture\n',
    );
    await write('flutter_app/.dart_tool/package_config.json', '{}');
    await write('flutter_app/macos/Runner/Release.entitlements', '<plist/>');
    await write('LICENSE', 'fixture MIT');
    await write('docs/legal/THIRD-PARTY-NOTICES.md', 'fixture notices');
    await write('docs/legal/ASSET-ATTRIBUTION.md', 'fixture assets');
    await Directory(p.join(app.path, 'Contents/MacOS')).create(recursive: true);
    await Directory(p.join(app.path, 'Contents/Frameworks')).create();
    await File(p.join(app.path, 'Contents/Info.plist'))
        .writeAsString('<plist/>');
    await File(p.join(app.path, 'Contents/MacOS/NSOAlbum'))
        .writeAsString('#!/bin/sh\nexit 0\n');
    await File(p.join(app.path, 'Contents/Frameworks/libfixture.dylib'))
        .writeAsString('fixture dylib');
    final seed = await write(
      'seed-worker',
      '#!/bin/sh\n# synthetic helper before signing\n',
    );
    final fake = await File(
      p.absolute('test/fixtures/ci/fake_macos_mtp_tools.sh'),
    ).readAsString();
    for (final tool in [
      'uname',
      'flutter',
      'dart',
      'PlistBuddy',
      'file',
      'lipo',
      'otool',
      'install_name_tool',
      'codesign',
      'plutil',
      'ditto',
      'hdiutil',
      'ln',
      'shasum',
    ]) {
      await write('bin/$tool', fake);
    }
    await write('sdk/bin/cache/dart-sdk/bin/dart', fake);
    await Directory(p.join(root.path, 'state')).create();
    await Directory(p.join(root.path, 'tmp')).create();
    environment = {
      'FLUTTER_ROOT': shellPath(p.join(root.path, 'sdk')),
      'NSO_SWIFTPM_ARTIFACTS': shellPath(p.join(root.path, 'cache')),
      'TMPDIR': shellPath(p.join(root.path, 'tmp')),
      'NSO_FAKE_ROOT': shellPath(root.path),
      'NSO_FAKE_PROJECT': shellPath(project.path),
      'NSO_FAKE_APP': shellPath(app.path),
      'NSO_FAKE_LOG': shellPath(log.path),
      'NSO_FAKE_STATE': shellPath(p.join(root.path, 'state')),
      'NSO_FAKE_SEED': shellPath(seed.path),
      'NSO_FAKE_FAIL': '',
      'NSO_FAKE_ARCH': 'arm64',
    };
    final permissions = await Process.run(bash, [
      '-c',
      'chmod +x "\$NSO_FAKE_PROJECT/build/macos/Build/Products/Release/NSOAlbum.app/Contents/MacOS/NSOAlbum" '
          '"\$NSO_FAKE_PROJECT/build/macos/Build/Products/Release/NSOAlbum.app/Contents/Frameworks/libfixture.dylib" '
          '"\$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" "\$NSO_FAKE_ROOT/bin/"*',
    ], environment: environment);
    expect(permissions.exitCode, 0, reason: '${permissions.stderr}');
  });
  tearDown(() => root.delete(recursive: true));

  Future<ProcessResult> run({
    bool reuse = false,
    bool buildOnly = true,
    String fail = '',
  }) async {
    final process = await Process.start(
      bash,
      [
        '-c',
        'export PATH="\$NSO_FAKE_ROOT/bin:\$PATH"; exec bash "\$@"',
        '--',
        shellPath(p.join(project.path, 'tool/package_macos.sh')),
        '--architecture',
        'arm64',
        '--version',
        '0.2.14',
        '--build-number',
        '47',
        '--reports',
        shellPath(p.join(root.path, reuse ? 'reuse-reports' : 'reports')),
        if (reuse) ...[
          '--reuse-app',
          shellPath(app.path),
        ] else if (buildOnly)
          '--build-only',
      ],
      environment: {...environment, 'NSO_FAKE_FAIL': fail},
    );
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    var exited = false;
    late int code;
    try {
      code = await process.exitCode.timeout(const Duration(minutes: 1));
      exited = true;
    } finally {
      if (!exited) {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    }
    return ProcessResult(process.pid, code, await output, await errors);
  }

  test(
    'synthetic build copies and sanitizes helper before inside-out signing',
    () async {
      final result = await run();
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final commands = await log.readAsLines();
      final helperSign = commands.indexWhere(
        (line) =>
            line.startsWith('codesign --force') &&
            line.endsWith('/nsoalbum_mtp_worker'),
      );
      final rootSign = commands.indexWhere(
        (line) =>
            line.startsWith('codesign --force') &&
            line.endsWith('/NSOAlbum.app'),
      );
      final sanitizers = commands.asMap().entries.where(
        (entry) => entry.value.startsWith('install_name_tool '),
      );
      expect(sanitizers.length, 3);
      expect(sanitizers.every((entry) => entry.key < helperSign), isTrue);
      expect(helperSign, greaterThan(0));
      expect(rootSign, greaterThan(helperSign));
      expect(
        await File(p.join(app.path, 'Contents/MacOS/nsoalbum_mtp_worker'))
            .readAsString(),
        endsWith('signed\n'),
      );
      expect(
        File(p.join(root.path, 'reports/nsoalbum-mtp-worker.final.json'))
            .existsSync(),
        isTrue,
      );
    },
    skip: skip,
  );

  test(
    'synthetic reuse never builds repairs or re-signs the sealed helper',
    () async {
      final built = await run();
      expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
      final finalRecord = File(
        p.join(root.path, 'reports/nsoalbum-mtp-worker.final.json'),
      );
      await finalRecord.copy(
        p.join(app.parent.path, 'nsoalbum-mtp-worker.final.json'),
      );
      final worker = File(
        p.join(app.path, 'Contents/MacOS/nsoalbum_mtp_worker'),
      );
      final before = (await sha256.bind(worker.openRead()).first).toString();
      final boundary = (await log.readAsLines()).length;
      final result = await run(reuse: true);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final commands = (await log.readAsLines()).skip(boundary);
      expect(
        commands.any(
          (line) =>
              line.startsWith('flutter ') ||
              line.startsWith('install_name_tool ') ||
              line.startsWith('codesign --force') ||
              line.contains('build_desktop_native.dart'),
        ),
        isFalse,
      );
      expect((await sha256.bind(worker.openRead()).first).toString(), before);
    },
    skip: skip,
  );

  test('a busy temporary DMG mount retries with scoped forced detach and reports the cause', () async {
    final result = await run(buildOnly: false, fail: 'detach-once');
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stderr, contains('Resource busy'));
    final commands = await log.readAsLines();
    final detachCalls = commands.where(
      (line) => line.startsWith('hdiutil detach'),
    );
    expect(detachCalls.length, 2);
    expect(detachCalls.first, contains('nsoalbum-dmg.'));
    expect(detachCalls.last, contains('-force'));
    expect(
      File(p.join(root.path, 'dist/NSOAlbum-macOS-arm64-0.2.14.dmg'))
          .existsSync(),
      isTrue,
    );
  }, skip: skip);

  for (final failure in [
    'build',
    'wrong-arch',
    'sign-helper',
    'final-record',
  ]) {
    test('synthetic $failure remains a nonzero packaging failure', () async {
      final result = await run(fail: failure);
      expect(result.exitCode, isNot(0), reason: '${result.stdout}');
      final commands = await log.readAsLines();
      expect(
        commands.any((line) => line.contains('build_desktop_native.dart')),
        isTrue,
      );
      if (failure == 'wrong-arch') {
        expect(result.stderr, contains('MTP helper architecture differs'));
      } else if (failure == 'sign-helper') {
        expect(
          commands.any(
            (line) =>
                line.startsWith('codesign --force') &&
                line.endsWith('/nsoalbum_mtp_worker'),
          ),
          isTrue,
        );
        expect(
          commands.any(
            (line) =>
                line.startsWith('codesign --force') &&
                line.endsWith('/NSOAlbum.app'),
          ),
          isFalse,
        );
      } else if (failure == 'final-record') {
        expect(commands.any((line) => line.contains('--write-record')), isTrue);
      }
    }, skip: skip);
  }

  test(
    'synthetic ordinary Runner signs its helper in every Flutter configuration',
    () async {
      for (final configuration in ['Debug', 'Profile', 'Release']) {
        final result = await Process.run(
          bash,
          [
            '-c',
            'export PATH="\$NSO_FAKE_ROOT/bin:\$PATH"; exec bash "\$@"',
            '--',
            shellPath(p.join(project.path, 'tool/build_macos_mtp_worker.sh')),
          ],
          environment: {
            ...environment,
            'CONFIGURATION': configuration,
            'ARCHS': 'arm64',
            'TARGET_BUILD_DIR': shellPath(app.parent.path),
            'EXECUTABLE_FOLDER_PATH': 'NSOAlbum.app/Contents/MacOS',
            'TARGET_TEMP_DIR': shellPath(p.join(root.path, 'state')),
            'CODE_SIGNING_ALLOWED': 'YES',
            'EXPANDED_CODE_SIGN_IDENTITY': '-',
          },
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      }
      final commands = await log.readAsLines();
      for (final configuration in ['Debug', 'Profile', 'Release']) {
        expect(
          commands
              .where(
                (line) =>
                    line.startsWith('dart ') &&
                    line.contains('--configuration $configuration'),
              )
              .length,
          1,
        );
      }
      expect(
        commands
            .where(
              (line) =>
                  line.startsWith('codesign --force') &&
                  line.endsWith('/nsoalbum_mtp_worker'),
            )
            .length,
        3,
      );
    },
    skip: skip,
  );

  test(
    'synthetic normal Runner accepts the default two-architecture ARCHS',
    () async {
      final result = await Process.run(
        bash,
        [
          '-c',
          'export PATH="\$NSO_FAKE_ROOT/bin:\$PATH"; exec bash "\$@"',
          '--',
          shellPath(p.join(project.path, 'tool/build_macos_mtp_worker.sh')),
        ],
        environment: {
          ...environment,
          'CONFIGURATION': 'Release',
          'ARCHS': 'x86_64 arm64',
          'TARGET_BUILD_DIR': shellPath(app.parent.path),
          'EXECUTABLE_FOLDER_PATH': 'NSOAlbum.app/Contents/MacOS',
          'TARGET_TEMP_DIR': shellPath(p.join(root.path, 'state')),
          'CODE_SIGNING_ALLOWED': 'NO',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        File(p.join(app.path, 'Contents/MacOS/nsoalbum_mtp_worker'))
            .existsSync(),
        isTrue,
      );
    },
    skip: skip,
  );

  test(
    'synthetic reuse with missing helper does not rebuild or repair it',
    () async {
      final built = await run();
      expect(built.exitCode, 0, reason: '${built.stderr}');
      await File(p.join(root.path, 'reports/nsoalbum-mtp-worker.final.json'))
          .copy(p.join(app.parent.path, 'nsoalbum-mtp-worker.final.json'));
      await File(p.join(app.path, 'Contents/MacOS/nsoalbum_mtp_worker'))
          .delete();
      final boundary = (await log.readAsLines()).length;
      final result = await run(reuse: true);
      expect(result.exitCode, isNot(0));
      expect(
        File(p.join(app.path, 'Contents/MacOS/nsoalbum_mtp_worker'))
            .existsSync(),
        isFalse,
      );
      expect(
        (await log.readAsLines())
            .skip(boundary)
            .any(
              (line) =>
                  line.startsWith('flutter ') ||
                  line.startsWith('codesign --force'),
            ),
        isFalse,
      );
    },
    skip: skip,
  );
}
