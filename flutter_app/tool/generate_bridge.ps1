$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent $projectRoot
$codegenCommand = Get-Command 'flutter_rust_bridge_codegen' -ErrorAction SilentlyContinue
if ($null -eq $codegenCommand) {
    $codegenFallback = Join-Path $env:USERPROFILE '.cargo\bin\flutter_rust_bridge_codegen.exe'
    if (Test-Path -LiteralPath $codegenFallback) {
        $codegen = $codegenFallback
    } else {
        throw 'Cannot find flutter_rust_bridge_codegen. Install version 2.13.0 or add it to PATH.'
    }
} else {
    $codegen = $codegenCommand.Source
}
$dartCommand = Get-Command 'dart' -ErrorAction SilentlyContinue
if ($null -eq $dartCommand) {
    throw 'Cannot find dart. Install Flutter or add the Dart SDK to PATH.'
}
$dart = $dartCommand.Source

& $codegen generate `
    --rust-input crate::bridge `
    --rust-root (Join-Path $workspaceRoot 'rust_core') `
    --dart-root $projectRoot `
    --dart-output (Join-Path $projectRoot 'lib\src\rust') `
    --no-web `
    --stop-on-error `
    --skip-fvm-install `
    --no-deps-check

$generated = Join-Path $projectRoot 'lib\src\rust\frb_generated.dart'
$contents = Get-Content -Raw -LiteralPath $generated -Encoding UTF8
$contents = $contents.Replace("stem: 'UNKNOWN'", "stem: 'squid_album_core'")
[System.IO.File]::WriteAllText($generated, $contents, [System.Text.UTF8Encoding]::new($false))

& $dart format (Join-Path $projectRoot 'lib\src\rust')
if ($LASTEXITCODE -ne 0) {
    throw "Dart format failed with exit code $LASTEXITCODE."
}
