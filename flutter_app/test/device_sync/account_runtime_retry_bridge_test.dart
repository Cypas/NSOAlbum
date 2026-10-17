import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/frb_generated.dart';

import 'bridge_fault_matrix.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];
  test(
    'same coordinator retries failed abort compensation without releasing ownership',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      final root = await Directory.systemTemp.createTemp(
        'nsoalbum-5b2-runtime-recovery-',
      );
      final opened = await native.deviceSyncOpenLibrary(libraryRoot: root.path);
      try {
        await native.initCore(libraryRoot: root.path);
        await native.createTag(name: 'old library');
        await verifySameOwnerAbortCompensationRetry(opened.handle);
      } finally {
        await native.deviceSyncCloseLibrary(library_: opened.handle);
        RustLib.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: library == null ? 'Requires explicit current native DLL' : false,
  );
}
