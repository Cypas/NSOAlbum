import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A diagnostic library is never allowed to adopt an existing user directory.
class CiSmokeRoot {
  static const marker = '.nsoalbum-ci-owned';

  static Future<void> claim(String path, {bool reopen = false}) async {
    if (!p.isAbsolute(path) || p.normalize(path) == p.rootPrefix(path)) {
      throw StateError('Smoke root must be an absolute non-volume directory');
    }
    final root = Directory(path);
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('Smoke root cannot be a symbolic link');
    }
    var ancestor = root;
    while (!await ancestor.exists()) {
      final next = ancestor.parent;
      if (next.path == ancestor.path) {
        throw StateError('Smoke root has no existing parent');
      }
      ancestor = next;
    }
    if (!p.equals(
      p.normalize(await ancestor.resolveSymbolicLinks()),
      p.normalize(ancestor.absolute.path),
    )) {
      throw StateError('Smoke root must not contain redirected parents');
    }
    if (reopen) {
      final owner = File(p.join(path, marker));
      final report = File(p.join(path, 'normal.json'));
      for (final file in [owner, report]) {
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            !p.isWithin(
              root.absolute.path,
              await file.resolveSymbolicLinks(),
            )) {
          throw StateError(
            'Reopen requires ordinary contained ownership files',
          );
        }
      }
      if (await owner.length() > 128 ||
          await report.length() > 65536 ||
          await owner.readAsString() != 'NSOAlbum isolated CI library v1' ||
          !CiSmokeReport.accepts(
            jsonDecode(await report.readAsString()),
            scenario: 'normal',
          )) {
        throw StateError('Reopen requires a successful smoke-owned library');
      }
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is Link ||
            !p.isWithin(
              p.normalize(root.absolute.path),
              p.normalize(await entity.resolveSymbolicLinks()),
            )) {
          throw StateError(
            'Owned CI library must not contain redirected files',
          );
        }
      }
      return;
    }
    if (await root.exists() && !await root.list().isEmpty) {
      throw StateError('Smoke root must be new or empty');
    }
    await root.create(recursive: true);
    // Resolve parent links as well: a directory junction must not redirect CI
    // to a personal library. The driver always uses canonical temporary roots.
    final canonical = p.normalize(await root.resolveSymbolicLinks());
    if (!p.equals(canonical, p.normalize(root.absolute.path))) {
      throw StateError('Smoke root must not contain redirected parents');
    }
    await File(p.join(path, marker))
        .writeAsString('NSOAlbum isolated CI library v1', flush: true);
  }
}

class CiSmokeReport {
  CiSmokeReport(this.scenario);

  final String scenario;
  final List<Map<String, Object?>> steps = [];

  static List<String> requiredSteps(String scenario) => switch (scenario) {
    'normal' => const [
      'rust-initialization',
      'first-frame',
      'first-gallery-query',
      'desktop-plugins',
      'fixture-generation',
      'import',
      'image-decode',
      'video-first-frame',
      'thumbnail-duration',
      'thumbnail-cache-reuse',
      'trim',
      'trim-playback',
      'merge',
      'merge-playback',
      'source-integrity',
      'persistence-write',
    ],
    'reopen' => const [
      'rust-initialization',
      'first-frame',
      'first-gallery-query',
      'persistence-read',
      'thumbnail-cache-reuse',
    ],
    'safe' => const [
      'rust-initialization',
      'first-frame',
      'first-gallery-query',
      'safe-components-disabled',
    ],
    _ => throw ArgumentError('Unknown smoke scenario'),
  };

  void record(String name, {required bool passed, String? error}) {
    steps.add({
      'name': name,
      'status': passed ? 'passed' : 'failed',
      'error': ?error,
    });
  }

  bool get passed => _allStepsPassed(steps, requiredSteps(scenario));

  Map<String, Object?> toJson() => {
    'schema': 1,
    'scenario': scenario,
    'platform': Platform.operatingSystem,
    'status': passed ? 'passed' : 'failed',
    'steps': steps,
  };

  static bool accepts(Object? json, {required String scenario}) {
    if (json is! Map ||
        json['schema'] != 1 ||
        json['scenario'] != scenario ||
        json['status'] != 'passed' ||
        json['steps'] is! List) {
      return false;
    }
    return _allStepsPassed(json['steps'] as List, requiredSteps(scenario));
  }

  static bool _allStepsPassed(List steps, List<String> required) =>
      steps.isNotEmpty &&
      steps.every((step) => step is Map && step['status'] == 'passed') &&
      required.every(
        (name) =>
            steps.where((step) => step is Map && step['name'] == name).length ==
            1,
      );
}

String sanitizeSmokeDiagnostic(
  String message, {
  Iterable<String> roots = const [],
}) {
  var value = message;
  for (final root in roots.where((root) => root.isNotEmpty)) {
    value = value.replaceAll(root, '<ci-root>');
  }
  value = value
      .replaceAll(
        RegExp(r'(authorization|cookie)[^\r\n]*', caseSensitive: false),
        '<redacted>',
      )
      .replaceAll(
        RegExp(
          r'(?:session|access|refresh|id)[_-]?token[^\s,]*',
          caseSensitive: false,
        ),
        '<redacted>',
      )
      .replaceAll(RegExp(r'[A-Za-z]:[\\/][^\r\n"<>]+'), '<path>')
      .replaceAll(
        RegExp(r'/(?:Users|home|private|var|tmp)/[^\s"<>]+'),
        '<path>',
      );
  return value.length > 2000 ? value.substring(0, 2000) : value;
}
