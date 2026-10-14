@Tags(['platform-android'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const densitySizes = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };

  for (final entry in densitySizes.entries) {
    test(
      'Android ${entry.key} launcher retains the desktop brand artwork',
      () async {
        final source = await File('assets/tray/app_icon.png').readAsBytes();
        final icon = await File(
          p.join(
            'android',
            'app',
            'src',
            'main',
            'res',
            'mipmap-${entry.key}',
            'ic_launcher.png',
          ),
        ).readAsBytes();
        final sourceCodec = await ui.instantiateImageCodec(
          source,
          targetWidth: entry.value,
          targetHeight: entry.value,
        );
        final iconCodec = await ui.instantiateImageCodec(icon);
        ui.Image? sourceImage;
        ui.Image? iconImage;
        try {
          sourceImage = (await sourceCodec.getNextFrame()).image;
          iconImage = (await iconCodec.getNextFrame()).image;
          expect(iconImage.width, entry.value);
          expect(iconImage.height, entry.value);
          final sourcePixels = (await sourceImage.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          final iconPixels = (await iconImage.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          expect(iconPixels.length, sourcePixels.length);
          var difference = 0;
          for (var index = 0; index < sourcePixels.length; index++) {
            difference += (sourcePixels[index] - iconPixels[index]).abs();
          }
          // Independent Skia vs. System.Drawing downscaling can differ at
          // edges; replacing the artwork with Flutter's default icon cannot.
          expect(
            difference / sourcePixels.length,
            lessThan(16),
            reason: 'Android must use the same artwork as the PC application.',
          );
        } finally {
          sourceImage?.dispose();
          iconImage?.dispose();
          sourceCodec.dispose();
          iconCodec.dispose();
        }
      },
    );
  }
}
