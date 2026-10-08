param(
    [string]$Version,
    [switch]$SkipTests,
    [switch]$UseExistingFlutterBuild
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent $projectRoot
$rustRoot = Join-Path $workspaceRoot 'rust_core'
$pubspec = Join-Path $projectRoot 'pubspec.yaml'
$bridgeScript = Join-Path $PSScriptRoot 'generate_bridge.ps1'
$releaseRoot = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$rustDll = Join-Path $rustRoot 'target\release\squid_album_core.dll'
$releaseDll = Join-Path $releaseRoot 'squid_album_core.dll'
$distRoot = Join-Path $workspaceRoot 'dist'

function Resolve-Executable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Fallback
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    if (Test-Path -LiteralPath $Fallback) {
        return $Fallback
    }
    throw "Cannot find $Name. Expected it in PATH or at $Fallback."
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        & $Executable @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Executable failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}

function Resolve-CMake {
    $command = Get-Command 'cmake.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $visualStudio = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not [string]::IsNullOrWhiteSpace($visualStudio)) {
            $bundled = Join-Path $visualStudio 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
            if (Test-Path -LiteralPath $bundled) {
                return $bundled
            }
        }
    }
    throw 'Cannot find cmake.exe in PATH or the installed Visual Studio Build Tools.'
}

function Initialize-PluginJunctions {
    $dependenciesPath = Join-Path $projectRoot '.flutter-plugins-dependencies'
    if (-not (Test-Path -LiteralPath $dependenciesPath)) {
        throw "Flutter did not generate $dependenciesPath."
    }
    $dependencies = Get-Content -Raw -LiteralPath $dependenciesPath | ConvertFrom-Json
    $linkRoot = Join-Path $projectRoot 'windows\flutter\ephemeral\.plugin_symlinks'
    New-Item -ItemType Directory -Path $linkRoot -Force | Out-Null
    foreach ($plugin in $dependencies.plugins.windows) {
        $link = Join-Path $linkRoot $plugin.name
        if (Test-Path -LiteralPath $link) {
            continue
        }
        $target = [System.IO.Path]::GetFullPath($plugin.path)
        if (-not (Test-Path -LiteralPath $target)) {
            throw "Windows plugin path does not exist: $target"
        }
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    }
}

function Build-FlutterWindows {
    try {
        Invoke-Checked -Executable $flutter -Arguments @('build', 'windows', '--release') -WorkingDirectory $projectRoot
        return
    }
    catch {
        Write-Warning 'Flutter could not create Windows plugin symlinks. Retrying with directory junctions and the Visual Studio CMake toolchain.'
    }

    # A clean checkout may fail the regular build before Flutter writes its
    # generated CMake configuration. --config-only still produces that file
    # even when Windows Developer Mode is disabled.
    $generatedConfig = Join-Path $projectRoot 'windows\flutter\ephemeral\generated_config.cmake'
    Push-Location $projectRoot
    try {
        & $flutter @('build', 'windows', '--config-only')
        $configExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if (-not (Test-Path -LiteralPath $generatedConfig)) {
        throw "Flutter did not generate $generatedConfig (exit code $configExitCode)."
    }
    if ($configExitCode -ne 0) {
        Write-Warning 'Flutter generated the Windows CMake configuration but could not create plugin symlinks; continuing with directory junctions.'
    }
    Initialize-PluginJunctions
    $cmake = Resolve-CMake
    $buildRoot = Join-Path $projectRoot 'build\windows\x64'
    # The Flutter Windows CMake cache stores the executable target name. When
    # BINARY_NAME changes (for example squid_album -> NSOAlbum), reusing the
    # old cache leaves install rules pointing at a non-existent target.
    $cmakeCache = Join-Path $buildRoot 'CMakeCache.txt'
    $cmakeFiles = Join-Path $buildRoot 'CMakeFiles'
    if (Test-Path -LiteralPath $cmakeCache) {
        Remove-Item -LiteralPath $cmakeCache -Force
    }
    if (Test-Path -LiteralPath $cmakeFiles) {
        Remove-Item -LiteralPath $cmakeFiles -Recurse -Force
    }
    Invoke-Checked -Executable $cmake -Arguments @(
        '-S', (Join-Path $projectRoot 'windows'),
        '-B', $buildRoot,
        '-G', 'Visual Studio 17 2022',
        '-A', 'x64',
        '-DFLUTTER_TARGET_PLATFORM=windows-x64'
    ) -WorkingDirectory $projectRoot

    # Flutter's asset bundler is not safe when the Visual Studio generator
    # schedules duplicate custom-rule consumers in parallel. Remove only the
    # verified generated asset directory and build the fallback graph serially.
    $flutterAssetRoot = Join-Path $projectRoot 'build\flutter_assets'
    if (Test-Path -LiteralPath $flutterAssetRoot) {
        $resolvedAssetRoot = (Resolve-Path -LiteralPath $flutterAssetRoot).Path
        $expectedAssetRoot = [System.IO.Path]::GetFullPath($flutterAssetRoot)
        if ($resolvedAssetRoot -ne $expectedAssetRoot) {
            throw "Unexpected Flutter asset cleanup path: $resolvedAssetRoot"
        }
        Remove-Item -LiteralPath $resolvedAssetRoot -Recurse -Force
    }

    # Build first without running CMake's install step. On hosts where Flutter
    # cannot create plugin symlinks, Cargokit may complete successfully without
    # copying the Rust DLL into the per-plugin Release directory that Flutter's
    # generated install script expects.
    Invoke-Checked -Executable $cmake -Arguments @(
        '--build', $buildRoot,
        '--config', 'Release',
        '--target', 'ALL_BUILD',
        '--parallel', '1'
    ) -WorkingDirectory $projectRoot

    $pluginReleaseRoot = Join-Path $buildRoot 'plugins\squid_album_core\Release'
    $pluginDll = Join-Path $pluginReleaseRoot 'squid_album_core.dll'
    New-Item -ItemType Directory -Path $pluginReleaseRoot -Force | Out-Null
    Copy-Item -LiteralPath $rustDll -Destination $pluginDll -Force

    Invoke-Checked -Executable $cmake -Arguments @(
        '--install', $buildRoot,
        '--config', 'Release'
    ) -WorkingDirectory $projectRoot
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $versionLine = Select-String -LiteralPath $pubspec -Pattern '^version:\s*([^+\s]+)' | Select-Object -First 1
    if ($null -eq $versionLine) {
        throw 'Cannot read the release version from pubspec.yaml.'
    }
    $Version = $versionLine.Matches[0].Groups[1].Value
}

if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "Invalid release version: $Version"
}

$releaseTag = if ($env:GITHUB_REF_TYPE -eq 'tag') {
    $env:GITHUB_REF_NAME
} else {
    ''
}
$versionValidator = Join-Path $PSScriptRoot 'validate_release_version.ps1'
& $versionValidator -Version $Version -ReleaseTag $releaseTag

$cargo = Resolve-Executable -Name 'cargo.exe' -Fallback (Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe')
$flutter = Resolve-Executable -Name 'flutter.bat' -Fallback (Join-Path $env:USERPROFILE 'development\flutter\bin\flutter.bat')
$dart = Resolve-Executable -Name 'dart.exe' -Fallback (Join-Path $env:USERPROFILE 'development\flutter\bin\cache\dart-sdk\bin\dart.exe')

Write-Host 'Generating Flutter/Rust bridge code...'
& $bridgeScript
if ($LASTEXITCODE -ne 0) {
    throw "Bridge generation failed with exit code $LASTEXITCODE."
}

$rustGenerated = Get-Content -Raw -LiteralPath (Join-Path $rustRoot 'src\frb_generated.rs')
$dartGenerated = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'lib\src\rust\frb_generated.dart')
$rustHashMatch = [regex]::Match($rustGenerated, 'FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH:\s*i32\s*=\s*(-?\d+)')
$dartHashMatch = [regex]::Match($dartGenerated, 'rustContentHash\s*=>\s*(-?\d+)')
if (-not $rustHashMatch.Success -or -not $dartHashMatch.Success) {
    throw 'Cannot read the flutter_rust_bridge content hashes from generated code.'
}
if ($rustHashMatch.Groups[1].Value -ne $dartHashMatch.Groups[1].Value) {
    throw "Generated bridge hashes differ: Rust=$($rustHashMatch.Groups[1].Value), Dart=$($dartHashMatch.Groups[1].Value)."
}

if (-not $SkipTests) {
    Write-Host 'Running Rust and Flutter release checks...'
    Invoke-Checked -Executable $cargo -Arguments @('fmt', '--all', '--', '--check') -WorkingDirectory $rustRoot
    Invoke-Checked -Executable $cargo -Arguments @('clippy', '--all-targets', '--', '-D', 'warnings') -WorkingDirectory $rustRoot
    Invoke-Checked -Executable $cargo -Arguments @('test', '--lib') -WorkingDirectory $rustRoot
    Invoke-Checked -Executable $dart -Arguments @('analyze') -WorkingDirectory $projectRoot
    Invoke-Checked -Executable $flutter -Arguments @('test') -WorkingDirectory $projectRoot
}

Write-Host 'Building the Rust release library...'
Invoke-Checked -Executable $cargo -Arguments @('build', '--release') -WorkingDirectory $rustRoot
if (-not (Test-Path -LiteralPath $rustDll)) {
    throw "Rust build did not produce $rustDll."
}

if ($UseExistingFlutterBuild) {
    Write-Warning 'Reusing the existing Flutter Windows build. The Rust DLL will still be rebuilt, replaced, and verified.'
}
else {
    Write-Host 'Building the Flutter Windows application...'
    Build-FlutterWindows
}
if (-not (Test-Path -LiteralPath $releaseRoot)) {
    throw "Flutter build did not produce $releaseRoot."
}

# Remove obsolete executable names from an existing Release directory so the
# NSOAlbum package contains a single branded executable.
foreach ($staleName in @('FreshAlbum.exe', 'squid_album.exe')) {
    $staleExecutable = Join-Path $releaseRoot $staleName
    if (Test-Path -LiteralPath $staleExecutable) {
        Remove-Item -LiteralPath $staleExecutable -Force
    }
}

# Cargokit can leave a stale native library behind if its custom build step fails.
# Always replace it with the library built from the current generated Rust source.
Copy-Item -LiteralPath $rustDll -Destination $releaseDll -Force
$sourceDllHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $rustDll).Hash
$releaseDllHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseDll).Hash
if ($sourceDllHash -ne $releaseDllHash) {
    throw 'The packaged Rust DLL does not match the freshly built DLL.'
}

$packageName = "NSOAlbum-Windows-x64-$Version"
$packageDirectory = Join-Path $distRoot $packageName
New-Item -ItemType Directory -Path $distRoot -Force | Out-Null

if (Test-Path -LiteralPath $packageDirectory) {
    Remove-Item -LiteralPath $packageDirectory -Recurse -Force
}

Copy-Item -LiteralPath $releaseRoot -Destination $packageDirectory -Recurse
New-Item -ItemType Directory -Path (Join-Path $packageDirectory 'docs') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageDirectory 'licenses') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $workspaceRoot 'LICENSE') -Destination (Join-Path $packageDirectory 'licenses\MIT-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $workspaceRoot 'docs\legal\THIRD-PARTY-NOTICES.md') -Destination (Join-Path $packageDirectory 'licenses\THIRD-PARTY-NOTICES.md') -Force
Copy-Item -LiteralPath (Join-Path $workspaceRoot 'docs\legal\ASSET-ATTRIBUTION.md') -Destination (Join-Path $packageDirectory 'licenses\ASSET-ATTRIBUTION.md') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\fonts\SmileySans-OFL.txt') -Destination (Join-Path $packageDirectory 'licenses\SmileySans-OFL.txt') -Force

Write-Host "Bridge content hash: $($rustHashMatch.Groups[1].Value)"
Write-Host "Native DLL SHA-256: $sourceDllHash"
Write-Host "Package: $packageDirectory"
