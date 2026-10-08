param(
    [Parameter(Mandatory = $true)][string]$PackageDirectory,
    [string]$Version,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'

function Resolve-Executable {
    param([Parameter(Mandatory = $true)][string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    $candidates = @(
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe',
        'D:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'D:\Program Files\Inno Setup 6\ISCC.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    throw 'Cannot find ISCC.exe. Install Inno Setup 6 or add ISCC.exe to PATH.'
}

$packageDirectory = [System.IO.Path]::GetFullPath($PackageDirectory)
if (-not (Test-Path -LiteralPath $packageDirectory -PathType Container)) {
    throw "Package directory does not exist: $packageDirectory"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $versionMatch = [regex]::Match(
        [System.IO.Path]::GetFileName($packageDirectory),
        '(\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)?)$'
    )
    if (-not $versionMatch.Success) {
        throw 'Pass -Version when the package directory name does not end with a semantic version.'
    }
    $Version = $versionMatch.Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "Invalid release version: $Version"
}

$workspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $workspaceRoot 'installer\SquidAlbum.iss'
$iconPath = Join-Path $workspaceRoot 'flutter_app\windows\runner\resources\app_icon.ico'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Inno Setup script does not exist: $scriptPath"
}
if (-not (Test-Path -LiteralPath $iconPath)) {
    throw "Application icon does not exist: $iconPath"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $workspaceRoot 'dist\installers'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$iscc = Resolve-Executable -Name 'ISCC.exe'
& $iscc `
    "/DAppVersion=$Version" `
    "/DSourceDir=$packageDirectory" `
    "/DOutputDir=$OutputDirectory" `
    "/DIconFile=$iconPath" `
    $scriptPath
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
}

Write-Host "Inno Setup installer: $(Join-Path $OutputDirectory "NSOAlbum-$Version-Setup.exe")"
