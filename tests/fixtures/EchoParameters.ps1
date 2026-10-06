param([string]$Source, [switch]$IncludeInfo, [int]$MaxEntries)
@{ Source = $Source; IncludeInfo = [bool]$IncludeInfo; MaxEntries = $MaxEntries } | ConvertTo-Json -Compress
exit 3
