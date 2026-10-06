#Requires -Version 5.1
# Dependency-free regression tests. Never invokes real DISM/SFC or requests UAC.
[CmdletBinding()]
param([switch]$KeepArtifacts)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:assertions = 0
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'FileScan.Core.psm1') -Force
$testRoot = Join-Path $root ('tests\artifacts-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$encoding = [Text.UTF8Encoding]::new($false)
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw "$Message : expected <$Expected>, got <$Actual>" }
    $script:assertions++
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}
function Write-Fixture {
    param([string]$Path, [string[]]$Lines, [Text.Encoding]$Encoding = $encoding)
    [IO.File]::WriteAllLines($Path, $Lines, $Encoding)
}
function Invoke-EntryPoint {
    param([string[]]$Parameters, [switch]$Batch)
    # Native stderr is deliberately captured, including expected validation errors.
    $ErrorActionPreference = 'Continue'
    if ($Batch) { & (Join-Path $root 'FILE SCAN.bat') @Parameters 2>&1 | ForEach-Object { Write-Host $_ } }
    else { & $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'FileScan.ps1') @Parameters 2>&1 | ForEach-Object { Write-Host $_ } }
    return $LASTEXITCODE
}

try {
    # Parse both production files using this host's parser, before executing fixtures.
    foreach ($file in @('FileScan.ps1', 'FileScan.Core.psm1')) {
        $parseErrors = $null; $tokens = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$parseErrors)
        Assert-Equal @($parseErrors).Count 0 "$file parses"
    }
    $window = Get-FileScanWindow -Since '2026-10-05' -Until '2026-10-06'
    Assert-Equal $window.Since ([datetime]'2026-10-05') 'Since includes midnight'
    Assert-Equal $window.UntilExclusive ([datetime]'2026-10-07') 'Until date includes its entire day'
    $timed = Get-FileScanWindow -Since '2026-10-06T12:00:00' -Until '2026-10-06T13:00:00'
    Assert-Equal $timed.UntilExclusive ([datetime]'2026-10-06T13:00:00') 'Timestamp end is exclusive'
    Assert-Throws { Get-FileScanWindow -Since '10/06/2026' } 'Ambiguous date rejected'
    Assert-Throws { Get-FileScanWindow -Since '2026-02-30' } 'Invalid calendar date rejected'
    Assert-Throws { Get-FileScanWindow -Since '2026-10-07' -Until '2026-10-06' } 'Empty window rejected'
    $midnight = Get-FileScanWindow -DefaultSince ([datetime]'2026-10-05T23:59:55') -Now ([datetime]'2026-10-06T00:01:00')
    Assert-Equal $midnight.Since ([datetime]'2026-10-05T23:59:55') 'Scan window keeps start across midnight'
    Assert-Equal $midnight.UntilExclusive ([datetime]'2026-10-06T00:01:01') 'Scan window extends across midnight'

    Assert-Equal @(Get-FileScanPlan -Mode Analyze).Count 0 'Analyze runs no tools'
    $check = @(Get-FileScanPlan -Mode Check)
    Assert-Equal $check.Count 2 'Check has two steps'
    Assert-True ($check[0].Arguments -contains '/ScanHealth') 'Check scans the image'
    Assert-Equal $check[1].Arguments[0] '/verifyonly' 'Check verifies files without repair'
    $repair = @(Get-FileScanPlan -Mode Repair -Source 'wim:D:\Repair files\install.wim:2' -LimitAccess)
    Assert-True ($repair[0].Arguments -contains '/RestoreHealth') 'Repair restores the image'
    Assert-True ($repair[0].Arguments -contains '/Source:wim:D:\Repair files\install.wim:2') 'Source is one argument'
    Assert-True ($repair[0].Arguments -contains '/LimitAccess') 'LimitAccess forwarded'
    Assert-Equal $repair[1].Arguments[0] '/scannow' 'SFC repair follows DISM'
    Assert-Throws { Get-FileScanPlan -Mode Check -Source 'D:\source' } 'Source rejected in Check'
    Assert-Throws { Get-FileScanPlan -Mode Analyze -LimitAccess } 'LimitAccess rejected in Analyze'
    Assert-Throws { Get-FileScanPlan -Mode Repair -Source 'D:\bad"path' } 'Embedded source quote rejected'

    $cbs = Join-Path $testRoot "CBS [sample] & O'Brien!.log"
    $dism = Join-Path $testRoot 'DISM sample.log'
    Write-Fixture $cbs @(
        '2026-10-04 11:00:00, Error CSI outside window'
        '2026-10-05 00:00:00, Info                  CSI 00001 [SR] Verifying 100 components'
        '2026-10-05 10:00:01, Info CSI 00002 [SR] Beginning Verify and Repair transaction'
        '2026-10-05 10:00:02, Info CSI 00003 [SR] Cannot repair member file "broken.dll"'
        '2026-10-05 10:00:03, Info CSI 00004 [SR] Repairing corrupted file C:\Windows\broken.dll'
        '2026-10-05 10:00:04, Info CSI 00005 [SR] Verify and Repair Transaction completed'
        '2026-10-05 10:00:05, Warning CBS A servicing warning'
        '2026-10-06 10:00:06, Error CBS literal <script>alert("test")</script> & %PATH% !value! | ^ > <'
        '2026-10-06 10:00:07, Info CBS There were no errors; normal chatter'
        '2026-10-06 10:00:08, Info CSI Routine CSI information'
        'untimestamped continuation with Error is ignored'
        '2026-99-99 12:00:00, Error malformed date is ignored'
        '2026-10-07 00:00:00, Error CBS exclusive end boundary'
    )
    Write-Fixture $dism @(
        '2026-10-05 09:00:00, Info DISM routine startup'
        '2026-10-05 09:00:01, Warning DISM source missing'
        '2026-10-06 11:00:00.125, Error DISM repair failed 0x800f081f'
        '2026-10-06 11:00:01,125, Fatal DISM fractional timestamp failure'
    ) ([Text.Encoding]::Unicode)
    $arguments = @{ CbsPath = $cbs; DismPath = $dism; Since = $window.Since; UntilExclusive = $window.UntilExclusive }
    $analysis = Get-FileScanAnalysis @arguments
    Assert-Equal $analysis.Sources.Count 2 'Both logs analyzed'
    Assert-Equal @($analysis.Sources | Where-Object Status -eq Read).Count 2 'UTF-8 and UTF-16 logs readable'
    Assert-Equal $analysis.Summary.MatchedEntries 10L 'Matches use timestamp and severity columns'
    Assert-Equal $analysis.Summary.Errors 3L 'Fatal normalized to Error'
    Assert-Equal $analysis.Summary.Warnings 2L 'Warning count across both logs'
    Assert-Equal $analysis.Summary.SfcEntries 5L 'All SFC Info events retained'
    Assert-Equal $analysis.Summary.RepairEvents 1L 'Repair observed'
    Assert-Equal $analysis.Summary.UnrepairableEvents 1L 'Unrepairable observation recognized'
    Assert-True ($analysis.Entries[0].Timestamp -lt $analysis.Entries[-1].Timestamp) 'Entries chronological across sources'
    Assert-Equal (Get-FileScanExitCode -Commands @() -Analysis $analysis) 0 'Default findings are informational'
    Assert-Equal (Get-FileScanExitCode -Commands @() -Analysis $analysis -FailOnFindings) 3 'Opt-in findings exit code'
    $allInfo = Get-FileScanAnalysis @arguments -IncludeInfo
    Assert-Equal $allInfo.Summary.MatchedEntries 13L 'IncludeInfo includes routine entries'
    Assert-Equal $allInfo.Summary.Errors 3L 'An error word inside Info is not an error'
    $limited = Get-FileScanAnalysis @arguments -MaxEntries 2
    Assert-Equal $limited.Entries.Count 2 'Report excerpts bounded'
    Assert-Equal $limited.Summary.Errors 3L 'Counts include omitted matches'
    Assert-Equal $limited.Summary.OmittedEntries 8L 'Truncation explicit'
    Assert-True ($limited.Entries[0].Message -match '0x800f081f') 'Newest entries retained across sources'

    Write-Fixture (Join-Path $testRoot 'CbsPersist_20261005.log') @('2026-10-05 01:00:00, Error CSI older rotated entry')
    Write-Fixture (Join-Path $testRoot 'dism.log.bak') @('2026-10-06 12:00:00, Warning DISM rotated entry')
    Write-Fixture (Join-Path $testRoot 'CbsPersist_ignored.cab') @('2026-10-06 14:00:00, Error compressed archive not a log')
    $history = Get-FileScanAnalysis @arguments -IncludeHistory -MaxEntries 2
    Assert-Equal $history.Sources.Count 4 'Uncompressed rotated logs included'
    Assert-Equal $history.Summary.MatchedEntries 12L 'History counted'
    Assert-True ($history.Entries[-1].Message -match 'rotated entry') 'History participates in global time ordering'
    $missing = Get-FileScanAnalysis -CbsPath (Join-Path $testRoot 'missing.log') -DismPath $dism -Since $window.Since -UntilExclusive $window.UntilExclusive
    Assert-Equal $missing.Sources[0].Status 'Missing' 'Missing distinguished from no matches'
    Assert-Equal (Get-FileScanExitCode -Commands @() -Analysis $missing -FailOnFindings) 2 'Incomplete takes precedence over findings'
    $lockedStream = [IO.File]::Open($cbs, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { $locked = Get-FileScanAnalysis @arguments } finally { $lockedStream.Dispose() }
    Assert-Equal $locked.Sources[0].Status 'Unreadable' 'Sharing violation distinguished from empty log'
    $empty = Join-Path $testRoot 'empty.log'; Write-Fixture $empty @()
    $none = Get-FileScanAnalysis -CbsPath $empty -DismPath $empty -Since $window.Since -UntilExclusive $window.UntilExclusive
    Assert-Equal $none.Entries.Count 0 'No matches stays an empty array'

    # Stress bounded retention with descending timestamps (file order is not assumed).
    $large = Join-Path $testRoot 'large.log'
    $writer = [IO.StreamWriter]::new($large, $false, $encoding)
    try { for ($i = 2000; $i -ge 0; $i--) { $writer.WriteLine(('{0}, Error CSI entry {1}' -f ([datetime]'2026-10-05').AddSeconds($i).ToString('yyyy-MM-dd HH:mm:ss'), $i)) } }
    finally { $writer.Dispose() }
    $stress = Get-FileScanAnalysis -CbsPath $large -DismPath $empty -Since $window.Since -UntilExclusive $window.UntilExclusive -MaxEntries 3
    Assert-Equal $stress.Summary.MatchedEntries 2001L 'Every large-log entry counted'
    Assert-Equal $stress.Entries.Count 3 'Large-log memory retention bounded'
    Assert-True ($stress.Entries[-1].Message -match 'entry 2000$') 'Newest chosen even in descending input'

    # Use PowerShell as a harmless child process to verify execution and pipe capture.
    foreach ($code in @(0, 3010, 5)) {
        $fake = '[Console]::WriteLine("fake output"); [Console]::Error.WriteLine("fake stderr"); exit ' + $code
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($fake))
        $result = Invoke-FileScanCommand -Name DISM -FilePath $windowsPowerShell -Arguments @('-NoProfile', '-EncodedCommand', $encoded) -OutputPath (Join-Path $testRoot "fake-$code.txt")
        Assert-Equal $result.ExitCode $code 'Native exit preserved'
        Assert-Equal $result.Status $(if ($code -eq 5) { 'Failed' } else { 'Completed' }) 'Native completion classified'
        Assert-Equal $result.RebootRequired ($code -eq 3010) 'Reboot result preserved'
        $captured = [IO.File]::ReadAllText($result.OutputPath)
        Assert-True ($captured -match 'fake output' -and $captured -match 'fake stderr') 'Both pipes captured'
    }
    Assert-Equal (Get-FileScanExitCode -Commands @($result) -Analysis $missing -FailOnFindings) 1 'Command failure has highest precedence'
    $notFound = Invoke-FileScanCommand -Name Fake -FilePath (Join-Path $testRoot 'absent.exe') -Arguments @() -OutputPath (Join-Path $testRoot 'not-found.txt')
    Assert-Equal $notFound.Status 'Failed' 'Launch failure captured'
    Assert-True ([IO.File]::ReadAllText($notFound.OutputPath) -match 'Command failed') 'Launch failure saved'
    $unicodeFake = '[Console]::OutputEncoding = [Text.Encoding]::Unicode; [Console]::WriteLine([char]0x03A9); exit 0'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($unicodeFake))
    $unicodeResult = Invoke-FileScanCommand -Name SFC -FilePath $windowsPowerShell -Arguments @('-NoProfile', '-EncodedCommand', $encoded) -OutputPath (Join-Path $testRoot 'sfc-unicode.txt')
    Assert-True ([IO.File]::ReadAllText($unicodeResult.OutputPath).Contains([string][char]0x03A9)) 'Redirected Unicode SFC output decoded'

    # Round-trip Windows argument quoting through an actual native process.
    $echoScript = Join-Path $testRoot 'echo args.ps1'
    Write-Fixture $echoScript @('$args | ConvertTo-Json -Compress')
    $values = @('two words', 'C:\ends with slash\', 'a"b', 'a\"b', "O'Brien! & | ^ %PATH%", '')
    $echo = Invoke-FileScanCommand -Name Fake -FilePath $windowsPowerShell -Arguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $echoScript) + $values) -OutputPath (Join-Path $testRoot 'args.txt')
    Assert-Equal $echo.ExitCode 0 'Argument echo process succeeds'
    $roundTrip = @([IO.File]::ReadAllLines($echo.OutputPath)[0] | ConvertFrom-Json)
    Assert-Equal $roundTrip.Count $values.Count 'Empty argument retained'
    for ($i = 0; $i -lt $values.Count; $i++) { Assert-Equal $roundTrip[$i] $values[$i] 'Native quoted argument round trip' }

    # Run the real entry point in Analyze mode under Windows PowerShell 5.1.
    $outRoot = Join-Path $testRoot 'reports [test] & spaced!'
    $cli = @('-Mode', 'Analyze', '-NonInteractive', '-CbsPath', $cbs, '-DismPath', $dism,
        '-Since', '2026-10-05', '-Until', '2026-10-06', '-OutputDirectory', $outRoot, '-MaxEntries', '20')
    Assert-Equal (Invoke-EntryPoint $cli) 0 'CLI analysis succeeds under Windows PowerShell'
    $runs = @(Get-ChildItem -LiteralPath $outRoot -Directory)
    Assert-Equal $runs.Count 1 'Unique run folder created'
    foreach ($name in @('file_scan.log', 'file_scan.json', 'file_scan.html')) { Assert-True (Test-Path -LiteralPath (Join-Path $runs[0].FullName $name)) 'All report formats created' }
    $json = [IO.File]::ReadAllText((Join-Path $runs[0].FullName 'file_scan.json')) | ConvertFrom-Json
    Assert-Equal $json.SchemaVersion 1 'JSON schema version included'
    Assert-Equal $json.Summary.MatchedEntries 10 'JSON counts match parser'
    Assert-Equal $json.Commands.Count 0 'Analyze never launches servicing tools'
    $html = [IO.File]::ReadAllText((Join-Path $runs[0].FullName 'file_scan.html'))
    Assert-True ($html -notmatch '<script>') 'Log data cannot inject HTML scripts'
    Assert-True ($html -match '&lt;script&gt;' -and $html -match '&amp;') 'HTML entities encoded'
    Assert-True ($html -match 'Content-Security-Policy') 'Report excludes active external content'
    $log = [IO.File]::ReadAllText((Join-Path $runs[0].FullName 'file_scan.log'))
    Assert-True ($log.Contains('%PATH% !value! | ^ > <')) 'Log shell metacharacters preserved as data'
    Assert-Equal (Invoke-EntryPoint ($cli + @('-FailOnFindings')) -Batch) 3 'Batch forwards quoted paths and findings exit code'
    Assert-Equal @(Get-ChildItem -LiteralPath $outRoot -Directory).Count 2 'Subsequent run preserves prior reports'
    $dryRoot = Join-Path $testRoot 'dry-run-must-not-exist'
    Assert-Equal (Invoke-EntryPoint @('-Mode', 'Repair', '-DryRun', '-NonInteractive', '-OutputDirectory', $dryRoot)) 0 'Repair dry run safe without elevation'
    Assert-True (-not (Test-Path -LiteralPath $dryRoot)) 'Dry run writes nothing'
    # Invalid options must fail before reports, elevation, or native commands.
    Assert-Equal (Invoke-EntryPoint @('-Mode', 'Repair', '-Since', 'bad-date', '-DryRun', '-NonInteractive', '-OutputDirectory', $dryRoot)) 1 'Invalid date stops execution'
    Assert-True (-not (Test-Path -LiteralPath $dryRoot)) 'Invalid date writes nothing'
    Write-Host "PASS: $script:assertions assertions. No system scans or repairs performed." -ForegroundColor Green
    if ($KeepArtifacts) { Write-Host "Artifacts: $testRoot" }
} finally {
    if (-not $KeepArtifacts) {
        # Only delete the specific generated directory, after checking workspace containment.
        $resolvedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedTestRoot.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test cleanup target escaped the workspace.' }
        if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
    }
}
