param(
    [string]$FlutterMachineLog,
    [string]$RustLog,
    [string]$SummaryPath = $env:GITHUB_STEP_SUMMARY,
    [string]$ReportsDirectory,
    [string]$ProjectDirectory = (Split-Path -Parent $PSScriptRoot),
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function New-UnavailableTestSummary {
    param([string]$Status)
    $categories = [ordered]@{}
    foreach ($category in @('Common', 'Windows', 'macOS')) {
        $categories[$category] = [pscustomobject]@{ Status = $Status; Total = $null; Passed = $null; Failed = $null; Skipped = $null }
    }
    [pscustomobject]@{
        Status = $Status; Total = $null; Passed = $null; Failed = $null; Skipped = $null
        Success = $false; Categories = $categories; SkippedTests = @()
    }
}

function Get-FlutterTestSummary {
    param([string[]]$Lines, [hashtable]$SuiteCategories = @{})
    $tests = @{}
    $suites = @{}
    $groupSkipReasons = @{}
    $runSuccess = $null
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        switch ($event.type) {
            'suite' {
                $category = $SuiteCategories[[string]$event.suite.path]
                if ([string]::IsNullOrWhiteSpace($category)) { $category = 'Common' }
                $suites[[string]$event.suite.id] = $category
            }
            'group' {
                $groupSkipReasons[[string]$event.group.id] = [string]$event.group.metadata.skipReason
            }
            'testStart' {
                $id = [string]$event.test.id
                $category = $suites[[string]$event.test.suiteID]
                if ([string]::IsNullOrWhiteSpace($category)) { $category = 'Common' }
                if ([string]$event.test.name -match '^\[Windows\]') { $category = 'Windows' }
                elseif ([string]$event.test.name -match '^\[macOS\]') { $category = 'macOS' }
                $skipReason = [string]$event.test.metadata.skipReason
                if ([string]::IsNullOrWhiteSpace($skipReason)) {
                    foreach ($groupId in $event.test.groupIDs) {
                        $reason = $groupSkipReasons[[string]$groupId]
                        if (-not [string]::IsNullOrWhiteSpace($reason)) { $skipReason = $reason }
                    }
                }
                $tests[$id] = [ordered]@{
                    hidden = [bool]$event.test.hidden; done = $false; skipped = $false; failed = $false
                    category = $category; name = [string]$event.test.name; reason = $skipReason
                }
            }
            'testDone' {
                $id = [string]$event.testID
                if (-not $tests.ContainsKey($id)) {
                    $tests[$id] = [ordered]@{
                        hidden = [bool]$event.hidden; done = $false; skipped = $false; failed = $false
                        category = 'Common'; name = "Test $id"; reason = ''
                    }
                }
                $tests[$id].done = $true
                $tests[$id].hidden = [bool]$event.hidden
                $tests[$id].skipped = [bool]$event.skipped
                $tests[$id].failed = ($event.result -ne 'success' -and $event.result -ne 'pass')
            }
            'error' {
                $id = [string]$event.testID
                if ($tests.ContainsKey($id)) { $tests[$id].failed = $true }
            }
            'done' { $runSuccess = [bool]$event.success }
        }
    }
    $visible = @($tests.Values | Where-Object { -not $_.hidden })
    $total = $visible.Count
    if ($total -eq 0) { return (New-UnavailableTestSummary -Status 'incomplete') }
    $skipped = @($visible | Where-Object { $_.skipped }).Count
    $failed = @($visible | Where-Object { $_.failed }).Count
    $passed = @($visible | Where-Object { $_.done -and -not $_.skipped -and -not $_.failed }).Count
    $complete = ($total -gt 0 -and @($visible | Where-Object { -not $_.done }).Count -eq 0 -and $null -ne $runSuccess)
    $categories = [ordered]@{}
    foreach ($category in @('Common', 'Windows', 'macOS')) {
        $items = @($visible | Where-Object { $_.category -eq $category })
        $categoryPassed = @($items | Where-Object { $_.done -and -not $_.skipped -and -not $_.failed }).Count
        $categoryFailed = @($items | Where-Object { $_.failed }).Count
        $categorySkipped = @($items | Where-Object { $_.skipped }).Count
        $categoryIncomplete = @($items | Where-Object { -not $_.done }).Count -gt 0 -or $null -eq $runSuccess
        $categoryStatus = if ($items.Count -eq 0) { 'not-run' }
            elseif ($categoryIncomplete) { 'incomplete' }
            elseif ($categoryFailed -gt 0) { 'failed' }
            elseif ($categorySkipped -eq $items.Count) { 'skipped' }
            elseif ($categorySkipped -gt 0) { 'passed-with-skips' }
            else { 'passed' }
        $categories[$category] = [pscustomobject]@{
            Status = $categoryStatus
            Total = $items.Count
            Passed = $categoryPassed
            Failed = $categoryFailed
            Skipped = $categorySkipped
        }
    }
    [pscustomobject]@{
        Status = if (-not $complete) { 'incomplete' } elseif ($runSuccess -and $failed -eq 0) { 'passed' } else { 'failed' }
        Total = $total; Passed = $passed; Failed = $failed; Skipped = $skipped
        Success = ($complete -and $runSuccess -and $failed -eq 0)
        Categories = $categories
        SkippedTests = @($visible | Where-Object { $_.skipped } | Sort-Object name | ForEach-Object {
            [pscustomobject]@{ Name = $_.name; Category = $_.category; Reason = $_.reason }
        })
    }
}

function Get-RustTestSummary {
    param([string[]]$Lines)
    $line = @($Lines | Where-Object { $_ -match '^test result:' } | Select-Object -Last 1)
    if ($line.Count -eq 0 -or $line[0] -notmatch '(\d+) passed;\s+(\d+) failed;\s+(\d+) ignored;') {
        $running = @($Lines | Where-Object { $_ -match '^running \d+ tests?' } | Select-Object -First 1)
        $passed = @($Lines | Where-Object { $_ -match '^test .+ \.\.\. ok$' }).Count
        $failed = @($Lines | Where-Object { $_ -match '^test .+ \.\.\. FAILED$' }).Count
        $skipped = @($Lines | Where-Object { $_ -match '^test .+ \.\.\. ignored(?:$|,)' }).Count
        if ($running.Count -eq 0 -and $passed + $failed + $skipped -eq 0) {
            return (New-UnavailableTestSummary -Status 'incomplete')
        }
        $total = $passed + $failed + $skipped
        if ($running.Count -gt 0 -and $running[0] -match '^running (\d+) tests?') { $total = [int]$Matches[1] }
        return [pscustomobject]@{
            Status = 'incomplete'; Total = $total; Passed = $passed; Failed = $failed; Skipped = $skipped; Success = $false
        }
    }
    $passed = [int]$Matches[1]; $failed = [int]$Matches[2]; $skipped = [int]$Matches[3]
    $success = ($failed -eq 0 -and $line[0] -match '^test result: ok\.')
    [pscustomobject]@{
        Status = if ($success) { 'passed' } else { 'failed' }
        Total = $passed + $failed + $skipped; Passed = $passed; Failed = $failed; Skipped = $skipped; Success = $success
    }
}

if ($SelfTest) {
    $events = @(
        '{"type":"testStart","test":{"id":0}}'
        '{"type":"testDone","testID":0,"result":"success","hidden":true,"skipped":false}'
        '{"type":"testStart","test":{"id":1}}'
        '{"type":"testDone","testID":1,"result":"success","hidden":false,"skipped":false}'
        '{"type":"testStart","test":{"id":2}}'
        '{"type":"testDone","testID":2,"result":"success","hidden":false,"skipped":true}'
        '{"type":"done","success":true}'
    )
    $result = Get-FlutterTestSummary -Lines $events
    if ($result.Total -ne 2 -or $result.Passed -ne 1 -or
        $result.Skipped -ne 1 -or -not $result.Success) {
        throw 'Flutter parser must exclude hidden infrastructure tests and count skips.'
    }
    $lateError = $events[0..5] + @(
        '{"type":"error","testID":1,"isFailure":false}'
        '{"type":"done","success":false}'
    )
    $result = Get-FlutterTestSummary -Lines $lateError
    if ($result.Passed -ne 0 -or $result.Failed -ne 1 -or $result.Success) {
        throw 'Flutter parser must revise a completed test after a late error.'
    }
    $result = Get-FlutterTestSummary -Lines $events[0..5]
    if ($result.Success) {
        throw 'A truncated Flutter run must not pass.'
    }
    $categorized = @(
        '{"type":"suite","suite":{"id":10,"path":"test/common_test.dart"}}'
        '{"type":"suite","suite":{"id":11,"path":"test/windows_test.dart"}}'
        '{"type":"suite","suite":{"id":12,"path":"test/macos_test.dart"}}'
        '{"type":"testStart","test":{"id":1,"suiteID":10}}'
        '{"type":"testDone","testID":1,"result":"success","hidden":false,"skipped":false}'
        '{"type":"testStart","test":{"id":2,"suiteID":11,"name":"[Windows] native test","metadata":{"skipReason":"Requires native Windows host"}}}'
        '{"type":"testDone","testID":2,"result":"success","hidden":false,"skipped":true}'
        '{"type":"testStart","test":{"id":3,"suiteID":12}}'
        '{"type":"testDone","testID":3,"result":"success","hidden":false,"skipped":false}'
        '{"type":"done","success":true}'
    )
    $result = Get-FlutterTestSummary -Lines $categorized -SuiteCategories @{
        'test/windows_test.dart' = 'Windows'; 'test/macos_test.dart' = 'macOS'
    }
    if ($result.Categories.Common.Passed -ne 1 -or $result.Categories.Windows.Skipped -ne 1 -or $result.Categories.macOS.Passed -ne 1) {
        throw 'Category totals must use suite metadata and retain skips.'
    }
    if ($result.Categories.Windows.Status -ne 'skipped' -or
        $result.Categories.Common.Status -ne 'passed' -or
        $result.Categories.macOS.Status -ne 'passed') {
        throw 'A completely skipped platform category must not be reported as passed.'
    }
    if ($result.SkippedTests.Count -ne 1 -or $result.SkippedTests[0].Reason -ne 'Requires native Windows host') {
        throw 'Skipped-test reports must preserve the declared reason.'
    }
    $mixed = @(
        '{"type":"suite","suite":{"id":1,"path":"test/mixed_test.dart"}}'
        '{"type":"testStart","test":{"id":1,"suiteID":1,"name":"[Windows] native IME"}}'
        '{"type":"testDone","testID":1,"result":"success","hidden":false,"skipped":true}'
        '{"type":"testStart","test":{"id":2,"suiteID":1,"name":"portable behavior"}}'
        '{"type":"testDone","testID":2,"result":"success","hidden":false,"skipped":false}'
        '{"type":"done","success":true}'
    )
    $result = Get-FlutterTestSummary -Lines $mixed
    if ($result.Categories.Windows.Skipped -ne 1 -or $result.Categories.Common.Passed -ne 1) {
        throw 'Mixed suites must classify the platform prefix without affecting portable tests.'
    }
    $result = Get-RustTestSummary -Lines @(
        'test result: ok. 12 passed; 0 failed; 2 ignored; 0 measured; 5 filtered out; finished in 0.01s'
    )
    if ($result.Total -ne 14 -or $result.Passed -ne 12 -or $result.Skipped -ne 2) {
        throw 'Rust parser must derive counts from the actual libtest summary.'
    }
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) "nso-ci-summary-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $scratch | Out-Null
    try {
        $childShell = (Get-Command pwsh -ErrorAction Stop).Source
        $missingFlutter = Join-Path $scratch 'missing-flutter.jsonl'
        $missingRust = Join-Path $scratch 'missing-rust.log'
        $reports = Join-Path $scratch 'not-run'
        & $childShell -NoProfile -File $PSCommandPath -FlutterMachineLog $missingFlutter -RustLog $missingRust -ReportsDirectory $reports -SummaryPath '' 2>&1 | Out-Null
        $childExit = $LASTEXITCODE
        $reportPath = Join-Path $reports 'test-counts.json'
        if ($childExit -eq 0 -or -not (Test-Path -LiteralPath $reportPath)) {
            throw 'Missing-log helper process must write the structured report before failing.'
        }
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($report.flutter.Status -ne 'not-run' -or $null -ne $report.flutter.Total -or
            $report.rust.Status -ne 'not-run' -or $null -ne $report.rust.Total) {
            throw 'Missing logs must produce not-run suites with null unavailable totals.'
        }
        $partialFlutter = Join-Path $scratch 'partial-flutter.jsonl'
        $partialRust = Join-Path $scratch 'partial-rust.log'
        $events[0..5] | Set-Content -LiteralPath $partialFlutter -Encoding UTF8
        @('running 4 tests', 'test first ... ok', 'test second ... ignored') |
            Set-Content -LiteralPath $partialRust -Encoding UTF8
        $reports = Join-Path $scratch 'incomplete'
        & $childShell -NoProfile -File $PSCommandPath -FlutterMachineLog $partialFlutter -RustLog $partialRust -ReportsDirectory $reports -SummaryPath '' 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { throw 'Truncated helper process must fail.' }
        $report = Get-Content -LiteralPath (Join-Path $reports 'test-counts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($report.flutter.Status -ne 'incomplete' -or $report.flutter.Passed -ne 1 -or
            $report.rust.Status -ne 'incomplete' -or $report.rust.Passed -ne 1 -or $report.rust.Skipped -ne 1) {
            throw 'Truncated logs must keep observed partial counts and mark suites incomplete.'
        }
        $events | Set-Content -LiteralPath $partialFlutter -Encoding UTF8
        'test result: ok. 12 passed; 0 failed; 2 ignored; 0 measured; 0 filtered out; finished in 0.01s' |
            Set-Content -LiteralPath $partialRust -Encoding UTF8
        $reports = Join-Path $scratch 'complete'
        & $childShell -NoProfile -File $PSCommandPath -FlutterMachineLog $partialFlutter -RustLog $partialRust -ReportsDirectory $reports -SummaryPath '' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Complete successful logs must pass the helper process.' }
        $report = Get-Content -LiteralPath (Join-Path $reports 'test-counts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($report.flutter.Status -ne 'passed' -or $report.flutter.Total -ne 2 -or $report.rust.Status -ne 'passed') {
            throw 'Complete helper process must emit successful structured counts.'
        }
    }
    finally {
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        $resolvedScratch = [System.IO.Path]::GetFullPath($scratch)
        if (-not $resolvedScratch.StartsWith("$tempRoot$([System.IO.Path]::DirectorySeparatorChar)", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Self-test cleanup path escaped the temporary directory.'
        }
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
    Write-Host 'CI summary parser self-tests passed.'
    return
}

if ([string]::IsNullOrWhiteSpace($FlutterMachineLog) -or [string]::IsNullOrWhiteSpace($RustLog)) {
    throw 'Pass -FlutterMachineLog and -RustLog, or use -SelfTest.'
}
$suiteCategories = @{}
$projectRoot = [System.IO.Path]::GetFullPath($ProjectDirectory)
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $projectRoot 'test') -Filter '*_test.dart' -Recurse -File) {
    $category = 'Common'
    $source = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $annotation = [regex]::Match($source, '@Tags\s*\(\s*\[(.*?)\]\s*\)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($annotation.Success) {
        $tags = $annotation.Groups[1].Value
        if ($tags -match '["'']platform-windows["'']') { $category = 'Windows' }
        elseif ($tags -match '["'']platform-macos["'']') { $category = 'macOS' }
    }
    $relative = [System.IO.Path]::GetRelativePath($projectRoot, $file.FullName)
    $suiteCategories[$file.FullName] = $category
    $suiteCategories[$file.FullName.Replace('\', '/')] = $category
    $suiteCategories[$relative] = $category
    $suiteCategories[$relative.Replace('\', '/')] = $category
}
$flutter = New-UnavailableTestSummary -Status 'not-run'
if (Test-Path -LiteralPath $FlutterMachineLog -PathType Leaf) {
    try { $flutter = Get-FlutterTestSummary -Lines (Get-Content -LiteralPath $FlutterMachineLog -Encoding UTF8) -SuiteCategories $suiteCategories }
    catch { $flutter = New-UnavailableTestSummary -Status 'incomplete' }
}
$rust = New-UnavailableTestSummary -Status 'not-run'
if (Test-Path -LiteralPath $RustLog -PathType Leaf) {
    try { $rust = Get-RustTestSummary -Lines (Get-Content -LiteralPath $RustLog -Encoding UTF8) }
    catch { $rust = New-UnavailableTestSummary -Status 'incomplete' }
}
$flutterStatus = $flutter.Status
$rustStatus = $rust.Status
$summary = @(
    '### Native validation test summary'
    ''
    '| Suite | Status | Total | Passed | Failed | Skipped |'
    '| --- | --- | ---: | ---: | ---: | ---: |'
    "| Flutter | $flutterStatus | $($flutter.Total) | $($flutter.Passed) | $($flutter.Failed) | $($flutter.Skipped) |"
    "| Flutter common | $($flutter.Categories.Common.Status) | $($flutter.Categories.Common.Total) | $($flutter.Categories.Common.Passed) | $($flutter.Categories.Common.Failed) | $($flutter.Categories.Common.Skipped) |"
    "| Flutter Windows | $($flutter.Categories.Windows.Status) | $($flutter.Categories.Windows.Total) | $($flutter.Categories.Windows.Passed) | $($flutter.Categories.Windows.Failed) | $($flutter.Categories.Windows.Skipped) |"
    "| Flutter macOS | $($flutter.Categories.macOS.Status) | $($flutter.Categories.macOS.Total) | $($flutter.Categories.macOS.Passed) | $($flutter.Categories.macOS.Failed) | $($flutter.Categories.macOS.Skipped) |"
    "| Rust | $rustStatus | $($rust.Total) | $($rust.Passed) | $($rust.Failed) | $($rust.Skipped) |"
) -join [Environment]::NewLine
Write-Host $summary
if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) { Add-Content -LiteralPath $SummaryPath -Value $summary -Encoding UTF8 }
if (-not [string]::IsNullOrWhiteSpace($ReportsDirectory)) {
    New-Item -ItemType Directory -Path $ReportsDirectory -Force | Out-Null
    [ordered]@{ flutter = $flutter; rust = $rust } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $ReportsDirectory 'test-counts.json') -Encoding UTF8
}
if (-not $flutter.Success -or -not $rust.Success) {
    throw "Validation suite reports are not successful: Flutter=$flutterStatus; Rust=$rustStatus."
}
