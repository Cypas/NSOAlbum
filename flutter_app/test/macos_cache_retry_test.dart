import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final bash = Platform.isWindows
      ? r'C:\Program Files\Git\bin\bash.exe'
      : '/bin/bash';
  final skip = File(bash).existsSync()
      ? false
      : 'Requires bash to run the real dependency-retry wrapper';
  late Directory root;
  String shellPath(String path) => path.replaceAll(r'\', '/');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nso-swift-cache-');
    await Directory(p.join(root.path, 'cache', 'healthy'))
        .create(recursive: true);
    await File(p.join(root.path, 'cache', 'healthy', 'keep'))
        .writeAsString('verified cache entry');
  });
  tearDown(() => root.delete(recursive: true));

  Future<ProcessResult> run(String scenario) => Process.run(bash, [
    shellPath(p.absolute('tool/build_macos_cached.sh')),
    shellPath(p.join(root.path, 'cache')),
    bash,
    shellPath(p.absolute('test/fixtures/ci/fake_macos_build.sh')),
    shellPath(root.path),
    scenario,
  ]);

  test('successful build keeps healthy cached dependencies', () async {
    final result = await run('success');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(await File(p.join(root.path, 'count')).readAsString(), '1');
    expect(
      File(p.join(root.path, 'cache', 'healthy', 'keep')).existsSync(),
      isTrue,
    );
  }, skip: skip);

  test(
    'known artifact collision removes only that entry and retries once',
    () async {
      final result = await run('conflict');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(await File(p.join(root.path, 'count')).readAsString(), '2');
      expect(
        File(p.join(root.path, 'cache', 'healthy', 'keep')).existsSync(),
        isTrue,
      );
      expect(
        Directory(
          p.join(
            root.path,
            'cache',
            'https___github_com_sk3llo_ffmpeg_kit_flutter_releases_download_8_1_2_video_ffmpegkit_xcframework_zip',
          ),
        ).existsSync(),
        isFalse,
      );
    },
    skip: skip,
  );

  test(
    'unknown build errors are not retried or converted to success',
    () async {
      expect((await run('permanent')).exitCode, 9);
      expect(await File(p.join(root.path, 'count')).readAsString(), '1');
    },
    skip: skip,
  );

  test(
    'repeated dependency collision still fails after the single retry',
    () async {
      expect((await run('repeated')).exitCode, isNot(0));
      expect(await File(p.join(root.path, 'count')).readAsString(), '2');
    },
    skip: skip,
  );

  test('error paths outside cache are not removed or retried', () async {
    final foreign = await Directory(p.join(root.path, 'elsewhere')).create();
    expect((await run('foreign')).exitCode, isNot(0));
    expect(foreign.existsSync(), isTrue);
    expect(await File(p.join(root.path, 'count')).readAsString(), '1');
  }, skip: skip);
}
