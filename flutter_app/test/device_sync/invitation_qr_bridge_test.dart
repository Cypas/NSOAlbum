import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/ui/device_sync/invitation_qr.dart';
import 'package:zxing2/qrcode.dart';

import 'device_sync_page_test.dart' show pageApp;

void main() {
  final library = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_LIBRARY'];
  final address = Platform.environment['NSOALBUM_DEVICE_SYNC_TEST_TCP_ADDRESS'];
  if (library == null || address == null) {
    test(
      'actual Rust invitation decodes from the actual rendered QR pixels',
      () {},
      skip: 'Requires the current verified device-sync DLL and private TCP address.',
    );
    return;
  }
  testWidgets(
    'actual Rust invitation decodes from the actual rendered QR pixels',
    (tester) async {
      final opened = await tester.runAsync(() async {
        await RustLib.init(externalLibrary: ExternalLibrary.open(library));
        final root = await Directory.systemTemp.createTemp('nsoalbum-5b2-qr-');
        final opened = await native.deviceSyncOpenLibrary(
          libraryRoot: root.path,
        );
        final host = await native.deviceSyncHostTcp(
          library_: opened.handle,
          name: 'Desktop 桌面',
          address: '$address:0',
        );
        return (library: opened.handle, host: host);
      });
      final invitation = opened!.host.invitation;
      final key = GlobalKey();
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          pageApp(
            builder: (_) => Scaffold(
              body: Semantics(
                key: const Key('qr-safe-parent'),
                container: true,
                child: RepaintBoundary(
                  key: key,
                  child: SizedBox(
                    width: 260,
                    child: DeviceInvitationQr(
                      invitation: invitation,
                      remainingMs: BigInt.from(300000),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('open-page')));
        await tester.pumpAndSettle();
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final decodedMatches = await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 3);
          try {
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final rgba = data!.buffer.asUint8List();
            final pixels = Int32List(image.width * image.height);
            for (var index = 0; index < pixels.length; index++) {
              final at = index * 4;
              pixels[index] =
                  (rgba[at] << 16) | (rgba[at + 1] << 8) | rgba[at + 2];
            }
            final decoded = QRCodeReader().decode(
              BinaryBitmap(
                HybridBinarizer(
                  RGBLuminanceSource(image.width, image.height, pixels),
                ),
              ),
            );
            return decoded.text == invitation;
          } finally {
            image.dispose();
          }
        });
        expect(
          decodedMatches,
          isTrue,
          reason:
              'Rendered QR must retain the complete authenticated invitation.',
        );
        expect(
          tester
              .getSemantics(find.byKey(const Key('qr-safe-parent')))
              .toStringDeep()
              .contains(invitation),
          isFalse,
          reason: 'Invitation authentication material must not be spoken.',
        );
      } finally {
        semantics.dispose();
        await tester.runAsync(() async {
          await native.deviceSyncCloseEndpoint(endpoint: opened.host.handle);
          await native.deviceSyncCloseLibrary(library_: opened.library);
        });
      }
    },
  );
}
