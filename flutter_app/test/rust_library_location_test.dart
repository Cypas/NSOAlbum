import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:squid_album/src/backend/rust_initialization.dart';

void main() {
  test(
    'Windows packaged core is resolved from the executable, not the checkout',
    () {
      expect(
        packagedRustLibraryPath(
          platform: 'windows',
          executable: r'C:\Apps\NSOAlbum\NSOAlbum.exe',
        ),
        r'C:\Apps\NSOAlbum\squid_album_core.dll',
      );
    },
  );

  test('macOS links the packaged Rust framework using its bundle location', () {
    expect(
      packagedRustLibraryPath(
        platform: 'macos',
        executable: '/Volumes/NSOAlbum/NSOAlbum.app/Contents/MacOS/NSOAlbum',
      ),
      '/Volumes/NSOAlbum/NSOAlbum.app/Contents/Frameworks/squid_album_core.framework/squid_album_core',
    );
  });

  test(
    'bundled Rust library must exist inside its canonical bundle root',
    () async {
      final scratch = await Directory.systemTemp.createTemp('nso-core-path-');
      addTearDown(() => scratch.delete(recursive: true));
      final bundle = await Directory(p.join(scratch.path, 'bundle')).create();
      final library = await File(p.join(bundle.path, 'core.bin'))
          .writeAsString('fixture');
      expect(
        await validateBundledRustLibrary(
          libraryPath: library.path,
          bundleRoot: bundle.path,
        ),
        await library.resolveSymbolicLinks(),
      );
      await expectLater(
        validateBundledRustLibrary(
          libraryPath: p.join(bundle.path, 'missing.bin'),
          bundleRoot: bundle.path,
        ),
        throwsA(isA<FileSystemException>()),
      );
      final outside = await File(p.join(scratch.path, 'external.bin'))
          .writeAsString('fixture');
      await expectLater(
        validateBundledRustLibrary(
          libraryPath: outside.path,
          bundleRoot: bundle.path,
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
