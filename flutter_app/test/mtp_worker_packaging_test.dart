@Tags(['platform-windows'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../tool/verify_mtp_worker.dart';

void main() {
  late Directory retainedRun;
  late Directory compiled;
  late File workerFixture;
  late File hangingFixture;
  late File isolatedFixture;
  late File x86Fixture;
  late Directory root;
  late Directory project;
  late Directory release;
  late Directory legacy;
  late Directory destination;
  late File freshWorker;
  late File freshLibrary;
  late File cargoEvents;
  late File cargoCalls;
  final windowsSkip = Platform.isWindows
      ? false
      : 'Requires native Windows PE execution and PowerShell packaging';

  setUpAll(() async {
    final evidence = Directory(
      p.absolute('build', 'test-fixtures', 'mtp-worker-packaging'),
    );
    for (final relative in [
      'build',
      p.join('build', 'test-fixtures'),
      p.join('build', 'test-fixtures', 'mtp-worker-packaging'),
    ]) {
      if (await FileSystemEntity.type(
            p.absolute(relative),
            followLinks: false,
          ) ==
          FileSystemEntityType.link) {
        throw StateError('Synthetic fixture evidence must not traverse links');
      }
    }
    await evidence.create(recursive: true);
    if (!p.equals(await evidence.resolveSymbolicLinks(), evidence.path)) {
      throw StateError('Synthetic fixture evidence escaped its workspace');
    }
    retainedRun = await evidence.createTemp('run-');
    // These small synthetic artifacts are evidence, not product files. Keep
    // every unique run explicitly; deleting them is not a packaging assertion.
    stdout.writeln(
      'MTP helper synthetic fixtures retained: ${retainedRun.path}',
    );
    if (!Platform.isWindows) return;
    compiled = await Directory(p.join(retainedRun.path, 'compiled')).create();
    workerFixture = File(p.join(compiled.path, 'worker.exe'));
    hangingFixture = File(p.join(compiled.path, 'hang-worker.exe'));
    isolatedFixture = File(p.join(compiled.path, 'isolated-worker.exe'));
    x86Fixture = File(p.join(compiled.path, 'wrong-architecture.exe'));
    final compiler = p.join(
      Platform.environment['WINDIR']!,
      'Microsoft.NET',
      'Framework64',
      'v4.0.30319',
      'csc.exe',
    );
    for (final entry in {'x64': workerFixture, 'x86': x86Fixture}.entries) {
      final result = await Process.run(compiler, [
        '/nologo',
        '/target:exe',
        '/platform:${entry.key}',
        '/out:${p.windows.normalize(entry.value.path)}',
        p.windows.normalize(
          p.absolute('test/fixtures/ci/mtp_worker_fixture.cs'),
        ),
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }
    await workerFixture.copy(hangingFixture.path);
    await workerFixture.copy(isolatedFixture.path);
  });
  Future<File> write(String relative, String content) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    return file.writeAsString(content);
  }

  Future<void> copyTool(String name) async {
    final source = File(p.absolute('tool', name));
    if (await source.exists()) {
      final target = File(p.join(project.path, 'tool', name));
      await target.parent.create(recursive: true);
      await source.copy(target.path);
    }
  }

  Future<void> setCargoEvents({bool success = true, String optLevel = '3'}) =>
      cargoEvents.writeAsString(
        [
          for (final entry in {
            'squid_album_core': ['cdylib', 'staticlib', 'rlib'],
            'nsoalbum_mtp_worker': ['bin'],
          }.entries)
            jsonEncode({
              'reason': 'compiler-artifact',
              'package_id':
                  'path+file:///fixture/rust_core#squid_album_core@0.2.14',
              'manifest_path': p.join(root.path, 'rust_core', 'Cargo.toml'),
              'target': {
                'kind': entry.value,
                'crate_types': entry.value,
                'name': entry.key,
                'src_path': p.join(root.path, 'rust_core', 'src', 'lib.rs'),
                'edition': '2021',
                'doc': true,
                'doctest': true,
                'test': true,
              },
              'profile': {
                'opt_level': optLevel,
                'debuginfo': 0,
                'debug_assertions': optLevel == '0',
                'overflow_checks': optLevel == '0',
                'test': false,
              },
              'features': <String>[],
              'filenames': [
                entry.key == 'squid_album_core'
                    ? freshLibrary.path
                    : freshWorker.path,
              ],
              'executable': entry.key == 'nsoalbum_mtp_worker'
                  ? freshWorker.path
                  : null,
              'fresh': true,
            }),
          jsonEncode({'reason': 'build-finished', 'success': success}),
        ].join('\n'),
      );

  setUp(() async {
    root = await retainedRun.createTemp('case-');
    project = Directory(p.join(root.path, 'flutter_app'));
    release = Directory(
      p.join(project.path, 'build', 'windows', 'x64', 'runner', 'Release'),
    );
    legacy = Directory(
      p.join(root.path, 'dist', 'NSOAlbum-Windows-x64-0.2.14'),
    );
    destination = Directory(
      p.join(root.path, 'dist', 'isolated', 'NSOAlbum-Windows-x64-0.2.14'),
    );
    await copyTool('package_windows.ps1');
    await copyTool('validate_release_version.ps1');
    for (final name in [
      'build_desktop_native.dart',
      'verify_mtp_worker.dart',
    ]) {
      await copyTool(name);
    }
    final packageConfig = File(
      p.join(project.path, '.dart_tool', 'package_config.json'),
    );
    await packageConfig.parent.create(recursive: true);
    await File(p.absolute('.dart_tool/package_config.json'))
        .copy(packageConfig.path);
    await write('flutter_app/pubspec.yaml', 'version: 0.2.14+47\n');
    await write('rust_core/Cargo.toml', 'version = "0.2.14"\n');
    await write(
      'rust_core/src/frb_generated.rs',
      'FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH: i32 = 123;',
    );
    await write(
      'flutter_app/lib/src/rust/frb_generated.dart',
      'rustContentHash => 123;',
    );
    await write('LICENSE', 'synthetic license\n');
    await write('docs/legal/THIRD-PARTY-NOTICES.md', 'synthetic notices\n');
    await write('docs/legal/ASSET-ATTRIBUTION.md', 'synthetic assets\n');
    await write(
      'flutter_app/assets/fonts/SmileySans-OFL.txt',
      'synthetic font license\n',
    );
    await release.create(recursive: true);
    await File(p.join(release.path, 'NSOAlbum.exe')).writeAsString('app');
    await write(
      'rust_core/target/release/squid_album_core.dll',
      'stale F drive DLL',
    );
    freshLibrary = await write(
      'native-target/release/squid_album_core.dll',
      'new DLL',
    );
    freshWorker = File(
      p.join(root.path, 'native-target', 'release', 'nsoalbum_mtp_worker.exe'),
    );
    cargoEvents = File(p.join(root.path, 'cargo-events.jsonl'));
    cargoCalls = File(p.join(root.path, 'cargo-calls.txt'));
    await setCargoEvents();
    await legacy.create(recursive: true);
    await File(p.join(legacy.path, 'history.keep'))
        .writeAsString('old package');
    await Directory(p.join(root.path, 'bin')).create();
    if (Platform.isWindows) {
      await workerFixture.copy(p.join(root.path, 'bin', 'cargo.exe'));
    }
  });
  Future<ProcessResult> package({
    bool isolated = true,
    Map<String, String> environment = const {},
    String? output,
  }) => Process.run(
    'pwsh',
    [
      '-NoProfile',
      '-File',
      p.join(project.path, 'tool', 'package_windows.ps1'),
      '-SkipTests',
      '-SkipBridgeGeneration',
      '-UseExistingFlutterBuild',
      if (isolated) ...['-PackageDirectory', output ?? destination.path],
    ],
    environment: {
      'PATH': '${p.join(root.path, 'bin')};${Platform.environment['PATH']}',
      'GITHUB_ACTIONS': 'true',
      'GITHUB_REF_TYPE': 'branch',
      'GITHUB_REF_NAME': 'dev',
      'CARGO': p.join(root.path, 'bin', 'cargo.exe'),
      'NSO_CARGO_JSON': cargoEvents.path,
      'NSO_CARGO_CALLS': cargoCalls.path,
      ...environment,
    },
  );

  group('real packaging boundaries', () {
    test(
      '[Windows] successful Cargo without a helper cannot produce a package',
      () async {
        final result = await package();
        expect(
          result.exitCode,
          isNot(0),
          reason: 'A DLL-only bundle was accepted:\n${result.stdout}',
        );
        expect(destination.existsSync(), isFalse);
      },
    );

    test('[Windows] a corrupt helper cannot produce a package', () async {
      await freshWorker.writeAsString('not a PE executable');
      final result = await package();
      expect(
        result.exitCode,
        isNot(0),
        reason: 'A corrupt helper was accepted:\n${result.stdout}',
      );
      expect(destination.existsSync(), isFalse);
    });

    test('[Windows] explicit isolated output preserves an existing version package', () async {
      await package();
      expect(
        File(p.join(legacy.path, 'history.keep')).existsSync(),
        isTrue,
        reason:
            'The explicit destination must not replace a historical package',
      );
      expect(
        await File(p.join(legacy.path, 'history.keep')).readAsString(),
        'old package',
      );
    });

    test('[Windows] the package uses this invocation DLL and helper instead of an old target', () async {
      await workerFixture.copy(freshWorker.path);
      final result = await package();
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        await File(p.join(destination.path, 'squid_album_core.dll'))
            .readAsString(),
        'new DLL',
      );
      expect(
        await File(p.join(destination.path, 'nsoalbum_mtp_worker.exe'))
            .readAsBytes(),
        await workerFixture.readAsBytes(),
      );
      final receipt = await File(
        p.join(destination.path, 'data', 'mtp-worker-build.json'),
      ).readAsString();
      expect(receipt, isNot(contains(root.path)));
      expect(jsonDecode(receipt)['profile'], 'release');
      expect(
        await cargoCalls.readAsString(),
        contains(
          '--target x86_64-pc-windows-msvc --release --lib --bin nsoalbum_mtp_worker',
        ),
      );
    });

    for (final failCargo in [false, true]) {
      test(
        '[Windows] fallback-only Cargo ${failCargo ? "failure" : "success"} restores the caller environment',
        () async {
          await workerFixture.copy(freshWorker.path);
          final fakeProfile = p.join(root.path, 'fallback profile');
          final fallbackCargo = File(
            p.join(fakeProfile, '.cargo', 'bin', 'cargo.exe'),
          );
          await fallbackCargo.parent.create(recursive: true);
          await workerFixture.copy(fallbackCargo.path);
          final tools = await Process.run('pwsh', [
            '-NoProfile',
            '-Command',
            '(Get-Command flutter).Source; (Get-Command pwsh).Source',
          ]);
          expect(tools.exitCode, 0, reason: '${tools.stderr}');
          final toolPaths = const LineSplitter()
              .convert(tools.stdout.toString())
              .where((line) => line.trim().isNotEmpty)
              .toList();
          expect(toolPaths.length, 2);
          final flutterBin = p.dirname(toolPaths[0]);
          final dartBin = p.join(flutterBin, 'cache', 'dart-sdk', 'bin');
          expect(File(p.join(dartBin, 'dart.exe')).existsSync(), isTrue);
          final windows = Platform.environment['WINDIR']!;
          final beforeCargo = Platform.environment['CARGO'];
          final beforePath = Platform.environment['PATH'];
          final environment = Map<String, String>.from(Platform.environment)
            ..removeWhere(
              (key, _) => const {
                'cargo',
                'path',
                'userprofile',
              }.contains(key.toLowerCase()),
            )
            ..addAll({
              'PATH': [
                dartBin,
                flutterBin,
                p.dirname(toolPaths[1]),
                p.join(windows, 'System32'),
                windows,
              ].join(';'),
              'USERPROFILE': fakeProfile,
              'GITHUB_ACTIONS': 'true',
              'GITHUB_REF_TYPE': 'branch',
              'GITHUB_REF_NAME': 'dev',
              'NSO_CARGO_JSON': cargoEvents.path,
              'NSO_CARGO_CALLS': cargoCalls.path,
              'NSO_CARGO_FAIL': failCargo ? '1' : '0',
              'NSO_EXPECT_CARGO_FAILURE': failCargo ? '1' : '0',
              'NSO_PACKAGE_SCRIPT': p.join(
                project.path,
                'tool',
                'package_windows.ps1',
              ),
              'NSO_PACKAGE_OUT': destination.path,
            });
          final wrapper = await write('fallback-package.ps1', r'''
$ErrorActionPreference = 'Stop'
if ($null -ne (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw 'The fixture must not expose Cargo on PATH.'
}
if ($null -ne [Environment]::GetEnvironmentVariable('CARGO', 'Process')) {
    throw 'The fixture must start without CARGO.'
}
if ($null -eq (Get-Command dart -ErrorAction SilentlyContinue) -or
    $null -eq (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'The fixture must retain explicit Dart and Flutter tools.'
}
$beforePath = [Environment]::GetEnvironmentVariable('PATH', 'Process')
$expectedFailure = $env:NSO_EXPECT_CARGO_FAILURE -eq '1'
$failed = $false
try {
    & $env:NSO_PACKAGE_SCRIPT -SkipTests -SkipBridgeGeneration -UseExistingFlutterBuild -PackageDirectory $env:NSO_PACKAGE_OUT
    if ($LASTEXITCODE -ne 0) { throw 'The fallback package failed.' }
} catch {
    if (-not $expectedFailure) { throw }
    $failed = $true
}
if ($failed -ne $expectedFailure) { throw 'The fixture did not observe its expected Cargo outcome.' }
if ($null -ne [Environment]::GetEnvironmentVariable('CARGO', 'Process') -or
    $beforePath -cne [Environment]::GetEnvironmentVariable('PATH', 'Process')) {
    throw 'The package changed its caller environment.'
}
Write-Output 'Fallback-only Cargo package left CARGO absent and PATH unchanged.'
''');
          final result = await Process.run(
            toolPaths[1],
            ['-NoProfile', '-File', wrapper.path],
            environment: environment,
            includeParentEnvironment: false,
          );
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(
            result.stdout,
            contains(
              'Fallback-only Cargo package left CARGO absent and PATH unchanged.',
            ),
          );
          expect(
            cargoCalls.existsSync(),
            isTrue,
            reason: 'The resolved fallback Cargo must actually be invoked.',
          );
          expect(
            await cargoCalls.readAsString(),
            contains(
              '--target x86_64-pc-windows-msvc --release --lib --bin nsoalbum_mtp_worker',
            ),
          );
          if (failCargo) {
            expect(
              result.stderr,
              contains('Cargo did not finish successfully (exit 7)'),
            );
            expect(destination.existsSync(), isFalse);
          } else {
            expect(
              await File(p.join(destination.path, 'squid_album_core.dll'))
                  .readAsString(),
              'new DLL',
            );
            expect(
              await File(p.join(destination.path, 'nsoalbum_mtp_worker.exe'))
                  .readAsBytes(),
              await workerFixture.readAsBytes(),
            );
            final receipt = jsonDecode(
              await File(
                p.join(destination.path, 'data', 'mtp-worker-build.json'),
              ).readAsString(),
            ) as Map;
            expect(receipt['cargoSuccess'], isTrue);
            expect(receipt['profile'], 'release');
          }
          expect(
            Platform.environment['CARGO'] == beforeCargo &&
                Platform.environment['PATH'] == beforePath,
            isTrue,
            reason: 'The parent process environment must remain unchanged.',
          );
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );
    }

    test('[Windows] a wrong-architecture helper is refused', () async {
      await x86Fixture.copy(freshWorker.path);
      final result = await package();
      expect(result.exitCode, isNot(0), reason: '${result.stdout}');
      expect(destination.existsSync(), isFalse);
    });

    test(
      '[Windows] an unsuccessful Cargo cannot reuse old native files',
      () async {
        await workerFixture.copy(freshWorker.path);
        final result = await package(environment: {'NSO_CARGO_FAIL': '1'});
        expect(result.exitCode, isNot(0));
        expect(destination.existsSync(), isFalse);
      },
    );

    test('[Windows] a Debug artifact cannot be labelled Release', () async {
      await workerFixture.copy(freshWorker.path);
      await setCargoEvents(optLevel: '0');
      final result = await package();
      expect(result.exitCode, isNot(0));
      expect(destination.existsSync(), isFalse);
    });

    test('[Windows] an output outside dist is rejected before Cargo', () async {
      final result = await package(
        output: p.join(root.path, 'foreign', 'package'),
      );
      expect(result.exitCode, isNot(0));
      expect(cargoCalls.existsSync(), isFalse);
    });

    test(
      '[Windows] an output traversing a junction is rejected before Cargo',
      () async {
        final outside = await Directory(p.join(root.path, 'foreign')).create();
        final junction = p.join(root.path, 'dist', 'redirect');
        final linked = await Process.run(
          'pwsh',
          [
            '-NoProfile',
            '-Command',
            'New-Item -ItemType Junction -Path \$env:NSO_JUNCTION -Target \$env:NSO_TARGET | Out-Null',
          ],
          environment: {'NSO_JUNCTION': junction, 'NSO_TARGET': outside.path},
        );
        expect(linked.exitCode, 0, reason: '${linked.stderr}');
        final result = await package(output: p.join(junction, 'package'));
        expect(result.exitCode, isNot(0));
        expect(cargoCalls.existsSync(), isFalse);
        expect(
          Directory(p.join(outside.path, 'package')).existsSync(),
          isFalse,
        );
      },
    );

    test('[Windows] a dangling directory symlink is rejected before Cargo or target creation', () async {
      final missing = p.join(root.path, 'missing-target');
      final link = p.join(root.path, 'dist', 'dangling');
      final linked = await Process.run(
        'pwsh',
        [
          '-NoProfile',
          '-Command',
          '[IO.Directory]::CreateSymbolicLink(\$env:NSO_LINK, \$env:NSO_TARGET) | Out-Null',
        ],
        environment: {'NSO_LINK': link, 'NSO_TARGET': missing},
      );
      expect(linked.exitCode, 0, reason: '${linked.stdout}\n${linked.stderr}');
      expect(
        await FileSystemEntity.type(link, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(Directory(missing).existsSync(), isFalse);
      final result = await package(output: p.join(link, 'package'));
      expect(result.exitCode, isNot(0), reason: '${result.stdout}');
      expect(cargoCalls.existsSync(), isFalse);
      expect(Directory(missing).existsSync(), isFalse);
      expect(destination.existsSync(), isFalse);
    });

    test(
      '[Windows] an existing output is rejected before build or deletion',
      () async {
        await destination.create(recursive: true);
        final sentinel = File(p.join(destination.path, 'keep'));
        await sentinel.writeAsString('owned history');
        final result = await package();
        expect(result.exitCode, isNot(0));
        expect(await sentinel.readAsString(), 'owned history');
        expect(File(p.join(legacy.path, 'history.keep')).existsSync(), isTrue);
      },
    );
  }, skip: windowsSkip);

  group('real no-device helper process', () {
    test(
      '[Windows] helper loading uses only bundle-local and system search paths',
      () async {
        await expectLater(probeMtpWorker(isolatedFixture), completes);
      },
    );
    test('[Windows] Close returns successful null and natural exit', () async {
      await expectLater(probeMtpWorker(workerFixture), completes);
    });
    for (final behavior in ['bad', 'oversized', 'exit-error']) {
      test('[Windows] $behavior is a nonzero verifier failure', () async {
        await workerFixture.copy(
          p.join(release.path, 'nsoalbum_mtp_worker.exe'),
        );
        final result = await Process.run(
          'dart',
          [
            p.absolute('tool/verify_mtp_worker.dart'),
            '--bundle',
            release.path,
            '--platform',
            'windows-x64',
          ],
          environment: {'NSO_MTP_FIXTURE_BEHAVIOR': behavior},
          runInShell: Platform.isWindows,
        );
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('MTP helper verification failed'));
      });
    }
    test('[Windows] timeout reaps only the verifier-owned process', () async {
      final hanging = await Process.start(hangingFixture.path, const []);
      try {
        await expectLater(
          probeMtpWorker(
            hangingFixture,
            timeout: const Duration(milliseconds: 150),
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(
          await Process.run('tasklist', [
            '/FI',
            'PID eq ${hanging.pid}',
          ]).then((value) => value.stdout.toString()),
          contains('${hanging.pid}'),
        );
      } finally {
        hanging.kill(ProcessSignal.sigkill);
        await hanging.exitCode;
      }
    });
    test('[Windows] cancellation fails and drains the owned helper', () async {
      final cancellation = Completer<void>();
      final result = probeMtpWorker(
        hangingFixture,
        cancelled: cancellation.future,
      );
      cancellation.complete();
      await expectLater(result, throwsStateError);
    });
  }, skip: windowsSkip);

  group('Cargo JSON build selection', () {
    for (final configuration in ['Debug', 'Profile', 'Release']) {
      test(
        '[Windows] $configuration selects the matching Cargo mode',
        () async {
          await workerFixture.copy(freshWorker.path);
          await setCargoEvents(optLevel: configuration == 'Debug' ? '0' : '3');
          final output = p.join(
            root.path,
            'runner',
            configuration,
            'nsoalbum_mtp_worker.exe',
          );
          final report = p.join(
            root.path,
            'reports',
            configuration,
            'build.json',
          );
          final result = await Process.run(
            'dart',
            [
              p.join(project.path, 'tool', 'build_desktop_native.dart'),
              '--target',
              'x86_64-pc-windows-msvc',
              '--configuration',
              configuration,
              '--output',
              output,
              '--report',
              report,
              '--cargo-log',
              '$report.jsonl',
            ],
            environment: {
              'CARGO': p.join(root.path, 'bin', 'cargo.exe'),
              'NSO_CARGO_JSON': cargoEvents.path,
              'NSO_CARGO_CALLS': cargoCalls.path,
            },
            runInShell: Platform.isWindows,
          );
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(
            await File(output).readAsBytes(),
            await workerFixture.readAsBytes(),
          );
          final metadata = jsonDecode(await File(report).readAsString()) as Map;
          expect(
            metadata['profile'],
            configuration == 'Debug' ? 'debug' : 'release',
          );
          expect(metadata['target'], 'x86_64-pc-windows-msvc');
          final calls = await cargoCalls.readAsString();
          expect(calls.contains('--release'), configuration != 'Debug');
        },
      );
    }

    test('[Windows] independent bundle negative controls execute the real verifier', () async {
      await workerFixture.copy(freshWorker.path);
      final packageTimer = Stopwatch()..start();
      final packaged = await package();
      stdout.writeln(
        'MTP negative-control fixture package elapsedMs='
        '${packageTimer.elapsedMilliseconds} exit=${packaged.exitCode}',
      );
      expect(packaged.exitCode, 0, reason: '${packaged.stderr}');
      final verificationTimer = Stopwatch()..start();
      final result = await Process.run('dart', [
        p.absolute('tool/test_mtp_worker_bundle.dart'),
        '--bundle',
        destination.path,
        '--platform',
        'windows-x64',
        '--build-record',
        p.join(destination.path, 'data', 'mtp-worker-build.json'),
      ], runInShell: Platform.isWindows);
      stdout.writeln(
        'MTP negative-control verification elapsedMs='
        '${verificationTimer.elapsedMilliseconds} exit=${result.exitCode}',
      );
      stdout.write(result.stdout);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(jsonDecode(result.stdout)['cases'], [
        'missing',
        'empty',
        'corrupt',
        'wrong-architecture',
      ]);
    });
  }, skip: windowsSkip);

  group('synthetic universal macOS Cargo selection', () {
    for (final failure in [false, true]) {
      test(
        '[Windows] universal build ${failure ? "fails closed" : "combines current slices"}',
        () async {
          final eventsByArchitecture = <String, String>{};
          for (final entry in {
            'ARM64': 0x0100000c,
            'X64': 0x01000007,
          }.entries) {
            final path = p.join(
              root.path,
              'native-target',
              entry.key,
              'nsoalbum_mtp_worker',
            );
            final data = ByteData(128)
              ..setUint32(0, 0xfeedfacf, Endian.little)
              ..setUint32(4, entry.value, Endian.little)
              ..setUint32(12, 2, Endian.little);
            await File(path).parent.create(recursive: true);
            await File(path).writeAsBytes(data.buffer.asUint8List());
            final events = (await cargoEvents.readAsLines())
                .map((line) {
                  final event = jsonDecode(line) as Map<String, dynamic>;
                  if (event['target'] is Map &&
                      event['target']['name'] == 'nsoalbum_mtp_worker') {
                    event['executable'] = path;
                    event['filenames'] = [path];
                  }
                  return jsonEncode(event);
                })
                .join('\n');
            final eventFile = await write('cargo-${entry.key}.jsonl', events);
            eventsByArchitecture['NSO_CARGO_JSON_${entry.key}'] =
                eventFile.path;
          }
          final lipo = p.join(root.path, 'bin', 'lipo.exe');
          await workerFixture.copy(lipo);
          final output = await write(
            'runner/nsoalbum_mtp_worker',
            'previous helper',
          );
          final report = p.join(root.path, 'reports', 'universal.json');
          final result = await Process.run(
            'dart',
            [
              p.join(project.path, 'tool', 'build_desktop_native.dart'),
              '--target',
              'x86_64-apple-darwin,aarch64-apple-darwin',
              '--configuration',
              'Profile',
              '--output',
              output.path,
              '--report',
              report,
              '--cargo-log',
              '$report.jsonl',
            ],
            environment: {
              'CARGO': p.join(root.path, 'bin', 'cargo.exe'),
              'LIPO': lipo,
              'NSO_LIPO_CALLS': p.join(root.path, 'lipo-calls.txt'),
              'NSO_LIPO_FAIL': failure ? '1' : '0',
              'NSO_CARGO_JSON': cargoEvents.path,
              'NSO_CARGO_CALLS': cargoCalls.path,
              ...eventsByArchitecture,
            },
            runInShell: Platform.isWindows,
          );
          final metadata = jsonDecode(await File(report).readAsString()) as Map;
          if (failure) {
            expect(result.exitCode, isNot(0));
            expect(metadata['cargoSuccess'], isFalse);
            expect(await output.readAsString(), 'previous helper');
          } else {
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}\n${result.stderr}',
            );
            expect(metadata['cargoSuccess'], isTrue);
            expect(metadata['targets'], [
              'x86_64-apple-darwin',
              'aarch64-apple-darwin',
            ]);
            expect(metadata['profile'], 'release');
            expect((metadata['slices'] as List).length, 2);
            expect((await output.readAsBytes()).take(4), [
              0xca,
              0xfe,
              0xba,
              0xbe,
            ]);
            final calls = await cargoCalls.readAsLines();
            expect(calls.length, 2);
            expect(
              calls[0],
              contains('--target x86_64-apple-darwin --release'),
            );
            expect(
              calls[1],
              contains('--target aarch64-apple-darwin --release'),
            );
          }
        },
      );
    }
  }, skip: windowsSkip);

  group('normal Windows CMake dependency graph', () {
    test('[Windows] Runner brings its helper through Cargokit in all Flutter modes', () async {
      final vswhere = p.join(
        Platform.environment['ProgramFiles(x86)']!,
        'Microsoft Visual Studio',
        'Installer',
        'vswhere.exe',
      );
      final visualStudio = await Process.run(vswhere, [
        '-latest',
        '-products',
        '*',
        '-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property',
        'installationPath',
      ]);
      expect(visualStudio.exitCode, 0);
      final cmake = p.join(
        visualStudio.stdout.toString().trim(),
        'Common7',
        'IDE',
        'CommonExtensions',
        'Microsoft',
        'CMake',
        'CMake',
        'bin',
        'cmake.exe',
      );
      final fakeSdk = p.join(root.path, 'sdk');
      final fakeDart = File(
        p.join(fakeSdk, 'bin', 'cache', 'dart-sdk', 'bin', 'dart.exe'),
      );
      await fakeDart.parent.create(recursive: true);
      await workerFixture.copy(fakeDart.path);
      final sentinel = p.join(root.path, 'cargokit.complete');
      final calls = p.join(root.path, 'dart-calls.txt');
      final module = p
          .absolute('tool/desktop_mtp_worker.cmake')
          .replaceAll(r'\', '/');
      final fixtureRoot = root.path.replaceAll(r'\', '/');
      await write('cmake/CMakeLists.txt', '''
cmake_minimum_required(VERSION 3.20)
project(MtpGlueFixture LANGUAGES CXX)
set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release" CACHE STRING "" FORCE)
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "\${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "\${CMAKE_CXX_FLAGS_RELEASE}")
add_subdirectory(flutter)
set(BINARY_NAME NSOAlbum)
add_subdirectory(runner)
add_custom_target(squid_album_core_cargokit
  COMMAND "\${CMAKE_COMMAND}" -E touch "$fixtureRoot/cargokit.complete")
include("$module")
add_custom_target(launch_runner)
add_dependencies(launch_runner NSOAlbum)
''');
      // Match the real Runner's policy scope and buildable target. An imported
      // executable does not expose the implicit TARGET_FILE_DIR dependency cycle.
      await write('cmake/runner/CMakeLists.txt', '''
cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)
add_executable(\${BINARY_NAME} main.cpp)
''');
      await write('cmake/runner/main.cpp', 'int main() { return 0; }\n');
      await write(
        'cmake/flutter/CMakeLists.txt',
        'include("\${CMAKE_CURRENT_SOURCE_DIR}/ephemeral/generated_config.cmake")\n',
      );
      await write(
        'cmake/flutter/ephemeral/generated_config.cmake',
        'set(FLUTTER_ROOT "$fixtureRoot/sdk")\n',
      );
      // MSVC's longer link-cvtres tracking filename can exceed MAX_PATH even
      // with a one-letter case build directory. Keep the one graph build
      // directly in this uniquely owned retained run, without another case
      // prefix. Compiler sanity checks and all three configurations stay real.
      final build = p.join(retainedRun.path, 'b');
      final budget = Stopwatch()..start();
      Future<ProcessResult> runCmake(
        List<String> arguments, {
        Map<String, String>? environment,
      }) async {
        final remaining = const Duration(seconds: 90) - budget.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('Owned CMake graph budget exhausted');
        }
        final commandLimit = remaining < const Duration(seconds: 45)
            ? remaining
            : const Duration(seconds: 45);
        final process = await Process.start(
          cmake,
          arguments,
          environment: environment,
        );
        final output = process.stdout.transform(systemEncoding.decoder).join();
        final errors = process.stderr.transform(systemEncoding.decoder).join();
        var exited = false;
        final exit = process.exitCode.then((code) {
          exited = true;
          return code;
        });
        try {
          final code = await exit.timeout(commandLimit);
          return ProcessResult(process.pid, code, await output, await errors);
        } finally {
          if (!exited) {
            // Only this registered, not-yet-exited command's tree is owned.
            final reaper = await Process.start('taskkill.exe', [
              '/PID',
              '${process.pid}',
              '/T',
              '/F',
            ]);
            final reaperOutput = reaper.stdout.drain<void>();
            final reaperErrors = reaper.stderr.drain<void>();
            var reaperExited = false;
            final reaperExit = reaper.exitCode.then((code) {
              reaperExited = true;
              return code;
            });
            try {
              await reaperExit.timeout(const Duration(seconds: 5));
            } finally {
              if (!reaperExited) reaper.kill(ProcessSignal.sigkill);
              await reaperExit.timeout(const Duration(seconds: 5));
              await Future.wait([reaperOutput, reaperErrors])
                  .timeout(const Duration(seconds: 5));
            }
          }
          await exit.timeout(const Duration(seconds: 5));
          await Future.wait([output, errors])
              .timeout(const Duration(seconds: 5));
        }
      }

      final configured = await runCmake([
        '-S',
        p.join(root.path, 'cmake'),
        '-B',
        build,
        '-G',
        'Visual Studio 17 2022',
        '-A',
        'x64',
      ]);
      expect(
        configured.exitCode,
        0,
        reason: '${configured.stdout}\n${configured.stderr}',
      );
      for (final configuration in ['Debug', 'Profile', 'Release']) {
        if (File(sentinel).existsSync()) await File(sentinel).delete();
        final built = await runCmake(
          [
            '--build',
            build,
            '--config',
            configuration,
            '--target',
            'launch_runner',
            '--parallel',
            '1',
          ],
          environment: {
            'NSO_CARGOKIT_SENTINEL': sentinel,
            'NSO_DART_CALLS': calls,
          },
        );
        expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
        expect(
          File(
            p.join(build, 'runner', configuration, 'nsoalbum_mtp_worker.exe'),
          ).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(build, 'runner', configuration, 'NSOAlbum.exe'))
              .existsSync(),
          isTrue,
        );
      }
      final commands = await File(calls).readAsLines();
      expect(commands.length, 3);
      for (final configuration in ['Debug', 'Profile', 'Release']) {
        expect(
          commands
              .where((line) => line.contains('--configuration $configuration'))
              .length,
          1,
        );
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }, skip: windowsSkip);
}
