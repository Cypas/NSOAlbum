import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final bash = Platform.isWindows
      ? r'C:\Program Files\Git\bin\bash.exe'
      : '/bin/bash';
  final tools = File(bash).existsSync()
      ? await Process.run(bash, [
          '-c',
          r'test "${BASH_VERSINFO[0]}" -ge 4 && sha256sum --version >/dev/null',
        ])
      : null;
  final skip = tools?.exitCode == 0
      ? false
      : 'Requires Bash 4+ and GNU sha256sum for the Ubuntu Release collector; '
            'the macOS system shell is not supported';
  const version = '1.2.3';
  const apkName = 'NSOAlbum-Android-arm64-1.2.3.apk';
  const desktopNames = [
    'NSOAlbum-1.2.3-Setup.exe',
    'NSOAlbum-macOS-arm64-1.2.3.dmg',
    'NSOAlbum-macOS-x64-1.2.3.dmg',
  ];
  late Directory root;
  late String collectionScript;

  // Execute the workflow's run block, rather than checking source substrings.
  // A missing APK collection, a wrong input path, or a removed hash gate must
  // change the real output files or exit status asserted below.
  setUpAll(() async {
    final lines = await File(p.absolute('../.github/workflows/release.yml'))
        .readAsLines();
    final step = lines.indexWhere(
      (line) => line.startsWith('      - name: Collect '),
    );
    expect(step, greaterThanOrEqualTo(0));
    final end = lines.indexWhere(
      (line) => line.startsWith('      - '),
      step + 1,
    );
    final run = lines.indexOf('        run: |', step);
    expect(run, greaterThan(step));
    expect(run, lessThan(end));
    collectionScript = lines
        .sublist(run + 1, end)
        .map((line) => line.length >= 10 ? line.substring(10) : '')
        .join('\n');
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nso-release-assets-');
    final desktop = await Directory(
      p.join(root.path, 'release-assets', 'nested package'),
    ).create(recursive: true);
    for (final name in desktopNames) {
      await File(p.join(desktop.path, name)).writeAsString('fixture $name');
    }
    await Directory(p.join(root.path, 'release-android')).create();
    await File(p.join(root.path, 'release-android', apkName))
        .writeAsString('fixture release-key-signed APK bytes');
    await writeAndroidDigest(root, apkName);
  });
  tearDown(() => root.delete(recursive: true));

  Future<ProcessResult> collect({String targetVersion = version}) =>
      Process.run(
        bash,
        ['-c', collectionScript],
        workingDirectory: root.path,
        environment: {'VERSION': targetVersion},
      );

  test('collects four versioned packages and a unified digest of their exact bytes', () async {
    await File(p.join(root.path, 'release-assets', 'unpublished.zip'))
        .writeAsString('not a Release asset');
    final result = await collect();
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final upload = Directory(p.join(root.path, 'upload'));
    expect(
      upload.listSync().map((entry) => p.basename(entry.path)),
      unorderedEquals([...desktopNames, apkName, 'SHA256SUMS.txt']),
    );
    final digestLines = await File(p.join(upload.path, 'SHA256SUMS.txt'))
        .readAsLines();
    final actualDigests = <String, String>{};
    for (final line in digestLines) {
      final match = RegExp(r'^([0-9a-f]{64}) [ *](.+)$').firstMatch(line);
      expect(match, isNotNull, reason: 'Invalid SHA-256 entry: $line');
      expect(actualDigests.containsKey(match!.group(2)), isFalse);
      actualDigests[match.group(2)!] = match.group(1)!;
    }
    expect(actualDigests.keys, unorderedEquals([...desktopNames, apkName]));
    for (final name in [...desktopNames, apkName]) {
      final input = File(
        p.join(
          root.path,
          name == apkName ? 'release-android' : 'release-assets/nested package',
          name,
        ),
      );
      final bytes = await input.readAsBytes();
      expect(await File(p.join(upload.path, name)).readAsBytes(), bytes);
      expect(actualDigests[name], sha256.convert(bytes).toString());
    }
  }, skip: skip);

  test('missing signed APK prevents publication', () async {
    await File(p.join(root.path, 'release-android', apkName)).delete();
    expect((await collect()).exitCode, isNot(0));
  }, skip: skip);

  test('empty signed APK prevents publication', () async {
    await File(p.join(root.path, 'release-android', apkName)).writeAsString('');
    await writeAndroidDigest(root, apkName);
    expect((await collect()).exitCode, isNot(0));
  }, skip: skip);

  test('modified signed APK fails its signing job digest', () async {
    await File(p.join(root.path, 'release-android', apkName))
        .writeAsString('tampered bytes');
    expect((await collect()).exitCode, isNot(0));
  }, skip: skip);

  test('missing signing digest prevents publication', () async {
    await File(p.join(root.path, 'release-android', 'SHA256SUMS.txt')).delete();
    expect((await collect()).exitCode, isNot(0));
  }, skip: skip);

  test('digest for a different filename cannot authorize this APK', () async {
    final digest = File(p.join(root.path, 'release-android', 'SHA256SUMS.txt'));
    await digest.writeAsString(
      (await digest.readAsString()).replaceAll(apkName, 'CI-Test.apk'),
    );
    expect((await collect()).exitCode, isNot(0));
  }, skip: skip);

  test('malformed signing digest prevents publication', () async {
    await File(p.join(root.path, 'release-android', 'SHA256SUMS.txt'))
        .writeAsString('not-a-sha256  $apkName\n');
    expect((await collect()).exitCode, isNot(0));
  }, skip: skip);

  test('signing digest cannot authorize additional files', () async {
    final digest = File(p.join(root.path, 'release-android', 'SHA256SUMS.txt'));
    await digest.writeAsString(
      '${await digest.readAsString()}${sha256.convert(utf8.encode('extra'))}  extra.apk\n',
    );
    await File(p.join(root.path, 'release-android', 'extra.apk'))
        .writeAsString('extra');
    expect((await collect()).exitCode, isNot(0));
  }, skip: skip);

  test(
    'test APK from another artifact cannot replace the signed APK',
    () async {
      final apk = File(p.join(root.path, 'release-android', apkName));
      await apk.rename(p.join(root.path, 'release-assets', apkName));
      expect((await collect()).exitCode, isNot(0));
    },
    skip: skip,
  );

  test('older APK cannot satisfy the requested version', () async {
    await File(p.join(root.path, 'release-android', apkName)).rename(
      p.join(root.path, 'release-android', 'NSOAlbum-Android-arm64-1.2.2.apk'),
    );
    expect((await collect()).exitCode, isNot(0));
  }, skip: skip);

  test('missing desktop package still prevents publication', () async {
    await File(
      p.join(root.path, 'release-assets', 'nested package', desktopNames.first),
    ).delete();
    expect((await collect()).exitCode, isNot(0));
  }, skip: skip);

  test('ambiguous desktop package still prevents publication', () async {
    await File(p.join(root.path, 'release-assets', desktopNames.first))
        .writeAsString('duplicate fixture');
    expect((await collect()).exitCode, isNot(0));
  }, skip: skip);

  test('existing upload directory is not overwritten or reused', () async {
    final upload = await Directory(p.join(root.path, 'upload')).create();
    final existing = await File(p.join(upload.path, 'keep'))
        .writeAsString('existing output');
    expect((await collect()).exitCode, isNot(0));
    expect(await existing.readAsString(), 'existing output');
  }, skip: skip);
}

Future<void> writeAndroidDigest(Directory root, String name) async {
  final bytes = await File(p.join(root.path, 'release-android', name))
      .readAsBytes();
  await File(p.join(root.path, 'release-android', 'SHA256SUMS.txt'))
      .writeAsString('${sha256.convert(bytes)}  $name\n', encoding: utf8);
}
