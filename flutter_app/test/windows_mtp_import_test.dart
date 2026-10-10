import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/windows_mtp_import.dart';

void main() {
  test('cleans PowerShell CLIXML errors into a readable message', () {
    const raw = '''#< CLIXML
<Objs Version="1.1.0.1"><S S="Error">Game folder disappeared from the Nintendo Album: 喷射战士3_x000D__x000A_</S><S S="Error">所在位置 行:26 字符: 28_x000D__x000A_</S><S S="Error">+ throw something_x000D__x000A_</S></Objs>''';

    expect(
      cleanPowerShellError(raw),
      'Game folder disappeared from the Nintendo Album: 喷射战士3',
    );
  }, tags: 'common');

  test('leaves plain PowerShell errors readable', () {
    expect(
      cleanPowerShellError(
        'Nintendo media device disconnected: Nintendo Switch 2',
      ),
      'Nintendo media device disconnected: Nintendo Switch 2',
    );
  }, tags: 'common');

  test(
    '[Windows] PowerShell 5.1 reads Nintendo selection JSON as strict UTF-8',
    () async {
      final directory = await Directory.systemTemp.createTemp('mtp_json_test_');
      addTearDown(() => directory.delete(recursive: true));
      final selection = File('${directory.path}\\selection.json');
      await selection.writeAsString(
        jsonEncode({
          'version': 1,
          'entries': [
            {'gameName': 'ゼルダ無双 封印戦記', 'fileName': '2025122612345601.jpg'},
          ],
        }),
        encoding: utf8,
        flush: true,
      );
      final escapedPath = selection.path.replaceAll("'", "''");
      final script =
          '''
\$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(\$false)
\$selectionPath = '$escapedPath'
${WindowsNintendoMtp.selectionReaderPowerShellForTesting}
Write-Output (\$document.entries | ConvertTo-Json -Compress)
''';
      final units = script.codeUnits;
      final bytes = Uint8List(units.length * 2);
      final data = ByteData.sublistView(bytes);
      for (var index = 0; index < units.length; index++) {
        data.setUint16(index * 2, units[index], Endian.little);
      }
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-OutputFormat',
          'Text',
          '-EncodedCommand',
          base64Encode(bytes),
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

      expect(result.exitCode, 0, reason: result.stderr.toString());
      final decoded = jsonDecode((result.stdout as String).trim());
      expect(decoded['gameName'], 'ゼルダ無双 封印戦記');
      expect(decoded['fileName'], '2025122612345601.jpg');
    },
    tags: 'platform-windows',
    skip: Platform.isWindows ? false : 'Requires Windows PowerShell 5.1',
  );
}
