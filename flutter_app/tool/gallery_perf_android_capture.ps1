param(
  [ValidateSet('debug', 'profile')][string]$Mode = 'debug',
  [ValidateSet('idle', 'normalDown', 'fastDown', 'reverse', 'returnTop', 'settle', 'warmDown', 'warmReverse')]
  [string]$Scenario = 'normalDown',
  [ValidateSet('normal', 'placeholder', 'encodedWarm')][string]$CoverMode = 'normal',
  [ValidatePattern('^[a-zA-Z0-9_.-]+\.json$')][string]$Name,
  [ValidateRange(100, 120000)][int]$DurationMs = 20000,
  [ValidateRange(1, 100)][int]$Repetition = 1
)
$ErrorActionPreference = 'Stop'
$buildRoot = $env:NSOALBUM_BUILD_ROOT
if (!$buildRoot -or (Get-Location).Path -ne "$buildRoot\source\flutter_app" -or !$Name) {
  throw 'invalid_capture_configuration'
}
$adb = (Get-Command adb -ErrorAction Stop).Source
$serial = $env:ANDROID_SERIAL
if (!$serial) { throw 'android_serial_required' }
$dump = (& $adb -s $serial shell -t -t uiautomator dump /dev/tty) -join "`n"
$xmlStart = $dump.IndexOf('<?xml')
$xmlEnd = $dump.LastIndexOf('</hierarchy>')
if ($xmlStart -lt 0 -or $xmlEnd -le $xmlStart) { throw 'ui_unavailable' }
[xml]$tree = $dump.Substring($xmlStart, $xmlEnd + 12 - $xmlStart)
$nodes = $tree.SelectNodes('//node')
$scrollNode = $nodes | Where-Object {
  $_.package -eq 'io.github.cypas.nsoalbum' -and $_.scrollable -eq 'true'
} | Select-Object -First 1
$bounds = [regex]::Match($scrollNode.bounds, '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
if (!$bounds.Success) { throw 'gallery_scroll_unavailable' }
$left = [int]$bounds.Groups[1].Value
$top = [int]$bounds.Groups[2].Value
$right = [int]$bounds.Groups[3].Value
$bottom = [int]$bounds.Groups[4].Value
$swipeX = [int](($left + $right) / 2)
$lowY = [int]($top + ($bottom - $top) * .82)
$highY = [int]($top + ($bottom - $top) * .22)
if ($Scenario -eq 'returnTop') {
  $button = $nodes | Where-Object { $_.'content-desc' -in @('回到顶部', 'Back to top') } | Select-Object -First 1
  $buttonBounds = [regex]::Match($button.bounds, '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
  if (!$buttonBounds.Success) { throw 'return_top_unavailable' }
  $tapX = [int](([int]$buttonBounds.Groups[1].Value + [int]$buttonBounds.Groups[3].Value) / 2)
  $tapY = [int](([int]$buttonBounds.Groups[2].Value + [int]$buttonBounds.Groups[4].Value) / 2)
}
$appPid = (& $adb -s $serial shell pidof io.github.cypas.nsoalbum).Trim()
if ($appPid -notmatch '^\d+$') { throw 'app_unavailable' }
# The Android log and VM authentication URI exist only in this process memory.
# No raw log, URI, endpoint or exception text enters the report.
$appLog = (& $adb -s $serial logcat -d "--pid=$appPid" -t 500) -join "`n"
$match = [regex]::Match(
  $appLog,
  '(?:Dart VM service is listening on |Observatory listening on )(http://127[.]0[.]0[.]1:(\d+)/[^\s]+)'
)
if (!$match.Success) {
  # Long scroll sessions can push the startup record beyond the recent tail.
  # Read only this PID's bounded logcat ring in memory; never persist it.
  $appLog = (& $adb -s $serial logcat -d "--pid=$appPid") -join "`n"
  $match = [regex]::Match(
    $appLog,
    '(?:Dart VM service is listening on |Observatory listening on )(http://127[.]0[.]0[.]1:(\d+)/[^\s]+)'
  )
}
if (!$match.Success) { throw 'service_unavailable' }
$endpoint = [uri]$match.Groups[1].Value
$localPort = (& $adb -s $serial forward tcp:0 "tcp:$($endpoint.Port)").Trim()
if ($localPort -notmatch '^\d+$') { throw 'forward_failed' }
try {
  $builder = [UriBuilder]::new($endpoint)
  $builder.Scheme = 'ws'
  $builder.Port = [int]$localPort
  $builder.Path = $builder.Path.TrimEnd('/') + '/ws'
  $info = [Diagnostics.ProcessStartInfo]::new()
  $dartCommand = (Get-Command dart -CommandType Application -ErrorAction Stop).Source
  $info.FileName = if ($dartCommand.EndsWith('.bat')) {
    Join-Path (Split-Path -Parent $dartCommand) 'cache\dart-sdk\bin\dart.exe'
  } else { $dartCommand }
  if (!(Test-Path -LiteralPath $info.FileName -PathType Leaf)) { throw 'dart_executable_required' }
  $info.WorkingDirectory = "$buildRoot\source\flutter_app"
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  foreach ($argument in @('run', 'tool/gallery_perf_capture.dart', '--platform', 'android',
      '--mode', $Mode, '--scenario', $Scenario, '--cover-mode', $CoverMode,
      '--repetition', "$Repetition", '--duration-ms', "$DurationMs",
      '--output', "$buildRoot\perf\$Name")) {
    $info.ArgumentList.Add($argument)
  }
  $capture = [Diagnostics.Process]::Start($info)
  $capture.StandardInput.WriteLine($builder.Uri.AbsoluteUri)
  $capture.StandardInput.Close()
  $gestures = 0
  while (!$capture.StandardError.EndOfStream) {
    $line = $capture.StandardError.ReadLine()
    if ($line.TrimEnd().EndsWith('capture_started')) {
      Write-Output 'capture_started'
      # Start inputs from the actual capture latch, not from tool-call timing.
      $watch = [Diagnostics.Stopwatch]::StartNew()
      if ($Scenario -eq 'returnTop') {
        & $adb -s $serial shell input tap $tapX $tapY
        $gestures++
      } elseif ($Scenario -in @('normalDown', 'warmDown', 'reverse', 'warmReverse', 'fastDown')) {
        $reverse = $Scenario -in @('reverse', 'warmReverse')
        $fast = $Scenario -eq 'fastDown'
        while ($watch.ElapsedMilliseconds -lt ($DurationMs - 1500)) {
          $fromY = if ($reverse) { $highY } else { $lowY }
          $toY = if ($reverse) { $lowY } else { $highY }
          $swipeMs = if ($fast) { 250 } else { 700 }
          & $adb -s $serial shell input swipe $swipeX $fromY $swipeX $toY $swipeMs
          $gestures++
          Start-Sleep -Milliseconds $(if ($fast) { 180 } else { 300 })
        }
      }
    } elseif ($line -eq 'capture_stopped') {
      Write-Output 'capture_stopped'
    }
  }
  $capture.WaitForExit()
  if ($capture.ExitCode -ne 0) { throw 'capture_failed' }
  if ($Scenario -in @('normalDown', 'warmDown', 'reverse', 'warmReverse', 'fastDown', 'returnTop') -and $gestures -eq 0) {
    throw 'input_not_started'
  }
  $report = Get-Content -LiteralPath "$buildRoot\perf\$Name" -Raw | ConvertFrom-Json -AsHashtable
  $report['input'] = 'adb_touch_swipe'
  $report['performedGestures'] = $gestures
  $report | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath "$buildRoot\perf\$Name" -Encoding utf8
  Write-Output "gestures=$gestures report_written"
} finally {
  if ($null -ne $capture) { $capture.Dispose() }
  & $adb -s $serial forward --remove "tcp:$localPort"
}
