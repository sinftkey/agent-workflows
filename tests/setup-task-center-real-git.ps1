param(
    [string]$SetupPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/setup-task-center.ps1')
)
$ErrorActionPreference = 'Stop'
$parseTokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($SetupPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Setup source has parse errors.' }
foreach ($name in @('Stop-Setup','Invoke-Git','Get-CanonicalPath','Get-Worktrees',
    'Read-Registration','Assert-CandidateDirectory','Get-TaskCenterCandidate')) {
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $function) {
        if ($name -eq 'Assert-CandidateDirectory') { continue }
        throw "Missing source function: $name"
    }
    . ([scriptblock]::Create($function.Extent.Text))
}

# Run original discovery, Git and registration functions. Never execute setup's entry point.
$fixtureParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $fixtureParent ('setup-real-git-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $fixtureRoot 'repo'
$stale = Join-Path $fixtureRoot 'stale'
$live = Join-Path $fixtureRoot 'live'
$savedCenterPath = $env:TASK_CENTER_PATH
$savedNoSystem = $env:GIT_CONFIG_NOSYSTEM
$savedGlobalConfig = $env:GIT_CONFIG_GLOBAL
$script:Failures = [Collections.Generic.List[string]]::new()
$Branch = 'task-center'
function Git-Fixture([string[]]$GitArgs) {
    $output = @(& git -C $repo @GitArgs 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($GitArgs -join ' ')`n$($output -join "`n")" }
    return $output
}
function Check-Discovery([string]$Name, [string]$Explicit = '', [string]$Registered = '',
    [string]$ExpectedPath = '', [switch]$ExpectMissing) {
    $env:TASK_CENTER_PATH = $Explicit
    if ($Registered) { [IO.File]::WriteAllText($script:Registration, $Registered + "`n", [Text.UTF8Encoding]::new($false)) }
    elseif (Test-Path -LiteralPath $script:Registration) { Remove-Item -LiteralPath $script:Registration }
    $actual = $null; $failure = ''
    try { $actual = Get-TaskCenterCandidate } catch { $failure = $_.Exception.Message }
    $passed = if ($ExpectMissing) {
        $failure.Contains('候选目录不存在或不是目录') -and $failure.Contains($stale)
    } else {
        -not $failure -and $actual.Path -ceq (Get-CanonicalPath $ExpectedPath $repo)
    }
    if ($passed) { Write-Output "PASS: $Name" }
    else { $script:Failures.Add($Name); Write-Output "FAIL: $Name (path=$($actual.Path); error=$failure)" }
}
function Remove-FixtureDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $expectedRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $prefix = $expectedRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolved -ne $expectedRoot -and -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a path outside the test fixture.'
    }
    if ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing to recursively remove a reparse point.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
try {
    $null = New-Item -ItemType Directory -Path $repo
    $globalConfig = Join-Path $fixtureRoot 'gitconfig'
    [IO.File]::WriteAllText($globalConfig, '', [Text.UTF8Encoding]::new($false))
    $env:GIT_CONFIG_NOSYSTEM = '1'; $env:GIT_CONFIG_GLOBAL = $globalConfig
    $null = Git-Fixture @('init','-b','main')
    $null = Git-Fixture @('config','user.name','Candidate Regression')
    $null = Git-Fixture @('config','user.email','candidate@example.invalid')
    $null = Git-Fixture @('commit','--allow-empty','--no-gpg-sign','-m','test: isolated worktree fixture')
    $null = Git-Fixture @('worktree','add','-b',$Branch,$stale)
    $script:GitRoot = $repo
    $script:Registration = Join-Path $repo '.git/task-center/install-path'
    $script:RuntimeDir = Join-Path $repo '.git/task-center-runtime'
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:Registration)
    Check-Discovery 'existing registered worktree' -Registered $stale -ExpectedPath $stale

    # Delete only the worktree created above; keep its real Git administrative record.
    Remove-FixtureDirectory $stale
    $listing = @(Git-Fixture @('worktree','list','--porcelain'))
    Write-Output 'REAL GIT LISTING AFTER WORKTREE DELETION:'
    $listing | Write-Output
    if (($listing -join "`n") -notmatch '(?m)^prunable(?: |$)') { throw 'Git did not produce a prunable entry.' }
    $parsed = @(Get-Worktrees | Where-Object { $_.Path -eq $stale -and $_.Branch -eq $Branch })
    if ($parsed.Count -ne 1) { throw 'Original parser did not retain the deleted worktree.' }
    Check-Discovery 'deleted registered worktree from real listing' -Registered $stale -ExpectMissing
    Check-Discovery 'deleted explicit worktree from real listing' -Explicit $stale -ExpectMissing
    Check-Discovery 'deleted worktree from branch discovery' -ExpectMissing

    # Prune and recreate only in this disposable fixture to exercise an absent old record.
    $null = Git-Fixture @('worktree','prune','--expire','now')
    $null = Git-Fixture @('worktree','add',$live,$Branch)
    Check-Discovery 'stale registration absent from real listing discovers live' -Registered $stale -ExpectedPath $live
    Check-Discovery 'live explicit worktree' -Explicit $live -ExpectedPath $live
    Check-Discovery 'live branch discovery' -ExpectedPath $live
    if ($script:Failures.Count) { throw "Real Git regression failed: $($script:Failures -join '; ')" }
    Write-Output 'All 7 real Git discovery checks passed.'
} finally {
    if ($null -eq $savedCenterPath) { Remove-Item Env:TASK_CENTER_PATH -ErrorAction SilentlyContinue }
    else { $env:TASK_CENTER_PATH = $savedCenterPath }
    if ($null -eq $savedNoSystem) { Remove-Item Env:GIT_CONFIG_NOSYSTEM -ErrorAction SilentlyContinue }
    else { $env:GIT_CONFIG_NOSYSTEM = $savedNoSystem }
    if ($null -eq $savedGlobalConfig) { Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue }
    else { $env:GIT_CONFIG_GLOBAL = $savedGlobalConfig }
    $parentPrefix = $fixtureParent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not ([IO.Path]::GetFullPath($fixtureRoot)).StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fixture root is outside the intended temporary directory.'
    }
    Remove-FixtureDirectory $fixtureRoot
}
