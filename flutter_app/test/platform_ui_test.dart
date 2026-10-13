import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

void main() {
  test('production UI follows the operating system, not simulated theme', () {
    expect(
      resolveAppUiPlatform(),
      Platform.isAndroid ? AppUiPlatform.android : AppUiPlatform.desktop,
    );
  });

  test('explicit platform selection is independent of screen size', () {
    expect(
      resolveAppUiPlatform(platform: TargetPlatform.android),
      AppUiPlatform.android,
    );
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.iOS,
    ]) {
      expect(resolveAppUiPlatform(platform: platform), AppUiPlatform.desktop);
    }
  });
}
