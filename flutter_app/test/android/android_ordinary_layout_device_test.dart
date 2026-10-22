@Tags(['platform-android', 'native-android'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../account_tools/account_tools_pages_test.dart' as friends;
import 'android_account_header_test.dart' as headers;
import 'android_experience_test.dart' as albums;
import 'android_media_viewer_redesign_test.dart' as details;
import 'android_ui_batch_features_test.dart' as dates;

// Run the existing production-page matrices on the device renderer. All page
// backends remain synthetic; no Rust core, accounts, or personal files open.
Future<void> main() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final native =
      Platform.isAndroid &&
      binding is LiveTestWidgetsFlutterBinding &&
      const bool.fromEnvironment('NSOALBUM_ORDINARY_LAYOUT_DEVICE_QA');
  if (!native) {
    test(
      'Android ordinary layout device matrices require the native opt-in',
      () {},
      skip:
          'Run on Android with a Live binding and '
          'NSOALBUM_ORDINARY_LAYOUT_DEVICE_QA=true.',
    );
    return;
  }

  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (binding.platformDispatcher.views.first.physicalSize.isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Android layout viewport did not initialize.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  group('Android native ordinary layouts', () {
    friends.registerAccountToolsPageTests(layoutOnly: true);
    headers.main();
    albums.registerAndroidExperienceTests(layoutOnly: true);
    details.registerAndroidDetailLayoutTests();
    dates.registerAndroidBatchFeatureTests(layoutOnly: true);
  });
}
