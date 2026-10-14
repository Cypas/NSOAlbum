function Read-AndroidNativeLibraries {
    param([Parameter(Mandatory)][string]$Apk)

    $zip = [IO.Compression.ZipFile]::OpenRead((Get-Item -LiteralPath $Apk).FullName)
    try {
        $libraries = [Collections.Generic.List[string]]::new()
        foreach ($entry in $zip.Entries) {
            if (-not $entry.FullName.StartsWith('lib/', [StringComparison]::Ordinal)) { continue }
            if ($entry.FullName.EndsWith('/')) { continue }
            if ($entry.FullName -cnotmatch '^lib/arm64-v8a/[^/\\]+\.so$' -or
                    $libraries.Contains($entry.FullName)) {
                throw "Unexpected or duplicate native APK entry: $($entry.FullName)"
            }
            if ($entry.Length -lt 64) { throw "Truncated native ELF: $($entry.FullName)" }
            $stream = $entry.Open()
            try {
                $header = [byte[]]::new(64)
                $stream.ReadExactly($header)
                if ($header[0] -ne 0x7f -or $header[1] -ne 0x45 -or
                        $header[2] -ne 0x4c -or $header[3] -ne 0x46 -or
                        $header[4] -ne 2 -or $header[5] -ne 1 -or $header[6] -ne 1 -or
                        $header[16] -ne 3 -or $header[17] -ne 0 -or
                        $header[18] -ne 183 -or $header[19] -ne 0) {
                    throw "Native library is not a little-endian AArch64 shared ELF: $($entry.FullName)"
                }
            } finally { $stream.Dispose() }
            $libraries.Add($entry.FullName)
        }
        foreach ($required in @('libapp.so', 'libflutter.so', 'libsquid_album_core.so',
                'libmpv.so', 'libffmpegkit.so')) {
            if (-not $libraries.Contains("lib/arm64-v8a/$required")) {
                throw "Required Android runtime is missing: $required"
            }
        }
        return $libraries.ToArray()
    } finally { $zip.Dispose() }
}

function Assert-AndroidBadging {
    param(
        [Parameter(Mandatory)][string]$Badging,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$BuildNumber
    )

    $package = [regex]::Match($Badging,
        "(?m)^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'")
    if (-not $package.Success -or $package.Groups[1].Value -cne 'io.github.cypas.nsoalbum' -or
            $package.Groups[2].Value -cne $BuildNumber -or
            $package.Groups[3].Value -cne $Version) {
        throw 'Packaged Android identity or version differs from the requested source.'
    }
    if ($Badging -notmatch "(?m)^launchable-activity: name='io\.github\.cypas\.nsoalbum\.MainActivity'" -or
            $Badging -notmatch "(?m)^(?:minSdkVersion|sdkVersion):'24'\s*$" -or
            $Badging -notmatch "(?m)^native-code: 'arm64-v8a'\s*$" -or
            $Badging -match '(?m)^application-debuggable') {
        throw 'APK must have the expected launcher, minSdk 24, ARM64 only, and non-debuggable Release code.'
    }
    if ($Badging -notmatch "(?m)^uses-permission: name='android\.permission\.INTERNET'") {
        throw 'Final Release APK is missing INTERNET.'
    }
    foreach ($denied in @('MANAGE_EXTERNAL_STORAGE', 'POST_NOTIFICATIONS', 'FOREGROUND_SERVICE')) {
        if ($Badging -match "uses-permission[^\r\n]*name='android\.permission\.$denied'") {
            throw "Final Release APK must not request $denied."
        }
    }
}
