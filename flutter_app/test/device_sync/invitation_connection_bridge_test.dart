import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/device_sync/connection.dart';
import 'package:squid_album/src/rust/device_sync/read_model.dart';
import 'package:squid_album/src/rust/frb_generated.dart';

void main() {
  final dll = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];
  final address = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_TCP_ADDRESS'];
  test(
    'actual Bridge invitation preserves SSID and rejects missing or different app builds',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(dll!));
      final root = await Directory.systemTemp.createTemp(
        'nsoalbum-invitation-version-',
      );
      final library = await native.deviceSyncOpenLibrary(
        libraryRoot: root.path,
      );
      final endpoints = <String>[];
      const build = ApplicationBuild(version: '1.2.3', buildNumber: '456');
      try {
        final host = await native.deviceSyncHostTcp(
          library_: library.handle,
          name: 'Synthetic desktop',
          address: '$address:0',
          wifiSsid: 'Synthetic Wi-Fi',
          appBuild: build,
        );
        endpoints.add(host.handle);
        final info = await native.deviceSyncInspectInvitation(
          invitation: host.invitation,
          appBuild: build,
        );
        expect(info.usb, isFalse);
        expect(info.wifiSsid, 'Synthetic Wi-Fi');
        expect(info.appBuild, build);
        for (final other in [
          const ApplicationBuild(version: '1.2.4', buildNumber: '456'),
          const ApplicationBuild(version: '1.2.3', buildNumber: '457'),
        ]) {
          await expectLater(
            native.deviceSyncInspectInvitation(
              invitation: host.invitation,
              appBuild: other,
            ),
            throwsA(ReadError.versionMismatch),
          );
        }
        final legacy = await native.deviceSyncHostTcp(
          library_: library.handle,
          name: 'Synthetic legacy',
          address: '$address:0',
        );
        endpoints.add(legacy.handle);
        await expectLater(
          native.deviceSyncInspectInvitation(
            invitation: legacy.invitation,
            appBuild: build,
          ),
          throwsA(ReadError.versionMismatch),
        );
      } finally {
        for (final handle in endpoints) {
          await native.deviceSyncCloseEndpoint(endpoint: handle);
        }
        await native.deviceSyncCloseLibrary(library_: library.handle);
        RustLib.dispose();
      }
    },
    skip: dll == null || address == null
        ? 'Requires the current verified device-sync library and private TCP address; only synthetic data is used.'
        : false,
  );
}
