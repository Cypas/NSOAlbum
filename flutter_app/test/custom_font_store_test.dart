import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/fonts/custom_font_store.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('nsoalbum-font-store-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'copies fonts with their original names into separate entry folders',
    () async {
      final sourceA = await _makeFont(temporary, 'a', 'Custom.ttf');
      final sourceB = await _makeFont(temporary, 'b', 'Custom.ttf');
      final ids = ['entry-a', 'entry-b'];
      final store = CustomFontStore(
        supportDirectory: temporary.path,
        createEntryId: () => ids.removeAt(0),
      );

      final paths = await store.importFiles([sourceA.path, sourceB.path]);

      expect(paths, [
        '${temporary.path}${Platform.pathSeparator}custom_fonts'
            '${Platform.pathSeparator}'
            'entry-a${Platform.pathSeparator}entry-0'
            '${Platform.pathSeparator}Custom.ttf',
        '${temporary.path}${Platform.pathSeparator}custom_fonts'
            '${Platform.pathSeparator}'
            'entry-a${Platform.pathSeparator}entry-1'
            '${Platform.pathSeparator}Custom.ttf',
      ]);
      expect(await File(paths[0]).readAsBytes(), await sourceA.readAsBytes());
      expect(await File(paths[1]).readAsBytes(), await sourceB.readAsBytes());
      expect(await sourceA.exists(), isTrue);
      expect(await sourceB.exists(), isTrue);
    },
  );

  test('rejects an invalid font batch without copying any files', () async {
    final valid = await _makeFont(temporary, 'valid', 'Valid.otf');
    final invalid = File('${temporary.path}${Platform.pathSeparator}Bad.ttf');
    await invalid.writeAsBytes([1, 2, 3, 4]);
    final store = CustomFontStore(
      supportDirectory: temporary.path,
      createEntryId: () => 'unused',
    );

    await expectLater(
      store.importFiles([valid.path, invalid.path]),
      throwsA(isA<FormatException>()),
    );
    expect(
      await Directory('${temporary.path}${Platform.pathSeparator}custom_fonts')
          .exists(),
      isFalse,
    );
  });
}

Future<File> _makeFont(Directory root, String folder, String name) async {
  final directory = Directory('${root.path}${Platform.pathSeparator}$folder');
  await directory.create();
  final file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes([0, 1, 0, 0, 0, 0]);
  return file;
}
