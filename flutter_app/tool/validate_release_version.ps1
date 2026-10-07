param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$ReleaseTag
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent $projectRoot
$pubspec = Join-Path $projectRoot 'pubspec.yaml'
$cargoManifest = Join-Path $workspaceRoot 'rust_core\Cargo.toml'

$pubspecVersion = Select-String -LiteralPath $pubspec -Pattern '^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$' |
    Select-Object -First 1
if ($null -eq $pubspecVersion) {
    throw 'pubspec.yaml must declare a stable SemVer and numeric build number.'
}
$applicationVersion = $pubspecVersion.Matches[0].Groups[1].Value
$buildNumber = $pubspecVersion.Matches[0].Groups[2].Value
if ([string]::IsNullOrWhiteSpace($buildNumber)) {
    throw 'pubspec.yaml must declare an application build number.'
}

$crateVersion = Select-String -LiteralPath $cargoManifest -Pattern '^version\s*=\s*"(\d+\.\d+\.\d+)"' |
    Select-Object -First 1
if ($null -eq $crateVersion) {
    throw 'Cannot read a stable semantic version from rust_core/Cargo.toml.'
}
$rustVersion = $crateVersion.Matches[0].Groups[1].Value

if ($applicationVersion -ne $Version) {
    throw "Requested package version $Version differs from pubspec.yaml version $applicationVersion."
}
if ($rustVersion -ne $applicationVersion) {
    throw "Rust crate version $rustVersion differs from application version $applicationVersion."
}
if (-not [string]::IsNullOrWhiteSpace($ReleaseTag) -and
    $ReleaseTag -ne "v$applicationVersion") {
    throw "Release tag $ReleaseTag differs from expected v$applicationVersion."
}

Write-Host "Application version: $applicationVersion"
Write-Host "Build number: $buildNumber"
Write-Host "Rust crate version: $rustVersion"
if (-not [string]::IsNullOrWhiteSpace($ReleaseTag)) {
    Write-Host "Release tag: $ReleaseTag"
}
