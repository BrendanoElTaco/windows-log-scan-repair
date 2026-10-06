# Windows Log Scan & Repair

Check Windows integrity, repair it when requested, and turn CBS/DISM logs into a readable report. Use the native Windows GUI or the original command-line launcher. No WMIC, VBScript, downloaded modules, or installation required.

## Quick start

Keep the `src` folder beside the two batch launchers. Double-click **FILE SCAN GUI.bat** to open the desktop interface:

- Choose **Analyze logs**, **Check system**, or **Repair system** in the operation toolbar. New sessions always start in Analyze.
- Browse to CBS/DISM logs and a report folder, or use the defaults. Your paths and filter preferences are remembered.
- Set log paths and filters in **Inputs**, then click **Preview plan** to validate settings and inspect the plan without running tools. Preview also works for Repair without elevation.
- Click **Analyze logs**, **Run check**, or **Run repair** to run. Check/Repair requests Administrator access when needed and resumes the selected run in the elevated window.
- Follow the current stage and elapsed time in the status bar. The window remains responsive; the **Transcript** tab shows console messages and completed command output. The progress bar is indeterminate, not an estimate of DISM/SFC completion.
- Inspect counts and searchable entries in **Findings**. Filter by errors, warnings, or SFC events; select an entry to inspect and copy its full text in the adjacent entry inspector.
- Open the HTML report or report folder, load a previous JSON report, or export the report and captured command output as a ZIP. The export excludes unrelated files in that folder.

**Stop after current command** lets an active DISM/SFC command finish, skips later commands, and saves log reports. It never force-kills servicing tools. Log analysis and report writing finish normally, and the window prevents closing during an active run. No restart is performed automatically.

The GUI limits retained excerpts to 20,000 entries and loads JSON reports up to 64 MB. Counts still include all matches. Settings and temporary session metadata are stored under `%LOCALAPPDATA%\FileScan\UI`; reports use the separate report folder below.

To launch the GUI from a terminal:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\src\gui\FileScan.Gui.ps1
```

For the existing terminal menu, double-click **FILE SCAN.bat**. Choose:

| Choice | Behavior |
| --- | --- |
| **A - Analyze** | Read existing logs. Does not run integrity tools. |
| **C - Check** | Run `DISM /Online /Cleanup-Image /ScanHealth`, then `sfc /verifyonly`. Does not request repairs. |
| **R - Repair** | Run `DISM /Online /Cleanup-Image /RestoreHealth`, then `sfc /scannow`. Repairs the component store before checking protected files. |
| **Q - Quit** | Exit without running anything. |

Check and Repair request Administrator access through UAC if needed. Analyze runs with your existing permissions and reports inaccessible logs explicitly. A failed DISM command stops the sequence; SFC is marked skipped, and log reports are still generated. Scans can take several minutes. FileScan never restarts the computer automatically.

Requires **Windows 10/11 and Windows PowerShell 5.1 or later**. PowerShell 7 on Windows is also supported. The launcher uses the built-in Windows PowerShell executable and a process-scoped execution-policy bypass for these local scripts; it does not change the machine's policy. Organization policies can still prevent execution.

## What is new

- Fixed malformed Windows paths, fragile date parsing, and filters that missed normal timestamped log lines.
- Analysis works independently of scans, with custom log paths for copied logs.
- Local date/time windows, including scan sessions that cross midnight.
- SFC event interpretations, severity totals, file repair observations, and explicit missing/unreadable source status.
- Streaming log reads with bounded excerpt retention: counts cover **all** matches, while excerpts keep the newest entries across every selected source.
- Optional rotated-log history and routine Info entries.
- Timestamped folders containing text, JSON, HTML, and captured native command output; previous reports remain available.
- Repair sources, Windows Update restriction, dry runs, unattended operation, optional findings exit codes, and a mutex to prevent overlapping FileScan integrity scans.
- Dependency-free regression tests and Windows CI for PowerShell 5.1 and 7.
- A WPF desktop interface with file browsing, saved preferences, stage/elapsed updates, searchable report entries, previous-report loading, ZIP export, and cooperative stopping.

## Reports

By default, each run creates a unique folder under:

```text
%LOCALAPPDATA%\FileScan\Reports\file-scan-YYYYMMDD-HHMMSS-<id>\
```

| File | Contents |
| --- | --- |
| `file_scan.html` | Standalone browser report with summary cards, command results, source status, and an event timeline. No external resources or JavaScript. |
| `file_scan.log` | Plain-text summary and original matching log lines. |
| `file_scan.json` | Structured results (`SchemaVersion: 1`), counts, source paths, line numbers, command results, and retained entries. |
| `dism-output.txt`, `sfc-output.txt` | Captured stdout/stderr for commands that were attempted. |

Use `-OutputDirectory` to choose another root. **This replaces the old fixed `C:\Windows\Logs\file_scan.log` output.** The original Windows servicing logs are read without being overwritten. Reports may contain computer names, local paths, and log details; review them before sharing.

## Command-line examples

From PowerShell in the script folder:

```powershell
# Analyze today's active logs and open the report.
.\src\FileScan.ps1 -Mode Analyze -OpenReport

# Analyze a complete date range, including available uncompressed history.
.\src\FileScan.ps1 -Mode Analyze -Since 2026-10-01 -Until 2026-10-06 -IncludeHistory

# Check command selection and repair-source arguments without running anything.
.\src\FileScan.ps1 -Mode Repair -Source 'wim:D:\sources\install.wim:1' -LimitAccess -DryRun

# Repair, allowing DISM to use the configured repair source / Windows Update.
.\src\FileScan.ps1 -Mode Repair

# Analyze copied logs without Administrator access.
.\src\FileScan.ps1 -Mode Analyze -CbsPath '.\copies\CBS.log' -DismPath '.\copies\dism.log' -OutputDirectory '.\reports'

# Unattended log monitoring: exit 3 when findings require review.
.\src\FileScan.ps1 -Mode Analyze -NonInteractive -FailOnFindings

# Unattended checks must run from an already elevated terminal or scheduled task.
.\src\FileScan.ps1 -Mode Check -NonInteractive -OutputDirectory 'C:\Diagnostics\Reports'

# Use a precise interval: start included, end excluded.
.\src\FileScan.ps1 -Mode Analyze -Since '2026-10-06T09:00:00' -Until '2026-10-06T10:00:00'
```

The batch launcher accepts the same options. From Command Prompt:

```bat
"FILE SCAN.bat" -Mode Analyze -NonInteractive -MaxEntries 1000
"FILE SCAN.bat" -Mode Repair -DryRun -Source "D:\Repair files\Windows" -LimitAccess
```

Use `Get-Help .\src\FileScan.ps1 -Examples` for built-in examples. If your local execution policy blocks direct `.ps1` invocation, use the batch launcher.

## Options

| Parameter | Default / meaning |
| --- | --- |
| `-Mode` | `Interactive`; choose `Analyze`, `Check`, or `Repair` to skip the menu. |
| `-Since` | Analyze: today's midnight. Check/Repair: this run's start, rounded down to the second. Inclusive. |
| `-Until` | End of the run. A date includes that entire day; a timestamp is an exclusive upper bound. |
| `-CbsPath`, `-DismPath` | `%SystemRoot%\Logs\CBS\CBS.log` and `%SystemRoot%\Logs\DISM\dism.log`. |
| `-OutputDirectory` | `%LOCALAPPDATA%\FileScan\Reports`; creates a unique child folder for each run. |
| `-MaxEntries` | `5000`; allowed range `1..100000`. Applies to retained entries, not counts. |
| `-IncludeHistory` | Also reads `CbsPersist*.log` beside the CBS log and `dism.log.bak` beside the DISM log. |
| `-IncludeInfo` | Also includes routine Info entries; normally includes errors, warnings, and SFC events. |
| `-Source` | Repair only: a Windows repair directory, `wim:path:index`, or `esd:path:index`. Relative paths are resolved before elevation. |
| `-LimitAccess` | Repair only: prevents DISM from contacting Windows Update for repair content. |
| `-NonInteractive` | No menu, viewer, or UAC prompt. Defaults to Analyze when Mode is omitted. |
| `-NoElevate` | Fail if Check/Repair needs elevation, instead of requesting UAC. |
| `-OpenReport` | Open HTML after saving; incompatible with NonInteractive. |
| `-FailOnFindings` | Exit `3` for errors, warnings, or unrepairable-file observations. |
| `-DryRun` | Validate options and display the plan. No tool execution, elevation, log reads, or report writes. |

Dates must use `yyyy-MM-dd`, `yyyy-MM-ddTHH:mm:ss`, or `yyyy-MM-dd HH:mm:ss`. All windows use **local time**, matching the timestamps in servicing logs. For older dates, supply an explicit Until as well. Scan modes with an explicit historical window still run tools on the current system; use Analyze to inspect only historical logs.

## Interpreting the results

Errors and warnings are recognized from the log's severity column, not arbitrary words inside a message. CBS `[SR]` entries are included even when marked Info. Interpretations identify verification, transaction start/completion, repairs, and `Cannot repair member file` observations. Fatal entries are counted as errors. Separate events are not deduplicated, including events repeated in overlapping rotated logs.

A file reported unrepairable earlier in the interval may be repaired later. **No matches or a zero process exit code does not certify a healthy system.** Check the native tool output and subsequent verification. Counts remain complete for readable sources even when excerpts are truncated; missing or unreadable sources make analysis incomplete.

Only timestamped lines with a recognized Info/Warning/Error/Fatal column are parsed. Untimestamped continuation lines, localized formats, and compressed CBS `.cab` history need manual inspection. A log can change or rotate while it is being read. Historical intervals are limited to the files still available.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Requested commands and reports completed; findings may still be present unless FailOnFindings was used. |
| `1` | A native command failed, or setup/options/elevation/report writing failed. |
| `2` | One or more requested log sources were missing or unreadable. |
| `3` | FailOnFindings was enabled and errors, warnings, or unrepairable observations were found. |
| `4` | The GUI stopped the sequence at the user's request after the current command. Logs and reports are still saved. |

Precedence: command failure (`1`), requested stop (`4`), incomplete sources (`2`), then findings (`3`). DISM exit `3010` is treated as completed with a restart requested. SFC results are preserved without translating exit codes into health claims. The terminal batch launcher propagates the PowerShell exit code and pauses only when started without arguments.

## Repository layout

```text
FILE SCAN GUI.bat             Desktop launcher
FILE SCAN.bat                 Terminal launcher
FileScan.ps1                  Compatibility entry point for existing commands
FileScan.Core.psm1            Compatibility import for existing scripts
src/
  FileScan.ps1                CLI entry point and run orchestration
  FileScan.Core.psm1          Log analysis, native commands, and reports
  gui/
    FileScan.Gui.ps1          WPF window and event handlers
    FileScan.Gui.Core.psm1    Settings, worker sessions, and report export
    FileScan.Gui.xaml         Desktop layout and styles
tests/
  Test-All.ps1                Single test runner (All, CLI, or GUI)
  Test-FileScan.ps1           CLI and engine regression suite
  Test-FileScanGui.ps1        GUI regression suite
  Run-Tests.ps1               Older local CLI suite (preserved)
  fixtures/                  Harmless child scripts for tests
.github/workflows/test.yml   Windows PowerShell 5.1 and 7 CI
```

Run terminal examples from the repository root. Launchers and internal imports locate application files relative to their own files. The root compatibility files preserve older CLI invocations and module imports; implementation changes belong under `src`. Generated reports and GUI settings default to `%LOCALAPPDATA%\FileScan`; tests create ignored, temporary `tests/artifacts-<id>` folders and remove them unless `-KeepArtifacts` is supplied.

## Tests

Run from the repository folder using either PowerShell host:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
pwsh.exe -NoProfile -File .\tests\Test-All.ps1

# Run one suite or retain its reports and screenshots.
pwsh.exe -NoProfile -File .\tests\Test-All.ps1 -Suite GUI -KeepArtifacts
```

The runner uses the current PowerShell host and invokes each suite in its own script scope. `-Suite CLI` or `-Suite GUI` selects one suite; the default runs both. It exits with `1` if any selected suite fails. The older local `Run-Tests.ps1` is preserved for compatibility; CI and the commands above use `Test-All.ps1`.

Tests use synthetic UTF-8/UTF-16 logs and harmless child processes. They **never run real DISM/SFC, repair Windows, or request UAC**. Coverage includes date boundaries, severity parsing, SFC events, rotated logs, missing/locked files, newest-entry limits, native argument quoting, command output/failures/reboot results, HTML escaping, JSON export, and the batch entry point. Add `-KeepArtifacts` to retain generated reports under `tests\artifacts-<id>` for inspection.

GUI tests cover settings, source validation, stopping between mocked commands, progress messages, ZIP contents, and the actual WPF interface rendered offscreen. The interface analyzes copied sample logs and previews Repair commands; it never starts real servicing. With `-KeepArtifacts`, the GUI suite also retains `gui-preview.png` and additional Inputs, Repair, Transcript, and minimum-window-size screenshots for visual inspection. Both suites run in Windows CI.

## Microsoft references

- [Repair a Windows image (DISM health and repair-source options)](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/repair-a-windows-image?view=windows-11)
- [SFC command reference (verification and repair modes)](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/sfc)

## License

MIT; see [LICENSE](LICENSE).
