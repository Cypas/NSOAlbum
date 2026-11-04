@Tags(['platform-windows'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final enabled =
      Platform.isWindows &&
      Platform.environment['NSO_VERIFY_WINDOWS_WEBVIEW_LOADER'] == '1';
  test(
    'packaged WebView retains its dispatcher provider through DLL detach',
    () async {
      final bundle =
          Platform.environment['NSO_WINDOWS_WEBVIEW_BUNDLE'] ??
          p.absolute('build/windows/x64/runner/Debug');
      final plugin = File(
        p.join(bundle, 'flutter_inappwebview_windows_plugin.dll'),
      );
      expect(
        plugin.existsSync(),
        isTrue,
        reason: 'Build the native bundle first.',
      );
      final studio = await Process.run(
        p.join(
          Platform.environment['ProgramFiles(x86)']!,
          'Microsoft Visual Studio/Installer/vswhere.exe',
        ),
        [
          '-latest',
          '-products',
          '*',
          '-requires',
          'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
          '-property',
          'installationPath',
        ],
      );
      expect(studio.exitCode, 0, reason: '${studio.stderr}');
      final versions =
          Directory(p.join(studio.stdout.toString().trim(), 'VC/Tools/MSVC'))
              .listSync()
              .whereType<Directory>()
              .toList()
            ..sort((a, b) => b.path.compareTo(a.path));
      expect(versions, isNotEmpty);
      final imports = await Process.run(
        p.join(versions.first.path, 'bin/Hostx64/x64/dumpbin.exe'),
        ['/imports', plugin.path],
      );
      expect(imports.exitCode, 0, reason: '${imports.stderr}');
      final text = imports.stdout.toString();
      expect(
        text,
        isNot(matches(RegExp(r'\bCoreMessaging\.dll\b', caseSensitive: false))),
        reason: 'Keep the provider optional instead of eagerly binding its newer API.',
      );
      final executable = await Process.run(
        p.join(versions.first.path, 'bin/Hostx64/x64/dumpbin.exe'),
        ['/imports', p.join(bundle, 'NSOAlbum.exe')],
      );
      expect(executable.exitCode, 0, reason: '${executable.stderr}');
      final executableImports = executable.stdout.toString();
      expect(
        executableImports,
        isNot(contains('permission_handler_windows_plugin.dll')),
        reason:
            'The only permission request is Android-only Wi-Fi access. '
            'Do not initialize an unused Windows location subscription.',
      );
      final delayed = RegExp(
        r'delay\s+load\s+imports',
        caseSensitive: false,
      ).firstMatch(executableImports);
      expect(
        delayed,
        isNotNull,
        reason: 'Load the WebView consumer after its optional system provider.',
      );
      expect(
        executableImports.substring(delayed!.start),
        contains('flutter_inappwebview_windows_plugin.dll'),
      );
      expect(
        Directory(bundle).listSync().whereType<File>().where(
          (file) => p.basename(file.path).toLowerCase() == 'coremessaging.dll',
        ),
        isEmpty,
        reason:
            'Use the Windows SDK provider; do not bundle a shadow system DLL.',
      );
    },
    skip: enabled ? false : 'Requires a prepared Windows bundle and NSO_VERIFY_WINDOWS_WEBVIEW_LOADER=1.',
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
