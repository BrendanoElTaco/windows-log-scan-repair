#Requires -Version 5.1
# Compatibility import for existing scripts. Implementation is kept in src.
Import-Module (Join-Path $PSScriptRoot 'src\FileScan.Core.psm1') -Scope Local
Export-ModuleMember -Function *
