param(
    [string]$SetupPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/setup-task-center.ps1')
)
$ErrorActionPreference = 'Stop'

# Exercise the original discovery functions without invoking the setup entry point.
# Only Git's worktree listing and the registration input are simulated.
$parseTokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($SetupPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Setup source has parse errors.' }
foreach ($name in @('Get-CanonicalPath','Get-Worktrees','Assert-CandidateDirectory','Get-TaskCenterCandidate')) {
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $function) {
        if ($name -eq 'Assert-CandidateDirectory') { continue } # Allows a pre-fix regression run.
        throw "Missing source function: $name"
    }
    . ([scriptblock]::Create($function.Extent.Text))
}
function Stop-Setup([string]$Message) { throw $Message }
function Invoke-Git([string]$At, [string[]]$GitArgs) {
    if (($GitArgs -join ' ') -ne 'worktree list --porcelain') { throw 'Unexpected Git call.' }
    return $script:Listing
}
function Read-Registration { return $script:TestRegistration }
function New-Listing([string]$Path, [string]$OnBranch = 'task-center', [switch]$Prunable) {
    @("worktree $Path", 'HEAD 0000000000000000000000000000000000000000', "branch refs/heads/$OnBranch")
    if ($Prunable) { 'prunable gitdir file points to non-existent location' }
    ''
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('setup-candidate-' + [guid]::NewGuid().ToString('N'))
$live = Join-Path $fixtureRoot 'live'
$missing = Join-Path $fixtureRoot 'missing'
$plainFile = Join-Path $fixtureRoot 'plain-file'
$savedCenterPath = $env:TASK_CENTER_PATH
$script:GitRoot = $fixtureRoot
$Branch = 'task-center'
$script:Failures = [Collections.Generic.List[string]]::new()
function Check-Candidate([string]$Name, [string[]]$Listing, [string]$Registered = '',
    [string]$Explicit = '', [string]$ExpectedPath = '', [string]$ErrorContains = '', [switch]$ExpectNone) {
    $script:Listing = $Listing
    $script:TestRegistration = if ($Registered) { @{path=$Registered} } else { $null }
    $env:TASK_CENTER_PATH = $Explicit
    $actual = $null; $failure = ''
    try { $actual = Get-TaskCenterCandidate } catch { $failure = $_.Exception.Message }
    $passed = if ($ErrorContains) {
        $failure -and $failure.Contains($ErrorContains)
    } elseif ($ExpectNone) {
        -not $failure -and $null -eq $actual
    } else {
        -not $failure -and $actual.Path -ceq (Get-CanonicalPath $ExpectedPath $fixtureRoot)
    }
    if ($passed) { Write-Output "PASS: $Name" }
    else { $script:Failures.Add($Name); Write-Output "FAIL: $Name (path=$($actual.Path); error=$failure)" }
}
try {
    $null = New-Item -ItemType Directory -Path $live
    $null = New-Item -ItemType File -Path $plainFile
    $liveListing = @(New-Listing $live)
    $staleListing = @(New-Listing $missing -Prunable)
    Check-Candidate 'registered deleted path still listed, with live alternative' ($staleListing + $liveListing) -Registered $missing -ErrorContains $missing
    Check-Candidate 'explicit deleted path still listed' $staleListing -Explicit $missing -ErrorContains $missing
    Check-Candidate 'branch discovery selects deleted path' $staleListing -ErrorContains $missing
    Check-Candidate 'registered path is a file' @(New-Listing $plainFile) -Registered $plainFile -ErrorContains $plainFile
    Check-Candidate 'explicit live candidate' $liveListing -Explicit $live -ExpectedPath $live
    Check-Candidate 'registered live candidate retains priority' ($liveListing + $staleListing) -Registered $live -ExpectedPath $live
    Check-Candidate 'stale registration absent from list discovers live' $liveListing -Registered $missing -ExpectedPath $live
    Check-Candidate 'no registration discovers live' $liveListing -ExpectedPath $live
    Check-Candidate 'multiple branch matches remain ambiguous' ($liveListing + $staleListing) -ErrorContains '多个'
    Check-Candidate 'explicit path absent from list stays rejected' $liveListing -Explicit $missing -ErrorContains '不是当前克隆登记'
    Check-Candidate 'explicit wrong branch stays rejected' @(New-Listing $live 'other') -Explicit $live -ErrorContains '分支冲突'
    Check-Candidate 'no matching candidate returns none' @() -ExpectNone
    if ($script:Failures.Count) { throw "Candidate regression failed: $($script:Failures -join '; ')" }
    Write-Output 'All 12 candidate discovery checks passed.'
} finally {
    if ($null -eq $savedCenterPath) { Remove-Item Env:TASK_CENTER_PATH -ErrorAction SilentlyContinue }
    else { $env:TASK_CENTER_PATH = $savedCenterPath }
    # Only remove known files and empty directories created by this test.
    if (Test-Path -LiteralPath $plainFile) { Remove-Item -LiteralPath $plainFile -Force }
    if (Test-Path -LiteralPath $live) { Remove-Item -LiteralPath $live }
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot }
}
