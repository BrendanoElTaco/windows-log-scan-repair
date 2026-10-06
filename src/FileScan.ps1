#Requires -Version 5.1
<#
.SYNOPSIS
Check or repair Windows integrity and summarize CBS/DISM logs.
.DESCRIPTION
Without arguments, shows a menu. Analyze reads logs, Check runs DISM ScanHealth
and SFC verifyonly, and Repair runs DISM RestoreHealth followed by SFC scannow.
Reports are saved as text, JSON, and standalone HTML in a unique run folder.
.EXAMPLE
.\src\FileScan.ps1 -Mode Analyze -Since 2026-10-01 -Until 2026-10-06 -IncludeHistory
.EXAMPLE
.\src\FileScan.ps1 -Mode Repair -Source 'wim:D:\sources\install.wim:1' -LimitAccess -DryRun
.EXAMPLE
.\src\FileScan.ps1 -Mode Analyze -NonInteractive -FailOnFindings
#>
[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Analyze', 'Check', 'Repair')][string]$Mode = 'Interactive',
    [string]$Since,
    [string]$Until,
    [string]$CbsPath = (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'),
    [string]$DismPath = (Join-Path $env:SystemRoot 'Logs\DISM\dism.log'),
    [string]$OutputDirectory = (Join-Path $env:LOCALAPPDATA 'FileScan\Reports'),
    [ValidateRange(1, 100000)][int]$MaxEntries = 5000,
    [string]$Source,
    [switch]$LimitAccess,
    [switch]$IncludeHistory,
    [switch]$IncludeInfo,
    [switch]$NonInteractive,
    [switch]$NoElevate,
    [switch]$OpenReport,
    [switch]$FailOnFindings,
    [switch]$DryRun,
    [Parameter(DontShow=$true)][string]$StatusPath,
    [Parameter(DontShow=$true)][string]$CancelPath,
    [Parameter(DontShow=$true)][string]$SessionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$mutex = $null
$ownsMutex = $false
$runDirectory = ''
$interactive = $Mode -eq 'Interactive' -and -not $NonInteractive

try {
    Import-Module (Join-Path $PSScriptRoot 'FileScan.Core.psm1') -Force
    if ($StatusPath) {
        $StatusPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StatusPath)
        if ($SessionId -notmatch '^[0-9a-f]{32}$') { throw 'Progress sessions require a valid session ID.' }
    }
    if ($CancelPath) { $CancelPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CancelPath) }
    Write-FileScanStatus -Path $StatusPath -SessionId $SessionId -Data @{ Phase = 'Preparing'; Message = 'Validating options' }
    if ($env:OS -ne 'Windows_NT') { throw 'FileScan runs on Windows only.' }
    if ($interactive) {
        Write-Host "`nWindows File Scan" -ForegroundColor Cyan
        Write-Host '[A] Analyze existing logs   [C] Check integrity   [R] Repair integrity   [Q] Quit'
        do { $choice = (Read-Host 'Choose A, C, R, or Q').Trim().ToUpperInvariant() }
        while ($choice -notin @('A', 'C', 'R', 'Q'))
        if ($choice -eq 'Q') { exit 0 }
        $Mode = switch ($choice) { 'A' { 'Analyze' } 'C' { 'Check' } 'R' { 'Repair' } }
    } elseif ($Mode -eq 'Interactive') { $Mode = 'Analyze' }

    # Validate options and resolve relative paths before elevation changes the working directory.
    $runStarted = Get-Date
    $defaultSince = if ($Mode -eq 'Analyze') { $runStarted.Date } else { $runStarted.AddTicks(-($runStarted.Ticks % [TimeSpan]::TicksPerSecond)) }
    $window = Get-FileScanWindow -Since $Since -Until $Until -DefaultSince $defaultSince
    $plan = @(Get-FileScanPlan -Mode $Mode -Source $Source -LimitAccess:$LimitAccess)
    foreach ($name in @('CbsPath', 'DismPath', 'OutputDirectory')) {
        $value = Get-Variable -Name $name -ValueOnly
        if ([string]::IsNullOrWhiteSpace($value)) { throw "$name cannot be empty." }
        Set-Variable -Name $name -Value ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($value))
    }
    if ($Source) {
        if ($Source -match '^(?<Kind>wim|esd):(?<Image>.+):(?<Index>\d+)$') {
            $Source = '{0}:{1}:{2}' -f $Matches.Kind, $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Matches.Image), $Matches.Index
        } elseif ($Source -match '^(wim|esd):') { throw 'Image sources must use wim:path:index or esd:path:index.' }
        else { $Source = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Source) }
        $plan = @(Get-FileScanPlan -Mode $Mode -Source $Source -LimitAccess:$LimitAccess)
    }
    if ($NonInteractive -and $OpenReport) { throw 'OpenReport cannot be used with NonInteractive.' }
    if ($CbsPath -eq $DismPath) { throw 'CbsPath and DismPath must refer to different files.' }
    if ($DryRun) {
        Write-Host "Mode: $Mode | Output root: $OutputDirectory"
        Write-Host "Log window starts: $($window.Since.ToString('s')) | End: $(if ($Until) { $window.UntilExclusive.ToString('s') } else { 'end of run' })"
        foreach ($step in $plan) { Write-Host ("{0}.exe {1}" -f $step.Name, ($step.Arguments -join ' ')) }
        Write-Host "Read CBS: $CbsPath`nRead DISM: $DismPath"
        Write-Host 'Dry run complete. No commands, elevation, or report writes performed.'
        Write-FileScanStatus -Path $StatusPath -SessionId $SessionId -Data @{ Phase = 'Completed'; Message = 'Preview complete'; ExitCode = 0; ReportDirectory = '' }
        exit 0
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $isAdministrator = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
    if ($Mode -ne 'Analyze' -and -not $isAdministrator) {
        if ($NoElevate -or $NonInteractive) { throw 'Check/Repair requires Administrator access. Run from an elevated terminal; unattended runs never request UAC.' }
        # The child gets absolute paths, including the original caller's report folder.
        $forward = @{}
        foreach ($key in $PSBoundParameters.Keys) { $forward[$key] = $PSBoundParameters[$key] }
        $forward['Mode'] = $Mode
        $forward['CbsPath'] = $CbsPath; $forward['DismPath'] = $DismPath
        $forward['OutputDirectory'] = $OutputDirectory
        if ($Source) { $forward['Source'] = $Source }
        $elevationArguments = (Get-FileScanElevationArguments -ScriptPath $PSCommandPath -Parameters $forward |
            ForEach-Object { ConvertTo-FileScanNativeArgument $_ }) -join ' '
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe')) {
            $powershell = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        }
        Write-Host 'Requesting Administrator access for the selected mode...'
        try {
            $child = Start-Process -FilePath $powershell -ArgumentList $elevationArguments -Verb RunAs -Wait -PassThru
        } catch { throw "Elevation was cancelled or could not start: $($_.Exception.Message)" }
        exit $child.ExitCode
    }

    if ($plan.Count) {
        $mutex = [Threading.Mutex]::new($false, 'Global\WindowsFileScan.SystemScan')
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw 'Another FileScan integrity scan is already running. Wait for it to finish.' }
    }
    $runDirectory = Join-Path $OutputDirectory ('file-scan-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($runDirectory)
    $progressState = @{ LastUpdate = [datetime]::MinValue; Phase = '' }
    $progressCallback = {
        param($progress)
        if (-not $StatusPath) { return }
        if ($progress.Phase -ne $progressState.Phase -or ((Get-Date) - $progressState.LastUpdate).TotalSeconds -ge 1) {
            $progressState.Phase = $progress.Phase; $progressState.LastUpdate = Get-Date
            Write-FileScanStatus -Path $StatusPath -SessionId $SessionId -Data @{
                Phase = $progress.Phase; Message = $progress.Message; ReportDirectory = $runDirectory; Progress = $progress }
        }
    }.GetNewClosure()
    $stopCallback = { $CancelPath -and [IO.File]::Exists($CancelPath) }.GetNewClosure()
    $systemDirectory = Join-Path $env:SystemRoot 'System32'
    if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'Sysnative')) { $systemDirectory = Join-Path $env:SystemRoot 'Sysnative' }
    $commands = @(Invoke-FileScanPlan -Plan $plan -SystemDirectory $systemDirectory -RunDirectory $runDirectory -OnProgress $progressCallback -StopRequested $stopCallback)
    $stopped = @($commands | Where-Object { $_.PSObject.Properties['Stopped'] -and $_.Stopped }).Count -gt 0
    # Default scan windows end after the tools finish, including runs across midnight.
    $window = Get-FileScanWindow -Since $Since -Until $Until -DefaultSince $defaultSince
    Write-Host 'Analyzing servicing logs...'
    $analysis = Get-FileScanAnalysis -CbsPath $CbsPath -DismPath $DismPath -Since $window.Since `
        -UntilExclusive $window.UntilExclusive -MaxEntries $MaxEntries -IncludeInfo:$IncludeInfo -IncludeHistory:$IncludeHistory -OnProgress $progressCallback
    $exitCode = Get-FileScanExitCode -Commands $commands -Analysis $analysis -FailOnFindings:$FailOnFindings -Stopped:$stopped
    $status = switch ($exitCode) { 1 { 'Command failed' } 2 { 'Incomplete log analysis' } 3 { 'Findings require review' } 4 { 'Stopped after the current command' } default { 'Requested operations completed' } }
    $report = [pscustomobject]@{
        SchemaVersion = 1; GeneratedAt = (Get-Date).ToString('o'); ComputerName = $env:COMPUTERNAME
        OSVersion = [Environment]::OSVersion.VersionString; Mode = $Mode; Status = $status; ExitCode = $exitCode
        Stopped = $stopped
        RebootRequired = (@($commands | Where-Object RebootRequired).Count -gt 0)
        Window = [pscustomobject]@{ Since = $window.Since.ToString('s'); UntilExclusive = $window.UntilExclusive.ToString('s') }
        Summary = $analysis.Summary; Commands = $commands; Sources = $analysis.Sources; Entries = $analysis.Entries
        Notes = @(
            'Log findings and process exit codes alone do not establish system health. Review native tool output and later verification.'
            'Unrepairable events describe the file at that point in time; a later repair may have resolved it.'
            'Counts cover every matching entry. Excerpts retain only the newest MaxEntries matches, without deduplicating separate events.'
            'Only timestamped lines with an Info/Warning/Error/Fatal severity column are parsed. Untimestamped continuation lines are excluded; localized formats may need manual review.'
            'Active logs are read by default. IncludeHistory adds uncompressed CbsPersist*.log and dism.log.bak; compressed CAB archives are excluded.'
            'Log timestamps and date filters use local time. A file can change or rotate while it is being read.'
        )
    }
    Write-FileScanReport -Report $report -Directory $runDirectory
    Write-FileScanStatus -Path $StatusPath -SessionId $SessionId -Data @{ Phase = 'Completed'; Message = $status; ExitCode = $exitCode; ReportDirectory = $runDirectory }
    Write-Host ("{0}. Matches: {1} | Errors: {2} | Warnings: {3} | Omitted: {4}" -f $status,
        $analysis.Summary.MatchedEntries, $analysis.Summary.Errors, $analysis.Summary.Warnings, $analysis.Summary.OmittedEntries)
    foreach ($sourceResult in $analysis.Sources) {
        if ($sourceResult.Status -ne 'Read') { Write-Warning "$($sourceResult.Name) $($sourceResult.Status): $($sourceResult.Path)" }
    }
    Write-Host "Reports: $runDirectory" -ForegroundColor Cyan
    if ($report.RebootRequired) { Write-Warning 'DISM requested a restart. Restart when convenient; FileScan does not reboot automatically.' }
    if ($interactive -and -not $OpenReport) { $OpenReport = (Read-Host 'Open the HTML report? (Y/N)').Trim() -ieq 'Y' }
    if ($OpenReport) {
        try { Start-Process -FilePath (Join-Path $runDirectory 'file_scan.html') }
        catch { Write-Warning "Report saved, but could not open the viewer: $($_.Exception.Message)" }
    }
    exit $exitCode
} catch {
    if (Get-Command Write-FileScanStatus -ErrorAction SilentlyContinue) {
        Write-FileScanStatus -Path $StatusPath -SessionId $SessionId -Data @{ Phase = 'Failed'; Message = $_.Exception.Message; ExitCode = 1; ReportDirectory = $runDirectory }
    }
    Write-Error -Message ("FileScan: {0}" -f $_.Exception.Message) -ErrorAction Continue
    exit 1
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
