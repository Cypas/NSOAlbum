import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/device_sync_network.dart';
import 'package:squid_album/src/ui/device_sync/connection_info.dart';

import 'device_sync_page_test.dart' show pageApp;

void main() {
  testWidgets(
    'connection hints wrap at narrow widths and large text in both themes and languages',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      for (final width in [320.0, 360.0, 412.0]) {
        tester.view.physicalSize = Size(width, 820);
        for (final language in ['zh', 'en']) {
          for (final brightness in Brightness.values) {
            await tester.pumpWidget(
              pageApp(
                language: language,
                brightness: brightness,
                scale: 2,
                builder: (_) => Scaffold(
                  body: ListView(
                    children: [
                      DeviceSyncConnectionInfo(
                        usb: false,
                        mobile: true,
                        wifi: const DeviceWifiSnapshot(
                          ssid: 'Long current Wi-Fi network name',
                        ),
                        peerSsid: 'Long different Wi-Fi network name',
                      ),
                      const DeviceSyncConnectionInfo(
                        usb: false,
                        mobile: false,
                        wifi: DeviceWifiSnapshot(ssid: 'Home'),
                        selectedAddress: '192.168.1.5',
                      ),
                      const DeviceSyncConnectionInfo(
                        usb: true,
                        mobile: true,
                        wifi: DeviceWifiSnapshot(),
                      ),
                    ],
                  ),
                ),
              ),
            );
            await tester.tap(find.byKey(const Key('open-page')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      }
    },
  );
}
