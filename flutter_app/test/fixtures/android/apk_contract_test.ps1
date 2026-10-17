$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../tool/android_apk_contract.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) "nso-apk-contract-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root | Out-Null
$script:caseCount = 0

function Assert-Rejected([scriptblock]$Action, [string]$Reason) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid APK accepted: $Reason" }
    $script:caseCount++
}

function New-Fixture([string]$Name, [string]$ChangedEntry = '', [byte[]]$ChangedBytes = @(), [switch]$OmitCore) {
    $path = Join-Path $root "$Name.apk"
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $names = @('lib/arm64-v8a/libapp.so', 'lib/arm64-v8a/libflutter.so',
            'lib/arm64-v8a/libsquid_album_core.so', 'lib/arm64-v8a/libmpv.so',
            'lib/arm64-v8a/libffmpegkit.so')
        if ($OmitCore) { $names = @($names | Where-Object { $_ -notlike '*libsquid_album_core.so' }) }
        if ($ChangedEntry -and $ChangedEntry -notin $names) { $names += $ChangedEntry }
        foreach ($name in $names) {
            $bytes = [byte[]]::new(64)
            $bytes[0] = 0x7f; $bytes[1] = 0x45; $bytes[2] = 0x4c; $bytes[3] = 0x46
            $bytes[4] = 2; $bytes[5] = 1; $bytes[6] = 1
            $bytes[16] = 3; $bytes[18] = 183
            if ($name -eq $ChangedEntry -and $ChangedBytes.Length -gt 0) { $bytes = $ChangedBytes }
            $stream = $zip.CreateEntry($name).Open()
            try { $stream.Write($bytes) } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $path
}

try {
    $good = New-Fixture 'valid'
    $libraries = @(Read-AndroidNativeLibraries -Apk $good)
    if ($libraries.Count -ne 5) { throw 'Valid ARM64 payload did not expose five libraries.' }
    $script:caseCount++
    Assert-Rejected { Read-AndroidNativeLibraries -Apk (New-Fixture 'x86' 'lib/x86_64/libextra.so') } 'extra ABI'
    Assert-Rejected { Read-AndroidNativeLibraries -Apk (New-Fixture 'missing-core' -OmitCore) } 'missing Rust core'
    Assert-Rejected { Read-AndroidNativeLibraries -Apk (New-Fixture 'traversal' 'lib/arm64-v8a/../libextra.so') } 'traversal'
    Assert-Rejected { Read-AndroidNativeLibraries -Apk (New-Fixture 'invalid-elf' 'lib/arm64-v8a/libmpv.so' ([byte[]]::new(64))) } 'invalid ELF'
    $x64 = [byte[]]::new(64)
    [Array]::Copy([byte[]]@(0x7f, 0x45, 0x4c, 0x46, 2, 1, 1), $x64, 7)
    $x64[16] = 3; $x64[18] = 62
    Assert-Rejected { Read-AndroidNativeLibraries -Apk (New-Fixture 'wrong-machine' 'lib/arm64-v8a/libmpv.so' $x64) } 'x64 disguised as arm64'
    Assert-Rejected { Read-AndroidNativeLibraries -Apk (New-Fixture 'truncated' 'lib/arm64-v8a/libmpv.so' ([byte[]]@(0x7f, 0x45))) } 'truncated ELF'
    $badging = @"
package: name='io.github.cypas.nsoalbum' versionCode='47' versionName='0.2.14'
sdkVersion:'24'
uses-permission: name='android.permission.INTERNET'
uses-permission: name='android.permission.POST_NOTIFICATIONS'
uses-permission: name='android.permission.REQUEST_INSTALL_PACKAGES'
uses-permission: name='android.permission.CAMERA'
uses-feature-not-required: name='android.hardware.camera'
uses-feature-not-required: name='android.hardware.camera.autofocus'
launchable-activity: name='io.github.cypas.nsoalbum.MainActivity' label='NSOAlbum' icon=''
native-code: 'arm64-v8a'
"@
    Assert-AndroidBadging -Badging $badging -Version '0.2.14' -BuildNumber '47'
    $script:caseCount++
    Assert-AndroidBadging -Badging ($badging.Replace("sdkVersion:'24'", "minSdkVersion:'24'")) -Version '0.2.14' -BuildNumber '47'
    $script:caseCount++
    Assert-Rejected { Assert-AndroidBadging $badging '0.2.15' '47' } 'wrong version'
    Assert-Rejected { Assert-AndroidBadging $badging '0.2.14' '48' } 'wrong build'
    Assert-Rejected { Assert-AndroidBadging ($badging.Replace('io.github.cypas.nsoalbum', 'io.squidalbum.squid_album')) '0.2.14' '47' } 'old identity'
    Assert-Rejected { Assert-AndroidBadging ($badging.Replace('MainActivity', 'MissingActivity')) '0.2.14' '47' } 'wrong launcher'
    Assert-Rejected { Assert-AndroidBadging ($badging.Replace("uses-permission: name='android.permission.INTERNET'", '')) '0.2.14' '47' } 'missing INTERNET'
    Assert-Rejected { Assert-AndroidBadging ($badging.Replace("uses-permission: name='android.permission.POST_NOTIFICATIONS'", '')) '0.2.14' '47' } 'missing update notification permission'
    Assert-Rejected { Assert-AndroidBadging ($badging.Replace("uses-permission: name='android.permission.REQUEST_INSTALL_PACKAGES'", '')) '0.2.14' '47' } 'missing update installation permission'
    Assert-Rejected { Assert-AndroidBadging ($badging.Replace("uses-permission: name='android.permission.CAMERA'", '')) '0.2.14' '47' } 'missing optional scanner permission'
    foreach ($feature in @('android.hardware.camera', 'android.hardware.camera.autofocus')) {
        Assert-Rejected { Assert-AndroidBadging ($badging.Replace("uses-feature-not-required: name='$feature'", '')) '0.2.14' '47' } "missing optional $feature declaration"
        Assert-Rejected { Assert-AndroidBadging ($badging.Replace("uses-feature-not-required: name='$feature'", "uses-feature: name='$feature'")) '0.2.14' '47' } "required $feature excludes camera-less devices"
        Assert-Rejected { Assert-AndroidBadging "$badging`nuses-feature: name='$feature'" '0.2.14' '47' } "conflicting required $feature declaration"
        Assert-Rejected { Assert-AndroidBadging "$badging`nuses-implied-feature: name='$feature' reason='scanner permission'" '0.2.14' '47' } "implicitly required $feature declaration"
    }
    Assert-Rejected { Assert-AndroidBadging "$badging`napplication-debuggable" '0.2.14' '47' } 'debuggable APK'
    Assert-Rejected { Assert-AndroidBadging "$badging`nuses-permission: name='android.permission.MANAGE_EXTERNAL_STORAGE'" '0.2.14' '47' } 'all-files permission'
    Assert-Rejected { Assert-AndroidBadging ($badging.Replace("native-code: 'arm64-v8a'", "native-code: 'arm64-v8a' 'x86'")) '0.2.14' '47' } 'multiple packaged ABIs'
    $digest = 'ab' * 32
    $signature = "Verified using v2 scheme (APK Signature Scheme v2): true`nSigner #1 certificate DN: CN=NSOAlbum Fixture`nSigner #1 certificate SHA-256 digest: $digest"
    $actualDigest = Assert-AndroidApkSignature -Signature $signature -SigningMode Release -ExpectedCertificateSha256 $digest
    if ($actualDigest -cne $digest) { throw 'Signer fingerprint differs.' }
    $script:caseCount++
    Assert-Rejected { Assert-AndroidApkSignature ($signature.Replace(': true', ': false')) Test } 'v2 signature missing'
    Assert-Rejected { Assert-AndroidApkSignature $signature Release ('cd' * 32) } 'certificate mismatch'
    Assert-Rejected { Assert-AndroidApkSignature $signature Release } 'release verification without expected certificate'
    Assert-Rejected { Assert-AndroidApkSignature ($signature.Replace('NSOAlbum Fixture', 'Android Debug')) Release $digest } 'debug signing certificate'
    Assert-Rejected { Assert-AndroidApkSignature "$signature`nSigner #2 certificate SHA-256 digest: $digest" Release $digest } 'multiple signers'
    if ((Get-AndroidSigningMode -Requested $false -EventName pull_request -WorkflowRef refs/heads/dev -Repository Cypas/NSOAlbum) -ne 'Test') {
        throw 'PR verification should use Test signing.'
    }
    $script:caseCount++
    foreach ($scenario in @(
        @('push', 'refs/heads/main'),
        @('push', 'refs/tags/v0.2.14'),
        @('workflow_dispatch', 'refs/heads/dev'),
        @('workflow_dispatch', 'refs/heads/main')
    )) {
        if ((Get-AndroidSigningMode $true $scenario[0] $scenario[1] 'Cypas/NSOAlbum') -ne 'Release') {
            throw 'Trusted signing request was rejected.'
        }
        $script:caseCount++
    }
    Assert-Rejected { Get-AndroidSigningMode $true pull_request refs/heads/dev Cypas/NSOAlbum } 'PR cannot request release signing'
    Assert-Rejected { Get-AndroidSigningMode $true pull_request_target refs/heads/main Cypas/NSOAlbum } 'PR target cannot request signing'
    Assert-Rejected { Get-AndroidSigningMode $true workflow_dispatch refs/heads/untrusted Cypas/NSOAlbum } 'untrusted workflow definition'
    Assert-Rejected { Get-AndroidSigningMode $true push refs/heads/dev Cypas/NSOAlbum } 'dev push remains lightweight'
    Assert-Rejected { Get-AndroidSigningMode $true push refs/tags/test Cypas/NSOAlbum } 'unstable tag'
    Assert-Rejected { Get-AndroidSigningMode $true push refs/heads/main Other/NSOAlbum } 'other repository'
    Write-Host "Android APK contract tests passed ($script:caseCount cases)."
} finally {
    # Only remove this test's explicitly created, unique temporary directory.
    if (-not ([IO.Path]::GetFullPath($root)).StartsWith(
            [IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Test cleanup escaped the temporary directory.'
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
