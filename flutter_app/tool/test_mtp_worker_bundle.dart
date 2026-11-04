import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  Directory? scratch;
  try {
    if (arguments.length != 6 ||
        arguments[0] != '--bundle' ||
        arguments[2] != '--platform' ||
        arguments[4] != '--build-record') {
      throw ArgumentError(
        'Pass --bundle PATH --platform PLATFORM --build-record PATH',
      );
    }
    final bundle = Directory(arguments[1]).absolute;
    final platform = arguments[3];
    final receipt = File(arguments[5]).absolute;
    final verifier = p.join(
      p.dirname(Platform.script.toFilePath()),
      'verify_mtp_worker.dart',
    );
    Future<void> verify(String directory, bool accepted) async {
      final process = await Process.start(Platform.resolvedExecutable, [
        verifier,
        '--bundle',
        directory,
        '--platform',
        platform,
        '--build-record',
        receipt.path,
      ]);
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      var exited = false;
      late int code;
      try {
        code = await process.exitCode.timeout(const Duration(seconds: 25));
        exited = true;
      } finally {
        if (!exited) {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode.timeout(const Duration(seconds: 5));
        }
      }
      if ((code == 0) != accepted) {
        throw StateError(
          'MTP bundle ${accepted ? "positive" : "negative"} control failed: '
          '${await output}${await errors}',
        );
      }
      await Future.wait([output, errors]);
    }

    await verify(bundle.path, true);
    scratch = await Directory.systemTemp.createTemp('nso-mtp-negative-');
    final relative = platform == 'windows-x64'
        ? 'nsoalbum_mtp_worker.exe'
        : p.join('Contents', 'MacOS', 'nsoalbum_mtp_worker');
    final worker = File(p.join(scratch.path, relative));
    await worker.parent.create(recursive: true);
    if (platform == 'windows-x64') {
      await File(p.join(bundle.path, 'squid_album_core.dll'))
          .copy(p.join(scratch.path, 'squid_album_core.dll'));
    }
    // These product checks run independently of the general CI file seal.
    await verify(scratch.path, false);
    await worker.writeAsBytes(const []);
    await verify(scratch.path, false);
    await worker.writeAsString('corrupt native helper');
    await verify(scratch.path, false);
    await File(p.join(bundle.path, relative)).copy(worker.path);
    final bytes = await worker.readAsBytes();
    if (platform == 'windows-x64') {
      final pe = bytes[60] | bytes[61] << 8 | bytes[62] << 16 | bytes[63] << 24;
      bytes[pe + 4] = 0x4c;
      bytes[pe + 5] = 0x01;
    } else {
      bytes[4] = platform == 'macos-arm64' ? 7 : 12;
      final chmod = await Process.run('chmod', ['+x', worker.path]);
      if (chmod.exitCode != 0) {
        throw StateError('Cannot prepare executable fixture');
      }
    }
    await worker.writeAsBytes(bytes);
    await verify(scratch.path, false);
    stdout.writeln(
      jsonEncode({
        'mtpHelperNegativeControls': 'passed',
        'platform': platform,
        'cases': ['missing', 'empty', 'corrupt', 'wrong-architecture'],
      }),
    );
  } catch (error) {
    stderr.writeln('MTP helper negative controls failed: $error');
    exitCode = 1;
  } finally {
    if (scratch != null) await scratch.delete(recursive: true);
  }
}
