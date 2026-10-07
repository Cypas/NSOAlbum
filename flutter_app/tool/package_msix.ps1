param(
    [Parameter(Mandatory = $true)][string]$PackageDirectory,
    [string]$Version,
    [string]$OutputDirectory,
    [string]$Publisher = 'CN=Cypas',
    [string]$IdentityName = 'io.squidalbum',
    [string]$CertificatePath,
    [securestring]$CertificatePassword
)

$ErrorActionPreference = 'Stop'

function Resolve-Executable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Candidates
    )
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    throw "Cannot find $Name. Install the Windows SDK or add it to PATH."
}

function Convert-IcoToPng {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int]$Size
    )
    Add-Type -AssemblyName System.Drawing
    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($Source)
    if ($null -eq $icon) {
        throw "Cannot extract an icon from $Source"
    }
    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawIcon($icon, 0, 0)
        $bitmap.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
        $icon.Dispose()
    }
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
$iconPath = Join-Path $workspaceRoot 'flutter_app\windows\runner\resources\app_icon.ico'
if (-not (Test-Path -LiteralPath $iconPath)) {
    throw "Application icon does not exist: $iconPath"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $workspaceRoot 'dist\installers'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$staging = Join-Path $OutputDirectory "msix-staging-$Version"
$assets = Join-Path $staging 'Assets'
$manifest = Join-Path $staging 'AppxManifest.xml'
$msixPath = Join-Path $OutputDirectory "SquidAlbum-$Version.msix"
if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force
}
if (Test-Path -LiteralPath $msixPath) {
    Remove-Item -LiteralPath $msixPath -Force
}
New-Item -ItemType Directory -Path $staging -Force | Out-Null
New-Item -ItemType Directory -Path $assets -Force | Out-Null
Get-ChildItem -LiteralPath $packageDirectory -Force |
    Copy-Item -Destination $staging -Recurse -Force
Convert-IcoToPng -Source $iconPath -Destination (Join-Path $assets 'Square44x44Logo.png') -Size 44
Convert-IcoToPng -Source $iconPath -Destination (Join-Path $assets 'Square150x150Logo.png') -Size 150
Convert-IcoToPng -Source $iconPath -Destination (Join-Path $assets 'StoreLogo.png') -Size 50

$manifestTemplate = Join-Path $workspaceRoot 'installer\AppxManifest.xml'
$manifestContent = Get-Content -Raw -LiteralPath $manifestTemplate
$manifestContent = $manifestContent.Replace('__IDENTITY_NAME__', $IdentityName)
$manifestContent = $manifestContent.Replace('__PUBLISHER__', $Publisher)
$manifestContent = $manifestContent.Replace('__VERSION__', "$Version.0")
Set-Content -LiteralPath $manifest -Value $manifestContent -Encoding utf8NoBOM

$makeAppx = Resolve-Executable -Name 'makeappx.exe' -Candidates @(
    'C:\Program Files (x86)\Windows Kits\10\App Certification Kit\makeappx.exe'
)
& $makeAppx pack /d $staging /p $msixPath /o
if ($LASTEXITCODE -ne 0) {
    throw "makeappx failed with exit code $LASTEXITCODE."
}

if (-not [string]::IsNullOrWhiteSpace($CertificatePath)) {
    $signtool = Resolve-Executable -Name 'signtool.exe' -Candidates @(
        'C:\Program Files (x86)\Windows Kits\10\App Certification Kit\signtool.exe'
    )
    $signArguments = @('sign', '/fd', 'SHA256', '/a', '/f', $CertificatePath)
    if ($null -ne $CertificatePassword) {
        $certificatePasswordText = [System.Net.NetworkCredential]::new('', $CertificatePassword).Password
        $signArguments += @('/p', $certificatePasswordText)
    }
    $signArguments += $msixPath
    & $signtool @signArguments
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed with exit code $LASTEXITCODE."
    }
}

Remove-Item -LiteralPath $staging -Recurse -Force
Write-Host "MSIX package: $msixPath"
