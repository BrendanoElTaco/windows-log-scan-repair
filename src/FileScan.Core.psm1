#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:LogPattern = [regex]::new(
    '^(?<Time>\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d{1,7})?)[,\s]+(?<Level>Info|Warning|Error|Fatal)\b(?<Message>.*)',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

function Send-FileScanProgress {
    param([scriptblock]$Callback, [object]$Progress)
    if ($Callback) {
        try { [void](& $Callback $Progress) }
        catch { Write-Warning "Progress viewer could not update: $($_.Exception.Message)" }
    }
}

function ConvertTo-FileScanDate {
    param([string]$Value)
    $date = [datetime]::MinValue
    $formats = [string[]]@('yyyy-MM-dd', 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-dd HH:mm:ss')
    if (-not [datetime]::TryParseExact($Value, $formats, [cultureinfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$date)) {
        throw "Invalid date '$Value'. Use yyyy-MM-dd or yyyy-MM-ddTHH:mm:ss (local time)."
    }
    return $date
}

function Get-FileScanWindow {
    param([string]$Since, [string]$Until, [datetime]$DefaultSince = (Get-Date).Date,
        [datetime]$Now = (Get-Date))
    $start = $DefaultSince
    $end = $Now.AddTicks(-($Now.Ticks % [TimeSpan]::TicksPerSecond)).AddSeconds(1)
    if ($Since) { $start = ConvertTo-FileScanDate $Since }
    if ($Until) {
        $end = ConvertTo-FileScanDate $Until
        if ($Until.Length -eq 10) { $end = $end.AddDays(1) }
    }
    if ($start -ge $end) { throw 'Since must be earlier than the end of the selected time window.' }
    return [pscustomobject]@{ Since = $start; UntilExclusive = $end }
}

function Get-FileScanPlan {
    param([ValidateSet('Analyze', 'Check', 'Repair')][string]$Mode,
        [string]$Source, [switch]$LimitAccess)
    if (($Source -or $LimitAccess) -and $Mode -ne 'Repair') {
        throw 'Source and LimitAccess apply only to Repair mode.'
    }
    if ($Source -match '["\r\n\x00]') { throw 'Source cannot contain quotes, line breaks, or null characters.' }
    if ($Mode -eq 'Analyze') { return }
    if ($Mode -eq 'Check') {
        [pscustomobject]@{ Name = 'DISM'; Arguments = [string[]]@('/Online', '/Cleanup-Image', '/ScanHealth') }
        [pscustomobject]@{ Name = 'SFC'; Arguments = [string[]]@('/verifyonly') }
    } else {
        $arguments = @('/Online', '/Cleanup-Image', '/RestoreHealth')
        if ($Source) { $arguments += "/Source:$Source" }
        if ($LimitAccess) { $arguments += '/LimitAccess' }
        [pscustomobject]@{ Name = 'DISM'; Arguments = [string[]]$arguments }
        [pscustomobject]@{ Name = 'SFC'; Arguments = [string[]]@('/scannow') }
    }
}

function ConvertFrom-FileScanLine {
    param([string]$Line, [string]$Source, [string]$Path, [long]$LineNumber,
        [datetime]$Since, [datetime]$UntilExclusive, [switch]$IncludeInfo)
    $match = $script:LogPattern.Match($Line)
    if (-not $match.Success) { return }
    $timestamp = [datetime]::MinValue
    $timeText = $match.Groups['Time'].Value.Replace(',', '.')
    if (-not [datetime]::TryParse($timeText, [cultureinfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$timestamp)) { return }
    if ($timestamp -lt $Since -or $timestamp -ge $UntilExclusive) { return }
    $level = $match.Groups['Level'].Value
    $level = switch ($level.ToLowerInvariant()) { 'warning' { 'Warning' } 'info' { 'Info' } default { 'Error' } }
    $message = $match.Groups['Message'].Value.Trim()
    $event = ''
    $interpretation = ''
    if ($Source -eq 'CBS') {
        if ($message -match 'Cannot repair member file') {
            $event = 'Unrepairable'; $interpretation = 'SFC reported a file it could not repair at this point.'
        } elseif ($message -match 'Repairing corrupted file|Repaired the file') {
            $event = 'Repair'; $interpretation = 'A file repair was reported; review subsequent verification.'
        } elseif ($message -match '\[SR\].*Verify and Repair Transaction completed') {
            $event = 'RepairCompleted'; $interpretation = 'An SFC verification/repair transaction completed.'
        } elseif ($message -match '\[SR\].*Beginning Verify and Repair transaction') {
            $event = 'RepairStarted'; $interpretation = 'An SFC verification/repair transaction began.'
        } elseif ($message -match '\[SR\].*Verifying') {
            $event = 'Verification'; $interpretation = 'SFC is verifying protected components.'
        }
    }
    if ($level -eq 'Info' -and -not $IncludeInfo -and -not $event -and
        -not ($Source -eq 'CBS' -and $message -match '\[SR\]')) { return }
    [pscustomobject]@{
        Timestamp = $timestamp.ToString('yyyy-MM-ddTHH:mm:ss.fffffff', [cultureinfo]::InvariantCulture)
        Source = $Source; Path = $Path; LineNumber = $LineNumber; Severity = $level
        Event = $event; Interpretation = $interpretation; Message = $message; Raw = $Line
    }
}

function Get-FileScanAnalysis {
    param([string]$CbsPath, [string]$DismPath, [datetime]$Since, [datetime]$UntilExclusive,
        [ValidateRange(1, 100000)][int]$MaxEntries = 5000,
        [switch]$IncludeInfo, [switch]$IncludeHistory, [scriptblock]$OnProgress)
    $sources = [Collections.Generic.List[object]]::new()
    $files = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($spec in @(@{ Name = 'CBS'; Path = $CbsPath }, @{ Name = 'DISM'; Path = $DismPath })) {
        $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($spec.Path)
        if ($seen.Add($fullPath)) { $files.Add(@{ Name = $spec.Name; Path = $fullPath }) }
        if ($IncludeHistory) {
            $directory = [IO.Path]::GetDirectoryName($fullPath)
            $pattern = if ($spec.Name -eq 'CBS') { 'CbsPersist*.log' } else { 'dism.log.bak' }
            try {
                $archives = @(Get-ChildItem -LiteralPath $directory -Filter $pattern -File -ErrorAction Stop |
                    Sort-Object Name)
                foreach ($archive in $archives) {
                    if ($seen.Add($archive.FullName)) { $files.Add(@{ Name = $spec.Name; Path = $archive.FullName }) }
                }
            } catch {
                $sources.Add([pscustomobject]@{ Name = $spec.Name; Path = (Join-Path $directory $pattern)
                    Status = 'Unreadable'; LinesRead = 0; MatchedEntries = 0; Detail = $_.Exception.Message })
            }
        }
    }
    # Keep the newest N matches across all files, while counting every match.
    # SortedDictionary gives bounded memory and O(log N) insertion even for huge logs.
    $retained = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::Ordinal)
    $summary = [ordered]@{ MatchedEntries = 0L; Errors = 0L; Warnings = 0L; SfcEntries = 0L
        RepairEvents = 0L; UnrepairableEvents = 0L; OmittedEntries = 0L }
    foreach ($file in $files) {
        $source = [pscustomobject]@{ Name = $file.Name; Path = $file.Path; Status = 'Read'
            LinesRead = 0L; MatchedEntries = 0L; Detail = '' }
        $stream = $null
        $reader = $null
        Send-FileScanProgress $OnProgress ([pscustomobject]@{ Phase = 'Analyzing'; Message = "Reading $($file.Name) log"; SourcePath = $file.Path; LinesRead = 0 })
        try {
            # Servicing tools can still be writing or rotating a log during analysis.
            $stream = [IO.File]::Open($file.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
            while ($null -ne ($line = $reader.ReadLine())) {
                $source.LinesRead++
                if ($OnProgress -and $source.LinesRead % 1000 -eq 0) {
                    Send-FileScanProgress $OnProgress ([pscustomobject]@{ Phase = 'Analyzing'; Message = "Reading $($file.Name) log"; SourcePath = $file.Path; LinesRead = $source.LinesRead })
                }
                $entry = ConvertFrom-FileScanLine -Line $line -Source $file.Name -Path $file.Path `
                    -LineNumber $source.LinesRead -Since $Since -UntilExclusive $UntilExclusive -IncludeInfo:$IncludeInfo
                if ($null -eq $entry) { continue }
                $source.MatchedEntries++
                $summary.MatchedEntries++
                if ($entry.Severity -eq 'Error') { $summary.Errors++ }
                if ($entry.Severity -eq 'Warning') { $summary.Warnings++ }
                if ($entry.Source -eq 'CBS' -and $entry.Message -match '\[SR\]') { $summary.SfcEntries++ }
                if ($entry.Event -eq 'Repair') { $summary.RepairEvents++ }
                if ($entry.Event -eq 'Unrepairable') { $summary.UnrepairableEvents++ }
                $key = '{0}|{1:D20}' -f $entry.Timestamp, $summary.MatchedEntries
                $retained.Add($key, $entry)
                if ($retained.Count -gt $MaxEntries) {
                    $iterator = $retained.Keys.GetEnumerator()
                    try { [void]$iterator.MoveNext(); $oldest = $iterator.Current } finally { $iterator.Dispose() }
                    [void]$retained.Remove($oldest)
                }
            }
        } catch [IO.FileNotFoundException] {
            $source.Status = 'Missing'; $source.Detail = $_.Exception.Message
        } catch [IO.DirectoryNotFoundException] {
            $source.Status = 'Missing'; $source.Detail = $_.Exception.Message
        } catch {
            $source.Status = 'Unreadable'; $source.Detail = $_.Exception.Message
        } finally {
            if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
        }
        $sources.Add($source)
    }
    $summary.OmittedEntries = $summary.MatchedEntries - $retained.Count
    [pscustomobject]@{ Sources = @($sources.ToArray()); Summary = [pscustomobject]$summary
        Entries = @($retained.Values | ForEach-Object { $_ }) }
}

function ConvertTo-FileScanNativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW rules: double slashes before quotes and before
    # the closing quote. Always quote, including empty values and paths with spaces.
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-FileScanCommand {
    param([string]$Name, [string]$FilePath, [string[]]$Arguments, [string]$OutputPath, [scriptblock]$OnProgress)
    $start = Get-Date
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::new()
    $exitCode = $null
    $status = 'Failed'
    $detail = ''
    $output = ''
    try {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $FilePath
        $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-FileScanNativeArgument $_ }) -join ' '
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        # SFC emits UTF-16 when redirected; DISM uses the console encoding.
        $info.StandardOutputEncoding = if ($Name -eq 'SFC') { [Text.Encoding]::Unicode } else { [Console]::OutputEncoding }
        $info.StandardErrorEncoding = $info.StandardOutputEncoding
        $process.StartInfo = $info
        Write-Host ("Running {0} {1}" -f $Name, ($Arguments -join ' ')) -ForegroundColor Cyan
        [void]$process.Start()
        Send-FileScanProgress $OnProgress ([pscustomobject]@{ Phase = 'Running'; Message = "Running $Name"; Command = $Name; DurationSeconds = 0 })
        # Drain both pipes concurrently so verbose output cannot deadlock the child.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(500)) {
            Write-Progress -Activity "Running $Name" -Status ("Elapsed: {0:n0}s. Servicing can take several minutes." -f $watch.Elapsed.TotalSeconds)
            Send-FileScanProgress $OnProgress ([pscustomobject]@{ Phase = 'Running'; Message = "Running $Name"; Command = $Name; DurationSeconds = [int]$watch.Elapsed.TotalSeconds })
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        if ($errorOutput) { $output += "`r`nSTDERR:`r`n$errorOutput" }
        $exitCode = $process.ExitCode
        if ($exitCode -eq 0 -or ($Name -eq 'DISM' -and $exitCode -eq 3010)) { $status = 'Completed' }
        $detail = "Process exit code: $exitCode. Review command output and logs for the health result."
    } catch {
        $detail = $_.Exception.Message
        $output += "`r`nCommand failed: $detail"
    } finally {
        $watch.Stop()
        Write-Progress -Activity "Running $Name" -Completed
        $process.Dispose()
    }
    [IO.File]::WriteAllText($OutputPath, $output, [Text.UTF8Encoding]::new($false))
    if ($output) { Write-Host $output.TrimEnd() }
    [pscustomobject]@{ Name = $Name; Arguments = @($Arguments); Status = $status; ExitCode = $exitCode
        StartedAt = $start.ToString('o'); DurationSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
        RebootRequired = ($Name -eq 'DISM' -and $exitCode -eq 3010); OutputPath = $OutputPath; Detail = $detail }
}

function Get-FileScanExitCode {
    param([object[]]$Commands, [object]$Analysis, [switch]$FailOnFindings, [switch]$Stopped)
    if (@($Commands | Where-Object Status -eq 'Failed').Count) { return 1 }
    if ($Stopped) { return 4 }
    if (@($Analysis.Sources | Where-Object Status -ne 'Read').Count) { return 2 }
    if ($FailOnFindings -and ($Analysis.Summary.Errors -gt 0 -or $Analysis.Summary.Warnings -gt 0 -or
            $Analysis.Summary.UnrepairableEvents -gt 0)) { return 3 }
    return 0
}

function Invoke-FileScanPlan {
    param([object[]]$Plan, [string]$SystemDirectory, [string]$RunDirectory,
        [scriptblock]$OnProgress, [scriptblock]$StopRequested)
    $failed = $false
    foreach ($step in $Plan) {
        $stop = $StopRequested -and (& $StopRequested)
        if ($failed -or $stop) {
            [pscustomobject]@{ Name = $step.Name; Arguments = $step.Arguments; Status = 'Skipped'
                ExitCode = $null; StartedAt = $null; DurationSeconds = 0; RebootRequired = $false; OutputPath = ''
                Stopped = [bool]$stop; Detail = $(if ($stop) { 'Skipped at user request after the current command.' } else { 'Skipped because the preceding command failed.' }) }
            continue
        }
        $result = Invoke-FileScanCommand -Name $step.Name -FilePath (Join-Path $SystemDirectory ($step.Name + '.exe')) `
            -Arguments $step.Arguments -OutputPath (Join-Path $RunDirectory ($step.Name.ToLowerInvariant() + '-output.txt')) -OnProgress $OnProgress
        $result
        $failed = $result.Status -eq 'Failed'
    }
}

function Write-FileScanStatus {
    param([string]$Path, [string]$SessionId, [hashtable]$Data)
    if (-not $Path) { return }
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $value = @{ SchemaVersion = 1; SessionId = $SessionId; UpdatedAt = (Get-Date).ToString('o') }
        foreach ($key in $Data.Keys) { $value[$key] = $Data[$key] }
        [IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } catch {
        # Monitoring is optional. A transient viewer read must not abort servicing.
        Write-Warning "Could not update progress: $($_.Exception.Message)"
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-FileScanElevationArguments {
    param([string]$ScriptPath, [System.Collections.IDictionary]$Parameters)
    # Use -File, never evaluate a command assembled from parameter values.
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($value in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)) { $arguments.Add($value) }
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $arguments.Add("-$key") }
        } else {
            $arguments.Add("-$key")
            $arguments.Add([string]$value)
        }
    }
    $arguments.ToArray()
}

function Write-FileScanReport {
    param([object]$Report, [string]$Directory)
    $text = [Text.StringBuilder]::new()
    [void]$text.AppendLine('WINDOWS FILE SCAN REPORT')
    foreach ($line in @("Generated: $($Report.GeneratedAt)", "Computer: $($Report.ComputerName)",
            "Mode: $($Report.Mode)", "Status: $($Report.Status) (exit $($Report.ExitCode))",
            "Window: $($Report.Window.Since) <= timestamp < $($Report.Window.UntilExclusive)",
            "Reboot required by a command: $($Report.RebootRequired)", '')) { [void]$text.AppendLine($line) }
    foreach ($item in $Report.Summary.PSObject.Properties) { [void]$text.AppendLine("$($item.Name): $($item.Value)") }
    [void]$text.AppendLine("`r`nCOMMANDS")
    if (-not $Report.Commands.Count) { [void]$text.AppendLine('No servicing commands were requested.') }
    foreach ($command in $Report.Commands) {
        [void]$text.AppendLine("$($command.Name) $($command.Arguments -join ' ') | $($command.Status) | $($command.Detail)")
        [void]$text.AppendLine("  Duration: $($command.DurationSeconds)s | Output: $($command.OutputPath)")
    }
    [void]$text.AppendLine("`r`nLOG SOURCES")
    foreach ($source in $Report.Sources) {
        [void]$text.AppendLine("$($source.Name): $($source.Path) | $($source.Status) | $($source.LinesRead) lines read | $($source.MatchedEntries) matches")
        if ($source.Detail) { [void]$text.AppendLine("  $($source.Detail)") }
    }
    [void]$text.AppendLine("`r`nNOTES")
    foreach ($note in $Report.Notes) { [void]$text.AppendLine("- $note") }
    [void]$text.AppendLine("`r`nLOG ENTRIES (oldest to newest; newest $($Report.Entries.Count) retained)")
    foreach ($entry in $Report.Entries) {
        [void]$text.AppendLine("[$($entry.Source) | $($entry.Path):$($entry.LineNumber)] $($entry.Raw)")
        if ($entry.Interpretation) { [void]$text.AppendLine("  $($entry.Interpretation)") }
    }
    if (-not $Report.Entries.Count) { [void]$text.AppendLine('No matching entries in the readable sources and selected window.') }

    # Encode every value from logs, paths, and process output before placing it in HTML.
    $encode = { param($value) [Net.WebUtility]::HtmlEncode([string]$value) }
    $html = [Text.StringBuilder]::new()
    [void]$html.AppendLine(@'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<title>Windows File Scan Report</title><style>
:root{color-scheme:light dark}body{font:16px/1.5 system-ui,sans-serif;max-width:1200px;margin:40px auto;padding:0 24px}
h1{margin-bottom:0}h2{margin-top:36px}.muted{opacity:.75}.cards{display:flex;flex-wrap:wrap;gap:12px;margin:24px 0}
.card{border:1px solid #8886;border-radius:10px;padding:14px;min-width:125px}.card strong{display:block;font-size:28px}
table{border-collapse:collapse;width:100%;font-size:14px}th,td{text-align:left;border-bottom:1px solid #8886;padding:10px;vertical-align:top}
td{overflow-wrap:anywhere}th{white-space:nowrap}.Error,.Failed,.Missing,.Unreadable{color:#df5555;font-weight:700}
.Warning{color:#ab740c;font-weight:700}.message{white-space:pre-wrap}details{margin:10px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere}
@media(max-width:700px){body{padding:0 12px}table{display:block;overflow-x:auto}th,td{min-width:90px}}
@media print{body{margin:0;max-width:none;font-size:11px}details{display:block}.cards{break-inside:avoid}}
</style></head><body><h1>Windows File Scan</h1>
'@)
    [void]$html.AppendLine("<p class='muted'>$(& $encode $Report.ComputerName) &middot; $(& $encode $Report.Mode) &middot; $(& $encode $Report.GeneratedAt)</p>")
    [void]$html.AppendLine("<p><strong>$(& $encode $Report.Status)</strong> &middot; Exit code $($Report.ExitCode) &middot; Reboot requested: $($Report.RebootRequired)</p>")
    [void]$html.AppendLine("<p>Window: $(& $encode $Report.Window.Since) &le; timestamp &lt; $(& $encode $Report.Window.UntilExclusive)</p><div class='cards'>")
    $metrics = [ordered]@{ MatchedEntries = 'Matching entries'; Errors = 'Errors'; Warnings = 'Warnings'
        SfcEntries = 'SFC entries'; RepairEvents = 'File repairs'; UnrepairableEvents = 'Unrepairable reports'; OmittedEntries = 'Entries omitted' }
    foreach ($metric in $metrics.Keys) {
        [void]$html.AppendLine("<div class='card'><strong>$($Report.Summary.$metric)</strong>$($metrics[$metric])</div>")
    }
    [void]$html.AppendLine('</div><h2>What these results mean</h2><ul>')
    foreach ($note in $Report.Notes) { [void]$html.AppendLine("<li>$(& $encode $note)</li>") }
    [void]$html.AppendLine('</ul><h2>Commands</h2>')
    if (-not $Report.Commands.Count) { [void]$html.AppendLine('<p>No servicing commands were requested.</p>') }
    foreach ($command in $Report.Commands) {
        [void]$html.AppendLine("<details open><summary>$(& $encode $command.Name) $(& $encode ($command.Arguments -join ' ')) &mdash; $(& $encode $command.Status)</summary>")
        [void]$html.AppendLine("<p>$(& $encode $command.Detail) Duration: $($command.DurationSeconds)s.</p><p>Output file: $(& $encode $command.OutputPath)</p></details>")
    }
    [void]$html.AppendLine('<h2>Log sources</h2><table><thead><tr><th>Source</th><th>Path</th><th>Status</th><th>Read / matched</th></tr></thead><tbody>')
    foreach ($source in $Report.Sources) {
        [void]$html.AppendLine("<tr><td>$(& $encode $source.Name)</td><td>$(& $encode $source.Path)</td><td class='$($source.Status)'>$(& $encode $source.Status)<br>$(& $encode $source.Detail)</td><td>$($source.LinesRead) / $($source.MatchedEntries)</td></tr>")
    }
    [void]$html.AppendLine("</tbody></table><h2>Log entries</h2><p>Newest $($Report.Entries.Count) matches retained, shown oldest to newest. Counts include omitted entries.</p>")
    if (-not $Report.Entries.Count) { [void]$html.AppendLine('<p>No matching entries in the readable sources and selected window.</p>') }
    [void]$html.AppendLine('<table><thead><tr><th>Time / source</th><th>Severity</th><th>Entry</th></tr></thead><tbody>')
    foreach ($entry in $Report.Entries) {
        [void]$html.AppendLine("<tr><td>$(& $encode $entry.Timestamp)<br>$(& $encode $entry.Source):$($entry.LineNumber)</td><td class='$($entry.Severity)'>$(& $encode $entry.Severity)</td><td class='message'>$(& $encode $entry.Message)<br><span class='muted'>$(& $encode $entry.Interpretation)</span></td></tr>")
    }
    [void]$html.AppendLine('</tbody></table></body></html>')
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $Directory 'file_scan.log'), $text.ToString(), $encoding)
    [IO.File]::WriteAllText((Join-Path $Directory 'file_scan.json'), ($Report | ConvertTo-Json -Depth 8), $encoding)
    [IO.File]::WriteAllText((Join-Path $Directory 'file_scan.html'), $html.ToString(), $encoding)
}

Export-ModuleMember -Function Get-FileScanWindow, Get-FileScanPlan, ConvertFrom-FileScanLine,
    Get-FileScanAnalysis, ConvertTo-FileScanNativeArgument, Invoke-FileScanCommand,
    Invoke-FileScanPlan, Get-FileScanElevationArguments, Get-FileScanExitCode, Write-FileScanReport, Write-FileScanStatus
