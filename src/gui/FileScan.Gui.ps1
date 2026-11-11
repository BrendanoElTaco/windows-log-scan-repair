#Requires -Version 5.1
<#
.SYNOPSIS
Open the native Windows FileScan interface.
.EXAMPLE
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\src\gui\FileScan.Gui.ps1
#>
[CmdletBinding()]
param(
    [string]$SettingsDirectory = (Join-Path $env:LOCALAPPDATA 'FileScan\UI'),
    [Parameter(DontShow=$true)][string]$InitialSettings,
    [Parameter(DontShow=$true)][switch]$Resume,
    [Parameter(DontShow=$true)][switch]$SmokeTest,
    [Parameter(DontShow=$true)][string]$ScreenshotPath,
    [Parameter(DontShow=$true)][string]$SmokeResultPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Ui = $null
$script:GuiScriptPath = $PSCommandPath

function Show-GuiError {
    param([string]$Message)
    if ($SmokeTest) {
        $script:Ui.SmokeError = $Message
        $script:Ui.AllowClose = $true
        if ($script:Ui.Job -and -not $script:Ui.Job.Process.HasExited -and
            ($script:Ui.Job.Request.Mode -eq 'Analyze' -or $script:Ui.Job.Request['DryRun'])) { $script:Ui.Job.Process.Kill() }
        $script:Ui.Window.Close()
    } else {
        $script:Ui.Controls.Status.Text = $Message
        [void][System.Windows.MessageBox]::Show($script:Ui.Window, $Message, 'FileScan', 'OK', 'Error')
    }
}

function Get-GuiOptions {
    $c = $script:Ui.Controls
    $options = New-FileScanGuiOptions
    $options.Mode = if ($c.RepairMode.IsChecked) { 'Repair' } elseif ($c.CheckMode.IsChecked) { 'Check' } else { 'Analyze' }
    foreach ($key in @('CbsPath','DismPath','OutputDirectory','Since','Until','MaxEntries','SourcePath','ImageIndex')) { $options[$key] = $c[$key].Text.Trim() }
    foreach ($key in @('CustomRange','IncludeHistory','IncludeInfo','FailOnFindings','LimitAccess')) { $options[$key] = [bool]$c[$key].IsChecked }
    $options.SourceType = [string]$c.SourceType.SelectedItem.Content
    $options
}

function Update-GuiMode {
    $c = $script:Ui.Controls
    $mode = (Get-GuiOptions).Mode
    $c.Heading.Text = switch ($mode) { 'Analyze' { 'Log inspection' } 'Check' { 'Integrity check' } 'Repair' { 'System repair' } }
    $c.Description.Text = switch ($mode) {
        'Analyze' { 'Explore servicing events without running an integrity scan.' }
        'Check' { 'Scan the component store and verify protected files without requesting repairs.' }
        'Repair' { 'Repair the component store, then repair protected system files.' }
    }
    $c.RunButton.Content = switch ($mode) { 'Analyze' { 'Analyze logs' } 'Check' { 'Run check' } 'Repair' { 'Run repair' } }
    $c.RepairOptions.IsEnabled = $mode -eq 'Repair'
    $c.RepairOptions.IsExpanded = $mode -eq 'Repair'
    $type = [string]$c.SourceType.SelectedItem.Content
    $c.SourcePath.IsEnabled = $type -ne 'Default'; $c.SourceBrowse.IsEnabled = $type -ne 'Default'
    $c.ImageIndex.IsEnabled = $type -in @('WIM','ESD')
    $c.DateFields.IsEnabled = [bool]$c.CustomRange.IsChecked
    $default = if ($mode -eq 'Analyze') { 'today' } else { 'the current run' }
    $c.DateHint.Text = "Default: $default. Use YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS (local time). End dates include the full day; end times are excluded."
}

function Set-GuiBusy {
    param([bool]$Busy)
    $c = $script:Ui.Controls
    foreach ($key in @('RunButton','PreviewButton','AnalyzeMode','CheckMode','RepairMode','SetupTab','LoadReportButton')) { $c[$key].IsEnabled = -not $Busy }
    $c.Progress.IsIndeterminate = $Busy
    if ($Busy) { $c.Progress.Value = 0 }
    $c.StopButton.IsEnabled = $false
}

function Refresh-GuiResults {
    if (-not $script:Ui.View) { return }
    $script:Ui.View.Refresh()
    $report = $script:Ui.Report
    $script:Ui.Controls.ResultsHint.Text = "Showing $($script:Ui.View.Count) of $(@($report.Entries).Count) retained entries; $($report.Summary.OmittedEntries) omitted. Counts cover all matches.`r`n$($report.Mode) report. Log findings alone do not establish system health."
}

function Show-GuiReport {
    param([string]$Path)
    $report = Read-FileScanGuiReport $Path
    $script:Ui.Report = $report; $script:Ui.ReportPath = $Path
    $c = $script:Ui.Controls
    $c.MatchCount.Text = [string]$report.Summary.MatchedEntries; $c.ErrorCount.Text = [string]$report.Summary.Errors
    $c.WarningCount.Text = [string]$report.Summary.Warnings; $c.UnrepairableCount.Text = [string]$report.Summary.UnrepairableEvents
    $list = [Collections.ArrayList]::new()
    foreach ($entry in $report.Entries) {
        $time = [datetime]::MinValue
        $display = [string]$entry.Timestamp
        if ([datetime]::TryParse($display, [ref]$time)) { $display = $time.ToString('yyyy-MM-dd HH:mm:ss') }
        $entry | Add-Member -NotePropertyName DisplayTime -NotePropertyValue $display -Force
        [void]$list.Add($entry)
    }
    $script:Ui.View = [System.Windows.Data.ListCollectionView]::new($list)
    $script:Ui.View.Filter = [Predicate[object]]{
        param($entry)
        $c = $script:Ui.Controls
        switch ($c.SeverityFilter.SelectedIndex) {
            1 { if ($entry.Severity -ne 'Error') { return $false } }
            2 { if ($entry.Severity -ne 'Warning') { return $false } }
            3 { if ($entry.Source -ne 'CBS' -or ([string]$entry.Message).IndexOf('[SR]', [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false } }
        }
        $query = $c.Search.Text.Trim()
        if (-not $query) { return $true }
        foreach ($value in @($entry.Message, $entry.Interpretation, $entry.Path)) {
            if ([string]$value -and ([string]$value).IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
        return $false
    }
    $c.EntriesGrid.ItemsSource = $script:Ui.View
    $c.Search.Text = ''; $c.SeverityFilter.SelectedIndex = 0
    $c.EntryDetails.Text = "Report: $Path`r`n$($report.Status) | Generated: $($report.GeneratedAt)"
    foreach ($key in @('OpenFolderButton','ExportButton')) { $c[$key].IsEnabled = $true }
    $c.OpenHtmlButton.IsEnabled = [IO.File]::Exists((Join-Path ([IO.Path]::GetDirectoryName($Path)) 'file_scan.html'))
    $c.ResultsTab.IsSelected = $true
    Refresh-GuiResults
}

function Start-GuiRun {
    param([switch]$Preview)
    if ($script:Ui.Job -and -not $script:Ui.Job.Finished) { return }
    $options = Get-GuiOptions
    $request = Get-FileScanGuiRequest -Options $options -DryRun:$Preview
    if ($SmokeTest -and -not $Preview -and $request.Mode -ne 'Analyze') { throw 'GUI smoke tests only run copied-log analysis or dry runs.' }
    if (-not $Preview -and $request.Mode -ne 'Analyze' -and -not $script:Ui.IsAdministrator) {
        # Resolve paths before UAC changes the process's working directory or user profile.
        foreach ($key in @('CbsPath','DismPath','OutputDirectory')) { $options[$key] = $request[$key] }
        if ($options.SourcePath) { $options.SourcePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($options.SourcePath) }
        $snapshot = Join-Path $SettingsDirectory ('elevate-' + [guid]::NewGuid().ToString('N') + '.json')
        Save-FileScanGuiOptions -Path $snapshot -Options $options
        $hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if ([IO.File]::Exists((Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'))) { $hostPath = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe' }
        $arguments = @('-NoLogo','-NoProfile','-STA','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$script:GuiScriptPath,
            '-InitialSettings',$snapshot,'-SettingsDirectory',$SettingsDirectory,'-Resume')
        try {
            $elevated = Start-Process -FilePath $hostPath -ArgumentList (($arguments | ForEach-Object { ConvertTo-FileScanNativeArgument $_ }) -join ' ') -Verb RunAs -PassThru
            $elevated.Dispose()
        } catch {
            if ([IO.File]::Exists($snapshot)) { [IO.File]::Delete($snapshot) }
            throw "Administrator access was cancelled or could not start. $($_.Exception.Message)"
        }
        $script:Ui.AllowClose = $true; $script:Ui.Window.Close()
        return
    }
    Save-FileScanGuiOptions -Path $script:Ui.SettingsPath -Options $options
    if ($script:Ui.Job) { $script:Ui.Job.Process.Dispose(); $script:Ui.Job = $null }
    $script:Ui.Job = Start-FileScanGuiJob -Request $request -SessionDirectory (Join-Path $SettingsDirectory 'sessions')
    $script:Ui.Controls.Activity.Text = ''; $script:Ui.Controls.ActivityTab.IsSelected = $true
    $script:Ui.Controls.Status.Text = if ($Preview) { 'Preparing command preview...' } else { 'Preparing run...' }
    Set-GuiBusy $true
}

function Save-GuiScreenshot {
    param([string]$Path)
    if (-not $Path) { return }
    $root = $script:Ui.Controls.Root
    $root.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $root.UpdateLayout()
    if ($script:Ui.Controls.ResultsTab.IsSelected) {
        $script:Ui.SmokeChecks.ColumnWidths = @($script:Ui.Controls.EntriesGrid.Columns | ForEach-Object { $_.ActualWidth })
    }
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new([int]$root.ActualWidth, [int]$root.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($root)
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function Browse-GuiLog {
    param([string]$Control)
    $dialog = [Microsoft.Win32.OpenFileDialog]::new(); $dialog.Filter = 'Log files (*.log;*.bak)|*.log;*.bak|All files (*.*)|*.*'
    if ($dialog.ShowDialog($script:Ui.Window)) { $script:Ui.Controls[$Control].Text = $dialog.FileName }
}
function Browse-GuiFolder {
    param([string]$Control)
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.SelectedPath = $script:Ui.Controls[$Control].Text
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:Ui.Controls[$Control].Text = $dialog.SelectedPath }
    } finally { $dialog.Dispose() }
}

try {
    if ($env:OS -ne 'Windows_NT') { throw 'The FileScan GUI requires Windows.' }
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'Start the GUI with powershell.exe -STA, or use FILE SCAN GUI.bat.' }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'FileScan.Core.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'FileScan.Gui.Core.psm1') -Force
    $SettingsDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SettingsDirectory)
    $settingsPath = Join-Path $SettingsDirectory 'settings.json'
    if ($Resume -and (-not $InitialSettings -or -not [IO.File]::Exists($InitialSettings))) {
        throw 'An elevated resume requires the original run settings.'
    }
    $options = New-FileScanGuiOptions
    $settingsWarning = ''
    try {
        if ($InitialSettings) { $options = Read-FileScanGuiOptions -Path $InitialSettings -RestoreMode }
        else { $options = Read-FileScanGuiOptions -Path $settingsPath }
    } catch {
        if ($Resume) { throw 'The elevated run could not restore its settings. Reopen FileScan and retry.' }
        $settingsWarning = 'Saved settings could not be read. Defaults were loaded.'
    }
    if ($Resume -and [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($InitialSettings)) -eq $SettingsDirectory -and
        [IO.Path]::GetFileName($InitialSettings) -match '^elevate-[0-9a-f]{32}\.json$') {
        try { [IO.File]::Delete($InitialSettings) } catch { $settingsWarning = 'The temporary elevation settings could not be removed.' }
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $administrator = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
    $xml = [xml][IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FileScan.Gui.xaml'))
    $reader = [Xml.XmlNodeReader]::new($xml)
    try { $window = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
    $controls = @{}
    foreach ($node in $xml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $controls[$name] = $window.FindName($name)
    }
    $script:Ui = @{ Window = $window; Controls = $controls; IsAdministrator = $administrator; SettingsPath = $settingsPath
        Job = $null; Report = $null; ReportPath = ''; View = $null; AllowClose = $false; SmokeStage = 0
        SmokeError = ''; SmokeDeadline = (Get-Date).AddSeconds(60); SmokeChecks = @{} }
    foreach ($key in @('CbsPath','DismPath','OutputDirectory','Since','Until','MaxEntries','SourcePath','ImageIndex')) { $controls[$key].Text = [string]$options[$key] }
    foreach ($key in @('CustomRange','IncludeHistory','IncludeInfo','FailOnFindings','LimitAccess')) { $controls[$key].IsChecked = [bool]$options[$key] }
    $index = @('Default','Folder','WIM','ESD').IndexOf([string]$options.SourceType)
    $controls.SourceType.SelectedIndex = [math]::Max(0, $index)
    switch ($options.Mode) { 'Check' { $controls.CheckMode.IsChecked = $true } 'Repair' { $controls.RepairMode.IsChecked = $true } }
    $controls.AdminLabel.Text = if ($administrator) { 'Administrator access' } else { 'Standard access' }
    if ($settingsWarning) { $controls.Status.Text = $settingsWarning }
    Update-GuiMode

    $controls.RunButton.Add_Click({ try { Start-GuiRun } catch { Show-GuiError $_.Exception.Message } })
    $controls.PreviewButton.Add_Click({ try { Start-GuiRun -Preview } catch { Show-GuiError $_.Exception.Message } })
    $controls.StopButton.Add_Click({ try { Stop-FileScanGuiJob $script:Ui.Job; $script:Ui.Controls.StopButton.IsEnabled = $false; $script:Ui.Controls.Status.Text = 'Stop requested. The current command will finish before reports are saved.' } catch { Show-GuiError $_.Exception.Message } })
    foreach ($key in @('AnalyzeMode','CheckMode','RepairMode','CustomRange')) { $controls[$key].Add_Checked({ Update-GuiMode }) }
    $controls.CustomRange.Add_Unchecked({ Update-GuiMode }); $controls.SourceType.Add_SelectionChanged({ Update-GuiMode })
    $controls.CbsBrowse.Add_Click({ try { Browse-GuiLog 'CbsPath' } catch { Show-GuiError $_.Exception.Message } })
    $controls.DismBrowse.Add_Click({ try { Browse-GuiLog 'DismPath' } catch { Show-GuiError $_.Exception.Message } })
    $controls.OutputBrowse.Add_Click({ try { Browse-GuiFolder 'OutputDirectory' } catch { Show-GuiError $_.Exception.Message } })
    $controls.SourceBrowse.Add_Click({
        try {
            if ([string]$script:Ui.Controls.SourceType.SelectedItem.Content -eq 'Folder') { Browse-GuiFolder 'SourcePath' }
            else { $dialog = [Microsoft.Win32.OpenFileDialog]::new(); $dialog.Filter = 'Windows images (*.wim;*.esd)|*.wim;*.esd'; if ($dialog.ShowDialog($script:Ui.Window)) { $script:Ui.Controls.SourcePath.Text = $dialog.FileName } }
        } catch { Show-GuiError $_.Exception.Message }
    })
    $controls.LoadReportButton.Add_Click({
        try { $dialog = [Microsoft.Win32.OpenFileDialog]::new(); $dialog.Filter = 'FileScan JSON report (*.json)|*.json'; if ($dialog.ShowDialog($script:Ui.Window)) { Show-GuiReport $dialog.FileName } }
        catch { Show-GuiError $_.Exception.Message }
    })
    $controls.OpenHtmlButton.Add_Click({ try { Start-Process -FilePath (Join-Path ([IO.Path]::GetDirectoryName($script:Ui.ReportPath)) 'file_scan.html') } catch { Show-GuiError $_.Exception.Message } })
    $controls.OpenFolderButton.Add_Click({ try { Start-Process -FilePath 'explorer.exe' -ArgumentList (ConvertTo-FileScanNativeArgument ([IO.Path]::GetDirectoryName($script:Ui.ReportPath))) } catch { Show-GuiError $_.Exception.Message } })
    $controls.ExportButton.Add_Click({
        try {
            $dialog = [Microsoft.Win32.SaveFileDialog]::new(); $dialog.Filter = 'ZIP archive (*.zip)|*.zip'; $dialog.FileName = 'file-scan-report.zip'
            if ($dialog.ShowDialog($script:Ui.Window)) { Export-FileScanGuiReport -ReportPath $script:Ui.ReportPath -Destination $dialog.FileName; $script:Ui.Controls.Status.Text = "Exported: $($dialog.FileName)" }
        } catch { Show-GuiError $_.Exception.Message }
    })
    $controls.CopyButton.Add_Click({ try { [System.Windows.Clipboard]::SetText([string]$script:Ui.Controls.EntryDetails.Text) } catch { Show-GuiError $_.Exception.Message } })
    $controls.EntriesGrid.Add_SelectionChanged({
        $entry = $script:Ui.Controls.EntriesGrid.SelectedItem
        $script:Ui.Controls.CopyButton.IsEnabled = $null -ne $entry
        if ($entry) { $script:Ui.Controls.EntryDetails.Text = "$($entry.Path):$($entry.LineNumber)`r`n$($entry.Raw)`r`n$($entry.Interpretation)" }
    })
    $searchTimer = [System.Windows.Threading.DispatcherTimer]::new(); $searchTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $searchTimer.Add_Tick({ $searchTimer.Stop(); Refresh-GuiResults })
    $controls.Search.Add_TextChanged({ $searchTimer.Stop(); $searchTimer.Start() })
    $controls.SeverityFilter.Add_SelectionChanged({ Refresh-GuiResults })

    $timer = [System.Windows.Threading.DispatcherTimer]::new(); $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        try {
            $job = $script:Ui.Job
            if ($job -and -not $job.Finished) {
                Update-FileScanGuiJob $job
                $c = $script:Ui.Controls
                $c.Activity.Text = $job.Log.ToString(); $c.Activity.ScrollToEnd()
                $elapsed = (Get-Date) - $job.StartedAt
                $c.Elapsed.Text = '{0:00}:{1:00}' -f [int][math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
                if ($job.Status) {
                    $c.Status.Text = if ($job.StopRequested -and $job.Status.Phase -eq 'Running') { 'Stop requested. Waiting for the current command to finish...' } else { [string]$job.Status.Message }
                    $c.StopButton.IsEnabled = -not $job.StopRequested -and $job.Request.Mode -ne 'Analyze' -and -not $job.Request['DryRun'] -and $job.Status.Phase -in @('Preparing','Running')
                }
                if ($job.Finished) {
                    Set-GuiBusy $false; $c.Progress.Value = 1
                    $c.Status.Text = if ($job.Status) { [string]$job.Status.Message } else { "Run exited with code $($job.ExitCode). Review Activity for details." }
                    $reportPath = if ($job.ReportDirectory) { Join-Path $job.ReportDirectory 'file_scan.json' } else { '' }
                    if ($reportPath -and [IO.File]::Exists($reportPath)) { Show-GuiReport $reportPath }
                    if ($SmokeTest) {
                        if ($job.ExitCode -ne 0) { throw "Smoke run exited $($job.ExitCode): $($job.Log)" }
                        if ($script:Ui.SmokeStage -eq 0) {
                            if (-not $script:Ui.Report) { throw 'Analysis did not populate the report viewer.' }
                            $script:Ui.SmokeChecks.Entries = @($script:Ui.Report.Entries).Count
                            $script:Ui.Controls.SeverityFilter.SelectedIndex = 1; Refresh-GuiResults
                            $script:Ui.SmokeChecks.ErrorRows = $script:Ui.View.Count
                            $script:Ui.Controls.Search.Text = 'literal'; Refresh-GuiResults
                            $script:Ui.SmokeChecks.SearchRows = $script:Ui.View.Count
                            $script:Ui.Controls.Search.Text = ''; $script:Ui.Controls.SeverityFilter.SelectedIndex = 0; Refresh-GuiResults
                            Save-GuiScreenshot $ScreenshotPath
                            if ($ScreenshotPath) {
                                $width = $script:Ui.Window.Width; $height = $script:Ui.Window.Height
                                $script:Ui.Window.Width = $script:Ui.Window.MinWidth; $script:Ui.Window.Height = $script:Ui.Window.MinHeight
                                Save-GuiScreenshot ([IO.Path]::ChangeExtension($ScreenshotPath, 'compact.png'))
                                $script:Ui.Window.Width = $width; $script:Ui.Window.Height = $height
                            }
                            $script:Ui.SmokeStage = 1; $script:Ui.Controls.RepairMode.IsChecked = $true
                            $script:Ui.Controls.SetupTab.IsSelected = $true
                            $script:Ui.Controls.RepairOptions.BringIntoView()
                            if ($ScreenshotPath) { Save-GuiScreenshot ([IO.Path]::ChangeExtension($ScreenshotPath, 'repair.png')) }
                            Start-GuiRun -Preview
                        } else {
                            $script:Ui.SmokeChecks.PreviewExitCode = $job.ExitCode
                            $script:Ui.SmokeChecks.PreviewContainsRestoreHealth = $job.Log.ToString().Contains('/RestoreHealth')
                            if ($ScreenshotPath) { Save-GuiScreenshot ([IO.Path]::ChangeExtension($ScreenshotPath, 'transcript.png')) }
                            $script:Ui.AllowClose = $true; $script:Ui.Window.Close()
                        }
                    }
                }
            }
            if ($SmokeTest -and (Get-Date) -gt $script:Ui.SmokeDeadline) { throw 'GUI smoke test timed out.' }
        } catch { Show-GuiError $_.Exception.Message }
    })
    $window.Add_Closing({
        param($sender, $event)
        if (-not $script:Ui.AllowClose -and $script:Ui.Job -and -not $script:Ui.Job.Finished) {
            $event.Cancel = $true
            $script:Ui.Controls.Status.Text = 'A run is active. Let it finish, or stop after the current command before closing.'
        }
    })
    $window.Add_ContentRendered({
        try {
            if ($SmokeTest) {
                if ((Get-GuiOptions).Mode -ne 'Analyze') { throw 'Smoke tests must start in Analyze mode.' }
                if ($ScreenshotPath) { Save-GuiScreenshot ([IO.Path]::ChangeExtension($ScreenshotPath, 'setup.png')) }
                Start-GuiRun
            }
            elseif ($Resume) { Start-GuiRun }
        } catch { Show-GuiError $_.Exception.Message }
    })
    if ($SmokeTest) {
        $window.ShowInTaskbar = $false; $window.ShowActivated = $false; $window.WindowStartupLocation = 'Manual'
        $window.Left = -20000; $window.Top = -20000
        [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly
    }
    $timer.Start()
    [void]$window.ShowDialog()
    $timer.Stop(); $searchTimer.Stop()
    if ($SmokeTest) {
        if ($script:Ui.SmokeError) { throw $script:Ui.SmokeError }
        if ($SmokeResultPath) { [IO.File]::WriteAllText($SmokeResultPath, ($script:Ui.SmokeChecks | ConvertTo-Json), [Text.UTF8Encoding]::new($false)) }
    }
} catch {
    if ($SmokeTest) { Write-Error $_ -ErrorAction Continue; exit 1 }
    try { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'FileScan could not start') } catch { Write-Error $_ -ErrorAction Continue }
    exit 1
} finally {
    if ($script:Ui -and $script:Ui.Job -and $script:Ui.Job.Process.HasExited) { $script:Ui.Job.Process.Dispose() }
}
