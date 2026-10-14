param(
    [Parameter(Mandatory)][string]$Apk,
    [Parameter(Mandatory)][string]$BuildToolsDirectory,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$BuildNumber
)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) "nso-signing-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root | Out-Null
$script = Join-Path $PSScriptRoot '../../../tool/sign_android_apk.ps1'
$sourceHash = (Get-FileHash -LiteralPath $Apk -Algorithm SHA256).Hash
$cases = 0
try {
    $env:ANDROID_KEYSTORE_PASSWORD = 'nso-fixture-password'
    $env:ANDROID_KEY_PASSWORD = 'nso-fixture-password'
    $env:ANDROID_KEY_ALIAS = 'nso-fixture'
    $fixture = Join-Path $root 'fixture.jks'
    $null = (& keytool -genkeypair -keystore $fixture -storetype JKS -storepass:env ANDROID_KEYSTORE_PASSWORD -keypass:env ANDROID_KEY_PASSWORD -alias $env:ANDROID_KEY_ALIAS -keyalg RSA -keysize 2048 -validity 365 -dname 'CN=NSOAlbum Fixture' 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot generate disposable signing fixture.' }
    $validBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture))
    $env:ANDROID_KEYSTORE_BASE64 = $validBase64
    $output = Join-Path $root 'signed.apk'
    & $script -Apk $Apk -OutputApk $output -BuildToolsDirectory $BuildToolsDirectory -Version $Version -BuildNumber $BuildNumber -ReportsDirectory (Join-Path $root 'reports') -TemporaryRoot $root
    $report = Get-Content -LiteralPath (Join-Path $root 'reports/apk-verification.json') -Raw | ConvertFrom-Json
    if ($report.status -ne 'passed' -or $report.signing -ne 'release-key-signed-no-device-smoke' -or
        $report.certificate_sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Release signer was not verified.' }
    $cases++
    if ((Get-FileHash -LiteralPath $Apk -Algorithm SHA256).Hash -ne $sourceHash) { throw 'Input APK changed.' }
    $cases++
    foreach ($kind in @('invalid-base64', 'wrong-password', 'missing-secret', 'existing-output')) {
        $env:ANDROID_KEYSTORE_BASE64 = $validBase64
        $env:ANDROID_KEY_PASSWORD = 'nso-fixture-password'
        if ($kind -eq 'invalid-base64') { $env:ANDROID_KEYSTORE_BASE64 = 'not base64' }
        if ($kind -eq 'wrong-password') { $env:ANDROID_KEY_PASSWORD = 'wrong-fixture-password' }
        if ($kind -eq 'missing-secret') { Remove-Item Env:ANDROID_KEYSTORE_BASE64 }
        $failureOutput = if ($kind -eq 'existing-output') { $output } else { Join-Path $root "$kind.apk" }
        $rejected = $false
        try {
            & $script -Apk $Apk -OutputApk $failureOutput -BuildToolsDirectory $BuildToolsDirectory -Version $Version -BuildNumber $BuildNumber -ReportsDirectory (Join-Path $root 'failure-reports') -TemporaryRoot $root
        } catch { $rejected = $true }
        if (-not $rejected) { throw "Signing failure was accepted: $kind" }
        if ($kind -ne 'existing-output' -and (Test-Path -LiteralPath $failureOutput)) { throw 'Failed signed APK was retained.' }
        if (@(Get-ChildItem -LiteralPath $root -Filter 'nso-android-signing-*').Count -ne 0) { throw 'Private signing files were retained.' }
        $cases++
    }
    Write-Host "Android signing integration tests passed ($cases cases, disposable key only)."
} finally {
    if (-not ([IO.Path]::GetFullPath($root)).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Signing fixture cleanup escaped the temporary directory.'
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
