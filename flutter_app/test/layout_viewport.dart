import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Live bindings use their own surface size instead of the mock view metrics.
/// Set both so host and device matrices exercise the same logical constraints.
Future<void> useLayoutTestViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}
