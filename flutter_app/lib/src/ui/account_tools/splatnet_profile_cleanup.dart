import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> deleteOwnedSplatNetProfile(
  Directory directory,
  String parent,
) async {
  if (p.dirname(directory.absolute.path) != parent ||
      await FileSystemEntity.isLink(parent) ||
      await FileSystemEntity.isLink(directory.path)) {
    throw StateError('splatnet_profile_owner_changed');
  }
  if (!await directory.exists()) return;
  final resolvedParent = await Directory(parent).resolveSymbolicLinks();
  final resolved = await directory.resolveSymbolicLinks();
  if (p.dirname(resolved) != resolvedParent) {
    throw StateError('splatnet_profile_owner_changed');
  }
  await directory.delete(recursive: true);
}

/// Deletes only the retired, uniquely owned profile supplied by the caller.
Future<void> retireSplatNetProfile({
  required Future<void> Function() deleteProfile,
  required void Function(String issue) onIssue,
}) async {
  try {
    await deleteProfile();
  } on FileSystemException {
    onIssue('splatnet_profile_cleanup_deferred');
    // Native disposal has already completed. A retired profile is never reused;
    // its filesystem reclamation must not poison the native isolation barrier.
    unawaited(
      () async {
        for (final delay in const [
          Duration(milliseconds: 250),
          Duration(seconds: 1),
          Duration(seconds: 2),
          Duration(seconds: 5),
          Duration(seconds: 10),
          Duration(seconds: 30),
        ]) {
          await Future<void>.delayed(delay);
          try {
            await deleteProfile();
            return;
          } on FileSystemException {
            continue;
          }
        }
        onIssue('splatnet_profile_cleanup_incomplete');
      }().catchError((Object _) {
        // Report no arbitrary exception text: native paths can contain user data.
        onIssue('splatnet_profile_cleanup_incomplete');
      }),
    );
  }
}
