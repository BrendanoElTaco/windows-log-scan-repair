# Harmless process used to test exit codes and redirected output. No servicing tools.
param([int]$Code = 0, [string]$Message = 'fake output', [switch]$Unicode)
$encoding = if ($Unicode) { [Text.Encoding]::Unicode } else { [Text.Encoding]::ASCII }
$stdout = [Console]::OpenStandardOutput()
$stderr = [Console]::OpenStandardError()
$bytes = $encoding.GetBytes($Message + "`r`n")
$stdout.Write($bytes, 0, $bytes.Length)
$bytes = $encoding.GetBytes("fake stderr`r`n")
$stderr.Write($bytes, 0, $bytes.Length)
$stdout.Flush(); $stderr.Flush()
exit $Code
