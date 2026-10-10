import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:squid_album/src/startup/ci_smoke_contract.dart';

typedef SmokeLauncher = Future<SmokeProcessResult> Function(
  String executable,
  List<String> arguments,
  Duration timeout,
);

class SmokeProcessResult {
  const SmokeProcessResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.timedOut = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
}

class SmokeDriverOptions {
  SmokeDriverOptions({
    required this.appPath,
    required this.reportsDirectory,
    this.timeoutSeconds = 600,
    this.fault,
    this.scenarios = const ['normal', 'reopen', 'safe'],
  });

  final String? appPath;
  final String reportsDirectory;
  final int timeoutSeconds;
  final String? fault;
  final List<String> scenarios;

  Duration get timeout => Duration(seconds: timeoutSeconds);

  static SmokeDriverOptions parse(List<String> args) {
    String? appPath;
    String? reports;
    var timeout = 600;
    String? fault;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String? value;
      if (arg == '--launch-app' ||
          arg == '--reports-dir' ||
          arg == '--timeout-seconds' ||
          arg == '--fault') {
        if (i + 1 >= args.length) {
          throw FormatException('Missing value for $arg');
        }
        value = args[++i];
      } else if (arg.startsWith('--launch-app=')) {
        value = arg.substring('--launch-app='.length);
        appPath = value;
        continue;
      } else if (arg.startsWith('--reports-dir=')) {
        value = arg.substring('--reports-dir='.length);
        reports = value;
        continue;
      } else if (arg.startsWith('--timeout-seconds=')) {
        value = arg.substring('--timeout-seconds='.length);
        timeout = int.tryParse(value) ?? -1;
        continue;
      } else if (arg.startsWith('--fault=')) {
        value = arg.substring('--fault='.length);
        fault = value;
        continue;
      } else {
        throw FormatException('Unknown argument: $arg');
      }
      if (arg == '--launch-app') {
        appPath = value;
      } else if (arg == '--reports-dir') {
        reports = value;
      } else if (arg == '--timeout-seconds') {
        timeout = int.tryParse(value) ?? -1;
      } else if (arg == '--fault') {
        fault = value;
      }
    }
    if (timeout < 60 || timeout > 600) {
      throw FormatException('--timeout-seconds must be between 60 and 600');
    }
    return SmokeDriverOptions(
      appPath: appPath,
      reportsDirectory:
          reports ?? p.join(Directory.current.path, 'smoke-reports'),
      timeoutSeconds: timeout,
      fault: fault,
    );
  }
}

class SmokeDriverResult {
  const SmokeDriverResult(this.exitCode, this.failures);

  final int exitCode;
  final List<String> failures;
}

Future<SmokeDriverResult> runReleaseSmoke(
  SmokeDriverOptions options, {
  SmokeLauncher? launch,
}) async {
  final reports = Directory(p.absolute(options.reportsDirectory));
  await reports.create(recursive: true);
  final work = Directory(
    p.join(
      reports.path,
      'work',
      DateTime.now().toUtc().toIso8601String().replaceAll(':', '-'),
    ),
  );
  await work.create(recursive: true);
  final canonicalWork = await work.resolveSymbolicLinks();
  final failures = <String>[];
  final roots = <String>[];
  final nativeReports = <String, Object?>{};
  final logs = <StringBuffer>[];
  final overallWatch = Stopwatch()..start();

  if (options.appPath == null) {
    failures.add('launch-app is required for release smoke');
  } else {
    final executable = _resolveExecutable(options.appPath!);
    if (executable == null) {
      failures.add('launch app must point to an executable inside a bundle');
    } else {
      final runner = launch ?? _launchProcess;
      var normalRoot = '';
      for (final scenario in options.scenarios) {
        if (scenario == 'reopen' && normalRoot.isEmpty) {
          failures.add('reopen requires a successful normal run');
          continue;
        }
        final root = scenario == 'reopen'
            ? normalRoot
            : p.join(
                canonicalWork,
                '$scenario-${DateTime.now().microsecondsSinceEpoch}',
              );
        if (scenario != 'reopen') {
          await Directory(root).create(recursive: true);
        }
        roots.add(root);
        final args = <String>[
          '--ci-smoke',
          '--ci-smoke-root=$root',
          '--ci-smoke-scenario=$scenario',
          if (scenario == 'safe') '--safe-mode',
          if (options.fault != null) '--ci-smoke-fail=${options.fault}',
        ];
        SmokeProcessResult process;
        try {
          final remaining = options.timeout - overallWatch.elapsed;
          if (remaining <= Duration.zero) {
            failures.add('overall smoke timeout exceeded');
            break;
          }
          // The launcher owns timeout cancellation and waits for its process;
          // racing it with another timeout could leave that process running.
          process = await runner(executable, args, remaining);
        } catch (error) {
          process = SmokeProcessResult(
            exitCode: 1,
            stderr: sanitizeSmokeDiagnostic('$error', roots: roots),
          );
        }
        logs.add(
          StringBuffer()
            ..writeln(
              '[$scenario] exit=${process.exitCode}'
              '${process.timedOut ? ' timeout=true' : ''}',
            )
            ..writeln(
              sanitizeSmokeDiagnostic(
                '${process.stdout}\n${process.stderr}',
                roots: roots,
              ),
            ),
        );
        final nativeLog = File(p.join(root, 'logs', 'ci-smoke.log'));
        if (await nativeLog.exists()) {
          final content = await nativeLog
              .openRead(0, 256 * 1024)
              .transform(const Utf8Decoder(allowMalformed: true))
              .join();
          final sanitized = content
              .split('\n')
              .map((line) => sanitizeSmokeDiagnostic(line, roots: roots))
              .join('\n');
          logs.add(StringBuffer('[$scenario] native app log\n$sanitized'));
          await File(p.join(reports.path, 'sanitized-$scenario.log'))
              .writeAsString(sanitized);
        }
        final reportPath = p.join(root, '$scenario.json');
        final reportFile = File(reportPath);
        Map<String, Object?>? report;
        if (await reportFile.exists()) {
          try {
            final decoded = jsonDecode(await reportFile.readAsString());
            if (decoded is Map) {
              report = Map<String, Object?>.from(
                _sanitizeValue(decoded, roots)! as Map,
              );
            }
          } catch (error) {
            failures.add('$scenario report is not valid JSON');
          }
        }
        final validation = report == null
            ? 'missing native report'
            : validateNativeReport(report, scenario: scenario);
        if (validation != null) {
          failures.add('$scenario: $validation');
        }
        if (process.exitCode != 0) {
          failures.add('$scenario exited with code ${process.exitCode}');
        }
        if (process.timedOut) {
          failures.add('$scenario exceeded the overall smoke timeout');
          break;
        }
        if (report != null) {
          nativeReports[scenario] = report;
          await File(
            p.join(reports.path, 'native-$scenario.json'),
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        }
        if (scenario == 'normal' &&
            process.exitCode == 0 &&
            validation == null) {
          normalRoot = root;
        }
      }
      await _copyFailureScreenshots(roots, reports);
    }
  }
  final aggregate = <String, Object?>{
    'schema': 1,
    'status': failures.isEmpty ? 'passed' : 'failed',
    'exitCode': failures.isEmpty ? 0 : 1,
    'scenarios': nativeReports,
    'failures': failures,
  };
  await File(p.join(reports.path, 'report.json'))
      .writeAsString(const JsonEncoder.withIndent('  ').convert(aggregate));
  await File(p.join(reports.path, 'sanitized-process.log'))
      .writeAsString(logs.join('\n'));
  return SmokeDriverResult(failures.isEmpty ? 0 : 1, failures);
}

Object? _sanitizeValue(Object? value, Iterable<String> roots) {
  if (value is String) {
    return sanitizeSmokeDiagnostic(value, roots: roots);
  }
  if (value is List) {
    return value.map((item) => _sanitizeValue(item, roots)).toList();
  }
  if (value is Map) {
    return value.map((key, item) => MapEntry(key, _sanitizeValue(item, roots)));
  }
  return value;
}

String? validateNativeReport(
  Map<String, Object?> report, {
  required String scenario,
}) {
  return CiSmokeReport.accepts(report, scenario: scenario)
      ? null
      : 'native report failed schema or required steps';
}

String? _resolveExecutable(String bundle) {
  final input = FileSystemEntity.typeSync(bundle, followLinks: false);
  if (input == FileSystemEntityType.file) return bundle;
  if (input != FileSystemEntityType.directory) return null;
  final base = p.basenameWithoutExtension(bundle);
  final candidates = Platform.isWindows
      ? [p.join(bundle, '$base.exe'), p.join(bundle, 'NSOAlbum.exe')]
      : [
          p.join(bundle, 'Contents', 'MacOS', base),
          p.join(bundle, 'Contents', 'MacOS', 'NSOAlbum'),
        ];
  for (final candidate in candidates) {
    if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
        FileSystemEntityType.file) {
      return candidate;
    }
  }
  return null;
}

Future<SmokeProcessResult> _launchProcess(
  String executable,
  List<String> arguments,
  Duration timeout,
) async {
  final process = await Process.start(executable, arguments);
  final stdout = _CapturedPipe(process.stdout);
  final stderr = _CapturedPipe(process.stderr);
  var timedOut = false;
  var exit = 124;
  try {
    try {
      exit = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        // Only this Process's PID is targeted. Never kill by executable name.
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 1));
      }
    }
    await Future.wait([stdout.finish(), stderr.finish()]);
    return SmokeProcessResult(
      exitCode: exit,
      stdout: stdout.content,
      stderr: stderr.content,
      timedOut: timedOut,
    );
  } finally {
    await Future.wait([stdout.close(), stderr.close()]);
  }
}

class _CapturedPipe {
  _CapturedPipe(Stream<List<int>> pipe) {
    _subscription = pipe
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (chunk) {
            final remaining = 64 * 1024 - _buffer.length;
            if (remaining > 0) {
              _buffer.write(
                chunk.length > remaining
                    ? chunk.substring(0, remaining)
                    : chunk,
              );
            }
          },
          onError: (Object error) {
            if (!_done.isCompleted) _done.complete();
          },
          onDone: () {
            if (!_done.isCompleted) _done.complete();
          },
        );
  }

  final _buffer = StringBuffer();
  final _done = Completer<void>();
  late final StreamSubscription<String> _subscription;

  String get content => _buffer.toString();

  Future<void> finish() async {
    try {
      await _done.future.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      // A descendant can inherit the pipe. The driver never waits forever.
    }
  }

  Future<void> close() async {
    await _subscription.cancel().timeout(
      const Duration(seconds: 1),
      onTimeout: () {},
    );
  }
}

Future<void> _copyFailureScreenshots(
  Iterable<String> roots,
  Directory reports,
) async {
  var index = 0;
  for (final root in roots) {
    final directory = Directory(root);
    if (!await directory.exists()) continue;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File &&
          p.basename(entity.path).startsWith('failure') &&
          p.extension(entity.path).toLowerCase() == '.png') {
        await entity.copy(p.join(reports.path, 'failure-${index++}.png'));
      }
    }
  }
}

Future<void> main(List<String> args) async {
  try {
    final result = await runReleaseSmoke(SmokeDriverOptions.parse(args));
    exitCode = result.exitCode;
  } on FormatException catch (error) {
    stderr.writeln(sanitizeSmokeDiagnostic(error.message));
    exitCode = 2;
  } catch (error) {
    stderr.writeln(sanitizeSmokeDiagnostic('$error'));
    exitCode = 1;
  }
}
