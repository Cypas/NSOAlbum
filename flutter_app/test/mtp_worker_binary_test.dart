@Tags(['common'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../tool/verify_mtp_worker.dart';

void main() {
  late Directory root;
  late File file;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nso-native-header-');
    file = File(p.join(root.path, 'helper'));
  });
  tearDown(() => root.delete(recursive: true));

  Uint8List mach(int cpu, {int kind = 2}) {
    final bytes = ByteData(128)
      ..setUint32(0, 0xfeedfacf, Endian.little)
      ..setUint32(4, cpu, Endian.little)
      ..setUint32(12, kind, Endian.little);
    return bytes.buffer.asUint8List();
  }

  Future<void> executable(List<int> bytes) async {
    await file.writeAsBytes(bytes);
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['+x', file.path]);
      expect(result.exitCode, 0);
    }
  }

  test('missing and empty native helper files fail before launch', () async {
    await expectLater(
      inspectNativeExecutable(file, 'windows-x64'),
      throwsStateError,
    );
    await file.writeAsBytes(const []);
    await expectLater(
      inspectNativeExecutable(file, 'windows-x64'),
      throwsStateError,
    );
  });

  for (final platform in {
    'macos-arm64': 0x0100000c,
    'macos-x64': 0x01000007,
  }.entries) {
    test(
      '${platform.key} accepts only its own thin executable CPU header',
      () async {
        await executable(mach(platform.value));
        await expectLater(
          inspectNativeExecutable(file, platform.key),
          completes,
        );
        await executable(
          mach(platform.value == 0x0100000c ? 0x01000007 : 0x0100000c),
        );
        await expectLater(
          inspectNativeExecutable(file, platform.key),
          throwsStateError,
        );
        await executable(mach(platform.value, kind: 6));
        await expectLater(
          inspectNativeExecutable(file, platform.key),
          throwsStateError,
        );
      },
    );
  }

  test('PE parser rejects a header offset outside the actual file', () async {
    final bytes = ByteData(128)
      ..setUint8(0, 0x4d)
      ..setUint8(1, 0x5a)
      ..setUint32(60, 0xfffffff0, Endian.little);
    await file.writeAsBytes(bytes.buffer.asUint8List());
    await expectLater(
      inspectNativeExecutable(file, 'windows-x64'),
      throwsStateError,
    );
  });

  test('Android cannot be accepted as a desktop helper target', () async {
    await executable(mach(0x0100000c));
    await expectLater(
      inspectNativeExecutable(file, 'android-arm64'),
      throwsArgumentError,
    );
  });

  test(
    'a non-executable Mach-O file is rejected',
    () async {
      await file.writeAsBytes(mach(0x0100000c));
      final result = await Process.run('chmod', ['-x', file.path]);
      expect(result.exitCode, 0);
      await expectLater(
        inspectNativeExecutable(file, 'macos-arm64'),
        throwsStateError,
      );
    },
    skip: Platform.isWindows
        ? 'POSIX executable bits require a Unix host; Windows PE execution is tested separately'
        : false,
  );
}
