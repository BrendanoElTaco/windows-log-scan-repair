#Requires -Version 5.1
[CmdletBinding()]
param([switch]$KeepArtifacts)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sourceRoot = Join-Path $root 'src'
$guiRoot = Join-Path $sourceRoot 'gui'
Import-Module (Join-Path $sourceRoot 'FileScan.Core.psm1') -Force
Import-Module (Join-Path $guiRoot 'FileScan.Gui.Core.psm1') -Force
$testRoot = Join-Path $PSScriptRoot ('artifacts-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function Assert-Throws {
    param([scriptblock]$Action)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw 'Invalid GUI input must be rejected.'
}
try {
    foreach ($name in @('FileScan.Gui.ps1','FileScan.Gui.Core.psm1')) {
        $errors = $null; $tokens = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $guiRoot $name), [ref]$tokens, [ref]$errors)
        Assert-True (@($errors).Count -eq 0) "$name parses"
    }
    [void][xml][IO.File]::ReadAllText((Join-Path $guiRoot 'FileScan.Gui.xaml'))
    $options = New-FileScanGuiOptions
    Assert-True ($options.Mode -eq 'Analyze') 'GUI defaults to Analyze'
    $options.CbsPath = Join-Path $testRoot "CBS [GUI] & O'Brien!.log"
    $options.DismPath = Join-Path $testRoot 'DISM sample.log'
    $options.OutputDirectory = (Join-Path $testRoot 'reports [GUI] & spaced!') + '\'
    $options.CustomRange = $true; $options.Since = '2026-10-05'; $options.Until = '2026-10-06'
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllLines($options.CbsPath, @('2026-10-05 10:01:00, Info CSI [SR] Verifying components',
        '2026-10-05 10:02:00, Error CBS literal <script> & text', '2026-10-05 10:03:00, Warning CBS source warning'), $encoding)
    [IO.File]::WriteAllLines($options.DismPath, @('2026-10-05 10:04:00, Error DISM source error', '2026-10-05 10:05:00, Warning DISM source warning'), $encoding)
    $request = Get-FileScanGuiRequest $options
    Assert-True ($request.Mode -eq 'Analyze' -and $request.NonInteractive -and $request.NoElevate) 'GUI worker is unattended and cannot request UAC'
    Assert-True ($request.Since -eq '2026-10-05' -and $request.Until -eq '2026-10-06') 'Date options forwarded'
    $options.Mode = 'Repair'; $options.SourceType = 'WIM'; $options.SourcePath = 'D:\Repair files\install.wim'; $options.ImageIndex = '2'; $options.LimitAccess = $true
    $repair = Get-FileScanGuiRequest $options -DryRun
    Assert-True ($repair.Source -eq 'wim:D:\Repair files\install.wim:2' -and $repair.LimitAccess -and $repair.DryRun) 'WIM repair source and safe preview forwarded'
    $options.ImageIndex = '0'; Assert-Throws { Get-FileScanGuiRequest $options }
    $options.ImageIndex = '2'; $options.MaxEntries = '20001'; Assert-Throws { Get-FileScanGuiRequest $options }
    $options.MaxEntries = '5000'; $options.Since = 'bad'; Assert-Throws { Get-FileScanGuiRequest $options }
    $options.Since = '2026-10-05'; $options.Mode = 'Check'
    $check = Get-FileScanGuiRequest $options
    Assert-True (-not $check.ContainsKey('Source') -and -not $check.ContainsKey('LimitAccess')) 'Repair-only options do not leak into Check'
    $savedPath = Join-Path $testRoot 'settings.json'
    Save-FileScanGuiOptions $savedPath $options
    Assert-True ((Read-FileScanGuiOptions $savedPath).Mode -eq 'Analyze') 'Remembered settings do not reopen in Repair/Check'
    Assert-True ((Read-FileScanGuiOptions $savedPath -RestoreMode).Mode -eq 'Check') 'UAC handoff restores explicit selected mode'
    $options.Mode = 'Analyze'; $options.SourceType = 'Default'; $options.SourcePath = ''; $options.LimitAccess = $false
    Save-FileScanGuiOptions $savedPath $options
    $statusPath = Join-Path $testRoot 'status.json'; $sessionId = [guid]::NewGuid().ToString('N')
    Write-FileScanStatus $statusPath $sessionId @{ Phase = 'Preparing'; Message = 'Preparing' }
    Write-FileScanStatus $statusPath $sessionId @{ Phase = 'Completed'; Message = 'Complete' }
    $status = [IO.File]::ReadAllText($statusPath) | ConvertFrom-Json
    Assert-True ($status.SessionId -eq $sessionId -and $status.Phase -eq 'Completed') 'Status replacement is readable JSON'
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.tmp').Count -eq 0) 'Status writes leave no temporary files'
    $analysis = Get-FileScanAnalysis -CbsPath $options.CbsPath -DismPath $options.DismPath -Since ([datetime]'2026-10-05') -UntilExclusive ([datetime]'2026-10-07') -OnProgress { throw 'Simulated viewer failure' } 3>$null
    Assert-True ($analysis.Summary.MatchedEntries -eq 5) 'A viewer failure does not abort log analysis'
    Assert-True ((Get-FileScanExitCode -Commands @() -Analysis $analysis -Stopped) -eq 4) 'Cooperative stop has a separate exit code'
    $module = Get-Module FileScan.Core
    $original = & $module { (Get-Item Function:Invoke-FileScanCommand).ScriptBlock }
    try {
        & $module {
            $script:StopFlag = $false; $script:ToolCalls = 0
            function script:Invoke-FileScanCommand {
                param($Name, $FilePath, $Arguments, $OutputPath, $OnProgress)
                $script:ToolCalls++; $script:StopFlag = $true
                [pscustomobject]@{ Name = $Name; Status = 'Completed' }
            }
        }
        $stopCheck = & $module { { $script:StopFlag } }
        $plan = @(Get-FileScanPlan -Mode Repair)
        $results = @(Invoke-FileScanPlan -Plan $plan -SystemDirectory $testRoot -RunDirectory $testRoot -StopRequested $stopCheck)
        Assert-True ($results[0].Status -eq 'Completed' -and $results[1].Status -eq 'Skipped' -and $results[1].Stopped) 'Stop finishes the current command and skips the next'
        Assert-True ((& $module { $script:ToolCalls }) -eq 1) 'Stop never force-kills or invokes the later command'
    } finally { & $module { param($runner) Set-Item Function:script:Invoke-FileScanCommand $runner } $original }
    $screenshot = Join-Path $testRoot 'gui-preview.png'; $smokeResult = Join-Path $testRoot 'gui-smoke.json'
    $hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $guiRoot 'FileScan.Gui.ps1'),
        '-InitialSettings',$savedPath,'-SettingsDirectory',(Join-Path $testRoot 'ui'),'-SmokeTest','-ScreenshotPath',$screenshot,'-SmokeResultPath',$smokeResult)
    $run = Invoke-FileScanCommand -Name GuiSmoke -FilePath $hostPath -Arguments $arguments -OutputPath (Join-Path $testRoot 'smoke-output.txt')
    Assert-True ($run.ExitCode -eq 0) "GUI smoke test succeeds: $($run.Detail)"
    $smoke = [IO.File]::ReadAllText($smokeResult) | ConvertFrom-Json
    Assert-True ($smoke.Entries -eq 5 -and $smoke.ErrorRows -eq 2 -and $smoke.SearchRows -eq 1) 'Actual WPF results and literal search work'
    Assert-True ($smoke.PreviewExitCode -eq 0 -and $smoke.PreviewContainsRestoreHealth) 'Actual GUI Repair preview runs no servicing tools'
    Assert-True ($smoke.ColumnWidths[0] -ge 160 -and $smoke.ColumnWidths[1] -ge 60) 'WPF result columns render at readable widths'
    Assert-True ([IO.File]::Exists($screenshot) -and ([IO.FileInfo]$screenshot).Length -gt 1000) 'WPF UI renders a screenshot'
    Assert-True ([IO.File]::Exists([IO.Path]::ChangeExtension($screenshot, 'setup.png')) -and [IO.File]::Exists([IO.Path]::ChangeExtension($screenshot, 'repair.png'))) 'Setup and Repair views also render for visual review'
    $missingSettingsArguments = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $guiRoot 'FileScan.Gui.ps1'),
        '-InitialSettings',(Join-Path $testRoot 'missing.json'),'-SettingsDirectory',(Join-Path $testRoot 'ui'),'-Resume','-SmokeTest')
    $missingSettings = Invoke-FileScanCommand -Name GuiMissingSettings -FilePath $hostPath -Arguments $missingSettingsArguments -OutputPath (Join-Path $testRoot 'missing-settings-output.txt')
    Assert-True ($missingSettings.ExitCode -eq 1 -and [IO.File]::ReadAllText($missingSettings.OutputPath).Contains('original run settings')) 'An elevation handoff with missing settings fails before starting a run'
    $reports = @(Get-ChildItem -LiteralPath $options.OutputDirectory -Directory)
    Assert-True ($reports.Count -eq 1) 'Preview did not create a second report'
    $reportPath = Join-Path $reports[0].FullName 'file_scan.json'
    $report = Read-FileScanGuiReport $reportPath
    Assert-True ($report.Summary.Errors -eq 2) 'Saved report loads into the viewer model'
    $invalidReport = Join-Path $testRoot 'invalid-report.json'
    $report.Entries[0].PSObject.Properties.Remove('Message')
    [IO.File]::WriteAllText($invalidReport, ($report | ConvertTo-Json -Depth 8))
    Assert-Throws { Read-FileScanGuiReport $invalidReport }
    Assert-Throws { Export-FileScanGuiReport $reportPath $reportPath }
    [IO.File]::WriteAllText((Join-Path $reports[0].FullName 'private-unrelated.txt'), 'Do not export this unrelated file.')
    $zip = Join-Path $testRoot 'report.zip'
    Export-FileScanGuiReport $reportPath $zip
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        Assert-True ($archive.Entries.Count -eq 3) 'ZIP contains only text, JSON, and HTML for analysis'
        Assert-True (@($archive.Entries | Where-Object FullName -eq 'private-unrelated.txt').Count -eq 0) 'ZIP excludes unrelated files'
    } finally { $archive.Dispose() }
    Export-FileScanGuiReport $reportPath $zip
    Assert-True ([IO.File]::Exists($zip)) 'ZIP replacement succeeds without losing the previous archive early'
    Write-Host "PASS: $script:assertions GUI assertions. Only sample-log analysis and Repair dry runs executed." -ForegroundColor Green
    if ($KeepArtifacts) { Write-Host "Artifacts: $testRoot" }
} finally {
    if (-not $KeepArtifacts) {
        $fullPath = [IO.Path]::GetFullPath($testRoot)
        $allowedRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
        if (-not $fullPath.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'GUI test cleanup escaped the tests directory.' }
        if ([IO.Directory]::Exists($fullPath)) { Remove-Item -LiteralPath $fullPath -Recurse -Force }
    }
}
