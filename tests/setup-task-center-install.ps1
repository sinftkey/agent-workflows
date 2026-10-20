param(
    [string]$SetupPath = '',
    [string]$SourcePath = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('powershell','bash')][string]$ShellSelection = 'powershell',
    [string]$BashPath = 'D:\Git\bin\bash.exe',
    [switch]$RegistrationReadFault
)
$ErrorActionPreference = 'Stop'
if ($RegistrationReadFault -and $ShellSelection -ne 'bash') { throw 'RegistrationReadFault requires bash.' }
$engine = (Get-Command pwsh -ErrorAction Stop).Source
if (-not $SetupPath) {
    $extension = if ($ShellSelection -eq 'bash') { 'sh' } else { 'ps1' }
    $SetupPath = Join-Path $SourcePath "scripts/setup-task-center.$extension"
}
if ($ShellSelection -eq 'bash') {
    $BashPath = (Resolve-Path -LiteralPath $BashPath -ErrorAction Stop).Path
    $cygpath = Join-Path (Split-Path -Parent (Split-Path -Parent $BashPath)) 'usr/bin/cygpath.exe'
    if (-not (Test-Path -LiteralPath $cygpath -PathType Leaf)) { throw 'cygpath is required for this Windows Bash test.' }
}
function Convert-BashPath([string]$Path) {
    $result = @(& $cygpath -u $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "cygpath failed for $Path" }
    return ($result -join '').Trim()
}
$fixtureParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $fixtureParent ('setup-install-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $fixtureRoot 'repo'
$center = Join-Path $repo '.worktrees/task-center'
$registration = Join-Path $repo '.git/task-center/install-path'
$lockPath = Join-Path $repo '.git/task-center-write.lock'
$savedEnvironment = @{}
foreach ($name in @('TASK_CENTER_PATH','TASK_BRANCH','TASK_WORKTREE_NAME','GIT_CONFIG_GLOBAL','GIT_CONFIG_NOSYSTEM')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
function Git-Fixture([string[]]$GitArgs, [int[]]$Allowed = @(0)) {
    $output = @(& git -C $repo @GitArgs 2>&1)
    if ($Allowed -notcontains $LASTEXITCODE) { throw "Fixture Git failed: $($GitArgs -join ' ')`n$($output -join "`n")" }
    return $output
}
function Test-BashDirectoryDiagnostic([string]$Message, [string]$Directory) {
    if ($Message -match 'multiple worktrees|already registered|already checked out') { return $false }
    $matches = [regex]::Matches($Message, '(?m)^setup-task-center: candidate directory is not accessible: ([^\r\n]+)\r?$')
    if ($matches.Count -ne 1) { return $false }
    $reported = @(& $cygpath -w $matches[0].Groups[1].Value 2>&1)
    if ($LASTEXITCODE -ne 0) { return $false }
    return [IO.Path]::GetFullPath(($reported -join '').Trim()) -eq [IO.Path]::GetFullPath($Directory)
}
function Run-Setup([switch]$ExpectMissing, [switch]$ExpectMultiple, [switch]$ExpectReadFailure) {
    if ($ShellSelection -eq 'bash') {
        $setupUnix = Convert-BashPath $SetupPath
        $repoUnix = Convert-BashPath $repo
        $sourceUnix = Convert-BashPath $SourcePath
        $savedConfig = $env:GIT_CONFIG_GLOBAL
        $env:GIT_CONFIG_GLOBAL = Convert-BashPath $savedConfig
        try {
            $output = @(& $BashPath $setupUnix --repo $repoUnix --source $sourceUnix --branch task-center --worktree-name task-center 2>&1)
            $code = $LASTEXITCODE
        } finally { $env:GIT_CONFIG_GLOBAL = $savedConfig }
    } else {
        $output = @(& $engine -NoLogo -NoProfile -File $SetupPath -RepoPath $repo -SourcePath $SourcePath -Branch task-center -WorktreeName task-center 2>&1)
        $code = $LASTEXITCODE
    }
    $output | ForEach-Object { $_.ToString() } | Write-Output
    Write-Output "SETUP EXIT: $code"
    if ($ExpectReadFailure) {
        $script:BashReadExit = $code
        $script:BashReadMessage = $output -join "`n"
    } elseif ($ExpectMultiple) {
        if ($code -eq 0) { throw 'Setup accepted ambiguous worktrees.' }
        $script:BashMultipleDiagnostic = ($output -join "`n") -match '(?m)^setup-task-center: multiple worktrees are checked out on task-center\.\r?$' -and
            ($output -join "`n") -notmatch 'candidate directory is not accessible'
    } elseif ($ExpectMissing) {
        if ($ShellSelection -eq 'bash') {
            # Continue inspecting rejection effects, then fail on the misleading diagnostic.
            $script:BashDirectoryDiagnostic = Test-BashDirectoryDiagnostic ($output -join "`n") $center
            if ($code -eq 0) { throw 'Bash setup accepted the deleted installed directory.' }
        } elseif ($code -eq 0 -or ($output -join "`n") -notmatch '候选目录不存在或不是目录') {
            throw 'Setup did not reject the deleted selected directory with the expected diagnostic.'
        }
    } elseif ($code -ne 0) { throw 'Setup entry point failed.' }
}
function Check([string]$Name, [bool]$Passed) {
    if (-not $Passed) { throw "FAIL: $Name" }
    Write-Output "PASS: $Name"
}
function Check-BashPropagation {
    $source = [IO.File]::ReadAllText($SetupPath)
    $definitions = foreach ($name in @('install_or_register','repair_task_center','get_worktree_for_branch')) {
        $match = [regex]::Match($source, '(?ms)^' + $name + '\(\) \{\r?\n.*?^\}')
        if (-not $match.Success) { throw "Missing original Bash function: $name" }
        $match.Value
    }
    $probe = "set -euo pipefail`n" + ($definitions -join "`n") + @'

marker="$1"; injected_status="$2"; caller="$3"; BRANCH=task-center
die() { printf 'setup-task-center: %s\n' "$*" >&2; exit 1; }
remote_branch_refs() { :; }
find_candidate() { printf 'injected discovery status %s\n' "$injected_status" >&2; return "$injected_status"; }
get_main_worktree() { printf reached > "$marker"; return 91; }
gitc() { printf reached > "$marker"; return 91; }
worktree_lines() { return 91; }
"$caller"
'@
    $probePath = Join-Path $fixtureRoot 'propagation-probe.sh'
    [IO.File]::WriteAllText($probePath, $probe.Replace("`r`n","`n"), [Text.UTF8Encoding]::new($false))
    $probeUnix = Convert-BashPath $probePath
    $marker = Join-Path $fixtureRoot 'downstream-marker'
    $markerUnix = Convert-BashPath $marker
    foreach ($caller in @('install_or_register','repair_task_center')) {
        foreach ($status in @(1,2,3,4)) {
            if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker }
            $output = @(& $BashPath $probeUnix $markerUnix "$status" $caller 2>&1)
            $code = $LASTEXITCODE
            $reached = Test-Path -LiteralPath $marker
            $expected = if ($caller -eq 'install_or_register' -and $status -eq 1) { 91 } else { $status }
            Check "$caller discovery status $status propagation" ($code -eq $expected -and
                $reached -eq ($caller -eq 'install_or_register' -and $status -eq 1))
        }
    }
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker }
    $output = @(& $BashPath $probeUnix $markerUnix '0' get_worktree_for_branch 2>&1)
    $code = $LASTEXITCODE
    Check 'Git query failure is distinct from no candidate and ambiguity' ($code -eq 4 -and
        ($output -join "`n") -match 'could not query Git worktrees' -and
        ($output -join "`n") -notmatch 'multiple worktrees')
}
function Get-FileDigest([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path).Hash }
    return '<absent>'
}
function Get-RegistrationState {
    return (@($registration,(Join-Path $repo '.git/task-center-runtime/registration'),(Join-Path $repo '.git/info/exclude')) |
        ForEach-Object { Get-FileDigest $_ }) -join '|'
}
function Get-GitState {
    return @(
        ((Git-Fixture @('rev-parse','HEAD')) -join "`n")
        ((Git-Fixture @('for-each-ref','--format=%(refname) %(objectname)')) -join "`n")
        ((Git-Fixture @('worktree','list','--porcelain')) -join "`n")
        ((Git-Fixture @('status','--porcelain','--untracked-files=all')) -join "`n")
    ) -join "`n---`n"
}
function Get-FixtureTree {
    $gitPrefix = (Join-Path $repo '.git') + [IO.Path]::DirectorySeparatorChar
    $files = @(Get-ChildItem -LiteralPath $repo -File -Recurse -Force | Where-Object {
        -not $_.FullName.StartsWith($gitPrefix,[StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object FullName | ForEach-Object {
        [IO.Path]::GetRelativePath($repo,$_.FullName) + ' ' + (Get-FileHash -LiteralPath $_.FullName).Hash
    })
    $runtime = Join-Path $repo '.git/task-center-runtime'
    $runtimeEntries = if (Test-Path -LiteralPath $runtime) {
        @(Get-ChildItem -LiteralPath $runtime -Recurse -Force | Sort-Object FullName | ForEach-Object {
            [IO.Path]::GetRelativePath($runtime,$_.FullName)
        })
    } else { @() }
    return ($files + @('RUNTIME ENTRIES:') + $runtimeEntries) -join "`n"
}
function Check-BashRegistrationFaults([string]$Stage) {
    $legacy = Join-Path $repo '.git/task-center-runtime/registration'
    $hook = Join-Path $fixtureRoot 'reader-fault-env.sh'
    $marker = Join-Path $fixtureRoot 'reader-lock-marker'
    $hookText = @'
record_reader_fault() {
  if [[ -d "$X6_LOCK_DIR" && -f "$X6_LOCK_DIR/owner" ]]; then
    printf held > "$X6_READER_MARKER"
  else printf missing > "$X6_READER_MARKER"; fi
  printf 'X6 injected registration reader failure\n' >&2
}
cat() {
  if [[ $# == 2 && "$1" == -- && "$2" == "$X6_REGISTRATION_FILE" ]]; then
    record_reader_fault
    printf '%s' "$X6_READER_PARTIAL"
    return "$X6_READER_CODE"
  fi
  command cat "$@"
}
# Negative control also covers c1's old read -r first, without breaking the
# unrelated Git-version read at startup. The source file itself is untouched.
read() {
  if [[ $# == 2 && "$1" == -r && "$2" == first ]]; then
    record_reader_fault
    first="$X6_READER_PARTIAL"
    return "$X6_READER_CODE"
  fi
  builtin read "$@"
}
'@
    [IO.File]::WriteAllText($hook,$hookText.Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))
    $savedFiles = @{}
    foreach ($path in @($registration,$legacy)) {
        $savedFiles[$path] = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllBytes($path) } else { $null }
    }
    $savedFaultEnvironment = @{}
    foreach ($name in @('BASH_ENV','X6_LOCK_DIR','X6_READER_MARKER','X6_REGISTRATION_FILE','X6_READER_PARTIAL','X6_READER_CODE')) {
        $savedFaultEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    try {
        $env:BASH_ENV = Convert-BashPath $hook
        $env:X6_LOCK_DIR = Convert-BashPath $lockPath
        $env:X6_READER_MARKER = Convert-BashPath $marker
        foreach ($location in @('primary','legacy')) {
            foreach ($path in @($registration,$legacy)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
            }
            $inputPath = if ($location -eq 'primary') { $registration } else { $legacy }
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $inputPath) -Force
            [IO.File]::WriteAllText($inputPath,"/fixture/nonexistent-center`n",[Text.UTF8Encoding]::new($false))
            $env:X6_REGISTRATION_FILE = Convert-BashPath $inputPath
            foreach ($fault in @(@{Code=9;Partial=''},@{Code=1;Partial='/X6-partial-must-not-escape'})) {
                $env:X6_READER_CODE = [string]$fault.Code; $env:X6_READER_PARTIAL = $fault.Partial
                if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker }
                $registrationBefore = Get-RegistrationState
                $gitBefore = Get-GitState
                $treeBefore = Get-FixtureTree
                $label = "$Stage $location reader=$($fault.Code)"
                Run-Setup -ExpectReadFailure
                Check "$label fault reached under the real setup lock" (
                    (Test-Path -LiteralPath $marker) -and [IO.File]::ReadAllText($marker) -ceq 'held' -and
                    $script:BashReadMessage -match '(?m)^X6 injected registration reader failure\r?$')
                Check "$label returns 4 with only the correct failure category" (
                    $script:BashReadExit -eq 4 -and
                    $script:BashReadMessage -match '(?m)^setup-task-center: could not read task-center registration\.\r?$' -and
                    $script:BashReadMessage -notmatch 'multiple worktrees|was not found|candidate directory is not accessible|X6-partial-must-not-escape|Task center installed:|Task center is ready')
                Check "$label releases the real write lock" (-not (Test-Path -LiteralPath $lockPath))
                Check "$label preserves registration, exclude, refs and worktree listing" (
                    (Get-RegistrationState) -ceq $registrationBefore -and (Get-GitState) -ceq $gitBefore)
                Check "$label preserves code, center files and runtime contents" ((Get-FixtureTree) -ceq $treeBefore)
            }
        }
    } finally {
        foreach ($name in $savedFaultEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name,$savedFaultEnvironment[$name])
        }
        foreach ($path in $savedFiles.Keys) {
            if ($null -eq $savedFiles[$path]) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
            } else { [IO.File]::WriteAllBytes($path,$savedFiles[$path]) }
        }
    }
}
function Remove-FixtureDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $root = [IO.Path]::GetFullPath($fixtureRoot)
    $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolved -ne $root -and -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a path outside the test fixture.'
    }
    if ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing to recursively remove a reparse point.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
try {
    $null = New-Item -ItemType Directory -Path $repo
    $config = Join-Path $fixtureRoot 'gitconfig'
    [IO.File]::WriteAllText($config, '', [Text.UTF8Encoding]::new($false))
    $env:GIT_CONFIG_GLOBAL = $config; $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:TASK_CENTER_PATH = ''; $env:TASK_BRANCH = ''; $env:TASK_WORKTREE_NAME = ''
    $null = Git-Fixture @('init','-b','main')
    $null = Git-Fixture @('config','user.name','Install Regression')
    $null = Git-Fixture @('config','user.email','install@example.invalid')
    $readme = Join-Path $repo 'README.md'
    [IO.File]::WriteAllText($readme, 'fixture code branch sentinel', [Text.UTF8Encoding]::new($false))
    $null = Git-Fixture @('add','README.md')
    $null = Git-Fixture @('commit','--no-gpg-sign','-m','test: isolated install fixture')
    $mainHead = (Git-Fixture @('rev-parse','HEAD')) -join ''
    $readmeHash = (Get-FileHash -LiteralPath $readme).Hash

    if ($RegistrationReadFault) { Check-BashRegistrationFaults 'before installation' }
    Run-Setup
    Check 'registration points to installed directory' ([IO.Path]::GetFullPath(([IO.File]::ReadAllText($registration)).Trim()) -eq $center)
    $centerHead = (Git-Fixture @('rev-parse','refs/heads/task-center')) -join ''
    $null = Git-Fixture @('merge-base',$mainHead,$centerHead) @(1)
    Check 'task center history is separate from code history' ($LASTEXITCODE -eq 1)
    Push-Location $repo
    try {
        foreach ($command in @('init','check')) {
            if ($ShellSelection -eq 'bash') {
                $clientUnix = Convert-BashPath (Join-Path $center 'scripts/task.sh')
                $savedConfig = $env:GIT_CONFIG_GLOBAL
                $env:GIT_CONFIG_GLOBAL = Convert-BashPath $savedConfig
                try {
                    $output = @(& $BashPath $clientUnix $command 2>&1)
                    $code = $LASTEXITCODE
                } finally { $env:GIT_CONFIG_GLOBAL = $savedConfig }
            } else {
                $output = @(& $engine -NoLogo -NoProfile -File (Join-Path $center 'scripts/task.ps1') $command 2>&1)
                $code = $LASTEXITCODE
            }
            $output | ForEach-Object { $_.ToString() } | Write-Output
            Check "installed client $command" ($code -eq 0)
        }
    } finally { Pop-Location }
    Check 'code branch remains clean and unchanged' (
        ((Git-Fixture @('rev-parse','HEAD')) -join '') -eq $mainHead -and
        (Get-FileHash -LiteralPath $readme).Hash -eq $readmeHash -and
        -not ((Git-Fixture @('status','--porcelain')) -join '')
    )
    Run-Setup
    Check 'repeated setup keeps task center commit' (((Git-Fixture @('rev-parse','refs/heads/task-center')) -join '') -eq $centerHead)
    if ($RegistrationReadFault) { Check-BashRegistrationFaults 'after installation' }

    if ($ShellSelection -eq 'bash') {
        $other = Join-Path $fixtureRoot 'other-worktree'
        $registrationSaved = [IO.File]::ReadAllText($registration)
        # Create the deliberate ambiguity only in this disposable fixture.
        $null = Git-Fixture @('worktree','add','--force',$other,'task-center')
        Remove-Item -LiteralPath $registration
        $multipleBefore = (Git-Fixture @('worktree','list','--porcelain')) -join "`n"
        if ([regex]::Matches($multipleBefore,'(?m)^branch refs/heads/task-center\r?$').Count -ne 2) {
            throw 'Expected two actual task-center worktrees.'
        }
        Run-Setup -ExpectMultiple
        Check 'actual multiple worktrees have an ambiguity diagnostic' $script:BashMultipleDiagnostic
        Check 'ambiguity rejection preserves fixture state' (
            -not (Test-Path -LiteralPath $registration) -and -not (Test-Path -LiteralPath $lockPath) -and
            ((Git-Fixture @('worktree','list','--porcelain')) -join "`n") -ceq $multipleBefore -and
            ((Git-Fixture @('rev-parse','refs/heads/task-center')) -join '') -eq $centerHead -and
            ((Git-Fixture @('rev-parse','HEAD')) -join '') -eq $mainHead -and
            (Get-FileHash -LiteralPath $readme).Hash -eq $readmeHash -and
            -not ((Git-Fixture @('status','--porcelain')) -join '')
        )
        Remove-FixtureDirectory $other
        $null = Git-Fixture @('worktree','prune','--expire','now')
        [IO.File]::WriteAllText($registration,$registrationSaved,[Text.UTF8Encoding]::new($false))
    }

    $registrationBefore = [IO.File]::ReadAllText($registration)
    Remove-FixtureDirectory $center
    $listingBefore = (Git-Fixture @('worktree','list','--porcelain')) -join "`n"
    Check 'deleted installed worktree remains prunable' ($listingBefore -match '(?m)^prunable(?: |$)')
    Write-Output 'REAL GIT LISTING BEFORE REJECTED SETUP:'
    Write-Output $listingBefore
    $branchEntries = [regex]::Matches($listingBefore, '(?m)^branch refs/heads/task-center\r?$').Count
    if ($branchEntries -ne 1) { throw 'This fixture must have exactly one target branch entry.' }
    Write-Output 'OBSERVED: exactly one task-center branch entry before rejection.'
    Run-Setup -ExpectMissing
    Check 'rejected setup releases write lock' (-not (Test-Path -LiteralPath $lockPath))
    Check 'rejected setup keeps registration and task branch' (
        [IO.File]::ReadAllText($registration) -ceq $registrationBefore -and
        ((Git-Fixture @('rev-parse','refs/heads/task-center')) -join '') -eq $centerHead
    )
    Check 'rejected setup does not recreate or prune worktree' (
        -not (Test-Path -LiteralPath $center) -and
        ((Git-Fixture @('worktree','list','--porcelain')) -join "`n") -ceq $listingBefore
    )
    Check 'code branch remains clean after rejection' (
        ((Git-Fixture @('rev-parse','HEAD')) -join '') -eq $mainHead -and
        (Get-FileHash -LiteralPath $readme).Hash -eq $readmeHash -and
        -not ((Git-Fixture @('status','--porcelain')) -join '')
    )
    if ($ShellSelection -eq 'bash') {
        Check 'Bash refusal identifies the missing directory rather than reporting multiple worktrees' $script:BashDirectoryDiagnostic
        $validMessage = 'setup-task-center: candidate directory is not accessible: ' + $center.Replace('\','/')
        Check 'generic registered/checked-out text cannot pass missing-directory diagnosis' (
            -not (Test-BashDirectoryDiagnostic 'already registered; already checked out' $center))
        Check 'mixed correct and misleading messages cannot pass' (
            -not (Test-BashDirectoryDiagnostic ($validMessage + "`nsetup-task-center: multiple worktrees are checked out on task-center.") $center))
        Check 'a diagnostic naming another directory cannot pass' (
            -not (Test-BashDirectoryDiagnostic ($validMessage + '-other') $center))
        Check-BashPropagation
        if ($RegistrationReadFault) { Write-Output 'All 66 bash installation, error-propagation and full-entry reader-fault checks passed.' }
        else { Write-Output 'All 26 bash installation and error-propagation checks passed.' }
    } else { Write-Output 'All 11 powershell installation entry-point checks passed.' }
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
    $parentPrefix = $fixtureParent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not ([IO.Path]::GetFullPath($fixtureRoot)).StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fixture root is outside the intended temporary directory.'
    }
    Remove-FixtureDirectory $fixtureRoot
}
