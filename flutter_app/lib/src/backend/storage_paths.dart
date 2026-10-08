import 'dart:io';

const String currentApplicationRootName = 'NSOAlbum';
const List<String> legacyApplicationRootNames = [
  'squid_album_library',
  'FreshAlbum',
  'squid_album',
];

Future<String> resolveApplicationRoot(String supportDirectory) async {
  final root = Directory(supportDirectory);
  final candidates = <Directory>[
    Directory(_join(root.path, currentApplicationRootName)),
    ...legacyApplicationRootNames.map(
      (name) => Directory(_join(root.path, name)),
    ),
  ];
  for (final candidate in candidates) {
    if (await _hasLibraryDatabase(candidate)) return candidate.path;
  }
  return candidates.first.path;
}

Future<bool> _hasLibraryDatabase(Directory root) =>
    File(_join(root.path, 'database', 'library.sqlite3')).exists();

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
    [first, second, ?third].join(Platform.pathSeparator);
