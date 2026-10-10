// Development-only generator. CI/runtime use the checked-in base64 fixture;
// they never execute a system FFmpeg. Output belongs in ignored .dart_tool.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    throw ArgumentError(
      'Pass a development FFmpeg executable and optional generated asset output',
    );
  }
  final directory = Directory('.dart_tool/ci-fixture')
    ..createSync(recursive: true);
  const luminance = 160 * 96;
  const chrominance = luminance ~/ 4;
  const frameBytes = luminance + chrominance * 2;
  final raw = Uint8List(frameBytes * 48);
  for (var frame = 0; frame < 48; frame++) {
    final start = frame * frameBytes;
    raw.fillRange(start, start + luminance, 124);
    raw.fillRange(start + luminance, start + luminance + chrominance, 175);
    raw.fillRange(start + luminance + chrominance, start + frameBytes, 75);
  }
  await File('${directory.path}/source.rgb').writeAsBytes(raw);
  await File('${directory.path}/silence.pcm')
      .writeAsBytes(Uint8List(48000 * 2 * 2 * 2));
  final result = await Process.run(args.first, [
    '-y',
    '-f',
    'rawvideo',
    '-pix_fmt',
    'yuv420p',
    '-s',
    '160x96',
    '-r',
    '24',
    '-i',
    '${directory.path}/source.rgb',
    '-f',
    's16le',
    '-ar',
    '48000',
    '-ac',
    '2',
    '-i',
    '${directory.path}/silence.pcm',
    '-t',
    '2',
    '-vcodec',
    'libx264',
    '-pix_fmt',
    'yuv420p',
    '-preset',
    'slow',
    '-crf',
    '35',
    '-acodec',
    'aac',
    '-strict',
    'experimental',
    '-ab',
    '16k',
    '${directory.path}/original.mp4',
  ]);
  if (result.exitCode != 0) throw StateError('${result.stderr}');
  final encoded = base64Encode(
    await File('${directory.path}/original.mp4').readAsBytes(),
  );
  if (args.length == 2) {
    if (args[1] != 'assets/ci/synthetic-h264-aac.base64') {
      throw ArgumentError('Only the synthetic CI asset may be regenerated');
    }
    final lines = RegExp('.{1,76}')
        .allMatches(encoded)
        .map((match) => match[0])
        .join('\n');
    await File(args[1]).writeAsString('$lines\n');
  } else {
    stdout.writeln(encoded);
  }
}
