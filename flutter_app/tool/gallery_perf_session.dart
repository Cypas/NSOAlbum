// Resident local launcher. Flutter machine protocol, VM auth, and app output
// remain in memory. Requires an explicitly configured build-copy root.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service_io.dart';

import 'gallery_perf_capture.dart';
import 'gallery_perf_report.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length.isOdd) {
    stderr.writeln('invalid_launcher_configuration');
    exitCode = 64;
    return;
  }
  final options = <String, String>{};
  for (var i = 0; i + 1 < arguments.length; i += 2) {
    if (!const {'--mode', '--device', '--binary'}.contains(arguments[i])) {
      stderr.writeln('invalid_launcher_configuration');
      exitCode = 64;
      return;
    }
    options[arguments[i].replaceFirst('--', '')] = arguments[i + 1];
  }
  final mode = options['mode'];
  final device = options['device'];
  final binary = options['binary'];
  final root = Directory.current.absolute.path;
  final buildRoot = Platform.environment['NSOALBUM_BUILD_ROOT'];
  if (buildRoot == null ||
      !p.equals(root, p.join(buildRoot, 'source', 'flutter_app')) ||
      !{'debug', 'profile'}.contains(mode) ||
      device == null ||
      binary == null ||
      !File(binary).existsSync()) {
    stderr.writeln('invalid_launcher_configuration');
    exitCode = 64;
    return;
  }
  late final Process flutter;
  try {
    flutter = await Process.start(
      Platform.environment['NSOALBUM_FLUTTER'] ??
          (Platform.isWindows ? 'flutter.bat' : 'flutter'),
      [
        'run',
        '--machine',
        '--no-pub',
        '--endless-trace-buffer',
        '--$mode',
        '-d',
        device,
        '--use-application-binary',
        binary,
        '--dart-define=NSO_GALLERY_PERF=true',
      ],
      runInShell: true,
    );
  } catch (_) {
    stderr.writeln('launcher_failed');
    exitCode = 1;
    return;
  }
  String? uri;
  String? appId;
  var sequence = 100;
  final pending = <int, Completer<Map>>{};
  flutter.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      try {
        final message = jsonDecode(line);
        if (message is! List) return;
        for (final event in message) {
          if (event is! Map) continue;
          if (event['id'] is int) {
            pending.remove(event['id'])?.complete(event);
          }
          if (event['event'] == 'app.start' && event['params'] is Map) {
            appId = (event['params'] as Map)['appId'] as String?;
          }
          if (event['event'] == 'app.debugPort') {
            final params = event['params'] as Map;
            final candidate = params['wsUri'];
            if (candidate is String &&
                candidate.startsWith('ws://127.0.0.1:')) {
              uri = candidate;
              stdout.writeln('service_ready');
            }
          }
          if (event['event'] == 'app.started') stdout.writeln('app_started');
          if (event['event'] == 'app.stop') {
            final params = event['params'];
            final code = params is Map ? params['exitCode'] : null;
            stdout.writeln(code is num ? 'app_stopped=$code' : 'app_stopped');
          }
          if (event['error'] != null) stdout.writeln('machine_error');
        }
      } catch (_) {
        // Raw application messages can contain personal data; never forward.
      }
    },
  );
  flutter.stderr.listen((_) {});
  unawaited(
    flutter.exitCode.then((code) => stdout.writeln('flutter_exit=$code')),
  );
  stdout.writeln('launcher_ready');
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final args = line.trim().split(RegExp(r'\s+'));
    try {
      if (args.first == 'quit') {
        // Call after normal UI close; detach does not send an app kill.
        flutter.stdin.writeln(
          jsonEncode([
            {'id': 99, 'method': 'daemon.shutdown'},
          ]),
        );
        await flutter.stdin.flush();
        break;
      }
      if (uri == null) {
        stdout.writeln('service_not_ready');
        continue;
      }
      if (args.first == 'restart' && args.length == 1 && appId != null) {
        final id = ++sequence;
        final completion = Completer<Map>();
        pending[id] = completion;
        flutter.stdin.writeln(
          jsonEncode([
            {
              'id': id,
              'method': 'app.restart',
              'params': {'appId': appId, 'fullRestart': true, 'pause': false},
            },
          ]),
        );
        await flutter.stdin.flush();
        try {
          final response = await completion.future.timeout(
            const Duration(seconds: 90),
          );
          final result = response['result'];
          stdout.writeln(
            response['error'] == null && result is Map && result['code'] == 0
                ? 'restart_success'
                : 'restart_failed',
          );
        } finally {
          pending.remove(id);
        }
        continue;
      }
      if (args.first == 'policy' &&
          args.length == 2 &&
          const {'immediate', 'settled'}.contains(args[1])) {
        final service = await vmServiceConnectUri(uri!);
        try {
          final vm = await service.getVM();
          var applied = false;
          for (final ref in vm.isolates ?? []) {
            final isolate = await service.getIsolate(ref.id!);
            if (isolate.extensionRPCs?.contains(
                  'ext.squid_album.galleryPerf',
                ) !=
                true) {
              continue;
            }
            final response = await service.callServiceExtension(
              'ext.squid_album.galleryPerf',
              isolateId: ref.id,
              args: {'action': 'loadingPolicy', 'policy': args[1]},
            );
            applied = response.json?['ok'] == true;
            break;
          }
          stdout.writeln(
            applied ? 'policy_applied=${args[1]}' : 'policy_failed',
          );
        } finally {
          await service.dispose();
        }
        continue;
      }
      if (args.first == 'status') {
        final service = await vmServiceConnectUri(uri!);
        try {
          final vm = await service.getVM();
          var found = false;
          for (final ref in vm.isolates ?? []) {
            final isolate = await service.getIsolate(ref.id!);
            if (isolate.extensionRPCs?.contains(
                  'ext.squid_album.galleryPerf',
                ) !=
                true) {
              continue;
            }
            final response = await service.callServiceExtension(
              'ext.squid_album.galleryPerf',
              isolateId: ref.id,
              args: {'action': 'snapshot'},
            );
            if (response.json?['ok'] != true) {
              stdout.writeln('extension_unavailable');
              found = true;
              break;
            }
            stdout.writeln(
              jsonEncode(sanitizeGallerySnapshot(response.json ?? {})),
            );
            found = true;
            break;
          }
          if (!found) stdout.writeln('extension_unavailable');
        } finally {
          await service.dispose();
        }
        continue;
      }
      if (!const {
            'capture',
            'capture-thumb',
            'capture-detail',
          }.contains(args.first) ||
          args.length != 6 ||
          !galleryScenarios.contains(args[1]) ||
          !galleryCoverModes.contains(args[4]) ||
          !RegExp(r'^[a-zA-Z0-9_.-]+[.]json$').hasMatch(args[3])) {
        stdout.writeln('invalid_command');
        continue;
      }
      final millis = int.parse(args[2]);
      final repetition = int.parse(args[5]);
      if (millis < 100 || millis > 120000 || repetition < 1) {
        stdout.writeln('invalid_command');
        continue;
      }
      final report = await captureGallery(
        serviceUri: uri!,
        duration: Duration(milliseconds: millis),
        scenario: args[1],
        coverMode: args[4],
        status: stdout.writeln,
        replayWheel:
            const {'capture', 'capture-detail'}.contains(args.first) &&
            device == 'windows',
        profileFramework: args.first == 'capture-detail',
      );
      report['platform'] = device == 'windows' ? 'windows' : 'android';
      report['mode'] = mode;
      report['repetition'] = repetition;
      final destination = File(p.join(buildRoot, 'perf', args[3]));
      await destination.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
      stdout.writeln('report_saved=${args[3]}');
    } catch (error) {
      stdout.writeln('capture_failed=${captureFailureReason(error)}');
    }
  }
}
