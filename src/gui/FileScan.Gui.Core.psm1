#Requires -Version 5.1
Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'FileScan.Core.psm1')

function New-FileScanGuiOptions {
    @{
        Mode = 'Analyze'; CustomRange = $false; Since = (Get-Date -Format 'yyyy-MM-dd'); Until = ''
        CbsPath = (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'); DismPath = (Join-Path $env:SystemRoot 'Logs\DISM\dism.log')
        OutputDirectory = (Join-Path $env:LOCALAPPDATA 'FileScan\Reports'); MaxEntries = '5000'
        SourceType = 'Default'; SourcePath = ''; ImageIndex = '1'; LimitAccess = $false
        IncludeHistory = $false; IncludeInfo = $false; FailOnFindings = $false
    }
}

function Read-FileScanGuiJson {
    param([string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = $null
    try {
        if ($stream.Length -gt 64MB) { throw 'This file exceeds the 64 MB viewer limit. Use the text or HTML report.' }
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        $reader.ReadToEnd() | ConvertFrom-Json
    } finally { if ($reader) { $reader.Dispose() } else { $stream.Dispose() } }
}

function Read-FileScanGuiOptions {
    param([string]$Path, [switch]$RestoreMode)
    $options = New-FileScanGuiOptions
    if ([IO.File]::Exists($Path)) {
        $saved = Read-FileScanGuiJson $Path
        foreach ($key in @($options.Keys)) {
            if ($saved.PSObject.Properties[$key]) { $options[$key] = $saved.$key }
        }
    }
    if (-not $RestoreMode) { $options.Mode = 'Analyze' }
    $options
}

function Save-FileScanGuiOptions {
    param([string]$Path, [hashtable]$Options)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Options | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Get-FileScanGuiRequest {
    param([hashtable]$Options, [switch]$DryRun)
    if ($Options.Mode -notin @('Analyze', 'Check', 'Repair')) { throw 'Choose Analyze, Check, or Repair.' }
    $maximum = 0
    if (-not [int]::TryParse([string]$Options.MaxEntries, [ref]$maximum) -or $maximum -lt 1 -or $maximum -gt 20000) {
        throw 'Retained entries must be a whole number between 1 and 20000.'
    }
    $request = @{ Mode = $Options.Mode; MaxEntries = $maximum; NonInteractive = [switch]$true; NoElevate = [switch]$true }
    foreach ($key in @('CbsPath', 'DismPath', 'OutputDirectory')) {
        if ([string]::IsNullOrWhiteSpace([string]$Options[$key])) { throw "$key cannot be empty." }
        $request[$key] = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$Options[$key])
    }
    if ($request.CbsPath -eq $request.DismPath) { throw 'Choose different CBS and DISM log files.' }
    if ($Options.CustomRange) {
        if (-not $Options.Since -and -not $Options.Until) { throw 'Enter a start date or end date for the custom range.' }
        $defaultStart = if ($Options.Mode -eq 'Analyze') { (Get-Date).Date } else { Get-Date }
        [void](Get-FileScanWindow -Since $Options.Since -Until $Options.Until -DefaultSince $defaultStart)
        if ($Options.Since) { $request.Since = [string]$Options.Since }
        if ($Options.Until) { $request.Until = [string]$Options.Until }
    }
    foreach ($key in @('IncludeHistory', 'IncludeInfo', 'FailOnFindings')) {
        if ($Options[$key]) { $request[$key] = [switch]$true }
    }
    if ($Options.Mode -eq 'Repair') {
        if ($Options.SourceType -notin @('Default', 'Folder', 'WIM', 'ESD')) { throw 'Choose a supported repair source type.' }
        if ($Options.SourceType -ne 'Default') {
            if ([string]::IsNullOrWhiteSpace([string]$Options.SourcePath)) { throw 'Choose a repair source path.' }
            $source = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$Options.SourcePath)
            if ($Options.SourceType -in @('WIM', 'ESD')) {
                $index = 0
                if (-not [int]::TryParse([string]$Options.ImageIndex, [ref]$index) -or $index -lt 1) { throw 'Image index must be a positive whole number.' }
                $source = '{0}:{1}:{2}' -f $Options.SourceType.ToLowerInvariant(), $source, $index
            }
            $request.Source = $source
        }
        if ($Options.LimitAccess) { $request.LimitAccess = [switch]$true }
    }
    [void]@(Get-FileScanPlan -Mode $request.Mode -Source $request['Source'] -LimitAccess:([bool]$request['LimitAccess']))
    if ($DryRun) { $request.DryRun = [switch]$true }
    $request
}

function Start-FileScanGuiJob {
    param([hashtable]$Request, [string]$SessionDirectory)
    $id = [guid]::NewGuid().ToString('N')
    $directory = Join-Path $SessionDirectory $id
    [void][IO.Directory]::CreateDirectory($directory)
    $parameters = @{}
    foreach ($key in $Request.Keys) { $parameters[$key] = $Request[$key] }
    $parameters.StatusPath = Join-Path $directory 'status.json'; $parameters.CancelPath = Join-Path $directory 'stop.txt'; $parameters.SessionId = $id
    $hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $nativeHost = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if ([IO.File]::Exists($nativeHost)) { $hostPath = $nativeHost }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $hostPath
    $info.Arguments = (Get-FileScanElevationArguments -ScriptPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'FileScan.ps1') -Parameters $parameters |
        ForEach-Object { ConvertTo-FileScanNativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Console]::OutputEncoding; $info.StandardErrorEncoding = [Console]::OutputEncoding
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    try { [void]$process.Start() } catch { $process.Dispose(); throw }
    [pscustomobject]@{ Id = $id; Process = $process; Request = $Request; Directory = $directory
        StatusPath = $parameters.StatusPath; CancelPath = $parameters.CancelPath; StartedAt = (Get-Date)
        StdoutTask = $process.StandardOutput.ReadLineAsync(); StderrTask = $process.StandardError.ReadLineAsync()
        StdoutClosed = $false; StderrClosed = $false; Log = [Text.StringBuilder]::new(); Status = $null
        ReportDirectory = ''; Finished = $false; ExitCode = $null; StopRequested = $false }
}

function Update-FileScanGuiJob {
    param([object]$Job)
    foreach ($channel in @('Stdout', 'Stderr')) {
        $taskName = $channel + 'Task'; $closedName = $channel + 'Closed'
        for ($i = 0; $i -lt 200 -and -not $Job.$closedName -and $Job.$taskName.IsCompleted; $i++) {
            try { $line = $Job.$taskName.GetAwaiter().GetResult() }
            catch { $line = "Could not read command output: $($_.Exception.Message)"; $Job.$closedName = $true }
            if ($null -eq $line) { $Job.$closedName = $true; break }
            if ($line.Length -gt 4000) { $line = $line.Substring(0, 4000) + ' [line shortened in viewer]' }
            [void]$Job.Log.AppendLine($line)
            if (-not $Job.$closedName) {
                $reader = if ($channel -eq 'Stdout') { $Job.Process.StandardOutput } else { $Job.Process.StandardError }
                $Job.$taskName = $reader.ReadLineAsync()
            }
        }
    }
    if ($Job.Log.Length -gt 150000) {
        [void]$Job.Log.Remove(0, $Job.Log.Length - 140000)
        [void]$Job.Log.Insert(0, "[Earlier console output hidden. Saved reports retain the full results.]`r`n")
    }
    if ([IO.File]::Exists($Job.StatusPath)) {
        try {
            $status = Read-FileScanGuiJson $Job.StatusPath
            if ($status.SessionId -eq $Job.Id -and $status.SchemaVersion -eq 1) {
                $Job.Status = $status
                if ($status.PSObject.Properties['ReportDirectory'] -and $status.ReportDirectory) {
                    $path = [IO.Path]::GetFullPath([string]$status.ReportDirectory)
                    if ([IO.Path]::GetDirectoryName($path).TrimEnd('\') -eq $Job.Request.OutputDirectory.TrimEnd('\') -and
                        [IO.Path]::GetFileName($path) -match '^file-scan-\d{8}-\d{6}-[0-9a-f]{8}$') { $Job.ReportDirectory = $path }
                }
            }
        } catch { } # Atomic replacement may race a poll; retry on the next timer tick.
    }
    if ($Job.Process.HasExited -and $Job.StdoutClosed -and $Job.StderrClosed) {
        $Job.ExitCode = $Job.Process.ExitCode; $Job.Finished = $true
    }
}

function Stop-FileScanGuiJob {
    param([object]$Job)
    if ($Job.Finished -or $Job.Request.Mode -eq 'Analyze' -or $Job.Request['DryRun']) { return }
    [IO.File]::WriteAllText($Job.CancelPath, 'Stop after the current servicing command.')
    $Job.StopRequested = $true
}

function Read-FileScanGuiReport {
    param([string]$Path)
    $report = Read-FileScanGuiJson $Path
    if (-not $report.PSObject.Properties['SchemaVersion'] -or $report.SchemaVersion -ne 1 -or -not $report.PSObject.Properties['Summary'] -or
        -not $report.PSObject.Properties['Entries'] -or -not $report.PSObject.Properties['Sources']) { throw 'Choose a FileScan JSON report (schema version 1).' }
    foreach ($key in @('Mode','Status','GeneratedAt')) {
        if (-not $report.PSObject.Properties[$key]) { throw "The report is missing $key." }
    }
    foreach ($key in @('MatchedEntries', 'Errors', 'Warnings', 'UnrepairableEvents', 'OmittedEntries')) {
        $count = 0L
        if (-not $report.Summary.PSObject.Properties[$key] -or -not [long]::TryParse([string]$report.Summary.$key, [ref]$count) -or $count -lt 0) { throw 'The report has invalid summary counts.' }
    }
    foreach ($entry in $report.Entries) {
        if ($null -eq $entry) { throw 'The report contains an empty entry.' }
        foreach ($key in @('Timestamp','Source','Severity','Message','Interpretation','Path','LineNumber','Raw')) {
            if (-not $entry.PSObject.Properties[$key]) { throw "A report entry is missing $key." }
        }
        if ($entry.Severity -notin @('Info','Warning','Error')) { throw 'The report contains an unsupported severity.' }
    }
    $report
}

function Export-FileScanGuiReport {
    param([string]$ReportPath, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $directory = [IO.Path]::GetDirectoryName($ReportPath)
    $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$files.Add($ReportPath)
    foreach ($name in @('file_scan.log', 'file_scan.html', 'dism-output.txt', 'sfc-output.txt')) {
        $path = Join-Path $directory $name
        if ([IO.File]::Exists($path)) { [void]$files.Add($path) }
    }
    if ($files.Contains([IO.Path]::GetFullPath($Destination))) { throw 'Choose a ZIP filename separate from the report files.' }
    $temporary = $Destination + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
        foreach ($file in $files) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file, [IO.Path]::GetFileName($file), [IO.Compression.CompressionLevel]::Optimal) }
        $archive.Dispose(); $archive = $null
        if ([IO.File]::Exists($Destination)) { [IO.File]::Replace($temporary, $Destination, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Destination) }
    } finally {
        if ($archive) { $archive.Dispose() }
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

Export-ModuleMember -Function New-FileScanGuiOptions, Read-FileScanGuiOptions, Save-FileScanGuiOptions,
    Get-FileScanGuiRequest, Start-FileScanGuiJob, Update-FileScanGuiJob, Stop-FileScanGuiJob,
    Read-FileScanGuiReport, Export-FileScanGuiReport
