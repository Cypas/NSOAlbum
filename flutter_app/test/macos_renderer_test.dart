@Tags(['platform-macos'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const skipReason = 'Requires native macOS PlistBuddy and plutil';

  Future<Directory> bundle() async {
    final directory = await Directory.systemTemp.createTemp('nso-renderer-');
    addTearDown(() => directory.delete(recursive: true));
    final app = Directory(p.join(directory.path, 'NSOAlbum.app'));
    final contents = await Directory(p.join(app.path, 'Contents'))
        .create(recursive: true);
    await File(p.join(contents.path, 'Info.plist')).writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.squidalbum.NSOAlbum</string>
<key>FLTEnableImpeller</key><true/>
</dict></plist>
''');
    return app;
  }

  Future<ProcessResult> configure(Directory app, String arch) => Process.run(
    'bash',
    [p.absolute('tool/configure_macos_renderer.sh'), app.path, arch],
  );

  test(
    'Intel package disables Impeller using a boolean bundle setting',
    () async {
      final app = await bundle();
      final result = await configure(app, 'x64');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final setting = await Process.run('/usr/bin/plutil', [
        '-extract',
        'FLTEnableImpeller',
        'raw',
        '-expect',
        'bool',
        '-o',
        '-',
        p.join(app.path, 'Contents', 'Info.plist'),
      ]);
      expect(setting.exitCode, 0);
      expect('${setting.stdout}'.trim(), 'false');
      final identifier = await Process.run('/usr/libexec/PlistBuddy', [
        '-c',
        'Print :CFBundleIdentifier',
        p.join(app.path, 'Contents', 'Info.plist'),
      ]);
      expect('${identifier.stdout}'.trim(), 'io.squidalbum.NSOAlbum');
    },
    skip: Platform.isMacOS ? false : skipReason,
  );

  test('arm64 renderer metadata is unchanged', () async {
    final app = await bundle();
    final plist = File(p.join(app.path, 'Contents', 'Info.plist'));
    final before = await plist.readAsBytes();
    final result = await configure(app, 'arm64');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(await plist.readAsBytes(), before);
  }, skip: Platform.isMacOS ? false : skipReason);

  test(
    'Intel adds the renderer setting when the bundle has no override',
    () async {
      final app = await bundle();
      final plistPath = p.join(app.path, 'Contents', 'Info.plist');
      final removed = await Process.run('/usr/libexec/PlistBuddy', [
        '-c',
        'Delete :FLTEnableImpeller',
        plistPath,
      ]);
      expect(removed.exitCode, 0);
      final result = await configure(app, 'x64');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final setting = await Process.run('/usr/bin/plutil', [
        '-extract',
        'FLTEnableImpeller',
        'raw',
        '-expect',
        'bool',
        '-o',
        '-',
        plistPath,
      ]);
      expect(setting.exitCode, 0);
      expect('${setting.stdout}'.trim(), 'false');
    },
    skip: Platform.isMacOS ? false : skipReason,
  );

  test('unknown architecture fails without changing bundle metadata', () async {
    final app = await bundle();
    final plist = File(p.join(app.path, 'Contents', 'Info.plist'));
    final before = await plist.readAsBytes();
    final result = await configure(app, 'wrong');
    expect(result.exitCode, isNot(0));
    expect(await plist.readAsBytes(), before);
  }, skip: Platform.isMacOS ? false : skipReason);
}
