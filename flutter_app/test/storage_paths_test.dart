import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/storage_paths.dart';

void main() {
  test(
    'an existing saved preference is enough to preserve a legacy installation',
    () {
      expect(
        libraryProbeContainsInstallation(
          databaseReadable: true,
          mediaCount: BigInt.zero,
          accountCount: BigInt.zero,
          settingsCount: BigInt.one,
        ),
        isTrue,
      );
      expect(
        libraryProbeContainsInstallation(
          databaseReadable: true,
          mediaCount: BigInt.zero,
          accountCount: BigInt.zero,
          settingsCount: BigInt.zero,
        ),
        isFalse,
      );
      expect(
        libraryProbeContainsInstallation(
          databaseReadable: false,
          mediaCount: BigInt.one,
          accountCount: BigInt.zero,
          settingsCount: BigInt.one,
        ),
        isFalse,
      );
    },
  );
  test('new application root wins over legacy roots', () async {
    final support = await Directory.systemTemp.createTemp('nsoalbum-paths-');
    addTearDown(() => support.delete(recursive: true));
    for (final name in [
      currentApplicationRootName,
      ...legacyApplicationRootNames,
    ]) {
      final database = Directory(
        '${support.path}${Platform.pathSeparator}$name'
        '${Platform.pathSeparator}$libraryDirectoryName'
        '${Platform.pathSeparator}database',
      );
      await database.create(recursive: true);
      await File('${database.path}${Platform.pathSeparator}library.sqlite3')
          .writeAsString('x' * 4097);
    }

    expect(
      await resolveApplicationRoot(support.path),
      endsWith(
        '$currentApplicationRootName${Platform.pathSeparator}$libraryDirectoryName',
      ),
    );
  });

  test('empty legacy roots do not look like an existing installation', () async {
    final support = await Directory.systemTemp.createTemp('nsoalbum-paths-');
    addTearDown(() => support.delete(recursive: true));
    await Directory(
      '${support.path}${Platform.pathSeparator}${legacyApplicationRootNames.first}',
    ).create(recursive: true);

    expect(
      await resolveApplicationRoot(support.path),
      equals(
        '${support.path}${Platform.pathSeparator}$currentApplicationRootName',
      ),
    );
  });

  test(
    'fresh root already named NSOAlbum does not gain a nested directory',
    () async {
      final support = await Directory.systemTemp.createTemp('nsoalbum-paths-');
      addTearDown(() => support.delete(recursive: true));
      final root = '${support.path}${Platform.pathSeparator}NSOAlbum';
      expect(await resolveApplicationRoot(root), root);
    },
  );

  test('legacy root is selected when it contains a library database', () async {
    final support = await Directory.systemTemp.createTemp('nsoalbum-paths-');
    addTearDown(() => support.delete(recursive: true));
    final database = Directory(
      '${support.path}${Platform.pathSeparator}${legacyApplicationRootNames.first}'
      '${Platform.pathSeparator}$libraryDirectoryName'
      '${Platform.pathSeparator}database',
    );
    await database.create(recursive: true);
    await File('${database.path}${Platform.pathSeparator}library.sqlite3')
        .writeAsString('x' * 4097);

    expect(
      await resolveApplicationRoot(support.path),
      endsWith(
        '${legacyApplicationRootNames.first}${Platform.pathSeparator}$libraryDirectoryName',
      ),
    );
  });

  test(
    'a valid nested legacy library is reused without moving its database',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'nsoalbum-paths-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final root = '${temporary.path}${Platform.pathSeparator}NSOAlbum';
      final legacy = '$root${Platform.pathSeparator}squid_album_library';
      final database = Directory('$legacy${Platform.pathSeparator}database');
      await database.create(recursive: true);
      final file = File(
        '${database.path}${Platform.pathSeparator}library.sqlite3',
      );
      final contents = 'x' * 4097;
      await file.writeAsString(contents);

      expect(await resolveApplicationRoot(root), legacy);
      expect(await file.readAsString(), contents);
      expect(
        await File(
          '$root${Platform.pathSeparator}database'
          '${Platform.pathSeparator}library.sqlite3',
        ).exists(),
        isFalse,
      );
    },
  );
}
