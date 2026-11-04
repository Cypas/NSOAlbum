import 'dart:async';
import 'dart:io';

import '../rust/bridge.dart' as rust;
import '../rust/models.dart' show ImportSummary;
import '../rust/switch_import.dart' as native;

class NintendoMtpDevice {
  const NintendoMtpDevice(this.name);

  final String name;
}

class NintendoMtpProgress {
  const NintendoMtpProgress({
    required this.phase,
    required this.completedFiles,
    required this.totalFiles,
    required this.completedBytes,
    required this.totalBytes,
    this.currentFile,
  });

  final String phase;
  final int completedFiles;
  final int totalFiles;
  final int completedBytes;
  final int totalBytes;
  final String? currentFile;
}

class NintendoMtpMediaEntry {
  const NintendoMtpMediaEntry({
    required this.gameName,
    required this.fileName,
    required this.sizeBytes,
    required this.capturedAt,
  });

  final String gameName;
  final String fileName;
  final int sizeBytes;
  final DateTime? capturedAt;

  native.SwitchMtpEntry toNative() => native.SwitchMtpEntry(
    gameName: gameName,
    fileName: fileName,
    sizeBytes: BigInt.from(sizeBytes),
    capturedAt: capturedAt?.toIso8601String(),
  );
}

class NintendoMtpStagingResult {
  const NintendoMtpStagingResult({
    required this.directory,
    required this.files,
  });

  final Directory directory;
  final List<String> files;
}

class NintendoMtpImportException implements Exception {
  const NintendoMtpImportException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class NintendoMtpCancelled implements Exception {
  const NintendoMtpCancelled();
}

class NintendoMtpImportOutcome {
  const NintendoMtpImportOutcome({
    required this.summary,
    required this.cancelled,
  });

  final ImportSummary summary;
  final bool cancelled;
}

class WindowsNintendoMtp {
  static const supportedDeviceNames = {'Nintendo Switch', 'Nintendo Switch 2'};
  static const _poll = Duration(milliseconds: 200);

  static Future<List<NintendoMtpDevice>> listDevices() async {
    if (!Platform.isWindows) return const [];
    final names = await rust.switchMtpListDevices();
    return names
        .where(supportedDeviceNames.contains)
        .map(NintendoMtpDevice.new)
        .toList(growable: false);
  }

  static Future<List<NintendoMtpMediaEntry>> scanAlbum(
    NintendoMtpDevice device,
  ) async {
    if (!Platform.isWindows || !supportedDeviceNames.contains(device.name)) {
      throw UnsupportedError('Unsupported Nintendo media device');
    }
    final entries = await rust.switchMtpScan(device: device.name);
    return entries
        .map(
          (entry) => NintendoMtpMediaEntry(
            gameName: entry.gameName,
            fileName: entry.fileName,
            sizeBytes: entry.sizeBytes.toInt(),
            capturedAt: DateTime.tryParse(entry.capturedAt ?? ''),
          ),
        )
        .toList(growable: false);
  }

  static Future<NintendoMtpStagingResult> stageAlbum(
    NintendoMtpDevice device, {
    required List<NintendoMtpMediaEntry> entries,
    required String operationId,
    void Function(NintendoMtpProgress progress)? onProgress,
  }) async {
    if (!Platform.isWindows || !supportedDeviceNames.contains(device.name)) {
      throw UnsupportedError('Unsupported Nintendo media device');
    }
    if (entries.isEmpty) {
      throw ArgumentError.value(entries, 'entries', 'No media selected');
    }
    await rust.switchMtpStartStage(
      operationId: operationId,
      device: device.name,
      entries: entries.map((entry) => entry.toNative()).toList(growable: false),
    );
    while (true) {
      await Future<void>.delayed(_poll);
      final status = await rust.switchMtpStageStatus(operationId: operationId);
      if (status == null) {
        throw const NintendoMtpImportException(
          'unavailable',
          'Switch USB import is unavailable',
        );
      }
      final progress = NintendoMtpProgress(
        phase: status.phase,
        completedFiles: status.completedFiles.toInt(),
        totalFiles: status.totalFiles.toInt(),
        completedBytes: status.completedBytes.toInt(),
        totalBytes: status.totalBytes.toInt(),
        currentFile: status.currentFile,
      );
      onProgress?.call(progress);
      switch (status.phase) {
        case 'completed':
          final files = status.stagedFiles;
          final root = files.isEmpty
              ? Directory(
                  '${Directory.systemTemp.path}${Platform.pathSeparator}'
                  'nsoalbum-switch-$operationId',
                )
              : Directory(File(files.first).parent.parent.parent.path);
          return NintendoMtpStagingResult(directory: root, files: files);
        case 'cancelled':
          throw const NintendoMtpCancelled();
        case 'failed':
          throw NintendoMtpImportException(
            status.errorCode ?? 'unavailable',
            status.error ?? 'Switch USB import failed',
          );
      }
    }
  }

  static Future<bool> cancelStage(String operationId) =>
      rust.switchMtpCancelStage(operationId: operationId);

  static Future<void> cleanupStage(String operationId) =>
      rust.switchMtpCleanupStage(operationId: operationId);

  static Future<NintendoMtpImportOutcome> importWithProgress(
    List<String> paths,
    String deviceName, {
    required String operationId,
    void Function(NintendoMtpProgress progress)? onProgress,
  }) async {
    var reading = false;
    Future<void> refresh() async {
      if (reading) return;
      reading = true;
      try {
        final value = await rust.currentImportProgress(
          operationId: operationId,
        );
        if (value != null) {
          onProgress?.call(
            NintendoMtpProgress(
              phase: 'importing',
              completedFiles: value.processedItems.toInt(),
              totalFiles: value.totalItems?.toInt() ?? paths.length,
              completedBytes: value.processedBytes?.toInt() ?? 0,
              totalBytes: value.totalBytes?.toInt() ?? 0,
            ),
          );
        }
      } catch (_) {
        // Progress polling must not interrupt the import itself.
      } finally {
        reading = false;
      }
    }

    final timer = Timer.periodic(_poll, (_) => unawaited(refresh()));
    try {
      final summary = await rust.importMtpFilesWithProgress(
        paths: paths,
        deviceName: deviceName,
        operationId: operationId,
      );
      await refresh();
      final finalProgress = await rust.currentImportProgress(
        operationId: operationId,
      );
      return NintendoMtpImportOutcome(
        summary: summary,
        cancelled: finalProgress?.status == 'cancelled',
      );
    } finally {
      timer.cancel();
    }
  }

  static Future<bool> cancelImport(String operationId) =>
      rust.cancelImport(operationId: operationId);
}
