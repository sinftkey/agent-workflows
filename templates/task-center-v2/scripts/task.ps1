# ASCII-only wrapper, including Windows PowerShell 5.1. JSON is passed by file.
$ErrorActionPreference = 'Stop'
if (($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1) -or
    ($PSVersionTable.PSVersion.Major -ne 5 -and $PSVersionTable.PSVersion -lt [version]'7.2')) {
    [Console]::Error.WriteLine('task-center: PowerShell 5.1 or 7.2+ is required.')
    exit 8
}
$python = if ($env:TASK_PYTHON) { $env:TASK_PYTHON } else { 'python3' }
if (-not (Get-Command $python -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('task-center: configure TASK_PYTHON; no automatic runtime installation.')
    exit 8
}
$env:PYTHONDONTWRITEBYTECODE = '1'
& $python -I -B (Join-Path $PSScriptRoot 'task.py') @args
$result = $LASTEXITCODE
if ($null -eq $result) { exit 9 }
exit $result
