import 'package:squid_album/src/rust/device_sync/headless.dart';
import 'package:squid_album/src/rust/frb_generated.dart';
import 'package:squid_album/src/rust/settings.dart';

/// Existing account race tests keep their real Dart admission and OS boundary;
/// this supplies only the newly mandatory empty native startup journal.
mixin NoPendingStartupBoundary implements RustLibApi {
  @override
  Future<AppSettings?> crateBridgeBootstrapSettings() =>
      crateBridgeLoadSettings();

  @override
  Future<LibraryInfo> crateBridgeDeviceSyncOpenLibrary({
    required String libraryRoot,
  }) async => LibraryInfo(
    handle: 'synthetic-library-handle',
    libraryUuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    generation: BigInt.zero,
  );

  @override
  Future<LibraryInfo> crateBridgeDeviceSyncLibraryInfo({
    required String library_,
  }) => crateBridgeDeviceSyncOpenLibrary(libraryRoot: 'synthetic-root');

  @override
  Future<void> crateBridgeDeviceSyncCloseLibrary({
    required String library_,
  }) async {}
}
