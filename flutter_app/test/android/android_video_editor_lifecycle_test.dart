@Tags(['platform-android'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android video editor retires its native output before player disposal', () {
    final source = File(
      'lib/src/ui/android/android_video_editor.dart',
    ).readAsStringSync();

    expect(source, contains("import 'android_video_retirement.dart';"));
    expect(
      source,
      contains('final output = video.notifier.value;'),
    );
    expect(
      source,
      contains('retireAndroidVideoOutput(output, player.dispose)'),
    );
  });
}
