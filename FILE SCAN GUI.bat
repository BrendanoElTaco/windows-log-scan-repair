@echo off
setlocal DisableDelayedExpansion
set "FileScanGuiHost=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "FileScanGuiHost=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%~dp0src\gui\FileScan.Gui.ps1" (
    echo Application files are missing. Keep the src folder beside this launcher.
    pause
    exit /b 1
)
start "" "%FileScanGuiHost%" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0src\gui\FileScan.Gui.ps1" %*
exit /b 0
