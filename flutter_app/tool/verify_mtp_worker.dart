import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const maxNativeHeader = 64 * 1024;
// This probe accepts only Close: raw media payloads are never valid here.
const maxNativeIpc = maxNativeHeader + 16;
const _nativeMagic = <int>[78, 83, 79, 77, 84, 80, 50, 0];

Future<void> inspectNativeExecutable(File file, String platform) async {
  if (!await file.exists() ||
      await file.length() < 64 ||
      await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw StateError(
      'Required MTP helper is missing, empty, linked or corrupt',
    );
  }
  final reader = await file.open();
  try {
    final header = await reader.read(64);
    final data = ByteData.sublistView(header);
    if (platform == 'windows-x64') {
      if (header[0] != 0x4d || header[1] != 0x5a) {
        throw StateError('MTP helper is not a PE executable');
      }
      final offset = data.getUint32(60, Endian.little);
      if (offset < 64 || offset > await file.length() - 26) {
        throw StateError('MTP helper PE header is out of bounds');
      }
      await reader.setPosition(offset);
      final pe = ByteData.sublistView(await reader.read(26));
      if (pe.getUint32(0, Endian.little) != 0x4550 ||
          pe.getUint16(4, Endian.little) != 0x8664 ||
          pe.getUint16(24, Endian.little) != 0x20b ||
          pe.getUint16(22, Endian.little) & 0x2000 != 0) {
        throw StateError('MTP helper must be a Windows x64 PE32+ executable');
      }
    } else if (platform == 'macos-arm64' || platform == 'macos-x64') {
      final cpu = platform == 'macos-arm64' ? 0x0100000c : 0x01000007;
      if (data.getUint32(0, Endian.little) != 0xfeedfacf ||
          data.getUint32(4, Endian.little) != cpu ||
          data.getUint32(12, Endian.little) != 2) {
        throw StateError(
          'MTP helper must be a native thin $platform Mach-O executable',
        );
      }
      if (!Platform.isWindows && (await file.stat()).mode & 0x49 == 0) {
        throw StateError('MTP helper is not executable');
      }
    } else {
      throw ArgumentError('Unsupported desktop platform: $platform');
    }
  } finally {
    await reader.close();
  }
}

Future<void> probeMtpWorker(
  File worker, {
  Duration timeout = const Duration(seconds: 10),
  Future<void>? cancelled,
}) async {
  final environment = Map<String, String>.from(Platform.environment);
  if (Platform.isWindows) {
    final windows = environment.entries
        .where((entry) => entry.key.toLowerCase() == 'systemroot')
        .map((entry) => entry.value)
        .single;
    environment.removeWhere((key, _) => key.toLowerCase() == 'path');
    environment['PATH'] = [
      worker.absolute.parent.path,
      p.join(windows, 'System32'),
      windows,
    ].join(';');
  } else {
    environment.removeWhere(
      (key, _) => key.startsWith('DYLD_') || key == 'LD_LIBRARY_PATH',
    );
  }
  final process = await Process.start(
    worker.absolute.path,
    const [],
    workingDirectory: worker.absolute.parent.path,
    environment: environment,
    includeParentEnvironment: false,
  );
  final response = BytesBuilder(copy: false);
  final completion = Completer<void>();
  completion.future.ignore();
  final stdoutDone = Completer<void>();
  var stderrBytes = 0;
  var naturalExit = false;
  void fail(Object error) {
    if (!completion.isCompleted) completion.completeError(error);
  }

  final output = process.stdout.listen(
    (bytes) {
      if (response.length + bytes.length > maxNativeIpc + 4) {
        fail(StateError('MTP helper response exceeds the IPC limit'));
        return;
      }
      response.add(bytes);
      if (response.length >= 4) {
        final packet = response.toBytes();
        final length = ByteData.sublistView(packet).getUint32(0);
        if (length < 16 ||
            length > maxNativeIpc ||
            packet.length > length + 4) {
          fail(StateError('MTP helper returned an invalid or excessive frame'));
        }
      }
    },
    onError: (Object error) {
      fail(error);
      if (!stdoutDone.isCompleted) stdoutDone.complete();
    },
    onDone: () {
      if (!stdoutDone.isCompleted) stdoutDone.complete();
    },
  );
  final errors = process.stderr.listen((bytes) {
    stderrBytes += bytes.length;
    if (stderrBytes > 65536) {
      fail(StateError('MTP helper stderr exceeds its limit'));
    }
  }, onError: fail);
  final timer = Timer(
    timeout,
    () => fail(TimeoutException('MTP helper Close timed out')),
  );
  cancelled?.then(
    (_) => fail(StateError('MTP helper verification cancelled')),
    onError: fail,
  );
  final exited = process.exitCode.then((code) async {
    naturalExit = true;
    await stdoutDone.future;
    if (completion.isCompleted) return;
    try {
      if (code != 0) throw StateError('MTP helper exited with code $code');
      final packet = response.toBytes();
      if (packet.length < 21 ||
          ByteData.sublistView(packet).getUint32(0) != packet.length - 4) {
        throw StateError('MTP helper returned an incomplete Close response');
      }
      final envelope = ByteData.sublistView(packet);
      for (var index = 0; index < _nativeMagic.length; index++) {
        if (packet[4 + index] != _nativeMagic[index]) {
          throw StateError('MTP helper IPC version is incompatible');
        }
      }
      final headerLength = envelope.getUint32(12);
      final payloadLength = envelope.getUint32(16);
      if (headerLength == 0 ||
          headerLength > maxNativeHeader ||
          payloadLength != 0 ||
          packet.length != 20 + headerLength) {
        throw StateError(
          'MTP helper returned invalid Close lengths or payload',
        );
      }
      final value = jsonDecode(utf8.decode(packet.sublist(20)));
      if (value is! Map ||
          value.length != 2 ||
          value['payload_length'] != 0 ||
          value['value'] is! Map ||
          (value['value'] as Map).length != 1 ||
          !(value['value'] as Map).containsKey('Ok') ||
          value['value']['Ok'] != null) {
        throw StateError('MTP helper did not return successful null Close');
      }
      completion.complete();
    } catch (error) {
      fail(error);
    }
  });
  try {
    final request = utf8.encode('{"method":"close"}');
    final frame = ByteData(20)
      ..setUint32(0, 16 + request.length)
      ..setUint32(12, request.length)
      ..setUint32(16, 0);
    for (var index = 0; index < _nativeMagic.length; index++) {
      frame.setUint8(4 + index, _nativeMagic[index]);
    }
    process.stdin.add(frame.buffer.asUint8List());
    process.stdin.add(request);
    await process.stdin.flush();
    await process.stdin.close();
    await completion.future;
  } finally {
    timer.cancel();
    if (!naturalExit) {
      process.kill(ProcessSignal.sigkill);
    }
    await process.exitCode.timeout(const Duration(seconds: 5));
    await exited.timeout(const Duration(seconds: 5));
    await output.cancel();
    await errors.cancel();
  }
}

Future<void> main(List<String> arguments) async {
  try {
    final options = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length ||
          !const {
            '--bundle',
            '--platform',
            '--build-record',
            '--write-record',
          }.contains(arguments[index]) ||
          options.containsKey(arguments[index])) {
        throw ArgumentError('Invalid verification arguments');
      }
      options[arguments[index]] = arguments[index + 1];
    }
    final bundle = options['--bundle'];
    final platform = options['--platform'];
    if (bundle == null || platform == null) {
      throw ArgumentError('Pass --bundle and --platform');
    }
    final root = Directory(bundle).absolute;
    if (!await root.exists()) throw StateError('MTP bundle does not exist');
    final worker = File(
      p.joinAll([
        root.path,
        if (platform.startsWith('macos-')) ...['Contents', 'MacOS'],
        platform == 'windows-x64'
            ? 'nsoalbum_mtp_worker.exe'
            : 'nsoalbum_mtp_worker',
      ]),
    );
    await inspectNativeExecutable(worker, platform);
    final canonical = await worker.resolveSymbolicLinks();
    if (!p.isWithin(await root.resolveSymbolicLinks(), canonical)) {
      throw StateError('MTP helper escapes its bundle');
    }
    final hash = (await sha256.bind(worker.openRead()).first).toString();
    Map<String, dynamic>? record;
    if (options['--build-record'] case final String path) {
      record =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      final expectedTarget = {
        'windows-x64': 'x86_64-pc-windows-msvc',
        'macos-arm64': 'aarch64-apple-darwin',
        'macos-x64': 'x86_64-apple-darwin',
      }[platform];
      if (record['schema'] != 1 ||
          record['cargoSuccess'] != true ||
          record['target'] != expectedTarget ||
          record['profile'] != 'release' ||
          !const {'Profile', 'Release'}.contains(record['configuration'])) {
        throw StateError(
          'MTP helper differs from the same-run native build record',
        );
      }
      final expectedHash =
          record['packagedSha256'] ?? (record['worker'] as Map?)?['sha256'];
      if (expectedHash != hash) {
        // The build gate checked the copied bytes before signing. Signing
        // changes Mach-O bytes, so bind the final signed file before sealing.
        if (!platform.startsWith('macos-') ||
            options['--write-record'] == null ||
            record['packagedSha256'] != null) {
          throw StateError('MTP helper SHA differs from its same-run build');
        }
        final signature = await Process.run('codesign', [
          '--verify',
          '--strict',
          worker.path,
        ]);
        if (signature.exitCode != 0) {
          throw StateError('Final MTP helper signature is invalid');
        }
        final source = record['worker'] as Map;
        final sourceFile = File(source['path'] as String);
        if (!await sourceFile.exists() ||
            (await sha256.bind(sourceFile.openRead()).first).toString() !=
                source['sha256']) {
          throw StateError(
            'The original Cargo helper build is unavailable or changed',
          );
        }
      }
      if (platform == 'windows-x64') {
        final libraryHash =
            record['librarySha256'] ?? (record['library'] as Map?)?['sha256'];
        final library = File(p.join(root.path, 'squid_album_core.dll'));
        if (libraryHash == null ||
            !await library.exists() ||
            (await sha256.bind(library.openRead()).first).toString() !=
                libraryHash) {
          throw StateError(
            'Packaged DLL differs from the same-run native build',
          );
        }
      }
    }
    final cancellation = Completer<void>();
    final signal = ProcessSignal.sigint.watch().listen((_) {
      if (!cancellation.isCompleted) cancellation.complete();
    });
    try {
      await probeMtpWorker(worker, cancelled: cancellation.future);
    } finally {
      await signal.cancel();
    }
    if (options['--write-record'] case final String path) {
      if (record == null) {
        throw StateError('Writing a final record requires a build record');
      }
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert({'schema': 1, 'cargoSuccess': true, 'target': record['target'], 'profile': record['profile'], 'configuration': record['configuration'], 'cargoLogSha256': record['cargoLogSha256'], 'sourceSha256': (record['worker'] as Map?)?['sha256'] ?? record['sourceSha256'], 'packagedSha256': hash, if (record['library'] is Map) 'librarySha256': (record['library'] as Map)['sha256']})}\n',
      );
    }
    stdout.writeln(
      'MTP helper verified: $platform SHA-256=$hash Close=null exit=0',
    );
  } catch (error) {
    stderr.writeln('MTP helper verification failed: $error');
    exitCode = 1;
  }
}
