import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/device_sync_qa_fixture.dart';
import '../../tool/device_sync_qa_root.dart';

void main() {
  test(
    'realistic throughput fixture uses normal-size images and a large video',
    () async {
      final root = await createDeviceSyncQaRoot();
      const seed = [0, 0, 0, 12, 102, 116, 121, 112, 105, 115, 111, 109];
      final files = await createDeviceSyncRealisticThroughputFixture(
        root,
        videoSeed: seed,
      );
      expect(files, hasLength(17));
      expect(files.first.path, endsWith('.mp4'));
      expect(await files.first.length(), 56 * 1024 * 1024);
      expect(await files.first.openRead(0, 12).first, seed);
      // Appended padding is one MP4 "free" box, not invalid trailing samples.
      final padding = await files.first.openRead(12, 20).first;
      expect(padding.sublist(4), [102, 114, 101, 101]);
      var total = await files.first.length();
      final hashes = <String>{};
      for (var index = 1; index < files.length; index++) {
        expect(files[index].path, endsWith('.png'));
        final size = await files[index].length();
        expect(size, index.isOdd ? 1024 * 1024 : 2 * 1024 * 1024);
        total += size;
        hashes.add(
          (await sha256.bind(files[index].openRead()).single).toString(),
        );
      }
      expect(total, 80 * 1024 * 1024);
      expect(hashes, hasLength(16));
    },
  );

  test(
    'realistic fixture rejects unowned storage and unbounded seeds',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'nsoalbum-unowned-realistic-',
      );
      await expectLater(
        createDeviceSyncRealisticThroughputFixture(
          root,
          videoSeed: const [1, 2, 3],
        ),
        throwsStateError,
      );
      expect(await root.list().isEmpty, isTrue);
      final owned = await createDeviceSyncQaRoot();
      await expectLater(
        createDeviceSyncRealisticThroughputFixture(
          owned,
          videoSeed: List<int>.filled(1024 * 1024 + 1, 0),
        ),
        throwsArgumentError,
      );
    },
  );

  testWidgets('synthetic media PNG decodes with the real Flutter codec', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        base64Decode(syntheticQaPngBase64),
      );
      try {
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 1);
        expect(frame.image.height, 1);
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    });
  });

  test('throughput fixture is repeatable, unique and uses exact bounded file sizes', () async {
    final root = await createDeviceSyncQaRoot();
    final first = await createDeviceSyncThroughputFixture(root);
    final second = await createDeviceSyncThroughputFixture(root);
    expect(first, hasLength(65));
    expect(second, hasLength(65));
    expect(await first.first.length(), 64 * 1024 * 1024);
    final hashes = <String>[];
    for (var index = 0; index < first.length; index++) {
      if (index > 0) expect(await first[index].length(), 256 * 1024);
      final hash = (await sha256.bind(first[index].openRead()).single)
          .toString();
      hashes.add(hash);
      expect(
        (await sha256.bind(second[index].openRead()).single).toString(),
        hash,
      );
      expect(await first[index].openRead(0, 8).first, [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);
    }
    expect(hashes.toSet(), hasLength(65));
    expect(first.first.parent.path, isNot(second.first.parent.path));
  });

  test(
    'throughput fixture refuses an unowned directory without writing files',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'nsoalbum-unowned-fixture-',
      );
      await expectLater(
        createDeviceSyncThroughputFixture(root),
        throwsStateError,
      );
      expect(await root.list().isEmpty, isTrue);
    },
  );
}
