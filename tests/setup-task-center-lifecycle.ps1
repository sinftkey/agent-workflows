param(
    [string]$SourcePath = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('both','bash','powershell')][string]$InstallerShell = 'both',
    [string]$BashPath = 'D:\Git\bin\bash.exe'
)
$ErrorActionPreference = 'Stop'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$git = (Get-Command git -ErrorAction Stop).Source
$BashPath = (Resolve-Path -LiteralPath $BashPath).Path
$cygpath = Join-Path (Split-Path -Parent (Split-Path -Parent $BashPath)) 'usr/bin/cygpath.exe'
$SourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $tempParent ('setup-lifecycle-' + [guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$script:passed = 0
function Unix-Path([string]$Path) {
    $output = @(& $cygpath -u $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "cygpath failed: $Path" }
    return ($output -join '').Trim()
}
function Run-Process([string]$File, [string[]]$Arguments, [string]$WorkingDirectory, [hashtable]$Environment) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $File; $start.WorkingDirectory = $WorkingDirectory; $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    foreach ($key in $Environment.Keys) { $start.Environment[$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{Code=$process.ExitCode;Out=$stdout.Result;Error=$stderr.Result}
    } finally { $process.Dispose() }
}
function Check([string]$Name, [bool]$Passed) {
    if (-not $Passed) { throw "FAIL: $Name" }
    $script:passed++; Write-Output "PASS: $Name"
}
function Git-Fixture([string]$Directory, [string[]]$Arguments) {
    $result = Run-Process $git (@('-C',$Directory) + $Arguments) $repo $environment
    if ($result.Code -ne 0) { throw "Fixture Git failed: $($Arguments -join ' ')`n$($result.Out)$($result.Error)" }
    return $result.Out.TrimEnd([char[]]"`r`n")
}
function Client([string]$Shell, [string]$Identity, [string[]]$Arguments) {
    $childEnvironment = $environment.Clone()
    $childEnvironment.TASK_IDENTITY = $Identity
    # Discover the setup registration: do not bypass it with TASK_CENTER_PATH.
    if ($Shell -eq 'bash') {
        $childEnvironment.GIT_CONFIG_GLOBAL = Unix-Path $config
        $command = $BashPath
        $childArguments = @((Unix-Path (Join-Path $center 'scripts/task.sh'))) + $Arguments
        for ($i=0; $i -lt $childArguments.Count; $i++) {
            if ($childArguments[$i] -in @('--export','--import')) { $i++; $childArguments[$i] = Unix-Path $childArguments[$i] }
        }
    } else {
        $command = $pwsh
        $childArguments = @('-NoLogo','-NoProfile','-File',(Join-Path $center 'scripts/task.ps1')) + $Arguments
    }
    $result = Run-Process $command $childArguments $repo $childEnvironment
    Write-Output "CLIENT $Shell $Identity $($Arguments -join ' ') EXIT $($result.Code)"
    if ($result.Out) { Write-Output $result.Out.TrimEnd() }
    if ($result.Error) { Write-Output $result.Error.TrimEnd() }
    if ($result.Code -ne 0) { throw 'Client command failed.' }
}
function Task-Snapshot {
    $entries = @(Get-ChildItem -LiteralPath $center -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        [IO.Path]::GetRelativePath($center,$_.FullName) + ' ' + (Get-FileHash -LiteralPath $_.FullName).Hash
    })
    return ((Git-Fixture $center @('rev-parse','HEAD')) + "`n" + ($entries -join "`n"))
}
try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    $config = Join-Path $fixtureRoot 'gitconfig'
    [IO.File]::WriteAllText($config,'',$utf8)
    $environment = @{
        GIT_CONFIG_GLOBAL=$config; GIT_CONFIG_NOSYSTEM='1'; BASH_ENV=''; ENV=''
        TASK_CENTER_PATH=''; TASK_BRANCH='task-center'; TASK_WORKTREE_NAME='task-center'
        TASK_IDENTITY='maintainer'; TASK_MAINTAINERS='maintainer'; TASK_REVIEWERS='reviewer'
        TASK_TESTERS='tester'; TASK_MERGE_AUTHORIZED='maintainer'; TASK_LOCK_TIMEOUT='5'
        TASK_CENTER_BACKUP_DIR=''
    }
    $installers = if ($InstallerShell -eq 'both') { @('bash','powershell') } else { @($InstallerShell) }
    foreach ($installer in $installers) {
        $repo = Join-Path $fixtureRoot $installer
        $null = New-Item -ItemType Directory -Path $repo
        $center = Join-Path $repo '.worktrees/task-center'
        $null = Git-Fixture $repo @('init','-b','main')
        $null = Git-Fixture $repo @('config','user.name','Lifecycle Fixture')
        $null = Git-Fixture $repo @('config','user.email','lifecycle@example.invalid')
        $readme = Join-Path $repo 'README.md'
        [IO.File]::WriteAllText($readme,'fixture code branch',$utf8)
        $null = Git-Fixture $repo @('add','README.md')
        $null = Git-Fixture $repo @('commit','--no-gpg-sign','-m','test: isolated lifecycle fixture')
        $setupEnvironment = $environment.Clone()
        if ($installer -eq 'bash') {
            $setupEnvironment.GIT_CONFIG_GLOBAL = Unix-Path $config
            $setup = Run-Process $BashPath @((Unix-Path (Join-Path $SourcePath 'scripts/setup-task-center.sh')),'--repo',(Unix-Path $repo),'--source',(Unix-Path $SourcePath)) $repo $setupEnvironment
        } else {
            $setup = Run-Process $pwsh @('-NoLogo','-NoProfile','-File',(Join-Path $SourcePath 'scripts/setup-task-center.ps1'),'-RepoPath',$repo,'-SourcePath',$SourcePath) $repo $setupEnvironment
        }
        Write-Output "INSTALLER $installer EXIT $($setup.Code)`n$($setup.Out)$($setup.Error)"
        Check "$installer installation succeeds" ($setup.Code -eq 0)
        # Preserve a genuinely dirty code workspace while clients commit on the center branch.
        [IO.File]::WriteAllText($readme,'fixture uncommitted code change',$utf8)
        $untracked = Join-Path $repo 'unrelated.txt'
        [IO.File]::WriteAllText($untracked,'fixture untracked code file',$utf8)
        $codeHead = Git-Fixture $repo @('rev-parse','HEAD')
        $codeState = Git-Fixture $repo @('status','--porcelain','--untracked-files=all')
        $readmeHash = (Get-FileHash -LiteralPath $readme).Hash
        $untrackedHash = (Get-FileHash -LiteralPath $untracked).Hash
        $first = if ($installer -eq 'bash') { 'powershell' } else { 'bash' }
        $second = if ($first -eq 'bash') { 'powershell' } else { 'bash' }
        foreach ($shell in @($first,$second)) {
            Client $shell maintainer @('init')
            Check "$installer installed $shell client discovers registration" $true
        }
        Client $first maintainer @('new','Cross client fixture','--slug','cross-client','--acceptance','Fixture acceptance')
        $active = Join-Path $center 'docs/tasks/0001-cross-client.md'
        Check "$installer creates task 1" (Test-Path -LiteralPath $active)
        Client $second dev-session @('claim','TC-0001')
        Client $first dev-session @('status','1','进行中')
        Client $second dev-session @('progress','1','Fixture implementation checkpoint','--evidence','fixture-only')
        $snapshot = Task-Snapshot
        $intruderEnvironment = $environment.Clone(); $intruderEnvironment.TASK_IDENTITY = 'intruder'
        # Use the installed PowerShell client for a refused write, without an explicit center path.
        $refused = Run-Process $pwsh @('-NoLogo','-NoProfile','-File',(Join-Path $center 'scripts/task.ps1'),'status','1','待审核','--assignee','reviewer','--evidence','unauthorized') $repo $intruderEnvironment
        Write-Output "UNAUTHORIZED EXIT $($refused.Code)`n$($refused.Out)$($refused.Error)"
        Check "$installer refuses an unauthorized transition" ($refused.Code -ne 0 -and ($refused.Out + $refused.Error) -match 'owner|权限|负责人')
        Check "$installer refused write keeps task bytes and HEAD" ((Task-Snapshot) -ceq $snapshot)
        $draft = Join-Path $fixtureRoot "$installer-draft.md"
        Client $first dev-session @('edit','1','--export',$draft)
        $draftText = [IO.File]::ReadAllText($draft)
        if (-not $draftText.Contains('- [ ] Fixture acceptance')) { throw 'Expected an unchecked fixture acceptance criterion.' }
        [IO.File]::WriteAllText($draft,$draftText.Replace('- [ ] Fixture acceptance','- [x] Fixture acceptance'),$utf8)
        $base = ([IO.File]::ReadAllText("$draft.base").Trim() -split '\s+')[0]
        Client $second dev-session @('edit','1','--import',$draft,'--base',$base)
        Check "$installer imports the other client draft" ([IO.File]::ReadAllText($active).Contains('- [x] Fixture acceptance'))
        Client $first dev-session @('status','1','待审核','--assignee','reviewer','--evidence','fixture-ready')
        Client $second reviewer @('status','1','待测试','--assignee','tester','--evidence','fixture-review')
        Client $first tester @('status','1','待合并','--assignee','maintainer','--evidence','fixture-test')
        Client $second maintainer @('done','1','--evidence','fixture-delivery')
        $archive = Join-Path $center 'docs/tasks/archive/0001-cross-client.md'
        Check "$installer moves completed task 1 into the archive" ((Test-Path -LiteralPath $archive) -and -not (Test-Path -LiteralPath $active))
        $archived = [IO.File]::ReadAllText($archive)
        Check "$installer preserves completion and both client evidence" (
            $archived.Contains('状态：已完成') -and $archived.Contains('owner：dev-session') -and
            $archived.Contains('fixture-ready') -and $archived.Contains('fixture-review') -and
            $archived.Contains('fixture-test') -and $archived.Contains('fixture-delivery'))
        foreach ($shell in @($first,$second)) { Client $shell maintainer @('check'); Client $shell maintainer @('list','--all') }
        Client $second maintainer @('new','Next fixture task','--slug','next','--acceptance','No archived number reuse')
        Check "$installer does not reuse archived id" ((Test-Path -LiteralPath (Join-Path $center 'docs/tasks/0002-next.md')) -and [IO.File]::ReadAllText((Join-Path $center '.task-center/next-id')).Trim() -eq '3')
        Client $first maintainer @('cancel','2','--reason','fixture-only cleanup')
        foreach ($shell in @($first,$second)) { Client $shell maintainer @('check') }
        Check "$installer both clients finish with a valid clean center" (-not (Git-Fixture $center @('status','--porcelain','--untracked-files=all')))
        Check "$installer code HEAD and dirty state remain unchanged" (
            (Git-Fixture $repo @('rev-parse','HEAD')) -ceq $codeHead -and
            (Git-Fixture $repo @('status','--porcelain','--untracked-files=all')) -ceq $codeState -and
            (Get-FileHash -LiteralPath $readme).Hash -ceq $readmeHash -and
            (Get-FileHash -LiteralPath $untracked).Hash -ceq $untrackedHash)
        Check "$installer releases locks and leaves no pending transaction" (
            -not (Test-Path -LiteralPath (Join-Path $repo '.git/task-center-write.lock')) -and
            -not @(Get-ChildItem -LiteralPath (Join-Path $repo '.git/task-center-runtime/transactions') -Force -ErrorAction SilentlyContinue).Count)
    }
    Write-Output "Lifecycle assertions passed: $script:passed. All client commands succeeded except the expected unauthorized attempts."
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot).Path
        $prefix = $tempParent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
            (Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Refusing to recursively remove a fixture outside temp or a reparse point.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
        Write-Output "Fixture removed: $resolved"
    }
}
