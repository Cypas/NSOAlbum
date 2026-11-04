import 'dart:io';

const String currentApplicationRootName = 'NSOAlbum';
const String libraryDirectoryName = 'squid_album_library';
const List<String> legacyApplicationRootNames = [
  'Fresh Album',
  'FreshAlbum',
  'squid_album',
];

bool libraryProbeContainsInstallation({
  required bool databaseReadable,
  required BigInt mediaCount,
  required BigInt accountCount,
  required BigInt settingsCount,
}) =>
    databaseReadable &&
    (mediaCount > BigInt.zero ||
        accountCount > BigInt.zero ||
        settingsCount > BigInt.zero);

List<String> applicationRootCandidates(String supportDirectory) {
  final normalized = Directory(supportDirectory).absolute;
  final parent = normalized.parent;
  final candidates = <String>{
    normalized.path,
    _join(normalized.path, currentApplicationRootName),
    _join(parent.path, currentApplicationRootName),
    _join(normalized.path, libraryDirectoryName),
    _join(normalized.path, currentApplicationRootName, libraryDirectoryName),
    _join(parent.path, currentApplicationRootName, libraryDirectoryName),
    ...legacyApplicationRootNames.map(
      (name) => _join(parent.path, name, libraryDirectoryName),
    ),
    ...legacyApplicationRootNames.map(
      (name) => _join(normalized.path, name, libraryDirectoryName),
    ),
  };
  return candidates.toList();
}

Future<String> resolveApplicationRoot(
  String supportDirectory, {
  Future<bool> Function(String path)? isValidLibraryRoot,
}) async {
  final candidates = applicationRootCandidates(supportDirectory);
  final valid = isValidLibraryRoot ?? _hasLibraryDatabasePath;
  for (final candidate in candidates) {
    if (await valid(candidate)) return candidate;
  }
  final normalized = Directory(supportDirectory).absolute.path;
  return normalized.endsWith(currentApplicationRootName)
      ? normalized
      : _join(normalized, currentApplicationRootName);
}

Future<bool> _hasLibraryDatabasePath(String root) async {
  final database = File(_join(root, 'database', 'library.sqlite3'));
  if (!await database.exists()) return false;
  try {
    return await database.length() > 4096;
  } on FileSystemException {
    return false;
  }
}

String defaultLibraryPathForPlatform({
  required String supportDirectory,
  required bool isWindows,
  String? picturesDirectory,
  bool Function(String path)? directoryExists,
}) {
  if (isWindows && picturesDirectory?.trim().isNotEmpty == true) {
    final pictures = picturesDirectory!.trim();
    final exists = directoryExists ?? (path) => Directory(path).existsSync();
    final current = _join(pictures, 'NSOAlbum');
    if (exists(current)) return current;
    final legacy = _join(pictures, 'FreshAlbum');
    if (exists(legacy)) return legacy;
    return current;
  }
  return _join(supportDirectory, 'media');
}

String _join(String first, String second, [String? third]) =>
    [first, second, ?third].join(
      first.contains(r'\') || RegExp(r'^[A-Za-z]:').hasMatch(first)
          ? r'\'
          : Platform.pathSeparator,
    );
