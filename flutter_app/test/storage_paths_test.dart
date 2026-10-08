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
      await Directory(
        '${support.path}${Platform.pathSeparator}$name'
        '${Platform.pathSeparator}database',
      ).create(recursive: true);
      await File(
        '${support.path}${Platform.pathSeparator}$name'
        '${Platform.pathSeparator}database${Platform.pathSeparator}library.sqlite3',
      ).writeAsString('');
    }

    expect(
      await resolveApplicationRoot(support.path),
      endsWith(currentApplicationRootName),
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
      endsWith(currentApplicationRootName),
    );
  });

  test('legacy root is selected when it contains a library database', () async {
    final support = await Directory.systemTemp.createTemp('nsoalbum-paths-');
    addTearDown(() => support.delete(recursive: true));
    final legacy = Directory(
      '${support.path}${Platform.pathSeparator}${legacyApplicationRootNames.first}'
      '${Platform.pathSeparator}database',
    );
    await legacy.create(recursive: true);
    await File('${legacy.path}${Platform.pathSeparator}library.sqlite3')
        .writeAsString('');

    expect(
      await resolveApplicationRoot(support.path),
      endsWith(legacyApplicationRootNames.first),
    );
  });
}
