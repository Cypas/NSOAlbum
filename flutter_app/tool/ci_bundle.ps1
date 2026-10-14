param(
    [Parameter(Mandatory)][ValidateSet('Seal', 'Verify')][string]$Mode,
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$Commit,
    [Parameter(Mandatory)][ValidateSet('windows-x64', 'macos-arm64', 'macos-x64', 'android-arm64')][string]$Platform,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory)][ValidatePattern('^\d+$')][string]$BuildNumber
)

$ErrorActionPreference = 'Stop'
$root = (Get-Item -LiteralPath $Directory).FullName
$rootItem = Get-Item -LiteralPath $root
if (-not $rootItem.PSIsContainer -or $rootItem.LinkType) {
    throw 'CI bundle must be a real directory, not a link.'
}
$manifestPath = Join-Path $root '.nso-ci-bundle.json'

function Read-BundleEntries {
    $entries = [Collections.Generic.List[object]]::new()
    # Do not follow framework directory links: hash the real version directory
    # once and bind every link separately. Reject links escaping the bundle.
    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force |
            Sort-Object FullName) {
        if ($item.FullName -eq $manifestPath) { continue }
        $relative = [IO.Path]::GetRelativePath($root, $item.FullName).Replace('\', '/')
        if ($item.LinkType) {
            $resolved = $item.ResolveLinkTarget($true)
            if ($null -eq $resolved) { throw "Broken bundle link: $relative" }
            $destination = [IO.Path]::GetRelativePath($root, $resolved.FullName).Replace('\', '/')
            if ($destination -eq '..' -or $destination.StartsWith('../') -or
                    [IO.Path]::IsPathRooted($destination)) {
                throw "Bundle link escapes the root: $relative"
            }
            # Absolute links are nonportable even if they resolve locally.
            if ([IO.Path]::IsPathRooted($item.LinkTarget)) {
                throw "Bundle link must be relative: $relative"
            }
            $entries.Add([ordered]@{ path = $relative; kind = 'link'; target = $item.LinkTarget })
        } elseif ($item.PSIsContainer) {
            $entries.Add([ordered]@{ path = $relative; kind = 'directory' })
        } else {
            $entry = [ordered]@{
                path = $relative
                kind = 'file'
                sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            if (-not $IsWindows) {
                $entry['mode'] = [int][IO.File]::GetUnixFileMode($item.FullName)
            }
            $entries.Add($entry)
        }
    }
    return $entries.ToArray()
}

if ($Mode -eq 'Seal') {
    if (Test-Path -LiteralPath $manifestPath) { throw 'Refusing to reseal an existing bundle.' }
    $entries = @(Read-BundleEntries)
    if ($entries.Count -eq 0) { throw 'Cannot seal an empty bundle.' }
    $manifest = [ordered]@{
        schema = 1
        commit = $Commit
        platform = $Platform
        version = $Version
        build = $BuildNumber
        entries = $entries
    }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false))
} else {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'CI bundle manifest is missing.'
    }
    if ((Get-Item -LiteralPath $manifestPath -Force).LinkType) {
        throw 'CI bundle manifest must not be a link.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -AsHashtable
    if ($manifest.schema -ne 1 -or $manifest.commit -cne $Commit -or
            $manifest.platform -cne $Platform -or $manifest.version -cne $Version -or
            $manifest.build -cne $BuildNumber) {
        throw 'CI bundle metadata does not match the requested build.'
    }
    $actual = @(Read-BundleEntries)
    $expected = @($manifest.entries)
    if ($actual.Count -eq 0 -or $actual.Count -ne $expected.Count) {
        throw 'CI bundle file list has changed.'
    }
    for ($index = 0; $index -lt $actual.Count; $index++) {
        foreach ($field in @('path', 'kind', 'sha256', 'target', 'mode')) {
            if ($actual[$index][$field] -cne $expected[$index][$field]) {
                throw "CI bundle entry does not match: $($actual[$index].path) ($field)"
            }
        }
    }
}
Write-Host "CI bundle $Mode passed: $Platform $Version+$BuildNumber $Commit"
