import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/startup/ci_smoke_contract.dart';

import '../../tool/device_sync_qa_root.dart';

void main() {
  test(
    'QA runs cannot reuse an existing root or redirect to a personal library',
    () async {
      final first = await createDeviceSyncQaRoot();
      final second = await createDeviceSyncQaRoot();
      // Fresh isolated evidence is retained, not recursively removed.
      expect(first.path, isNot(second.path));
      expect(
        await File('${first.path}/${CiSmokeRoot.marker}').readAsString(),
        'NSOAlbum isolated CI library v1',
      );
      expect(await first.list().length, 1);
      await expectLater(CiSmokeRoot.claim(first.path), throwsStateError);
    },
  );
}
