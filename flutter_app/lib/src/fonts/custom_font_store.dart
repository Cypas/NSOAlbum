import 'dart:io';
import 'dart:math';

class CustomFontStore {
  CustomFontStore({
    required this.supportDirectory,
    String Function()? createEntryId,
  }) : _createEntryId = createEntryId ?? _newEntryId;

  final String supportDirectory;
  final String Function() _createEntryId;

  static Future<void> validateFiles(List<String> sourcePaths) async {
    for (final sourcePath in sourcePaths) {
      await _validateFontFile(File(sourcePath));
    }
  }

  Future<List<String>> importFiles(List<String> sourcePaths) async {
    if (sourcePaths.isEmpty) return const [];

    final sources = sourcePaths.map(File.new).toList(growable: false);
    for (final source in sources) {
      await _validateFontFile(source);
    }

    final root = Directory(
      '$supportDirectory${Platform.pathSeparator}custom_fonts',
    );
    await root.create(recursive: true);

    Directory staging;
    Directory destination;
    while (true) {
      final id = _createEntryId();
      staging = Directory('${root.path}${Platform.pathSeparator}.import-$id');
      destination = Directory('${root.path}${Platform.pathSeparator}$id');
      if (await staging.exists() || await destination.exists()) continue;
      await staging.create();
      break;
    }

    try {
      final stagedFiles = <String>[];
      for (var index = 0; index < sources.length; index++) {
        final entryDirectory = Directory(
          '${staging.path}${Platform.pathSeparator}entry-$index',
        );
        await entryDirectory.create();
        final name = sources[index].uri.pathSegments.last;
        final target = File(
          '${entryDirectory.path}${Platform.pathSeparator}$name',
        );
        await sources[index].copy(target.path);
        stagedFiles.add(
          '${destination.path}${Platform.pathSeparator}entry-$index'
          '${Platform.pathSeparator}$name',
        );
      }
      await staging.rename(destination.path);
      return stagedFiles;
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  static Future<void> _validateFontFile(File file) async {
    final extension = file.path.toLowerCase().split('.').last;
    if (extension != 'ttf' && extension != 'otf') {
      throw const FormatException('Only .ttf and .otf fonts are supported.');
    }
    if (!await file.exists() || await file.length() < 4) {
      throw FormatException('Font file is missing or too small: ${file.path}');
    }
    final header = await file
        .openRead(0, 4)
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    const supportedHeaders = [
      [0x00, 0x01, 0x00, 0x00],
      [0x4f, 0x54, 0x54, 0x4f], // OpenType CFF (OTTO).
      [0x74, 0x72, 0x75, 0x65],
      [0x74, 0x79, 0x70, 0x31],
    ];
    if (!supportedHeaders.any(
      (signature) => signature.asMap().entries.every(
        (entry) => header[entry.key] == entry.value,
      ),
    )) {
      throw FormatException('Unsupported or invalid font file: ${file.path}');
    }
  }

  static String _newEntryId() {
    final random = Random.secure();
    return '${DateTime.now().microsecondsSinceEpoch}-'
        '${random.nextInt(1 << 32).toRadixString(16)}';
  }
}
