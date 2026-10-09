import 'frb_generated.dart';

Future<void>? _rustLibInitialization;

Future<void> ensureRustLibInitialized() {
  return _rustLibInitialization ??= RustLib.init();
}
