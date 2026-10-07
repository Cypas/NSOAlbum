$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent $projectRoot
$codegen = Join-Path $env:USERPROFILE '.cargo\bin\flutter_rust_bridge_codegen.exe'
$flutterRoot = Join-Path $env:USERPROFILE 'development\flutter'
$dart = Join-Path $flutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
$cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
$env:Path = "$(Join-Path $flutterRoot 'bin');$cargoBin;$env:Path"

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
