#requires -Version 7.0
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,
    [Parameter(Mandatory = $true)]
    [string]$ApprovedBuildRoot,
    [switch]$StaticDependency,
    [switch]$DescriptorOnly,
    [switch]$PreloadProvider
)

$ErrorActionPreference = 'Stop'
$approvedRoot = [IO.Path]::GetFullPath($ApprovedBuildRoot).TrimEnd('\')
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
if (-not $output.StartsWith("$approvedRoot\", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The native probe output must stay inside the approved build root.'
}
$source = Join-Path $PSScriptRoot 'composition_lifetime_probe.cpp'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$studio = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($studio)) {
    throw 'Visual C++ tooling is unavailable.'
}
$environment = Join-Path $studio 'VC\Auxiliary\Build\vcvars64.bat'
if (@($StaticDependency, $DescriptorOnly, $PreloadProvider |
        Where-Object { $_ }).Count -gt 1) {
    throw 'Select only one static dependency strategy.'
}
$variant = if ($PreloadProvider) { 'preload' } elseif ($DescriptorOnly) {
    'descriptor'
} elseif ($StaticDependency) {
    'import'
} else { 'dynamic' }
$module = Join-Path $output "nsoalbum-composition-lifetime-$variant.dll"
$hostExecutable = Join-Path $output 'nsoalbum-composition-lifetime.exe'
$common = '/nologo /std:c++17 /EHsc /MDd /Od /D_DEBUG /DUNICODE /D_UNICODE /DNOMINMAX /W4 /WX /wd4100'

foreach ($target in @('module', 'host')) {
    $object = Join-Path $output "nsoalbum-composition-$target-$variant.obj"
    if ($target -eq 'module') {
        $import = Join-Path $output "nsoalbum-composition-lifetime-$variant.lib"
        $dependency = if ($DescriptorOnly) {
            'coremessaging.lib /INCLUDE:__IMPORT_DESCRIPTOR_CoreMessaging'
        } elseif ($StaticDependency) {
            'coremessaging.lib /INCLUDE:__imp_CreateDispatcherQueueController'
        } else { '' }
        $arguments = "$common /DNSOALBUM_COMPOSITION_MODULE /LD `"$source`" /Fo`"$object`" /Fe`"$module`" /link windowsapp.lib user32.lib $dependency /IMPLIB:`"$import`""
    } else {
        $arguments = "$common `"$source`" /Fo`"$object`" /Fe`"$hostExecutable`" /link windowsapp.lib user32.lib"
    }
    & $env:ComSpec /d /s /c "call `"$environment`" >nul && cl $arguments"
    if ($LASTEXITCODE -ne 0) { throw "Could not compile the $target probe." }
}

$results = @()
foreach ($scenario in @('static-detach', 'release', 'close-drain')) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $hostExecutable
    $start.ArgumentList.Add($module)
    $start.ArgumentList.Add($scenario)
    if ($PreloadProvider) { $start.ArgumentList.Add('preload-provider') }
    $start.WorkingDirectory = $output
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $child = [Diagnostics.Process]::Start($start)
    $stdout = $child.StandardOutput.ReadToEndAsync()
    $stderr = $child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(15000)) {
        # Only this exact, newly started synthetic child can be terminated.
        $child.Kill()
        $child.WaitForExit()
        throw "The owned $scenario child did not complete within 15 seconds."
    }
    $text = $stdout.GetAwaiter().GetResult()
    $errorText = $stderr.GetAwaiter().GetResult()
    $code = $child.ExitCode
    $result = [ordered]@{
        variant = $variant
        scenario = $scenario
        exitCode = $code
        exitHex = ('0x{0:x8}' -f ([long]$code -band 0xffffffffL))
        created = $text.Contains('COMPOSITION_PROBE created=true')
        released = $text.Contains('COMPOSITION_PROBE released=true')
        output = $text.Trim()
        errors = $errorText.Trim()
    }
    $results += [pscustomobject]$result
    $child.Dispose()
}
$results | ConvertTo-Json -Depth 4
if (@($results | Where-Object { -not $_.created }).Count -gt 0) {
    throw 'An SDK initialization failure is not proof of the exit regression.'
}
$closed = $results | Where-Object scenario -eq 'close-drain'
if ($closed.exitCode -ne 0 -or -not $closed.released) {
    throw 'The orderly close/drain probe did not finish normally.'
}
