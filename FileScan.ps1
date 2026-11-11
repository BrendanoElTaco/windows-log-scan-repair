#Requires -Version 5.1
<#
.SYNOPSIS
Compatibility entry point for FileScan; the implementation lives in src.
.EXAMPLE
.\FileScan.ps1 -Mode Analyze -NonInteractive
.EXAMPLE
.\FileScan.ps1 -Mode Repair -DryRun
#>
$entryPoint = Join-Path $PSScriptRoot 'src\FileScan.ps1'
if (-not [IO.File]::Exists($entryPoint)) {
    Write-Error 'Application files are missing. Keep the src folder beside this entry point.' -ErrorAction Continue
    exit 1
}
& $entryPoint @args
exit $LASTEXITCODE
