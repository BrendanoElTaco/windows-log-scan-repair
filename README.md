# Windows Log Scan & Repair

Check Windows integrity, repair it when requested, and turn CBS/DISM logs into a readable report. The original `FILE SCAN.bat` entry point now launches a Windows PowerShell engine, with no WMIC, VBScript, downloaded modules, or installation required.

## Quick start

Keep `FILE SCAN.bat`, `FileScan.ps1`, and `FileScan.Core.psm1` together, then double-click **FILE SCAN.bat**. Choose:

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
.\FileScan.ps1 -Mode Analyze -OpenReport

# Analyze a complete date range, including available uncompressed history.
.\FileScan.ps1 -Mode Analyze -Since 2026-10-01 -Until 2026-10-06 -IncludeHistory

# Check command selection and repair-source arguments without running anything.
.\FileScan.ps1 -Mode Repair -Source 'wim:D:\sources\install.wim:1' -LimitAccess -DryRun

# Repair, allowing DISM to use the configured repair source / Windows Update.
.\FileScan.ps1 -Mode Repair

# Analyze copied logs without Administrator access.
.\FileScan.ps1 -Mode Analyze -CbsPath '.\copies\CBS.log' -DismPath '.\copies\dism.log' -OutputDirectory '.\reports'

# Unattended log monitoring: exit 3 when findings require review.
.\FileScan.ps1 -Mode Analyze -NonInteractive -FailOnFindings

# Unattended checks must run from an already elevated terminal or scheduled task.
.\FileScan.ps1 -Mode Check -NonInteractive -OutputDirectory 'C:\Diagnostics\Reports'

# Use a precise interval: start included, end excluded.
.\FileScan.ps1 -Mode Analyze -Since '2026-10-06T09:00:00' -Until '2026-10-06T10:00:00'
```

The batch launcher accepts the same options. From Command Prompt:

```bat
"FILE SCAN.bat" -Mode Analyze -NonInteractive -MaxEntries 1000
"FILE SCAN.bat" -Mode Repair -DryRun -Source "D:\Repair files\Windows" -LimitAccess
```

Use `Get-Help .\FileScan.ps1 -Examples` for built-in examples. If your local execution policy blocks direct `.ps1` invocation, use the batch launcher.

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

Precedence: command failure (`1`), incomplete sources (`2`), then findings (`3`). DISM exit `3010` is treated as completed with a restart requested. SFC results are preserved without translating exit codes into health claims. The batch launcher propagates the PowerShell exit code and pauses only when started without arguments.

## Tests

Run from the repository folder using either PowerShell host:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FileScan.ps1
pwsh.exe -NoProfile -File .\tests\Test-FileScan.ps1
```

Tests use synthetic UTF-8/UTF-16 logs and harmless child processes. They **never run real DISM/SFC, repair Windows, or request UAC**. Coverage includes date boundaries, severity parsing, SFC events, rotated logs, missing/locked files, newest-entry limits, native argument quoting, command output/failures/reboot results, HTML escaping, JSON export, and the batch entry point. Add `-KeepArtifacts` to retain generated reports under `tests\artifacts-<id>` for inspection.

## Microsoft references

- [Repair a Windows image (DISM health and repair-source options)](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/repair-a-windows-image?view=windows-11)
- [SFC command reference (verification and repair modes)](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/sfc)

## License

MIT; see [LICENSE](LICENSE).
