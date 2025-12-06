@echo off
REM This script checks for administrative privileges, requests elevation if necessary,
REM offers to run system scans using DISM and SFC tools, filters for recent and important entries in the CBS and DISM log files,
REM and offers to view the filtered log file with the default program for .log files.
REM Check if the current session has administrative privileges by trying to list network sessions.
net session >nul 2>&1
if %errorlevel% == 0 (
    REM Administrative privileges are confirmed.
    echo Administrative privileges confirmed.
    goto :start
) else (
    REM If not, request administrative privileges.
    echo Requesting administrative privileges...
    goto :UACPrompt
)
:UACPrompt
REM Create a VBScript to request elevation and rerun this script with administrative privileges.
echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
"%temp%\getadmin.vbs"
REM Exit the script to avoid running the rest of the commands without elevation.
exit /B
:start
REM Get the current date in YYYY-MM-DD format.
for /f "tokens=2 delims==" %%i in ('wmic os get localdatetime /value') do set datetime=%%i
set currentdate=%datetime:~0,4%-%datetime:~4,2%-%datetime:~6,2%
REM Prompt the user to decide whether to scan the computer for file corruptions.
set /p choice="Would you like to scan your computer for file corruptions? (Y/N) "
if /I "%choice%"=="Y" goto :runScans
if /I "%choice%"=="N" goto :endScript
:runScans
REM Section for running system scans. The DISM tool is run first to repair system files,
REM followed by the System File Checker (SFC) to check for and fix other file corruptions.
echo Running DISM tool...
Dism /Online /Cleanup-Image /ScanHealth
Dism /Online /Cleanup-Image /CheckHealth
Dism /Online /Cleanup-Image /RestoreHealth
echo Running System File Checker...
sfc /scannow
:filterLogs
REM Filter for recent and important entries in the CBS and DISM log files and combine them into a single file.
echo Filtering for recent and important entries in CBS and DISM log files for %currentdate%...
echo ========== FILE SCAN LOG ========== > C:\\WINDOWS\\Logs\\file_scan.log
REM Check CBS.log for recent and important entries.
echo ========== CBS LOG ========== >> C\WINDOWS\Logs\file_scan.log
findstr /c:"%currentdate% Info CSI" /c:"%currentdate% Error" /c:"%currentdate% Warning" C\WINDOWS\Logs\CBS\cbs.log > temp_log.txt
if %errorlevel% GEQ 2 goto :cbsLogMissing
if %errorlevel% == 1 goto :cbsNoEntries
goto :cbsInterpret
:cbsLogMissing
echo CBS log missing or unreadable. >> C\WINDOWS\Logs\file_scan.log
goto :checkDism
:cbsNoEntries
echo No Errors or Warnings found in CBS.log on %currentdate%. >> C\WINDOWS\Logs\file_scan.log
goto :checkDism
:cbsInterpret
echo ========== Interpreted CBS LOG Entries ========== >> C\WINDOWS\Logs\file_scan.log
for /f "tokens=*" %%a in (temp_log.txt) do (
    echo %%a >> C\WINDOWS\Logs\file_scan.log
    echo Analyzing entry: %%a
    echo %%a | findstr /c:"[SR] Verifying" && (
        echo Verifying components entry detected. >> C\WINDOWS\Logs\file_scan.log
    )
    echo %%a | findstr /c:"[SR] Beginning Verify and Repair transaction" && (
        echo Beginning Verify and Repair transaction entry detected. >> C\WINDOWS\Logs\file_scan.log
    )
    echo %%a | findstr /c:"[SR] Repairing corrupted file" && (
        echo Repairing corrupted file detected. >> C\WINDOWS\Logs\file_scan.log
    )
    echo %%a | findstr /c:"Cannot repair member file" && (
        echo Cannot repair member file detected. >> C\WINDOWS\Logs\file_scan.log
    )
    echo %%a | findstr /c:"Repaired the file" && (
        echo Repaired the file by copying from backup detected. >> C\WINDOWS\Logs\file_scan.log
    )
)
goto :checkDism
REM Check DISM.log for recent and important entries.
echo ========== DISM LOG ========== >> C\WINDOWS\Logs\file_scan.log
findstr /c:"%currentdate% Error" /c:"%currentdate% Warning" C\WINDOWS\Logs\DISM\dism.log > temp_log.txt
if %errorlevel% GEQ 2 goto :dismLogMissing
if %errorlevel% == 1 goto :dismNoEntries
goto :dismAppend
:dismLogMissing
echo DISM log missing or unreadable. >> C\WINDOWS\Logs\file_scan.log
goto :cleanupTemp
:dismNoEntries
echo No Errors or Warnings found in DISM.log on %currentdate%. >> C\WINDOWS\Logs\file_scan.log
goto :cleanupTemp
:dismAppend
type temp_log.txt >> C\WINDOWS\Logs\file_scan.log
goto :cleanupTemp
:cleanupTemp
REM Clean up the temporary log file.
if exist temp_log.txt del temp_log.txt
REM Append a message about where to find the full CBS and DISM logs.
echo. >> C:\\WINDOWS\\Logs\\file_scan.log
echo Full CBS and DISM logs can be found at C:\\WINDOWS\\Logs\\CBS\\cbs.log and C:\\WINDOWS\\Logs\\DISM\\dism.log, respectively. >> C:\\WINDOWS\\Logs\\file_scan.log
:viewLog
REM Ask the user if they want to view the filtered log file.
set /p viewLog="Filtering complete. Would you like to view the recent and important log entries now? (Y/N) "
if /I "%viewLog%"=="Y" start "" "C:\WINDOWS\Logs\file_scan.log"
if /I "%viewLog%"=="N" goto :endScript
:endScript
REM The script will exit after a 5-second countdown, giving the user time to read the final messages.
echo Exiting script in 5 seconds...
timeout /t 5 /nobreak >nul
