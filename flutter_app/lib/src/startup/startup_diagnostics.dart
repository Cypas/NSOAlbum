import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../backend/app_logger.dart';
import 'startup_options.dart';

class StartupDiagnostics {
  StartupDiagnostics({required this.options, required this.logger});

  final StartupOptions options;
  final AppLogger logger;

  String get logPath => logger.path;

  static Future<StartupDiagnostics> open(StartupOptions options) async {
    String logPath;
    try {
      final support = await getApplicationSupportDirectory();
      logPath = _join(
        support.path,
        'squid_album_library',
        'logs',
        'squid_album.log',
      );
    } catch (_) {
      logPath = _join(
        Directory.systemTemp.path,
        'squid_album',
        'logs',
        'squid_album.log',
      );
    }
    final diagnostics = StartupDiagnostics(
      options: options,
      logger: AppLogger(logPath),
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
