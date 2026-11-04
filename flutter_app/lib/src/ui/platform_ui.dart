import 'dart:io';

import 'package:flutter/foundation.dart';

enum AppUiPlatform { android, desktop }

AppUiPlatform resolveAppUiPlatform({TargetPlatform? platform}) {
  final android = platform == null
      ? Platform.isAndroid
      : platform == TargetPlatform.android;
  return android ? AppUiPlatform.android : AppUiPlatform.desktop;
}
