# File-based arguments are identical to the Bash entry point.
$ErrorActionPreference = 'Stop'
& (Join-Path (Split-Path -Parent $PSScriptRoot) 'templates/task-center-v2/scripts/task.ps1') @args
exit $LASTEXITCODE
