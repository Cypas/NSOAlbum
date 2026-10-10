import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:path/path.dart' as p;

import '../rust/frb_generated.dart';

Future<void>? _rustLibInitialization;

Future<void> ensureRustLibInitialized() {
  return _rustLibInitialization ??= _initializePackagedRust();
}

/// Never let a packaged build silently borrow a DLL from the source checkout.
String? packagedRustLibraryPath({
  required String platform,
  required String executable,
}) {
  if (platform == 'windows') {
    final paths = p.Context(style: p.Style.windows);
    return paths.join(paths.dirname(executable), 'squid_album_core.dll');
  }
  if (platform == 'macos') {
    final paths = p.Context(style: p.Style.posix);
    return paths.join(
      paths.dirname(paths.dirname(executable)),
      'Frameworks',
      'squid_album_core.framework',
      'squid_album_core',
    );
  }
  return null;
}

Future<String> validateBundledRustLibrary({
  required String libraryPath,
  required String bundleRoot,
}) async {
  final canonicalRoot = await Directory(bundleRoot).resolveSymbolicLinks();
  final canonicalLibrary = await File(libraryPath).resolveSymbolicLinks();
  if (!p.isWithin(canonicalRoot, canonicalLibrary)) {
    throw const FileSystemException(
      'Packaged Rust library resolves outside the application bundle',
    );
  }
  return canonicalLibrary;
}

Future<void> _initializePackagedRust() async {
  final path = packagedRustLibraryPath(
    platform: Platform.operatingSystem,
    executable: Platform.resolvedExecutable,
  );
  if (Platform.isWindows) {
    final library = await validateBundledRustLibrary(
      libraryPath: path!,
      bundleRoot: p.dirname(Platform.resolvedExecutable),
    );
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
  } else if (Platform.isMacOS) {
    // CocoaPods may put the Rust archive in a framework or force-link it into
    // the executable. Both choices must resolve within the running bundle.
    final library = path != null && File(path).existsSync()
        ? ExternalLibrary.open(
            await validateBundledRustLibrary(
              libraryPath: path,
              bundleRoot: p.dirname(p.dirname(Platform.resolvedExecutable)),
            ),
          )
        : ExternalLibrary.process(iKnowHowToUseIt: true);
    await RustLib.init(externalLibrary: library);
  } else {
    await RustLib.init();
  }
}
