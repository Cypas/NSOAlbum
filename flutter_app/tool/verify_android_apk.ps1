param(
    [Parameter(Mandatory)][string]$Apk,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory)][ValidatePattern('^\d+$')][string]$BuildNumber,
    [Parameter(Mandatory)][string]$BuildToolsDirectory,
    [Parameter(Mandatory)][string]$ReportsDirectory,
    [ValidateSet('Test', 'Release')][string]$SigningMode = 'Test',
    [string]$ExpectedCertificateSha256
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'android_apk_contract.ps1')

$apkPath = (Get-Item -LiteralPath $Apk).FullName
$aapt = Join-Path $BuildToolsDirectory $(if ($IsWindows) { 'aapt2.exe' } else { 'aapt2' })
$signer = Join-Path $BuildToolsDirectory $(if ($IsWindows) { 'apksigner.bat' } else { 'apksigner' })
$previousEncoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $badging = (& $aapt dump badging $apkPath | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the final APK manifest.' }
    Assert-AndroidBadging -Badging $badging -Version $Version -BuildNumber $BuildNumber
    $libraries = @(Read-AndroidNativeLibraries -Apk $apkPath)
    $signature = (& $signer verify --verbose --print-certs $apkPath | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Final APK signature verification failed.' }
    $certificate = Assert-AndroidApkSignature -Signature $signature -SigningMode $SigningMode -ExpectedCertificateSha256 $ExpectedCertificateSha256
    New-Item -ItemType Directory -Path $ReportsDirectory -Force | Out-Null
    $report = [ordered]@{
        schema = 1
        status = 'passed'
        scope = 'static-apk-verification-not-device-smoke'
        signing = if ($SigningMode -eq 'Release') { 'release-key-signed-no-device-smoke' } else { 'ci-test-only-not-for-distribution' }
        application_id = 'io.github.cypas.nsoalbum'
        version = $Version
        build = $BuildNumber
        sha256 = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
        native_libraries = $libraries
        signature_v2 = $true
        certificate_sha256 = $certificate
    }
    [IO.File]::WriteAllText((Join-Path ([IO.Path]::GetFullPath($ReportsDirectory)) 'apk-verification.json'),
        ($report | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Write-Host "Android $SigningMode APK verified: $Version+$BuildNumber; $($libraries.Count) AArch64 libraries. No device smoke performed."
} finally {
    [Console]::OutputEncoding = $previousEncoding
}
