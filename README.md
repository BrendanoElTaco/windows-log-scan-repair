
# windows-log-scan-repair

## Description
A single batch script that automates Windows file integrity repairs and log analysis. It runs optional **DISM** and **SFC** scans, then filters the **CBS** and **DISM** logs for today’s entries, summarizing key Info/Warning/Error lines into `C:\Windows\Logs\file_scan.log`.

---

## Features
- Requests **Administrator (UAC)** access automatically.
- Runs **DISM** and **SFC** scans to detect and repair system file issues.
- Extracts **same-day** log entries from CBS and DISM logs.
- Adds helpful interpretations for common repair events.
- Outputs a single summary log and offers to open it.

---

## Requirements
- Windows 10/11
- Administrator privileges
- DISM & SFC tools (built into Windows)
- `wmic` available for date parsing (or use PowerShell fallback below)

---

## Usage
1. Save the script as `file_scan.bat`.
2. Run it as Administrator (or let UAC prompt appear).
3. Choose **Y** to run scans or **N** to skip.
4. After filtering, choose **Y** to open the summarized log.

**Summary output:**  
`C:\Windows\Logs\file_scan.log`

**Full logs:**  
- `C:\Windows\Logs\CBS\CBS.log`  
- `C:\Windows\Logs\DISM\dism.log`

---

## Filtering Details
**CBS.log:**  
Searches for today's lines containing:
- `Info CSI`
- `Error`
- `Warning`

Interprets special entries like:
- `[SR] Verifying` → Component verification
- `[SR] Beginning Verify and Repair transaction` → Repair transaction start
- `[SR] Repairing corrupted file` → File repaired
- `Cannot repair member file` → File could not be repaired
- `Repaired the file` → Repaired from backup

**DISM.log:**  
Searches for today’s `Error` and `Warning` lines.

---

## PowerShell Fallback (if WMIC is missing)
Replace this line:
```bat
for /f "tokens=2 delims==" %%i in ('wmic os get localdatetime /value') do set datetime=%%i
```
With:
```bat
for /f %%i in ('powershell -NoProfile -Command "(Get-Date).ToString(\"yyyy-MM-dd\")"') do set currentdate=%%i
```

---

## Troubleshooting
- **Missing permissions:** Run as Administrator.
- **Source issues:** Use DISM with `/Source` flag.
- **Log path not found:** Ensure `C:\Windows\Logs\` exists.

---

## License
MIT License  
Use at your own risk. Always back up or create restore points before system repairs.
