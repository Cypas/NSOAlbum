// Diagnostic fixture only; never a user's media or a packaged application asset.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:squid_album/src/startup/ci_smoke_contract.dart';

const syntheticQaPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=';

/// Same bytes on every device and round; at most 64KiB is prepared per write.
/// Media is a valid tiny PNG with diagnostic padding, not a user's image.
Future<List<File>> createDeviceSyncThroughputFixture(Directory root) async {
  await _requireOwnedFixtureRoot(root);
  final directory = await root.createTemp('throughput-');
  final files = <File>[];
  final header = base64Decode(syntheticQaPngBase64);
  for (var index = 0; index < 65; index++) {
    final size = index == 0 ? 64 * 1024 * 1024 : 256 * 1024;
    files.add(await _writePaddedFile(directory, index, size, header, 'png'));
  }
  return files;
}

/// Exactly 80MiB: sixteen 1/2MiB PNGs and one 56MiB MP4. The existing
/// authored CI video remains playable; padding is a standard MP4 free box.
Future<List<File>> createDeviceSyncRealisticThroughputFixture(
  Directory root, {
  required List<int> videoSeed,
}) async {
  await _requireOwnedFixtureRoot(root);
  if (videoSeed.length < 12 ||
      videoSeed.length > 1024 * 1024 ||
      ascii.decode(videoSeed.sublist(4, 8), allowInvalid: true) != 'ftyp') {
    throw ArgumentError('A bounded synthetic MP4 seed is required');
  }
  final directory = await root.createTemp('throughput-realistic-');
  const videoSize = 56 * 1024 * 1024;
  final free = ByteData(8)..setUint32(0, videoSize - videoSeed.length);
  free.buffer.asUint8List().setRange(4, 8, ascii.encode('free'));
  final files = <File>[
    await _writePaddedFile(directory, 0, videoSize, [
      ...videoSeed,
      ...free.buffer.asUint8List(),
    ], 'mp4'),
  ];
  final header = base64Decode(syntheticQaPngBase64);
  for (var index = 1; index <= 16; index++) {
    files.add(
      await _writePaddedFile(
        directory,
        index,
        (index.isOdd ? 1 : 2) * 1024 * 1024,
        header,
        'png',
      ),
    );
  }
  return files;
}

Future<void> _requireOwnedFixtureRoot(Directory root) async {
  final canonical = p.normalize(await root.resolveSymbolicLinks());
  final owner = File(p.join(root.path, CiSmokeRoot.marker));
  if (!p.equals(canonical, p.normalize(root.absolute.path)) ||
      await FileSystemEntity.type(owner.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await owner.length() > 128 ||
      await owner.readAsString() != 'NSOAlbum isolated CI library v1') {
    throw StateError('Throughput fixture requires a contained owned QA root');
  }
}

Future<File> _writePaddedFile(
  Directory directory,
  int index,
  int size,
  List<int> header,
  String extension,
) async {
  final file = File(p.join(directory.path, 'sample-$index.$extension'));
  final output = await file.open(mode: FileMode.writeOnly);
  try {
    await output.writeFrom(header);
    final block = Uint8List(64 * 1024);
    for (var offset = 0; offset < block.length; offset++) {
      block[offset] = (index * 31 + offset * 13) & 255;
    }
    var remaining = size - header.length;
    while (remaining > 0) {
      final count = remaining < block.length ? remaining : block.length;
      await output.writeFrom(block, 0, count);
      remaining -= count;
    }
    await output.flush();
  } finally {
    await output.close();
  }
  return file;
}
