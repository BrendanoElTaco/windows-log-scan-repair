@echo off
setlocal DisableDelayedExpansion
REM Keep the double-click entry point; all logic lives beside this launcher.
set "FileScanPowerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "FileScanPowerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%~dp0FileScan.ps1" (
    echo FileScan.ps1 is missing. Keep all FileScan files in the same folder.
    exit /b 1
)
"%FileScanPowerShell%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0FileScan.ps1" %*
set "FileScanExitCode=%errorlevel%"
if "%~1"=="" pause
exit /b %FileScanExitCode%
