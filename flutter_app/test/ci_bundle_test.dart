import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  const commit = '0123456789012345678901234567890123456789';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nso-ci-bundle-');
    await Directory(p.join(root.path, 'data')).create();
    await File(p.join(root.path, 'NSOAlbum.exe')).writeAsString('fixture exe');
    await File(p.join(root.path, 'data', 'app.so'))
        .writeAsString('fixture aot');
  });
  tearDown(() => root.delete(recursive: true));

  Future<ProcessResult> run(
    String mode, {
    String sha = commit,
    String platform = 'windows-x64',
    String version = '0.2.14',
    String build = '47',
    Directory? directory,
  }) => Process.run('pwsh', [
    '-NoProfile',
    '-File',
    p.absolute('tool/ci_bundle.ps1'),
    '-Mode',
    mode,
    '-Directory',
    (directory ?? root).path,
    '-Commit',
    sha,
    '-Platform',
    platform,
    '-Version',
    version,
    '-BuildNumber',
    build,
  ]);

  Future<void> seal() async {
    final result = await run('Seal');
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  test(
    'sealed bundle verifies exact metadata and nested file content',
    () async {
      await seal();
      final result = await run('Verify');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final manifest = jsonDecode(
        await File(p.join(root.path, '.nso-ci-bundle.json')).readAsString(),
      ) as Map;
      expect(manifest['commit'], commit);
      expect((manifest['entries'] as List).length, 3);
    },
  );

  test('modified native binary is rejected', () async {
    await seal();
    await File(p.join(root.path, 'NSOAlbum.exe')).writeAsString('tampered');
    expect((await run('Verify')).exitCode, isNot(0));
  });

  test('missing nested runtime file is rejected', () async {
    await seal();
    await File(p.join(root.path, 'data', 'app.so')).delete();
    expect((await run('Verify')).exitCode, isNot(0));
  });

  test('unexpected runtime file is rejected', () async {
    await seal();
    await File(p.join(root.path, 'extra.dll')).writeAsString('unverified');
    expect((await run('Verify')).exitCode, isNot(0));
  });

  test(
    'other commits platforms versions and builds cannot reuse bundle',
    () async {
      await seal();
      for (final result in [
        await run('Verify', sha: '1123456789012345678901234567890123456789'),
        await run('Verify', platform: 'macos-x64'),
        await run('Verify', version: '0.2.15'),
        await run('Verify', build: '48'),
      ]) {
        expect(result.exitCode, isNot(0));
      }
    },
  );

  test('bundle without a manifest cannot pass verification', () async {
    expect((await run('Verify')).exitCode, isNot(0));
  });

  test('invalid commit cannot seal a reusable bundle', () async {
    expect((await run('Seal', sha: 'dev')).exitCode, isNot(0));
    expect(
      File(p.join(root.path, '.nso-ci-bundle.json')).existsSync(),
      isFalse,
    );
  });

  test(
    'external symbolic links cannot enter a sealed bundle',
    () async {
      final external = await Directory.systemTemp.createTemp(
        'nso-ci-external-',
      );
      try {
        final file = await File(p.join(external.path, 'private'))
            .writeAsString('not part of the bundle');
        await Link(p.join(root.path, 'outside')).create(file.path);
        expect((await run('Seal')).exitCode, isNot(0));
      } finally {
        await Link(p.join(root.path, 'outside')).delete();
        await external.delete(recursive: true);
      }
    },
    skip: Platform.isWindows
        ? 'Windows symlink privilege is host-dependent; exercised on Unix hosts'
        : false,
  );

  test(
    'internal framework-style links survive seal and verification',
    () async {
      await Link(p.join(root.path, 'current')).create('data');
      await seal();
      expect((await run('Verify')).exitCode, 0);
      await Link(p.join(root.path, 'current')).delete();
    },
    skip: Platform.isWindows
        ? 'Framework symbolic links are exercised on Unix hosts'
        : false,
  );

  test(
    'tar transfer preserves the bundle and relative framework links',
    () async {
      final transfer = await Directory.systemTemp.createTemp(
        'nso-ci-transfer-',
      );
      try {
        if (!Platform.isWindows) {
          await Link(p.join(root.path, 'current')).create('data');
        }
        await seal();
        final archive = p.join(transfer.path, 'build.tar');
        final packed = await Process.run('tar', [
          '-cf',
          archive,
          '-C',
          root.path,
          '.',
        ]);
        expect(packed.exitCode, 0, reason: '${packed.stderr}');
        final restored = await Directory(p.join(transfer.path, 'restored'))
            .create();
        final unpacked = await Process.run('tar', [
          '-xpf',
          archive,
          '-C',
          restored.path,
        ]);
        expect(unpacked.exitCode, 0, reason: '${unpacked.stderr}');
        final verified = await run('Verify', directory: restored);
        expect(verified.exitCode, 0, reason: '${verified.stderr}');
        if (!Platform.isWindows) {
          expect(await Link(p.join(restored.path, 'current')).target(), 'data');
          await Link(p.join(restored.path, 'current')).delete();
          await Link(p.join(root.path, 'current')).delete();
        }
      } finally {
        await transfer.delete(recursive: true);
      }
    },
  );

  test(
    'changed Unix executable permissions cannot pass verification',
    () async {
      await seal();
      final changed = await Process.run('chmod', [
        '755',
        p.join(root.path, 'NSOAlbum.exe'),
      ]);
      expect(changed.exitCode, 0);
      expect((await run('Verify')).exitCode, isNot(0));
    },
    skip: Platform.isWindows
        ? 'Unix file mode check requires a Unix host'
        : false,
  );
}
