param(
    [string]$SetupPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/setup-task-center.sh'),
    [string]$BashPath = 'D:\Git\bin\bash.exe'
)
$ErrorActionPreference = 'Stop'
$BashPath = (Resolve-Path -LiteralPath $BashPath).Path
$cygpath = Join-Path (Split-Path -Parent (Split-Path -Parent $BashPath)) 'usr/bin/cygpath.exe'
$fixtureParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $fixtureParent ('setup-registration-' + [guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$script:passed = 0; $script:failed = 0
function Unix-Path([string]$Path) {
    $result = @(& $cygpath -u $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "cygpath failed: $Path" }
    return ($result -join '').Trim()
}
function Check([string]$Name, [bool]$Passed) {
    if ($Passed) { $script:passed++; Write-Output "PASS: $Name" }
    else { $script:failed++; Write-Output "FAIL: $Name" }
}
try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    $runtime = Join-Path $fixtureRoot 'runtime'
    $null = New-Item -ItemType Directory -Path $runtime
    $registration = Join-Path $fixtureRoot 'install-path'
    $legacy = Join-Path $runtime 'registration'
    $marker = Join-Path $fixtureRoot 'downstream-marker'
    $fallback = Join-Path $fixtureRoot 'fallback-marker'
    $stdout = Join-Path $fixtureRoot 'stdout'
    $stderr = Join-Path $fixtureRoot 'stderr'
    $source = [IO.File]::ReadAllText($SetupPath)
    $definitions = foreach ($name in @('read_registered_path','find_candidate','install_or_register','repair_task_center','normalize_path','canonical_existing')) {
        $match = [regex]::Match($source, '(?ms)^' + $name + '\(\) \{\r?\n.*?^\}')
        if (-not $match.Success) { throw "Missing original Bash function: $name" }
        $match.Value
    }
    $probe = "set -euo pipefail`n" + ($definitions -join "`n") + @'

REGISTRATION="$1"; RUNTIME_DIR="$2"; marker="$3"; fallback="$4"
fault_code="$5"; partial="$6"; caller="$7"; BRANCH=task-center; TASK_CENTER_PATH=''
die() { printf 'setup-task-center: %s\n' "$*" >&2; exit 1; }
remote_branch_refs() { :; }
get_worktree_for_branch() { printf reached > "$fallback"; return 1; }
get_main_worktree() { printf reached > "$marker"; return 91; }
gitc() { printf reached > "$marker"; return 91; }
if [[ "$fault_code" != 0 ]]; then
  # Support the old read implementation and the replacement byte reader.
  # Both model failure after -f succeeds; the production call chain is intact.
  read() { first="$partial"; printf 'injected registration read failure\n' >&2; return "$fault_code"; }
  cat() { printf '%s' "$partial"; printf 'injected registration read failure\n' >&2; return "$fault_code"; }
fi
"$caller"
'@
    $probePath = Join-Path $fixtureRoot 'registration-probe.sh'
    [IO.File]::WriteAllText($probePath, $probe.Replace("`r`n","`n"), $utf8)
    $probeUnix = Unix-Path $probePath
    $registrationUnix = Unix-Path $registration; $runtimeUnix = Unix-Path $runtime
    $markerUnix = Unix-Path $marker; $fallbackUnix = Unix-Path $fallback
    function Run-Probe([string]$Caller, [int]$Fault = 0, [string]$Partial = '') {
        foreach ($path in @($marker,$fallback)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
        & $BashPath $probeUnix $registrationUnix $runtimeUnix $markerUnix $fallbackUnix "$Fault" $Partial $Caller 1> $stdout 2> $stderr
        $code = $LASTEXITCODE
        return [pscustomobject]@{
            Code = $code
            Value = [IO.File]::ReadAllText($stdout).TrimEnd([char[]]"`r`n")
            Error = [IO.File]::ReadAllText($stderr)
            Downstream = (Test-Path -LiteralPath $marker)
            Fallback = (Test-Path -LiteralPath $fallback)
        }
    }
    $validCases = @(
        @{ Name='absent registration'; Primary=$null; Legacy=$null; Expected='' },
        @{ Name='plain path with newline'; Primary="/fixture/center`n"; Legacy=$null; Expected='/fixture/center' },
        @{ Name='plain path without final newline'; Primary='/fixture/center'; Legacy=$null; Expected='/fixture/center' },
        @{ Name='plain path uses first line'; Primary="/fixture/center`n/ignored`n"; Legacy=$null; Expected='/fixture/center' },
        @{ Name='empty file preserves previous empty result'; Primary=''; Legacy=$null; Expected='' },
        @{ Name='legacy format with newline uses first path'; Primary=$null; Legacy="format=1`npath=/fixture/legacy`npath=/ignored`n"; Expected='/fixture/legacy' },
        @{ Name='legacy format without final newline'; Primary=$null; Legacy="format=1`npath=/fixture/legacy"; Expected='/fixture/legacy' },
        @{ Name='primary registration precedes legacy'; Primary='/fixture/center'; Legacy="format=1`npath=/ignored"; Expected='/fixture/center' }
    )
    foreach ($case in $validCases) {
        foreach ($path in @($registration,$legacy)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
        if ($null -ne $case.Primary) { [IO.File]::WriteAllText($registration,$case.Primary,$utf8) }
        if ($null -ne $case.Legacy) { [IO.File]::WriteAllText($legacy,$case.Legacy,$utf8) }
        $result = Run-Probe read_registered_path
        Check $case.Name ($result.Code -eq 0 -and $result.Value -ceq $case.Expected -and -not $result.Error -and -not $result.Downstream -and -not $result.Fallback)
    }
    foreach ($path in @($registration,$legacy)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    foreach ($caller in @('find_candidate','install_or_register','repair_task_center')) {
        $result = Run-Probe $caller
        $install = $caller -eq 'install_or_register'
        $expected = if ($install) { 91 } else { 1 }
        Check "$caller genuine absence control" ($result.Code -eq $expected -and $result.Fallback -and $result.Downstream -eq $install -and $result.Error -notmatch 'could not read')
    }
    foreach ($location in @('primary','legacy')) {
        foreach ($path in @($registration,$legacy)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
        $inputPath = if ($location -eq 'primary') { $registration } else { $legacy }
        [IO.File]::WriteAllText($inputPath,"/fixture/center`n",$utf8)
        foreach ($fault in @(@{Code=9;Partial=''},@{Code=9;Partial='/injected/partial'},@{Code=1;Partial='/injected/partial'})) {
            foreach ($caller in @('read_registered_path','find_candidate','install_or_register','repair_task_center')) {
                $result = Run-Probe $caller $fault.Code $fault.Partial
                $diagnostic = if ($caller -eq 'read_registered_path') { $result.Error -match 'injected registration read failure' }
                    else { $result.Error -match '(?m)^setup-task-center: could not read task-center registration\.\r?$' }
                Check "$location $caller reader failure $($fault.Code) partial=$([bool]$fault.Partial)" (
                    $result.Code -eq 4 -and $result.Value -ceq '' -and $diagnostic -and
                    $result.Error -notmatch 'multiple worktrees|was not found|candidate directory is not accessible' -and
                    -not $result.Downstream -and -not $result.Fallback)
            }
        }
    }
    Write-Output "Registration checks: $script:passed passed, $script:failed failed."
} finally {
    $resolved = (Resolve-Path -LiteralPath $fixtureRoot).Path
    $parentPrefix = $fixtureParent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($parentPrefix,[StringComparison]::OrdinalIgnoreCase) -or
        (Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing to remove a fixture outside the temporary directory or a reparse point.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    Write-Output "Fixture removed: $resolved"
}
if ($script:failed) { exit 1 }
