#Requires -Version 5.1
# All system-tool calls below use harmless fixtures or module-local mocks.
[CmdletBinding()]
param([switch]$KeepArtifacts)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:assertions = 0
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'FileScan.Core.psm1') -Force
$testRoot = Join-Path $PSScriptRoot ('artifacts-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$encoding = [Text.UTF8Encoding]::new($false)
$hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
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
    param([scriptblock]$Action)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw 'Invalid option rejected'
}
function Write-Fixture {
    param([string]$Path, [string[]]$Lines, [Text.Encoding]$Encoding = $encoding)
    [IO.File]::WriteAllLines($Path, $Lines, $Encoding)
}
function Invoke-Fixture {
    param([string]$Name, [string[]]$Arguments)
    Invoke-FileScanCommand -Name $Name -FilePath $hostPath -Arguments $Arguments -OutputPath (Join-Path $testRoot ($Name + '-output.txt')) 6>$null
}
try {
    foreach ($file in @('FileScan.ps1', 'FileScan.Core.psm1')) {
        $parseErrors = $null; $tokens = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$parseErrors)
        Assert-Equal @($parseErrors).Count 0 "$file parses"
    }
    $window = Get-FileScanWindow -Since '2026-10-05' -Until '2026-10-06'
    Assert-Equal $window.Since ([datetime]'2026-10-05') 'Inclusive start'
    Assert-Equal $window.UntilExclusive ([datetime]'2026-10-07') 'Entire end date included'
    Assert-Equal (Get-FileScanWindow -Since '2026-10-06T12:00:00' -Until '2026-10-06T13:00:00').UntilExclusive ([datetime]'2026-10-06T13:00:00') 'Timestamp end exclusive'
    Assert-Throws { Get-FileScanWindow -Since '10/06/2026' }
    Assert-Throws { Get-FileScanWindow -Since '2026-02-30' }
    Assert-Throws { Get-FileScanWindow -Since '2026-10-07' -Until '2026-10-06' }
    $midnight = Get-FileScanWindow -DefaultSince ([datetime]'2026-10-05T23:59:55') -Now ([datetime]'2026-10-06T00:01:00')
    Assert-Equal $midnight.Since ([datetime]'2026-10-05T23:59:55') 'Start preserved across midnight'
    Assert-Equal $midnight.UntilExclusive ([datetime]'2026-10-06T00:01:01') 'Window spans midnight'
    Assert-Equal @(Get-FileScanPlan -Mode Analyze).Count 0 'Analyze runs no tools'
    $check = @(Get-FileScanPlan -Mode Check)
    Assert-True ($check[0].Arguments -contains '/ScanHealth') 'Check scans image'
    Assert-Equal $check[1].Arguments[0] '/verifyonly' 'Check does not repair files'
    $repair = @(Get-FileScanPlan -Mode Repair -Source 'wim:D:\Repair files\install.wim:2' -LimitAccess)
    Assert-True ($repair[0].Arguments -contains '/RestoreHealth') 'Repair restores image'
    Assert-True ($repair[0].Arguments -contains '/Source:wim:D:\Repair files\install.wim:2') 'Source is one argument'
    Assert-True ($repair[0].Arguments -contains '/LimitAccess') 'LimitAccess forwarded'
    Assert-Equal $repair[1].Arguments[0] '/scannow' 'SFC repair follows DISM'
    Assert-Throws { Get-FileScanPlan -Mode Check -Source 'D:\source' }
    Assert-Throws { Get-FileScanPlan -Mode Analyze -LimitAccess }
    Assert-Throws { Get-FileScanPlan -Mode Repair -Source 'D:\bad"path' }
    $module = Get-Module FileScan.Core
    $originalRunner = & $module { (Get-Item Function:Invoke-FileScanCommand).ScriptBlock }
    try {
        & $module {
            $script:FakeCalls = [Collections.Generic.List[string]]::new()
            $script:FakeFail = $false
            function script:Invoke-FileScanCommand {
                param($Name, $FilePath, $Arguments, $OutputPath)
                $script:FakeCalls.Add($Name)
                [pscustomobject]@{ Name = $Name; Arguments = $Arguments; Status = $(if ($script:FakeFail) { 'Failed' } else { 'Completed' }) }
            }
        }
        $sequenced = @(Invoke-FileScanPlan -Plan $repair -SystemDirectory $testRoot -RunDirectory $testRoot)
        Assert-Equal ($sequenced.Name -join ',') 'DISM,SFC' 'Repair order preserved'
        & $module { $script:FakeCalls.Clear(); $script:FakeFail = $true }
        $stopped = @(Invoke-FileScanPlan -Plan $repair -SystemDirectory $testRoot -RunDirectory $testRoot)
        Assert-Equal $stopped[1].Status 'Skipped' 'SFC skipped after DISM failure'
        Assert-Equal (& $module { $script:FakeCalls.Count }) 1 'SFC never invoked after failure'
    } finally { & $module { param($Runner) Set-Item Function:script:Invoke-FileScanCommand $Runner } $originalRunner }
    $cbs = Join-Path $testRoot "CBS [sample] & O'Brien!.log"
    $dism = Join-Path $testRoot 'DISM sample.log'
    Write-Fixture $cbs @(
        '2026-10-04 11:00:00, Error CSI outside window'
        '2026-10-05 00:00:00, Info CSI [SR] Verifying 100 components'
        '2026-10-05 10:00:01, Info CSI [SR] Beginning Verify and Repair transaction'
        '2026-10-05 10:00:02, Info CSI [SR] Cannot repair member file "broken.dll"'
        '2026-10-05 10:00:03, Info CSI [SR] Repairing corrupted file C:\Windows\broken.dll'
        '2026-10-05 10:00:04, Info CSI [SR] Verify and Repair Transaction completed'
        '2026-10-05 10:00:05, Warning CBS A servicing warning'
        '2026-10-06 10:00:06, Error CBS literal <script>alert("test")</script> & %PATH% !value! | ^ > <'
        '2026-10-06 10:00:07, Info CBS No errors; routine chatter'
        'untimestamped Error ignored'
        '2026-99-99 12:00:00, Error malformed date ignored'
        '2026-10-07 00:00:00, Error exclusive end boundary'
    )
    Write-Fixture $dism @('2026-10-05 09:00:00, Info DISM routine startup',
        '2026-10-05 09:00:01, Warning DISM source missing',
        '2026-10-06 11:00:00.125, Error DISM failed 0x800f081f',
        '2026-10-06 11:00:01,125, Fatal DISM fractional timestamp') ([Text.Encoding]::Unicode)
    $arguments = @{ CbsPath = $cbs; DismPath = $dism; Since = $window.Since; UntilExclusive = $window.UntilExclusive }
    $analysis = Get-FileScanAnalysis @arguments
    Assert-Equal @($analysis.Sources | Where-Object Status -eq Read).Count 2 'UTF-8 and UTF-16 readable'
    Assert-Equal $analysis.Summary.MatchedEntries 10L 'Timestamp/severity matching'
    Assert-Equal $analysis.Summary.Errors 3L 'Fatal normalized to Error'
    Assert-Equal $analysis.Summary.Warnings 2L 'Warnings counted'
    Assert-Equal $analysis.Summary.SfcEntries 5L 'SFC Info retained'
    Assert-Equal $analysis.Summary.RepairEvents 1L 'Repair recognized'
    Assert-Equal $analysis.Summary.UnrepairableEvents 1L 'Unrepairable recognized'
    Assert-Equal (Get-FileScanExitCode -Commands @() -Analysis $analysis) 0 'Default findings informational'
    Assert-Equal (Get-FileScanExitCode -Commands @() -Analysis $analysis -FailOnFindings) 3 'Findings exit code'
    $allInfo = Get-FileScanAnalysis @arguments -IncludeInfo
    Assert-Equal $allInfo.Summary.MatchedEntries 12L 'IncludeInfo adds routine entries'
    Assert-Equal $allInfo.Summary.Errors 3L 'Error word inside Info not an error'
    $limited = Get-FileScanAnalysis @arguments -MaxEntries 2
    Assert-Equal $limited.Entries.Count 2 'Excerpts bounded'
    Assert-Equal $limited.Summary.OmittedEntries 8L 'Omissions explicit'
    Assert-Equal $limited.Summary.Errors 3L 'Counts include omitted entries'
    Assert-True ($limited.Entries[0].Message -match '0x800f081f') 'Newest across sources retained'
    Write-Fixture (Join-Path $testRoot 'CbsPersist_20261005.log') @('2026-10-05 01:00:00, Error CSI rotated entry')
    Write-Fixture (Join-Path $testRoot 'dism.log.bak') @('2026-10-06 12:00:00, Warning DISM rotated entry')
    Write-Fixture (Join-Path $testRoot 'CbsPersist_ignored.cab') @('2026-10-06 14:00:00, Error excluded archive')
    $history = Get-FileScanAnalysis @arguments -IncludeHistory -MaxEntries 2
    Assert-Equal $history.Sources.Count 4 'Only uncompressed history included'
    Assert-Equal $history.Summary.MatchedEntries 12L 'History counted'
    Assert-True ($history.Entries[-1].Message -match 'rotated entry') 'History globally sorted'
    $missing = Get-FileScanAnalysis -CbsPath (Join-Path $testRoot 'missing.log') -DismPath $dism -Since $window.Since -UntilExclusive $window.UntilExclusive
    Assert-Equal $missing.Sources[0].Status 'Missing' 'Missing source explicit'
    Assert-Equal (Get-FileScanExitCode -Commands @() -Analysis $missing -FailOnFindings) 2 'Incomplete precedes findings'
    $lockedStream = [IO.File]::Open($cbs, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { $locked = Get-FileScanAnalysis @arguments } finally { $lockedStream.Dispose() }
    Assert-Equal $locked.Sources[0].Status 'Unreadable' 'Locked source explicit'
    $empty = Join-Path $testRoot 'empty.log'; Write-Fixture $empty @()
    $large = Join-Path $testRoot 'large.log'
    $writer = [IO.StreamWriter]::new($large, $false, $encoding)
    try { for ($i = 2000; $i -ge 0; $i--) { $writer.WriteLine(('{0}, Error CSI entry {1}' -f ([datetime]'2026-10-05').AddSeconds($i).ToString('yyyy-MM-dd HH:mm:ss'), $i)) } }
    finally { $writer.Dispose() }
    $stress = Get-FileScanAnalysis -CbsPath $large -DismPath $empty -Since $window.Since -UntilExclusive $window.UntilExclusive -MaxEntries 3
    Assert-Equal $stress.Summary.MatchedEntries 2001L 'All large-log entries counted'
    Assert-Equal $stress.Entries.Count 3 'Large-log retention bounded'
    Assert-True ($stress.Entries[-1].Message -match 'entry 2000$') 'Descending file retains newest timestamp'
    $nativeFixture = Join-Path $PSScriptRoot 'fixtures\NativeTool.ps1'
    foreach ($code in @(0, 3010, 5)) {
        $result = Invoke-Fixture DISM @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $nativeFixture, '-Code', [string]$code)
        Assert-Equal $result.ExitCode $code 'Native exit preserved'
        Assert-Equal $result.Status $(if ($code -eq 5) { 'Failed' } else { 'Completed' }) 'Native status classified'
        Assert-Equal $result.RebootRequired ($code -eq 3010) 'Restart only for DISM 3010'
        $captured = [IO.File]::ReadAllText($result.OutputPath)
        Assert-True ($captured -match 'fake output' -and $captured -match 'fake stderr') 'Both pipes captured'
    }
    Assert-Equal (Get-FileScanExitCode -Commands @($result) -Analysis $missing -FailOnFindings) 1 'Command failure precedes incomplete'
    $notFound = Invoke-FileScanCommand -Name Fake -FilePath (Join-Path $testRoot 'absent.exe') -Arguments @() -OutputPath (Join-Path $testRoot 'absent.txt') 6>$null
    Assert-Equal $notFound.Status 'Failed' 'Launch failure captured'
    $unicode = Invoke-Fixture SFC @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $nativeFixture, '-Unicode', '-Message', [string][char]0x03A9)
    Assert-True ([IO.File]::ReadAllText($unicode.OutputPath).Contains([string][char]0x03A9)) 'Unicode output decoded'
    $values = @('two words', 'C:\ends with slash\', 'a"b', 'a\"b', "O'Brien! & | ^ %PATH%", '')
    $echoScript = Join-Path $PSScriptRoot 'fixtures\EchoArguments.ps1'
    $echo = Invoke-Fixture Echo (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $echoScript) + $values)
    Assert-Equal $echo.ExitCode 0 'Argument echo succeeds'
    $roundTrip = [IO.File]::ReadAllLines($echo.OutputPath)[0] | ConvertFrom-Json
    Assert-Equal $roundTrip.Count $values.Count 'Empty argument retained'
    for ($i = 0; $i -lt $values.Count; $i++) { Assert-Equal $roundTrip[$i] $values[$i] 'Native argument round trip' }
    $transportScript = Join-Path $testRoot "elevation O'Brien.ps1"
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\EchoParameters.ps1') -Destination $transportScript
    $transportSource = "D:\O'Brien & `$dollar; !folder!\"
    $transportArgs = @(Get-FileScanElevationArguments -ScriptPath $transportScript -Parameters @{ Source = $transportSource; IncludeInfo = [Management.Automation.SwitchParameter]::new($true); MaxEntries = 7 })
    $transport = Invoke-Fixture Transport $transportArgs
    Assert-Equal $transport.ExitCode 3 'Elevation arguments preserve exit code'
    $transportJson = [IO.File]::ReadAllLines($transport.OutputPath)[0] | ConvertFrom-Json
    Assert-Equal $transportJson.Source $transportSource 'Elevation paths remain literal data'
    Assert-Equal $transportJson.IncludeInfo $true 'Elevation switches preserved'
    Assert-Equal $transportJson.MaxEntries 7 'Elevation numbers preserved'
    $falseArgs = @(Get-FileScanElevationArguments -ScriptPath $transportScript -Parameters @{ IncludeInfo = [Management.Automation.SwitchParameter]::new($false) })
    Assert-True ($falseArgs -notcontains '-IncludeInfo') 'False switch omitted'
    $outRoot = Join-Path $testRoot 'reports [test] & spaced!'
    $cli = @('-Mode', 'Analyze', '-NonInteractive', '-CbsPath', $cbs, '-DismPath', $dism, '-Since', '2026-10-05', '-Until', '2026-10-06', '-OutputDirectory', $outRoot, '-MaxEntries', '20')
    $cliResult = Invoke-Fixture CLI (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'FileScan.ps1')) + $cli)
    Assert-Equal $cliResult.ExitCode 0 'Real CLI analysis succeeds'
    $runs = @(Get-ChildItem -LiteralPath $outRoot -Directory)
    Assert-Equal $runs.Count 1 'Unique run directory created'
    foreach ($name in @('file_scan.log', 'file_scan.json', 'file_scan.html')) { Assert-True (Test-Path -LiteralPath (Join-Path $runs[0].FullName $name)) 'Every report format created' }
    $json = [IO.File]::ReadAllText((Join-Path $runs[0].FullName 'file_scan.json')) | ConvertFrom-Json
    Assert-Equal $json.SchemaVersion 1 'JSON schema version'
    Assert-Equal $json.Summary.MatchedEntries 10 'JSON counts correct'
    Assert-Equal $json.Commands.Count 0 'Analyze launches no native tools'
    $html = [IO.File]::ReadAllText((Join-Path $runs[0].FullName 'file_scan.html'))
    Assert-True ($html -notmatch '<script>') 'No HTML injection'
    Assert-True ($html -match '&lt;script&gt;' -and $html -match '&amp;') 'HTML entities encoded'
    Assert-True ($html -match 'Content-Security-Policy') 'No active external content'
    $log = [IO.File]::ReadAllText((Join-Path $runs[0].FullName 'file_scan.log'))
    Assert-True ($log.Contains('%PATH% !value! | ^ > <')) 'Shell metacharacters preserved as data'
    $ErrorActionPreference = 'Continue'
    & (Join-Path $root 'FILE SCAN.bat') @cli -FailOnFindings 2>&1 | ForEach-Object { Write-Host $_ }
    $batchExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert-Equal $batchExit 3 'Batch forwards paths and exit code'
    Assert-Equal @(Get-ChildItem -LiteralPath $outRoot -Directory).Count 2 'Previous reports retained'
    $missingCli = @('-NonInteractive', '-CbsPath', (Join-Path $testRoot 'missing.log'), '-DismPath', $dism, '-Since', '2026-10-05', '-Until', '2026-10-06', '-OutputDirectory', $outRoot)
    $incomplete = Invoke-Fixture CLI (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'FileScan.ps1')) + $missingCli)
    Assert-Equal $incomplete.ExitCode 2 'Unattended defaults to Analyze and signals missing logs'
    Assert-Equal @(Get-ChildItem -LiteralPath $outRoot -Directory).Count 3 'Incomplete analysis saves reports'
    $dryRoot = Join-Path $testRoot 'dry-run-must-not-exist'
    $dry = Invoke-Fixture CLI @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'FileScan.ps1'), '-Mode', 'Repair', '-DryRun', '-NonInteractive', '-OutputDirectory', $dryRoot)
    Assert-Equal $dry.ExitCode 0 'Repair dry run needs no elevation'
    Assert-True (-not (Test-Path -LiteralPath $dryRoot)) 'Dry run writes nothing'
    $invalid = Invoke-Fixture CLI @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'FileScan.ps1'), '-Mode', 'Repair', '-Since', 'bad-date', '-DryRun', '-NonInteractive', '-OutputDirectory', $dryRoot)
    Assert-Equal $invalid.ExitCode 1 'Bad date stops execution'
    Assert-True (-not (Test-Path -LiteralPath $dryRoot)) 'Bad date writes nothing'
    [IO.File]::WriteAllText((Join-Path $testRoot 'PASS.txt'), "PASS: $script:assertions assertions.")
    Write-Host "PASS: $script:assertions assertions. No system scans or repairs performed." -ForegroundColor Green
    if ($KeepArtifacts) { Write-Host "Artifacts: $testRoot" }
} finally {
    if (-not $KeepArtifacts) {
        $resolvedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedTestRoot.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup target escaped workspace.' }
        if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
    }
}
