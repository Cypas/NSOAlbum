import 'package:path/path.dart' as p;

import 'app_backend.dart';

bool mobileStorageIsAvailable({
  required String libraryPath,
  required String applicationRoot,
  required List<MobileStorageLocation> locations,
}) {
  final paths = p.Context(style: p.Style.posix);
  final normalized = paths.normalize(libraryPath);
  if (paths.isWithin(paths.normalize(applicationRoot), normalized)) return true;
  return locations.any((item) => paths.normalize(item.path) == normalized);
}
