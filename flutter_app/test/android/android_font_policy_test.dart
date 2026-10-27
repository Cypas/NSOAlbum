@Tags(['platform-android'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/android/android_theme.dart';

void main() {
  test('Android ordinary text leaves font selection to the platform', () {
    final theme = androidTheme('ocean');
    const desktopFamilies = {'DFPT_ZY9', 'DFP_GBZY9', 'BlitzMain'};
    final ordinaryStyles = [
      theme.textTheme.headlineMedium,
      theme.textTheme.titleLarge,
      theme.textTheme.titleMedium,
      theme.textTheme.bodyLarge,
      theme.textTheme.bodyMedium,
      theme.textTheme.bodySmall,
    ];

    for (final style in ordinaryStyles) {
      expect(desktopFamilies.contains(style?.fontFamily), isFalse);
      for (final family in style?.fontFamilyFallback ?? const <String>[]) {
        expect(desktopFamilies.contains(family), isFalse);
      }
    }
  });
}
