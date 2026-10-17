import 'dart:io';

import 'package:squid_album/src/startup/desktop_single_instance.dart';

Future<void> main(List<String> args) async {
  final directory = Directory(args[0]);
  await directory.create(recursive: true);
  if (args.length > 1 && args[1] == 'hold') {
    final lock = await File('${directory.path}/owner.lock')
        .open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
    stdout.writeln('holder');
    await stdin.first;
    await lock.close();
    return;
  }
  try {
    final owner = await DesktopSingleInstance.acquire(
      directory: directory,
      waitTimeout: const Duration(seconds: 2),
      onActivate: () async => stdout.writeln('activated'),
    );
    if (owner == null) {
      stdout.writeln('secondary');
      return;
    }
    stdout.writeln('primary');
    stdout.writeln('business-started');
    await stdin.first;
    await owner.close();
  } catch (_) {
    stderr.writeln('instance-unavailable');
    exitCode = 73;
  }
}
