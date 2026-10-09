import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/storage_paths.dart';

void main() {
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
      endsWith(
        '$currentApplicationRootName${Platform.pathSeparator}$libraryDirectoryName',
      ),
    );
  });

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
}
