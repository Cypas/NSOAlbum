param(
    [Parameter(Mandatory)][string]$Apk,
    [Parameter(Mandatory)][string]$OutputApk,
    [Parameter(Mandatory)][string]$BuildToolsDirectory,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory)][ValidatePattern('^\d+$')][string]$BuildNumber,
    [Parameter(Mandatory)][string]$ReportsDirectory,
    [Parameter(Mandatory)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
$source = (Get-Item -LiteralPath $Apk).FullName
$output = [IO.Path]::GetFullPath($OutputApk)
if ($source -eq $output -or (Test-Path -LiteralPath $output)) {
    throw 'Signed output must be new and must not replace the input APK.'
}
foreach ($name in @('ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Required release signing secret is missing: $name"
    }
}
$temp = (Get-Item -LiteralPath $TemporaryRoot).FullName
if ((Get-Item -LiteralPath $temp).LinkType) { throw 'Signing temporary root must not be a link.' }
$private = [IO.Path]::GetFullPath((Join-Path $temp "nso-android-signing-$([guid]::NewGuid().ToString('N'))"))
if (-not $private.StartsWith("$($temp.TrimEnd([IO.Path]::DirectorySeparatorChar))$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Signing directory escaped the temporary root.'
}
New-Item -ItemType Directory -Path $private | Out-Null
$passed = $false
try {
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode($private, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    }
    $keystore = Join-Path $private 'release.jks'
    try {
        $bytes = [Convert]::FromBase64String($env:ANDROID_KEYSTORE_BASE64)
        if ($bytes.Length -eq 0) { throw 'Empty keystore' }
        [IO.File]::WriteAllBytes($keystore, $bytes)
    } catch { throw 'ANDROID_KEYSTORE_BASE64 is not a nonempty Base64 keystore.' }
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode($keystore, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
    $certificateFile = Join-Path $private 'signer.der'
    # Capture diagnostics without exposing passwords, alias or private paths.
    $null = (& keytool -exportcert -keystore $keystore -alias $env:ANDROID_KEY_ALIAS -storepass:env ANDROID_KEYSTORE_PASSWORD -file $certificateFile 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Release certificate export failed. Check keystore, alias and password Secrets.' }
    $fingerprint = (Get-FileHash -LiteralPath $certificateFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $signer = Join-Path $BuildToolsDirectory $(if ($IsWindows) { 'apksigner.bat' } else { 'apksigner' })
    New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
    $null = (& $signer sign --ks $keystore --ks-key-alias $env:ANDROID_KEY_ALIAS --ks-pass env:ANDROID_KEYSTORE_PASSWORD --key-pass env:ANDROID_KEY_PASSWORD --v2-signing-enabled true --v4-signing-enabled false --out $output $source 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'APK signing failed. Check the configured signing key and password Secrets.' }
    & (Join-Path $PSScriptRoot 'verify_android_apk.ps1') -Apk $output -Version $Version -BuildNumber $BuildNumber -BuildToolsDirectory $BuildToolsDirectory -ReportsDirectory $ReportsDirectory -SigningMode Release -ExpectedCertificateSha256 $fingerprint
    $passed = $true
} finally {
    if (-not $passed -and (Test-Path -LiteralPath $output -PathType Leaf)) {
        Remove-Item -LiteralPath $output -Force
    }
    # Only remove this invocation's validated, unique private directory.
    Remove-Item -LiteralPath $private -Recurse -Force
}
