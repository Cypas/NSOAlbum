import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/startup/ci_smoke_contract.dart';

import '../tool/run_release_smoke.dart' as smoke;

void main() {
  group('release smoke driver', () {
    test('parses package, reports directory and bounded timeout', () {
      final options = smoke.SmokeDriverOptions.parse([
        '--launch-app=C:\\build\\NSOAlbum\\NSOAlbum.exe',
        '--reports-dir=C:\\agent\\reports',
        '--timeout-seconds=60',
        '--fault=video-first-frame',
      ]);

      expect(options.timeoutSeconds, 60);
      expect(options.fault, 'video-first-frame');
      expect(options.softwareRendering, isFalse);
      expect(options.scenarios, ['normal', 'reopen', 'safe']);
    });

    test('adds the Flutter software renderer switch when requested', () async {
      final temp = await Directory.systemTemp.createTemp('smoke-driver-render-');
      addTearDown(() => temp.delete(recursive: true));
      final bundle = await Directory('${temp.path}/bundle').create();
      final app = File('${bundle.path}/NSOAlbum.exe')..createSync();
      final reports = Directory('${temp.path}/reports');
      final launched = <List<String>>[];

      final result = await smoke.runReleaseSmoke(
        smoke.SmokeDriverOptions(
          appPath: app.path,
          reportsDirectory: reports.path,
          scenarios: const ['safe'],
          softwareRendering: true,
        ),
        launch: (executable, arguments, timeout) async {
          launched.add(arguments);
          final root = _argumentRoot(arguments);
          await Directory(root).create(recursive: true);
          await File('$root/safe.json')
              .writeAsString(jsonEncode(_report('safe')));
          return const smoke.SmokeProcessResult(exitCode: 0);
        },
      );

      expect(result.exitCode, 0);
      expect(launched.single, contains('--enable-software-rendering'));
    });

    test('rejects timeout outside supported bounds', () {
      expect(
        () => smoke.SmokeDriverOptions.parse([
          '--launch-app=/tmp/NSOAlbum.app',
          '--reports-dir=/tmp/reports',
          '--timeout-seconds=59',
        ]),
        throwsFormatException,
      );
      expect(
        () => smoke.SmokeDriverOptions.parse([
          '--launch-app=/tmp/NSOAlbum.app',
          '--reports-dir=/tmp/reports',
          '--timeout-seconds=601',
        ]),
        throwsFormatException,
      );
    });

    test('accepts only successful reports that satisfy required steps', () {
      final valid = _report('normal');
      expect(smoke.validateNativeReport(valid, scenario: 'normal'), isNull);
      (valid['steps'] as List<Map<String, Object?>>).removeWhere(
        (step) => step['name'] == 'merge',
      );
      expect(smoke.validateNativeReport(valid, scenario: 'normal'), isNotNull);
    });

    test(
      'runs normal then reopen on its exact root and safe on a new root',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'smoke-driver-test-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final bundle = await Directory('${temp.path}/bundle').create();
        final app = File('${bundle.path}/NSOAlbum.exe')..createSync();
        final reports = Directory('${temp.path}/reports');
        final launched = <List<String>>[];

        final result = await smoke.runReleaseSmoke(
          smoke.SmokeDriverOptions(
            appPath: app.path,
            reportsDirectory: reports.path,
            timeoutSeconds: 60,
          ),
          launch: (executable, arguments, timeout) async {
            launched.add(arguments);
            final scenario = arguments
                .singleWhere((arg) => arg.startsWith('--ci-smoke-scenario='))
                .split('=')
                .last;
            final root = arguments
                .singleWhere((arg) => arg.startsWith('--ci-smoke-root='))
                .substring('--ci-smoke-root='.length);
            await Directory(root).create(recursive: true);
            if (scenario == 'normal') {
              await File('$root/${CiSmokeRoot.marker}')
                  .writeAsString('NSOAlbum isolated CI library v1');
            }
            await File('$root/$scenario.json')
                .writeAsString(jsonEncode(_report(scenario)));
            return const smoke.SmokeProcessResult(exitCode: 0);
          },
        );

        expect(result.exitCode, 0);
        expect(launched, hasLength(3));
        final normalRoot = _argumentRoot(launched[0]);
        expect(_argumentRoot(launched[1]), normalRoot);
        expect(_argumentRoot(launched[2]), isNot(normalRoot));
        expect(launched[0], isNot(contains('--safe-mode')));
        expect(launched[2], contains('--safe-mode'));
        expect(File('${reports.path}/native-normal.json').existsSync(), isTrue);
        expect(File('${reports.path}/report.json').existsSync(), isTrue);
      },
    );

    test(
      'fails and writes sanitized aggregate artifacts for invalid report',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'smoke-driver-test-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final bundle = await Directory('${temp.path}/bundle').create();
        final app = File('${bundle.path}/NSOAlbum.exe')..createSync();
        final reports = Directory('${temp.path}/reports');

        final result = await smoke.runReleaseSmoke(
          smoke.SmokeDriverOptions(
            appPath: app.path,
            reportsDirectory: reports.path,
            timeoutSeconds: 60,
          ),
          launch: (executable, arguments, timeout) async {
            final root = _argumentRoot(arguments);
            await Directory(root).create(recursive: true);
            await File('$root/normal.json')
                .writeAsString(jsonEncode(_report('safe')));
            return const smoke.SmokeProcessResult(
              exitCode: 1,
              stderr: r'C:\Users\private\account-token=secret',
            );
          },
        );

        expect(result.exitCode, isNot(0));
        final log = await File('${reports.path}/sanitized-process.log')
            .readAsString();
        expect(log, isNot(contains(r'C:\Users\private')));
        expect(log, isNot(contains('secret')));
        expect(await File('${reports.path}/report.json').exists(), isTrue);
      },
    );

    test('copies native app logs with sensitive fields removed', () async {
      final temp = await Directory.systemTemp.createTemp('smoke-driver-log-');
      addTearDown(() => temp.delete(recursive: true));
      final app = File('${temp.path}/NSOAlbum.exe')..createSync();
      final reports = '${temp.path}/reports';
      final result = await smoke.runReleaseSmoke(
        smoke.SmokeDriverOptions(
          appPath: app.path,
          reportsDirectory: reports,
          scenarios: const ['safe'],
        ),
        launch: (executable, arguments, timeout) async {
          final root = _argumentRoot(arguments);
          await Directory('$root/logs').create(recursive: true);
          await File('$root/logs/ci-smoke.log').writeAsString(
            '$root/private.mp4\nAuthorization: Bearer test-secret\n'
            'native diagnostic retained\n',
          );
          await File('$root/safe.json')
              .writeAsString(jsonEncode(_report('safe')));
          return const smoke.SmokeProcessResult(exitCode: 0);
        },
      );

      expect(result.exitCode, 0);
      final log = await File('$reports/sanitized-process.log').readAsString();
      expect(log, contains('native diagnostic retained'));
      expect(log, isNot(contains(temp.path)));
      expect(log, isNot(contains('test-secret')));
    });
  });

  group('owned executable smoke process', () {
    late Directory temp;
    late String executable;

    setUpAll(() async {
      temp = await Directory.systemTemp.createTemp('smoke-driver-executable-');
      final fixture = File('${temp.path}/fixture.dart');
      await fixture.writeAsString(_fixtureScript);
      executable = '${temp.path}/NSOAlbum${Platform.isWindows ? '.exe' : ''}';
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      final dart = flutterRoot != null
          ? '$flutterRoot/bin/cache/dart-sdk/bin/'
                'dart${Platform.isWindows ? '.exe' : ''}'
          : '${File(Platform.resolvedExecutable).parent.parent.parent.parent.path}'
                '/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
      final compilation = await Process.run(dart, [
        'compile',
        'exe',
        fixture.path,
        '-o',
        executable,
      ]);
      expect(compilation.exitCode, 0, reason: '${compilation.stderr}');
    });
    tearDownAll(() => temp.delete(recursive: true));

    test(
      'missing report fails even when owned executable exits zero',
      () async {
        final reports = '${temp.path}/missing-report';
        final result = await smoke.runReleaseSmoke(
          smoke.SmokeDriverOptions(
            appPath: executable,
            reportsDirectory: reports,
            scenarios: const ['normal'],
            fault: 'missing',
          ),
        );
        expect(result.exitCode, 1);
        expect(result.failures, contains('normal: missing native report'));
        expect(
          await File('$reports/sanitized-process.log').readAsString(),
          contains('owned fixture started'),
        );
      },
    );

    test('valid report cannot override owned process nonzero exit', () async {
      final reports = '${temp.path}/nonzero';
      final result = await smoke.runReleaseSmoke(
        smoke.SmokeDriverOptions(
          appPath: executable,
          reportsDirectory: reports,
          scenarios: const ['normal'],
          fault: 'exit',
        ),
      );
      expect(result.exitCode, 1);
      expect(result.failures, contains('normal exited with code 7'));
      expect(await File('$reports/native-normal.json').exists(), isTrue);
    });

    test(
      'hang terminates the owned process and bounds captured pipes',
      () async {
        final reports = '${temp.path}/hang';
        final watch = Stopwatch()..start();
        final result = await smoke.runReleaseSmoke(
          smoke.SmokeDriverOptions(
            appPath: executable,
            reportsDirectory: reports,
            scenarios: const ['normal'],
            timeoutSeconds: 1,
            fault: 'hang',
          ),
        );
        expect(result.exitCode, 1);
        expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
        expect(
          await File('$reports/sanitized-process.log').readAsString(),
          contains('timeout=true'),
        );
      },
    );
  });
}

String _argumentRoot(List<String> arguments) => arguments
    .singleWhere((arg) => arg.startsWith('--ci-smoke-root='))
    .substring('--ci-smoke-root='.length);

Map<String, Object?> _report(String scenario) => {
  'schema': 1,
  'scenario': scenario,
  'platform': 'windows',
  'status': 'passed',
  'steps': [
    for (final name in _requiredSteps[scenario]!)
      {'name': name, 'status': 'passed'},
  ],
};

const _requiredSteps = {
  'normal': [
    'rust-initialization',
    'first-frame',
    'first-gallery-query',
    'desktop-plugins',
    'fixture-generation',
    'import',
    'image-decode',
    'video-first-frame',
    'thumbnail-duration',
    'thumbnail-cache-reuse',
    'trim',
    'trim-playback',
    'merge',
    'merge-playback',
    'source-integrity',
    'persistence-write',
  ],
  'reopen': [
    'rust-initialization',
    'first-frame',
    'first-gallery-query',
    'persistence-read',
    'thumbnail-cache-reuse',
  ],
  'safe': [
    'rust-initialization',
    'first-frame',
    'first-gallery-query',
    'safe-components-disabled',
  ],
};

const _fixtureScript = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  stdout.writeln('owned fixture started');
  final root = args.singleWhere((arg) =>
      arg.startsWith('--ci-smoke-root=')).substring('--ci-smoke-root='.length);
  final scenario = args.singleWhere((arg) =>
      arg.startsWith('--ci-smoke-scenario=')).split('=').last;
  if (args.contains('--ci-smoke-fail=hang')) {
    Timer.periodic(const Duration(milliseconds: 100), (_) {
      stdout.writeln('process still active');
    });
    await Completer<void>().future;
  }
  if (args.contains('--ci-smoke-fail=missing')) return;
  final steps = [
    'rust-initialization', 'first-frame', 'first-gallery-query',
    'desktop-plugins', 'fixture-generation', 'import', 'image-decode',
    'video-first-frame',
    'thumbnail-duration', 'thumbnail-cache-reuse', 'trim', 'trim-playback',
    'merge', 'merge-playback', 'source-integrity', 'persistence-write',
  ];
  await File('$root/$scenario.json').writeAsString(jsonEncode({
    'schema': 1, 'scenario': scenario, 'status': 'passed',
    'steps': [for (final name in steps) {'name': name, 'status': 'passed'}],
  }));
  if (args.contains('--ci-smoke-fail=exit')) exitCode = 7;
}
''';
