import 'package:window_manager/window_manager.dart';

/// Retire only this secondary Flutter runner through its native message loop.
/// dart:io exit tears down the Windows runtime from the UI isolate and can
/// fail-fast with loaded native media plugins. No primary close policy exists
/// in this window and no application backend has been opened.
Future<void> dismissSecondaryDesktopWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.destroy();
}
