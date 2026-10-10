import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/startup/ci_smoke_contract.dart';
import 'package:squid_album/src/startup/startup_options.dart';

void main() {
  test('smoke requires a separate absolute root before startup', () {
    expect(() => StartupOptions.parse(['--ci-smoke']), throwsFormatException);
    expect(
      () => StartupOptions.parse(['--ci-smoke', '--ci-smoke-root=relative']),
      throwsFormatException,
    );
  });

  test('smoke never enables sync and preserves the exact root case', () {
    final root = Directory.systemTemp.absolute.path;
    final options = StartupOptions.parse([
      '--ci-smoke',
      '--ci-smoke-root=$root',
    ]);
    expect(options.ciSmokeRoot, root);
    expect(options.disableAutomaticSync, isTrue);
    expect(options.disableMtpDetection, isTrue);
    expect(options.safeMode, isFalse);
  });

  test(
    'smoke refuses existing user content even when database exists',
    () async {
      final root = await _temporaryRoot('nso-ci-contract-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/private.txt')
          .writeAsString('not a test library');
      await expectLater(CiSmokeRoot.claim(root.path), throwsStateError);
      expect(
        await File('${root.path}/private.txt').readAsString(),
        'not a test library',
      );
    },
  );

  test(
    'reopen requires a smoke-owned marker and successful first run',
    () async {
      final root = await _temporaryRoot('nso-ci-contract-');
      addTearDown(() => root.delete(recursive: true));
      await expectLater(
        CiSmokeRoot.claim(root.path, reopen: true),
        throwsStateError,
      );
      await CiSmokeRoot.claim(root.path);
      await expectLater(
        CiSmokeRoot.claim(root.path, reopen: true),
        throwsStateError,
      );
    },
  );

  test(
    'report cannot pass when a step fails or required steps are missing',
    () {
      expect(
        CiSmokeReport.accepts({
          'schema': 1,
          'scenario': 'normal',
          'status': 'passed',
          'steps': [],
        }, scenario: 'normal'),
        isFalse,
      );
      final report = CiSmokeReport('normal');
      for (final step in CiSmokeReport.requiredSteps('normal')) {
        report.record(step, passed: step != 'video-first-frame');
      }
      expect(report.passed, isFalse);
    },
  );

  test('required normal steps include real edit and merge validation', () {
    final names = CiSmokeReport.requiredSteps('normal');
    expect(
      names,
      containsAll([
        'rust-initialization',
        'first-gallery-query',
        'image-decode',
        'video-first-frame',
        'thumbnail-duration',
        'thumbnail-cache-reuse',
        'trim',
        'trim-playback',
        'merge',
        'merge-playback',
        'source-integrity',
      ]),
    );
  });

  test('diagnostic report redacts paths and sensitive error fields', () {
    final root = Directory.systemTemp.absolute.path;
    final value = sanitizeSmokeDiagnostic(
      '$root/file.mp4 Authorization: Bearer secret\nsession_token=abc',
      roots: [root],
    );
    expect(value, isNot(contains(root)));
    expect(value, isNot(contains('secret')));
    expect(value, isNot(contains('abc')));
  });

  test(
    'reopen rejects redirected directories before reading library data',
    () async {
      final parent = await _temporaryRoot('nso-ci-links-');
      addTearDown(() => parent.delete(recursive: true));
      final real = await Directory('${parent.path}/owned').create();
      await CiSmokeRoot.claim(real.path);
      final linked = Link('${parent.path}/linked');
      await linked.create(real.path);
      await expectLater(
        CiSmokeRoot.claim(linked.path, reopen: true),
        throwsStateError,
      );
    },
    skip: Platform.isWindows
        ? 'Symlink creation privilege is host-dependent; exercised on macOS/Linux'
        : false,
  );

  test('fault arguments cannot affect a regular application launch', () {
    expect(
      () => StartupOptions.parse(['--ci-smoke-fail=trim']),
      throwsFormatException,
    );
  });

  test(
    'reopen rejects a redirected parent before accepting its owned marker',
    () async {
      final parent = await _temporaryRoot('nso-ci-parent-link-');
      addTearDown(() => parent.delete(recursive: true));
      final realParent = await Directory('${parent.path}/real').create();
      final realRoot = await Directory('${realParent.path}/owned').create();
      await CiSmokeRoot.claim(realRoot.path);
      final report = CiSmokeReport('normal');
      for (final name in CiSmokeReport.requiredSteps('normal')) {
        report.record(name, passed: true);
      }
      await File('${realRoot.path}/normal.json')
          .writeAsString(jsonEncode(report.toJson()));
      await Link('${parent.path}/redirect').create(realParent.path);
      await expectLater(
        CiSmokeRoot.claim('${parent.path}/redirect/owned', reopen: true),
        throwsStateError,
      );
    },
  );

  test(
    'reopen refuses a database link inside an otherwise owned library',
    () async {
      final parent = await _temporaryRoot('nso-ci-inner-link-');
      addTearDown(() => parent.delete(recursive: true));
      final root = await Directory('${parent.path}/owned').create();
      await CiSmokeRoot.claim(root.path);
      final report = CiSmokeReport('normal');
      for (final name in CiSmokeReport.requiredSteps('normal')) {
        report.record(name, passed: true);
      }
      await File('${root.path}/normal.json')
          .writeAsString(jsonEncode(report.toJson()));
      final external = await Directory('${parent.path}/outside').create();
      await Link('${root.path}/database').create(external.path);
      await expectLater(
        CiSmokeRoot.claim(root.path, reopen: true),
        throwsStateError,
      );
    },
  );
}

Future<Directory> _temporaryRoot(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  return Directory(await directory.resolveSymbolicLinks());
}
