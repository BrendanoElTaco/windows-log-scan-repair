#Requires -Version 5.1
<#
.SYNOPSIS
Run FileScan's dependency-free regression suites with the current PowerShell host.
.DESCRIPTION
Each suite runs in its own script scope using the current PowerShell host.
Tests use copied logs, harmless fixture processes, and repair previews only.
.EXAMPLE
.\tests\Test-All.ps1
.EXAMPLE
.\tests\Test-All.ps1 -Suite GUI -KeepArtifacts
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'CLI', 'GUI')][string]$Suite = 'All',
    [switch]$KeepArtifacts
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$targets = @(
    @{ Name = 'CLI'; File = 'Test-FileScan.ps1' }
    @{ Name = 'GUI'; File = 'Test-FileScanGui.ps1' }
)
$failed = [Collections.Generic.List[string]]::new()
foreach ($target in $targets) {
    if ($Suite -ne 'All' -and $Suite -ne $target.Name) { continue }
    Write-Host ("Running {0} suite using PowerShell {1}..." -f $target.Name, $PSVersionTable.PSVersion) -ForegroundColor Cyan
    try {
        & (Join-Path $PSScriptRoot $target.File) -KeepArtifacts:$KeepArtifacts
    } catch {
        $failed.Add($target.Name)
        Write-Error $_ -ErrorAction Continue
    }
}
if ($failed.Count) {
    Write-Host ('FAIL: ' + ($failed -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host 'PASS: All selected suites passed. No live scans or repairs ran.' -ForegroundColor Green
exit 0
