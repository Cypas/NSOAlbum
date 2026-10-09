import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../backend/app_logger.dart';
import '../backend/storage_paths.dart';
import '../rust/bridge.dart' as rust_api;
import '../rust/rust_initialization.dart';
import 'startup_options.dart';

class StartupDiagnostics {
  StartupDiagnostics({
    required this.options,
    required this.logger,
    required this.applicationRoot,
  });

  final StartupOptions options;
  final AppLogger logger;
  final String applicationRoot;

  String get logPath => logger.path;

  static Future<StartupDiagnostics> open(StartupOptions options) async {
    String applicationRoot;
    try {
      final support = await getApplicationSupportDirectory();
      await ensureRustLibInitialized();
      applicationRoot = await resolveApplicationRoot(
        support.path,
        isValidLibraryRoot: (path) async {
          final probe = await rust_api.probeLibraryRoot(libraryRoot: path);
          return probe.databaseReadable &&
              (probe.mediaCount > BigInt.zero ||
                  probe.accountCount > BigInt.zero ||
                  probe.settingsCount > BigInt.one);
        },
      );
    } catch (_) {
      applicationRoot = _join(Directory.systemTemp.path, 'squid_album');
    }
    final diagnostics = StartupDiagnostics(
      options: options,
      applicationRoot: applicationRoot,
      logger: AppLogger(_join(applicationRoot, 'logs', 'squid_album.log')),
    );
    await diagnostics.logger.ensureExists();
    return diagnostics;
  }

  Future<void> phase(String name, [String? detail]) =>
      logger.info('Startup phase: $name${detail == null ? '' : ' ($detail)'}');

  Future<void> failure(String name, Object error, [StackTrace? stackTrace]) =>
      logger.error('Startup phase failed: $name', error, stackTrace);

  Future<void> runGuarded(
    String name,
    Future<void> Function() action, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await phase('$name-start');
    try {
      await action().timeout(timeout);
      await phase('$name-complete');
    } catch (error, stackTrace) {
      await failure(name, error, stackTrace);
    }
  }

  static String _join(
    String first,
    String second, [
    String? third,
    String? fourth,
  ]) {
    final parts = <String>[first, second, ?third, ?fourth];
    return parts.join(Platform.pathSeparator);
  }
}
