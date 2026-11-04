@Tags(['platform-windows'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows UI isolate shares the runner STA thread for WebView2', () {
    final source = File('windows/runner/main.cpp')
        .readAsStringSync()
        .replaceAll(RegExp(r'\s+'), ' ');
    expect(
      source,
      contains(
        'project.set_ui_thread_policy( flutter::UIThreadPolicy::RunOnPlatformThread)',
      ),
      reason:
          'WebView2 environment and controller creation must happen on the '
          'runner platform thread initialized as STA before Flutter starts.',
    );
  });
}
