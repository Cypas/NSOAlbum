import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class NintendoMtpDevice {
  const NintendoMtpDevice(this.name);

  final String name;
}

class NintendoMtpProgress {
  const NintendoMtpProgress({required this.completed, required this.total});

  final int completed;
  final int total;
}

class NintendoMtpMediaEntry {
  const NintendoMtpMediaEntry({
    required this.gameName,
    required this.fileName,
    required this.sizeBytes,
    required this.capturedAt,
  });

  final String gameName;
  final String fileName;
  final int sizeBytes;
  final DateTime? capturedAt;

  Map<String, Object?> toJson() => {'gameName': gameName, 'fileName': fileName};
}

class NintendoMtpStagingResult {
  const NintendoMtpStagingResult({
    required this.directory,
    required this.files,
  });

  final Directory directory;
  final List<String> files;
}

class WindowsNintendoMtp {
  static const supportedDeviceNames = {'Nintendo Switch', 'Nintendo Switch 2'};

  static Future<List<NintendoMtpDevice>> listDevices() async {
    if (!Platform.isWindows) return const [];
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-OutputFormat',
        'Text',
        '-EncodedCommand',
        _encodedListDevicesScript,
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw StateError(
        'Unable to enumerate Nintendo media devices: ${cleanPowerShellError(result.stderr.toString())}',
      );
    }
    final output = (result.stdout as String).trim();
    if (output.isEmpty) return const [];
    final decoded = jsonDecode(output);
    final names = decoded is List ? decoded : [decoded];
    return names
        .whereType<String>()
        .where(supportedDeviceNames.contains)
        .map(NintendoMtpDevice.new)
        .toList(growable: false);
  }

  static Future<NintendoMtpStagingResult> stageAlbum(
    NintendoMtpDevice device, {
    required List<NintendoMtpMediaEntry> entries,
    void Function(NintendoMtpProgress progress)? onProgress,
  }) async {
    if (!Platform.isWindows || !supportedDeviceNames.contains(device.name)) {
      throw UnsupportedError('Unsupported Nintendo media device');
    }
    if (entries.isEmpty) {
      throw ArgumentError.value(entries, 'entries', 'No media selected');
    }
    for (final entry in entries) {
      if (entry.gameName.trim().isEmpty || entry.fileName.trim().isEmpty) {
        throw ArgumentError.value(
          entries,
          'entries',
          'Nintendo media entries must include a game and file name',
        );
      }
      if (entry.fileName != entry.fileName.split(RegExp(r'[\\/]')).last) {
        throw ArgumentError.value(
          entry.fileName,
          'fileName',
          'Nintendo media file name must not include a path',
        );
      }
    }
    final staging = await Directory.systemTemp.createTemp('fresh_album_mtp_');
    final selectionFile = File('${staging.path}\\selection.json');
    await selectionFile.writeAsString(
      jsonEncode({
        'version': 1,
        'entries': entries.map((entry) => entry.toJson()).toList(),
      }),
      encoding: utf8,
      flush: true,
    );
    final process = await Process.start(
      'powershell.exe',
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-OutputFormat',
        'Text',
        '-EncodedCommand',
        _encodedStageAlbumScript,
      ],
      environment: {
        ...Platform.environment,
        'FRESH_ALBUM_MTP_DEVICE': device.name,
        'FRESH_ALBUM_MTP_TARGET': staging.path,
        'FRESH_ALBUM_MTP_SELECTION': selectionFile.path,
      },
    );
    final files = <String>[];
    final errors = StringBuffer();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          if (line.startsWith('PROGRESS\t')) {
            final parts = line.split('\t');
            if (parts.length >= 3) {
              onProgress?.call(
                NintendoMtpProgress(
                  completed: int.tryParse(parts[1]) ?? 0,
                  total: int.tryParse(parts[2]) ?? 0,
                ),
              );
            }
          } else if (line.startsWith('FILE\t')) {
            files.add(line.substring(5));
          }
        });
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(errors.writeln);
    final exitCode = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    if (exitCode != 0) {
      await staging.delete(recursive: true);
      throw StateError(
        errors.isEmpty
            ? 'Failed to copy the Nintendo Album directory'
            : cleanPowerShellError(errors.toString()),
      );
    }
    if (files.isEmpty) {
      await staging.delete(recursive: true);
      throw StateError(
        'The Nintendo Album directory contains no supported media',
      );
    }
    return NintendoMtpStagingResult(directory: staging, files: files);
  }

  static Future<List<NintendoMtpMediaEntry>> scanAlbum(
    NintendoMtpDevice device,
  ) async {
    if (!Platform.isWindows || !supportedDeviceNames.contains(device.name)) {
      throw UnsupportedError('Unsupported Nintendo media device');
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
        _encodedScanAlbumScript,
      ],
      environment: {
        ...Platform.environment,
        'FRESH_ALBUM_MTP_DEVICE': device.name,
      },
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw StateError(
        'Unable to read the Nintendo Album index: ${cleanPowerShellError(result.stderr.toString())}',
      );
    }
    final output = (result.stdout as String).trim();
    if (output.isEmpty) return const [];
    final decoded = jsonDecode(output);
    final rows = decoded is List ? decoded : [decoded];
    return rows
        .whereType<Map<String, dynamic>>()
        .map((row) {
          final captured = row['capturedAt'] as String?;
          return NintendoMtpMediaEntry(
            gameName: row['gameName'] as String? ?? '',
            fileName: row['fileName'] as String? ?? '',
            sizeBytes: (row['sizeBytes'] as num?)?.toInt() ?? 0,
            capturedAt: captured == null ? null : DateTime.tryParse(captured),
          );
        })
        .where((entry) {
          return entry.gameName.isNotEmpty && entry.fileName.isNotEmpty;
        })
        .toList(growable: false);
  }

  static final String _encodedListDevicesScript = _encodePowerShell(r'''
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$shell = New-Object -ComObject Shell.Application
$computer = $shell.Namespace(17)
$names = @($computer.Items() |
  Where-Object { $_.Name -eq 'Nintendo Switch' -or $_.Name -eq 'Nintendo Switch 2' } |
  ForEach-Object { $_.Name })
Write-Output ($names | ConvertTo-Json -Compress)
''');

  static final String _encodedScanAlbumScript = _encodePowerShell(r'''
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$deviceName = $env:FRESH_ALBUM_MTP_DEVICE
$extensions = @('.jpg', '.jpeg', '.png', '.webp', '.mp4', '.mov')
$shell = New-Object -ComObject Shell.Application
$computer = $shell.Namespace(17)
$device = @($computer.Items() | Where-Object { $_.Name -eq $deviceName } | Select-Object -First 1)
if ($device.Count -eq 0) { throw "Nintendo media device disconnected: $deviceName" }
$album = @($device[0].GetFolder.Items() |
  Where-Object { $_.IsFolder -and $_.Name -eq 'Album' } |
  Select-Object -First 1)
if ($album.Count -eq 0) { throw "Album directory was not found on $deviceName" }
$rows = [Collections.Generic.List[Object]]::new()
foreach ($game in @($album[0].GetFolder.Items() | Where-Object { $_.IsFolder })) {
  foreach ($item in @($game.GetFolder.Items() | Where-Object { -not $_.IsFolder })) {
    if ($extensions -notcontains [System.IO.Path]::GetExtension($item.Name).ToLowerInvariant()) { continue }
    $size = 0L
    try {
      $rawSize = $item.ExtendedProperty('System.Size')
      if ($null -ne $rawSize) { $size = [Int64]$rawSize }
    } catch {}
    $capturedAt = $null
    if ($item.Name -match '^(\d{14})') {
      try {
        $capturedAt = [DateTime]::ParseExact(
          $Matches[1],
          'yyyyMMddHHmmss',
          [Globalization.CultureInfo]::InvariantCulture
        ).ToString('o')
      } catch {}
    }
    if ($null -eq $capturedAt) {
      try {
        $modified = $item.ExtendedProperty('System.DateModified')
        if ($null -ne $modified) { $capturedAt = ([DateTime]$modified).ToString('o') }
      } catch {}
    }
    [void]$rows.Add([PSCustomObject]@{
      gameName = [String]$game.Name
      fileName = [String]$item.Name
      sizeBytes = $size
      capturedAt = $capturedAt
    })
  }
}
Write-Output ($rows | ConvertTo-Json -Compress -Depth 3)
''');

  static const String selectionReaderPowerShellForTesting = r'''
$selectionJson = [System.IO.File]::ReadAllText(
  $selectionPath,
  [System.Text.UTF8Encoding]::new($false, $true)
)
try {
  $document = ConvertFrom-Json -InputObject $selectionJson -ErrorAction Stop
} catch {
  throw "Invalid Nintendo media selection UTF-8 JSON: $($_.Exception.Message)"
}
''';

  static final String _encodedStageAlbumScript = _encodePowerShell(
    r'''
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$deviceName = $env:FRESH_ALBUM_MTP_DEVICE
$target = $env:FRESH_ALBUM_MTP_TARGET
$selectionPath = $env:FRESH_ALBUM_MTP_SELECTION
$extensions = @('.jpg', '.jpeg', '.png', '.webp', '.mp4', '.mov')
''' +
        selectionReaderPowerShellForTesting +
        r'''
if ($null -eq $document -or $document.version -ne 1) { throw 'Unsupported Nintendo media selection format' }
$selection = @($document.entries)
if ($selection.Count -eq 0) { throw 'No Nintendo media files were selected' }
$shell = New-Object -ComObject Shell.Application
$computer = $shell.Namespace(17)
$device = @($computer.Items() | Where-Object { $_.Name -eq $deviceName } | Select-Object -First 1)
if ($device.Count -eq 0) { throw "Nintendo media device disconnected: $deviceName" }
$album = @($device[0].GetFolder.Items() |
  Where-Object { $_.IsFolder -and $_.Name -eq 'Album' } |
  Select-Object -First 1)
if ($album.Count -eq 0) { throw "Album directory was not found on $deviceName" }
$total = $selection.Count
Write-Output "PROGRESS`t0`t$total"
$albumTarget = Join-Path $target 'Album'
New-Item -ItemType Directory -Force -Path $albumTarget | Out-Null
$gameFolders = @{}
foreach ($folder in @($album[0].GetFolder.Items() | Where-Object { $_.IsFolder })) {
  $gameFolders[[String]$folder.Name] = $folder
}
$destinations = @{}
foreach ($selected in $selection) {
  $gameName = ([String]$selected.gameName).Trim()
  $fileName = ([String]$selected.fileName).Trim()
  if ([String]::IsNullOrWhiteSpace($gameName)) { throw 'Selected Nintendo media entry has an empty game name' }
  if ([String]::IsNullOrWhiteSpace($fileName)) { throw "Selected Nintendo media entry in '$gameName' has an empty file name" }
  if ([System.IO.Path]::GetFileName($fileName) -ne $fileName) { throw "Selected Nintendo media file name is invalid: $fileName" }
  $game = $gameFolders[$gameName]
  if ($null -eq $game) {
    foreach ($folder in @($album[0].GetFolder.Items() | Where-Object { $_.IsFolder })) {
      $gameFolders[[String]$folder.Name] = $folder
    }
    $game = $gameFolders[$gameName]
  }
  if ($null -eq $game) { throw "Game folder disappeared from the Nintendo Album: $gameName" }
  $safeGameName = [Regex]::Replace($gameName, '[\\/:*?"<>|]', '＿').Trim().TrimEnd('.')
  if ([String]::IsNullOrWhiteSpace($safeGameName)) { $safeGameName = 'Unknown Game' }
  $gameTarget = Join-Path $albumTarget $safeGameName
  New-Item -ItemType Directory -Force -Path $gameTarget | Out-Null
  $destination = $destinations[$gameTarget]
  if ($null -eq $destination) {
    $destination = $shell.Namespace($gameTarget)
    $destinations[$gameTarget] = $destination
  }
  if ($null -eq $destination) { throw "Unable to open staging directory: $gameTarget" }
  $item = @($game.GetFolder.Items() |
    Where-Object { -not $_.IsFolder -and $_.Name -eq $fileName } |
    Select-Object -First 1)
  if ($item.Count -eq 0) { throw "Nintendo media file disappeared from '$gameName': $fileName" }
  $destination.CopyHere($item[0], 20)
}
$deadline = [DateTime]::UtcNow.AddHours(2)
$lastCount = -1
$lastSize = -1L
$stable = 0
do {
  Start-Sleep -Milliseconds 500
  $localFiles = @(Get-ChildItem -LiteralPath (Join-Path $target 'Album') -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() })
  $count = $localFiles.Count
  $size = [Int64](($localFiles | Measure-Object -Property Length -Sum).Sum)
  if ($count -ne $lastCount) { Write-Output "PROGRESS`t$count`t$total" }
  if ($count -ge $total -and $size -gt 0 -and $size -eq $lastSize) { $stable++ } else { $stable = 0 }
  $lastCount = $count
  $lastSize = $size
  if ([DateTime]::UtcNow -gt $deadline) { throw 'Timed out while copying the Nintendo Album directory' }
} while ($count -lt $total -or $stable -lt 4)
foreach ($file in $localFiles) { Write-Output ("FILE`t" + $file.FullName) }
Write-Output "PROGRESS`t$total`t$total"
''',
  );

  static String _encodePowerShell(String script) {
    final units = script.codeUnits;
    final bytes = Uint8List(units.length * 2);
    final data = ByteData.sublistView(bytes);
    for (var index = 0; index < units.length; index++) {
      data.setUint16(index * 2, units[index], Endian.little);
    }
    return base64Encode(bytes);
  }
}

String cleanPowerShellError(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return value;
  if (value.contains('#< CLIXML') || value.contains('<Objs ')) {
    final matches = RegExp(
      r'<S S="Error">(.*?)</S>',
      dotAll: true,
    ).allMatches(value);
    final lines = matches
        .map((match) => _decodePowerShellXml(match.group(1) ?? ''))
        .expand((entry) => entry.split(RegExp(r'[\r\n]+')))
        .map((line) => line.trim())
        .where(
          (line) =>
              line.isNotEmpty &&
              !line.startsWith('所在位置') &&
              !line.startsWith('+') &&
              !line.startsWith('~') &&
              !line.startsWith('CategoryInfo') &&
              !line.startsWith('FullyQualifiedErrorId'),
        )
        .toList(growable: false);
    if (lines.isNotEmpty) return lines.first;
    value = _decodePowerShellXml(value.replaceAll('#< CLIXML', ''));
  }
  return value.trim();
}

String _decodePowerShellXml(String value) => value
    .replaceAll('_x000D__x000A_', '\n')
    .replaceAll('&#xD;', '\r')
    .replaceAll('&#xA;', '\n')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');
