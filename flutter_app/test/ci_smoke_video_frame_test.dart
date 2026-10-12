import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/startup/ci_smoke_contract.dart';

void main() {
  test(
    'a completed output signal cannot substitute for a new decoded frame',
    () async {
      await expectLater(
        verifySmokeVideoFrame(capture: () async => null, decode: (_) async {}),
        throwsStateError,
      );
    },
  );

  test(
    'each playback assertion must capture and decode its own frame',
    () async {
      final decoded = <int>[];
      for (final value in [10, 20, 30]) {
        await verifySmokeVideoFrame(
          capture: () async => Uint8List.fromList([value]),
          decode: (bytes) async => decoded.add(bytes.single),
        );
      }
      expect(decoded, [10, 20, 30]);
    },
  );

  test('empty or undecodable frames cannot pass playback validation', () async {
    await expectLater(
      verifySmokeVideoFrame(
        capture: () async => Uint8List(0),
        decode: (_) async {},
      ),
      throwsStateError,
    );
    await expectLater(
      verifySmokeVideoFrame(
        capture: () async => Uint8List.fromList([1]),
        decode: (_) async => throw const FormatException('Invalid image'),
      ),
      throwsFormatException,
    );
  });
}
