import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'verify_mtp_worker.dart' show inspectNativeExecutable;

const desktopTargets = {
  'x86_64-pc-windows-msvc': 'windows-x64',
  'aarch64-apple-darwin': 'macos-arm64',
  'x86_64-apple-darwin': 'macos-x64',
};

Future<void> buildUniversalMac(
  Map<String, String> options,
  List<String> targets,
  String configuration,
) async {
  final reportFile = File(p.absolute(options['--report']!));
  final output = File(p.absolute(options['--output']!));
  await reportFile.parent.create(recursive: true);
  final staging = await reportFile.parent.createTemp('mtp-slices-');
  final slices = <Map<String, dynamic>>[];
  final slicePaths = <String>[];
  for (final target in targets) {
    final slicePath = p.join(staging.path, target, 'nsoalbum_mtp_worker');
    final sliceReport = '${reportFile.path}.$target.json';
    final result = await Process.run(Platform.resolvedExecutable, [
      Platform.script.toFilePath(),
      '--target',
      target,
      '--configuration',
      configuration,
      '--output',
      slicePath,
      '--report',
      sliceReport,
      '--cargo-log',
      '${options['--cargo-log']}.$target.jsonl',
    ]);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      throw StateError('Cargo helper slice failed: $target');
    }
    final record = jsonDecode(
      await File(sliceReport).readAsString(),
    ) as Map<String, dynamic>;
    final profile = configuration == 'Debug' ? 'debug' : 'release';
    if (record['cargoSuccess'] != true ||
        record['target'] != target ||
        record['profile'] != profile) {
      throw StateError('Mismatched Cargo helper slice: $target');
    }
    await inspectNativeExecutable(File(slicePath), desktopTargets[target]!);
    final digest = (await sha256.bind(File(slicePath).openRead()).first)
        .toString();
    if (digest != (record['worker'] as Map)['sha256']) {
      throw StateError('Copied helper slice changed: $target');
    }
    slices.add(record);
    slicePaths.add(slicePath);
  }
  final combined = File(p.join(staging.path, 'nsoalbum_mtp_worker'));
  final lipo = Platform.environment['LIPO'] ?? 'lipo';
  final merged = await Process.run(lipo, [
    '-create',
    ...slicePaths,
    '-output',
    combined.path,
  ]);
  if (merged.exitCode != 0 ||
      !await combined.exists() ||
      await combined.length() == 0) {
    throw StateError(
      'Cannot combine current Cargo helper slices: ${merged.stderr}',
    );
  }
  final inspected = await Process.run(lipo, ['-archs', combined.path]);
  final architectures = inspected.stdout.toString().trim().split(
    RegExp(r'\s+'),
  );
  if (inspected.exitCode != 0 ||
      architectures.length != 2 ||
      architectures.toSet().length != 2 ||
      !architectures.contains('arm64') ||
      !architectures.contains('x86_64')) {
    throw StateError(
      'Combined MTP helper must contain exactly arm64 and x86_64',
    );
  }
  final hash = (await sha256.bind(combined.openRead()).first).toString();
  await output.parent.create(recursive: true);
  await combined.copy(output.path);
  if ((await sha256.bind(output.openRead()).first).toString() != hash) {
    throw StateError('Combined helper copy differs from the lipo output');
  }
  await reportFile.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert({
      'schema': 1,
      'cargoSuccess': true,
      'targets': targets,
      'configuration': configuration,
      'profile': configuration == 'Debug' ? 'debug' : 'release',
      'slices': slices,
      'worker': {'path': combined.path, 'sha256': hash},
    })}\n',
  );
  stdout.writeln('Universal helper copied: ${output.path} SHA-256=$hash');
}

Future<void> main(List<String> arguments) async {
  try {
    final options = <String, String>{};
    var library = false;
    for (var index = 0; index < arguments.length; index++) {
      final key = arguments[index];
      if (key == '--library') {
        library = true;
      } else if (const {
            '--target',
            '--configuration',
            '--output',
            '--report',
            '--cargo-log',
          }.contains(key) &&
          index + 1 < arguments.length &&
          !options.containsKey(key)) {
        options[key] = arguments[++index];
      } else {
        throw ArgumentError('Invalid build argument: $key');
      }
    }
    final targets = options['--target']?.split(',') ?? const <String>[];
    final configuration = options['--configuration'];
    if (targets.isEmpty ||
        targets.any((target) => !desktopTargets.containsKey(target)) ||
        targets.toSet().length != targets.length ||
        (targets.length > 1 &&
            (targets.length != 2 ||
                targets.any((target) => !target.endsWith('-apple-darwin')))) ||
        !const {'Debug', 'Profile', 'Release'}.contains(configuration) ||
        options['--output'] == null ||
        options['--report'] == null ||
        options['--cargo-log'] == null) {
      throw ArgumentError(
        'Pass a desktop --target, --configuration Debug|Profile|Release, '
        '--output, --report and --cargo-log; --library also builds the DLL.',
      );
    }
    final target = targets.singleOrNull;
    if (library && target != 'x86_64-pc-windows-msvc') {
      throw ArgumentError('--library is only used for Windows DLL packaging');
    }
    final pendingReport = File(p.absolute(options['--report']!));
    await pendingReport.parent.create(recursive: true);
    await pendingReport.writeAsString(
      jsonEncode({
        'schema': 1,
        'cargoSuccess': false,
        'targets': targets,
        'configuration': configuration,
      }),
    );
    if (targets.length == 2) {
      await buildUniversalMac(options, targets, configuration!);
      return;
    }
    final project = p.dirname(p.dirname(Platform.script.toFilePath()));
    final rust = p.join(p.dirname(project), 'rust_core');
    final profile = configuration == 'Debug' ? 'debug' : 'release';
    final command = [
      'build',
      '--manifest-path',
      p.join(rust, 'Cargo.toml'),
      '--target',
      target!,
      if (profile == 'release') '--release',
      if (library) '--lib',
      '--bin',
      'nsoalbum_mtp_worker',
      '--message-format=json-render-diagnostics',
      '--locked',
    ];
    final logFile = File(p.absolute(options['--cargo-log']!));
    final reportFile = File(p.absolute(options['--report']!));
    await logFile.parent.create(recursive: true);
    await reportFile.parent.create(recursive: true);
    final log = logFile.openWrite();
    final artifacts = <Map<String, dynamic>>[];
    var finished = false;
    Object? parseFailure;
    try {
      final cargo = await Process.start(
        Platform.environment['CARGO'] ?? 'cargo',
        command,
        workingDirectory: rust,
      );
      final output = cargo.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            log.writeln(line);
            try {
              final event = jsonDecode(line) as Map<String, dynamic>;
              if (event['reason'] == 'build-finished') {
                finished = event['success'] == true;
              } else if (event['reason'] == 'compiler-artifact') {
                artifacts.add(event);
              } else if (event['reason'] == 'compiler-message') {
                final message = event['message'] as Map<String, dynamic>;
                stderr.write(message['rendered'] ?? '');
              }
            } catch (error) {
              parseFailure ??= error;
            }
          });
      final errors = cargo.stderr.forEach(stderr.add);
      final code = await cargo.exitCode;
      await Future.wait([output, errors]);
      if (code != 0 || !finished || parseFailure != null) {
        throw StateError('Cargo did not finish successfully (exit $code)');
      }
    } finally {
      await log.close();
    }

    Map<String, dynamic> select(String name, String kind) {
      final matches = artifacts.where((event) {
        final item = event['target'] as Map<String, dynamic>;
        return item['name'] == name &&
            (item['kind'] as List).contains(kind) &&
            p.equals(
              event['manifest_path'] as String,
              p.join(rust, 'Cargo.toml'),
            );
      }).toList();
      if (matches.length != 1) {
        throw StateError('Cargo must report exactly one $name $kind artifact');
      }
      final event = matches.single;
      final details = event['profile'] as Map<String, dynamic>;
      if (details['test'] != false ||
          (profile == 'debug'
              ? details['opt_level'] != '0'
              : details['opt_level'] == '0')) {
        throw StateError('Cargo artifact does not match $profile: $name');
      }
      return event;
    }

    Future<Map<String, dynamic>> describe(String source) async {
      final file = File(source);
      if (!p.isAbsolute(source) ||
          !await file.exists() ||
          await file.length() == 0) {
        throw StateError('Cargo reported a missing or empty artifact: $source');
      }
      return {
        'path': p.normalize(source),
        'sha256': (await sha256.bind(file.openRead()).first).toString(),
      };
    }

    final worker = select('nsoalbum_mtp_worker', 'bin');
    final executable = worker['executable'];
    if (executable is! String) {
      throw StateError('Cargo did not report the helper executable');
    }
    await inspectNativeExecutable(File(executable), desktopTargets[target]!);
    final workerRecord = await describe(executable);
    Map<String, dynamic>? libraryRecord;
    if (library) {
      final nativeLibrary = select('squid_album_core', 'cdylib');
      final dlls = (nativeLibrary['filenames'] as List)
          .whereType<String>()
          .where((path) => p.basename(path) == 'squid_album_core.dll')
          .toList();
      if (dlls.length != 1) {
        throw StateError('Cargo did not report exactly one release DLL');
      }
      libraryRecord = await describe(dlls.single);
    }
    final output = File(p.absolute(options['--output']!));
    await output.parent.create(recursive: true);
    if (p.normalize(executable) != p.normalize(output.path)) {
      await File(executable).copy(output.path);
    }
    final copiedHash = (await sha256.bind(output.openRead()).first).toString();
    if (copiedHash != workerRecord['sha256']) {
      throw StateError('Copied helper differs from the Cargo artifact');
    }
    final report = {
      'schema': 1,
      'cargoSuccess': true,
      'target': target,
      'configuration': configuration,
      'profile': profile,
      'cargoArguments': command,
      'cargoLogSha256': (await sha256.bind(logFile.openRead()).first)
          .toString(),
      'worker': workerRecord,
      'library': ?libraryRecord,
    };
    await reportFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    );
    stdout.writeln('Native $target $profile helper: $executable');
    stdout.writeln('Helper SHA-256: $copiedHash');
    if (libraryRecord != null) {
      stdout.writeln('Native DLL: ${libraryRecord['path']}');
      stdout.writeln('DLL SHA-256: ${libraryRecord['sha256']}');
    }
  } catch (error) {
    stderr.writeln('Desktop native build failed: $error');
    exitCode = 1;
  }
}
