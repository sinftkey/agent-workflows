param(
    [string]$BashPath = 'D:\Git\bin\bash.exe',
    [ValidateSet('both','bash','powershell')][string]$ShellSelection = 'both',
    [switch]$KeepTestData
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Git = (Get-Command git -ErrorAction Stop).Source
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$Bash = (Resolve-Path -LiteralPath $BashPath -ErrorAction Stop).Path
$Cygpath = Join-Path (Split-Path -Parent (Split-Path -Parent $Bash)) 'usr/bin/cygpath.exe'
if (-not (Test-Path -LiteralPath $Cygpath)) { throw "找不到 cygpath：$Cygpath" }
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("task-center-conformance-" + [guid]::NewGuid().ToString('N'))

function Invoke-GitLocal([string]$Path, [string[]]$Arguments) {
    $output = @(& $Git -C $Path @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') 失败：$($output -join "`n")" }
    return ($output -join "`n")
}
function Invoke-Process([string]$File, [string[]]$Arguments, [string]$WorkingDirectory, [hashtable]$Environment) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $File; $start.WorkingDirectory = $WorkingDirectory; $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    foreach ($key in $Environment.Keys) { $start.Environment[$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start; [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync(); $process.WaitForExit()
    $stdout = $stdoutTask.Result.Replace("`r`n","`n").Replace("`r","`n").TrimEnd()
    $stderr = $stderrTask.Result.Replace("`r`n","`n").Replace("`r","`n").TrimEnd()
    return [pscustomobject]@{ExitCode=$process.ExitCode;Stdout=$stdout;Stderr=$stderr}
}
function Assert-Task([string]$Shell, [string]$CodeRoot, [string]$TaskRoot, [string]$Identity, [string[]]$Arguments, [switch]$ExpectFailure) {
    $environment = @{
        TASK_CENTER_PATH = $TaskRoot
        TASK_BRANCH = 'task-center'
        TASK_IDENTITY = $Identity
        TASK_MAINTAINERS = 'maintainer'
        TASK_REVIEWERS = 'reviewer'
        TASK_TESTERS = 'tester'
        TASK_MERGE_AUTHORIZED = 'maintainer'
        TASK_LOCK_TIMEOUT = '5'
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_GLOBAL = (Join-Path $TempRoot 'gitconfig')
    }
    if ($Shell -eq 'bash') {
        $unixRoot = (& $Cygpath -u $TaskRoot).Trim(); $unixScript = (& $Cygpath -u (Join-Path $Repo 'templates/task-center/scripts/task.sh')).Trim()
        $environment.TASK_CENTER_PATH = $unixRoot
        $environment.GIT_CONFIG_GLOBAL = (& $Cygpath -u $environment.GIT_CONFIG_GLOBAL).Trim()
        $unixArguments = [Collections.Generic.List[string]]::new()
        for ($i=0; $i -lt $Arguments.Count; $i++) {
            $unixArguments.Add($Arguments[$i])
            if ($Arguments[$i] -in @('--export','--import')) { $i++; $unixArguments.Add((& $Cygpath -u $Arguments[$i]).Trim()) }
        }
        $result = Invoke-Process $Bash (@($unixScript) + $unixArguments.ToArray()) $CodeRoot $environment
    } else {
        $scriptPath = Join-Path $Repo 'templates/task-center/scripts/task.ps1'
        $result = Invoke-Process $Pwsh (@('-NoLogo','-NoProfile','-File',$scriptPath) + $Arguments) $CodeRoot $environment
    }
    if ($ExpectFailure) {
        if ($result.ExitCode -eq 0) { throw "$Shell 命令意外成功：$($Arguments -join ' ')`n$($result.Stdout)`n$($result.Stderr)" }
    } elseif ($result.ExitCode -ne 0) { throw "$Shell 命令失败：$($Arguments -join ' ')`n$($result.Stdout)`n$($result.Stderr)" }
    return $result
}
function New-TestRepo([string]$Name) {
    $repoPath = Join-Path $TempRoot $Name; $taskPath = Join-Path $TempRoot "$Name-task-center"
    [IO.Directory]::CreateDirectory($repoPath) | Out-Null
    Invoke-GitLocal $repoPath @('init','-b','main') | Out-Null
    Invoke-GitLocal $repoPath @('config','user.name','Conformance Test') | Out-Null
    Invoke-GitLocal $repoPath @('config','user.email','conformance@example.invalid') | Out-Null
    Set-Content -LiteralPath (Join-Path $repoPath 'README.md') -Value 'code branch fixture' -Encoding utf8NoBOM
    Invoke-GitLocal $repoPath @('add','README.md') | Out-Null; Invoke-GitLocal $repoPath @('commit','-m','test: code branch') | Out-Null
    Invoke-GitLocal $repoPath @('worktree','add','--detach',$taskPath,'HEAD') | Out-Null
    Invoke-GitLocal $taskPath @('switch','--orphan','task-center') | Out-Null
    Remove-Item -LiteralPath (Join-Path $taskPath 'README.md') -Force -ErrorAction SilentlyContinue
    foreach ($directory in @('scripts','.task-center','docs/tasks/archive')) { [IO.Directory]::CreateDirectory((Join-Path $taskPath $directory)) | Out-Null }
    Copy-Item -LiteralPath (Join-Path $Repo 'templates/task-center/TASK-CENTER.md') -Destination (Join-Path $taskPath 'TASK-CENTER.md')
    Copy-Item -LiteralPath (Join-Path $Repo 'templates/task-center/INDEX.md') -Destination (Join-Path $taskPath 'docs/tasks/INDEX.md')
    Copy-Item -LiteralPath (Join-Path $Repo 'templates/task-center/.task-center/version') -Destination (Join-Path $taskPath '.task-center/version')
    Copy-Item -LiteralPath (Join-Path $Repo 'templates/task-center/.task-center/next-id') -Destination (Join-Path $taskPath '.task-center/next-id')
    Copy-Item -LiteralPath (Join-Path $Repo 'templates/task-center/scripts/task.sh') -Destination (Join-Path $taskPath 'scripts/task.sh')
    Copy-Item -LiteralPath (Join-Path $Repo 'templates/task-center/scripts/task.ps1') -Destination (Join-Path $taskPath 'scripts/task.ps1')
    Invoke-GitLocal $taskPath @('add','TASK-CENTER.md','docs/tasks/INDEX.md','.task-center/version','.task-center/next-id','scripts/task.sh','scripts/task.ps1') | Out-Null
    Invoke-GitLocal $taskPath @('commit','-m','docs(tasks): initialize fixture') | Out-Null
    return [pscustomobject]@{Code=$repoPath;Task=$taskPath}
}
function New-PendingNextIdTransaction([string]$TaskPath,[string]$Id,[int]$Before,[int]$After) {
    $common = Invoke-GitLocal $TaskPath @('rev-parse','--git-common-dir')
    if (-not [IO.Path]::IsPathRooted($common)) { $common = Join-Path $TaskPath $common }
    $transaction = Join-Path (Join-Path ([IO.Path]::GetFullPath($common)) 'task-center-runtime/transactions') $Id
    $beforeRoot = Join-Path $transaction 'before/.task-center'; $afterRoot = Join-Path $transaction 'after/.task-center'
    [IO.Directory]::CreateDirectory($beforeRoot) | Out-Null; [IO.Directory]::CreateDirectory($afterRoot) | Out-Null
    $base = Invoke-GitLocal $TaskPath @('rev-parse','HEAD'); $relative = '.task-center/next-id'
    [IO.File]::WriteAllText((Join-Path $beforeRoot 'next-id'), "$Before`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $afterRoot 'next-id'), "$After`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $transaction 'manifest'), "journal-version=1`nid=$Id`ntoken=task-center-$Id`nbase=$base`nmessage=docs(tasks): recover fixture`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $transaction 'paths'), "$relative`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $transaction 'before-absent'), '', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $transaction 'after-absent'), '', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $transaction 'state'), "prepared`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $TaskPath $relative), "$After`n", [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{Directory=$transaction;Id=$Id;Relative=$relative}
}

try {
    [IO.Directory]::CreateDirectory($TempRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $TempRoot 'gitconfig'), '', [Text.UTF8Encoding]::new($false))
    $oldGitConfigNoSystem = $env:GIT_CONFIG_NOSYSTEM; $oldGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
    $env:GIT_CONFIG_NOSYSTEM = '1'; $env:GIT_CONFIG_GLOBAL = Join-Path $TempRoot 'gitconfig'
    $baselines = @{}
    $shells = if ($ShellSelection -eq 'both') { @('bash','powershell') } else { @($ShellSelection) }
    foreach ($shellName in $shells) {
        $fixture = New-TestRepo $shellName
        Assert-Task $shellName $fixture.Code $fixture.Task 'maintainer' @('init') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'maintainer' @('new','Invalid arguments','unexpected-value') -ExpectFailure | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'maintainer' @('new','Duplicate option','--slug','first','--slug','second') -ExpectFailure | Out-Null
        Invoke-GitLocal $fixture.Task @('config','branch.task-center.remote','origin') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'maintainer' @('check') -ExpectFailure | Out-Null
        Invoke-GitLocal $fixture.Task @('config','--unset','branch.task-center.remote') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'maintainer' @('new','Parity task','--slug','parity','--priority','高','--acceptance','Result matches','--external','https://example.invalid/issues/1') | Out-Null
        $taskFile = Join-Path $fixture.Task 'docs/tasks/0001-parity.md'
        $taskText = [IO.File]::ReadAllText($taskFile,[Text.Encoding]::UTF8).Replace('# 任务 #1 Parity task','# 任务 #0001 Parity task')
        [IO.File]::WriteAllText($taskFile,$taskText,[Text.UTF8Encoding]::new($false))
        Invoke-GitLocal $fixture.Task @('add','docs/tasks/0001-parity.md') | Out-Null
        Invoke-GitLocal $fixture.Task @('commit','-m','test: pad task header id') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'dev-session' @('claim','TC-0001') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'dev-session' @('status','1','进行中') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'dev-session' @('progress','1','Checkpoint','--evidence','commit abc') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'dev-session' @('status','1','已完成') -ExpectFailure | Out-Null
        $draft = Join-Path $TempRoot "$shellName-draft.md"
        Assert-Task $shellName $fixture.Code $fixture.Task 'dev-session' @('edit','1','--export',$draft) | Out-Null
        $draftText = (Get-Content -LiteralPath $draft -Raw -Encoding utf8).Replace('- [ ] Result matches','- [x] Result matches')
        [IO.File]::WriteAllText($draft,$draftText,[Text.UTF8Encoding]::new($false))
        $base = (Get-Content -LiteralPath "$draft.base" -Raw).Split(' ')[0]
        Assert-Task $shellName $fixture.Code $fixture.Task 'dev-session' @('edit','1','--import',$draft,'--base',$base) | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'dev-session' @('status','1','待审核','--assignee','reviewer','--evidence','review-ready') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'reviewer' @('status','1','待测试','--assignee','tester','--evidence','review-passed') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'tester' @('block','1','--reason','waiting fixture','--waiting-for','reviewer') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'tester' @('unblock','1','--evidence','dependency-ready') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'tester' @('status','1','进行中','--reason','test requested changes') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'dev-session' @('status','1','待审核','--assignee','reviewer','--evidence','review-ready-again') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'reviewer' @('status','1','待测试','--assignee','tester','--evidence','review-passed-again') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'tester' @('status','1','待合并','--assignee','maintainer','--evidence','tests-passed') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'maintainer' @('done','1','--evidence','delivery complete') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'maintainer' @('new','Archive numbering','--slug','second','--acceptance','No reuse') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'maintainer' @('cancel','2','--reason','fixture cleanup') | Out-Null
        $pending = New-PendingNextIdTransaction $fixture.Task 'recovery-fixture' 3 4
        $headBeforeRecovery = Invoke-GitLocal $fixture.Task @('rev-parse','HEAD')
        $taskCenterPath = Join-Path $fixture.Task 'TASK-CENTER.md'; $taskCenterBytes = [IO.File]::ReadAllBytes($taskCenterPath)
        [IO.File]::AppendAllText($taskCenterPath,"`nrecovery isolation sentinel",[Text.UTF8Encoding]::new($false))
        Invoke-GitLocal $fixture.Task @('add','TASK-CENTER.md') | Out-Null
        Assert-Task $shellName $fixture.Code $fixture.Task 'maintainer' @('recover','--commit') -ExpectFailure | Out-Null
        if ((Invoke-GitLocal $fixture.Task @('rev-parse','HEAD')) -ne $headBeforeRecovery) { throw 'recover --commit 提交了事务外暂存内容' }
        $staged = @(& $Git -C $fixture.Task diff --cached --name-only 2>$null)
        if ($LASTEXITCODE -ne 0) { throw '无法读取恢复后的暂存路径' }
        $staged = @($staged | Where-Object { $_ })
        if ($staged.Count -ne 1 -or $staged[0] -ne 'TASK-CENTER.md') { throw '拒绝恢复时未保留原有事务外暂存内容' }
        Invoke-GitLocal $fixture.Task @('reset','-q','HEAD','--','TASK-CENTER.md') | Out-Null
        [IO.File]::WriteAllBytes($taskCenterPath,$taskCenterBytes)
        Remove-Item -LiteralPath (Join-Path $fixture.Task $pending.Relative) -Force
        Copy-Item -LiteralPath (Join-Path $pending.Directory 'after/.task-center/next-id') -Destination "$(Join-Path $fixture.Task $pending.Relative).tmp.$($pending.Id)"
        Copy-Item -LiteralPath (Join-Path $pending.Directory 'before/.task-center/next-id') -Destination "$(Join-Path $fixture.Task $pending.Relative).bak.$($pending.Id)"
        $recoveryShell = if ($shellName -eq 'bash') { 'powershell' } else { 'bash' }
        Assert-Task $recoveryShell $fixture.Code $fixture.Task 'maintainer' @('recover','--commit') | Out-Null
        $recoveredPathText = Invoke-GitLocal $fixture.Task @('diff-tree','--no-commit-id','--name-only','-r','HEAD')
        $recoveredPaths = @($recoveredPathText -split "`r?`n" | Where-Object { $_ })
        if ($recoveredPaths.Count -ne 1 -or $recoveredPaths[0] -ne $pending.Relative) { throw '恢复提交夹带了事务外文件' }
        if ((Test-Path -LiteralPath "$(Join-Path $fixture.Task $pending.Relative).tmp.$($pending.Id)") -or (Test-Path -LiteralPath "$(Join-Path $fixture.Task $pending.Relative).bak.$($pending.Id)")) { throw '恢复后残留了原子替换临时文件' }
        Assert-Task $shellName $fixture.Code $fixture.Task 'maintainer' @('check') | Out-Null
        $list = Assert-Task $shellName $fixture.Code $fixture.Task 'maintainer' @('list','--all')
        $files = @('docs/tasks/INDEX.md','docs/tasks/archive/0001-parity.md','docs/tasks/archive/0002-second.md','.task-center/next-id')
        $snapshot = @{}
        foreach ($relative in $files) { $snapshot[$relative] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes((Join-Path $fixture.Task $relative)))) }
        $baselines[$shellName] = [pscustomobject]@{Snapshot=$snapshot;List=$list.Stdout;TaskRoot=$fixture.Task}
    }
    if ($ShellSelection -eq 'both') {
        foreach ($relative in $baselines.bash.Snapshot.Keys) {
            if ($baselines.bash.Snapshot[$relative] -ne $baselines.powershell.Snapshot[$relative]) {
                $bashBytes = [IO.File]::ReadAllBytes((Join-Path $baselines.bash.TaskRoot $relative))
                $powershellBytes = [IO.File]::ReadAllBytes((Join-Path $baselines.powershell.TaskRoot $relative))
                $limit = [Math]::Min($bashBytes.Length,$powershellBytes.Length); $first = 0
                while ($first -lt $limit -and $bashBytes[$first] -eq $powershellBytes[$first]) { $first++ }
                Write-Host "Bash bytes=$($bashBytes.Length); PowerShell bytes=$($powershellBytes.Length); first difference=$first"
                $from = [Math]::Max(0,$first-8); $count = [Math]::Min(32,$limit-$from)
                if ($count -gt 0) { Write-Host "Bash hex:       $([Convert]::ToHexString($bashBytes[$from..($from+$count-1)]))"; Write-Host "PowerShell hex: $([Convert]::ToHexString($powershellBytes[$from..($from+$count-1)]))" }
                Write-Host "--- Bash $relative ---"; Get-Content -LiteralPath (Join-Path $baselines.bash.TaskRoot $relative) -Encoding utf8
                Write-Host "--- PowerShell $relative ---"; Get-Content -LiteralPath (Join-Path $baselines.powershell.TaskRoot $relative) -Encoding utf8
                throw "Bash / PowerShell 结果不一致：$relative"
            }
        }
        if ($baselines.bash.List -cne $baselines.powershell.List) {
            Write-Host "--- Bash list ---`n$($baselines.bash.List)"
            Write-Host "--- PowerShell list ---`n$($baselines.powershell.List)"
            throw 'Bash / PowerShell list 输出不一致'
        }
    }
    Write-Host "任务中心 $ShellSelection conformance passed."
    if ($KeepTestData) { Write-Host "保留测试数据：$TempRoot" }
} finally {
    $env:GIT_CONFIG_NOSYSTEM = $oldGitConfigNoSystem
    $env:GIT_CONFIG_GLOBAL = $oldGitConfigGlobal
    $resolvedTemp = [IO.Path]::GetFullPath($TempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $KeepTestData -and $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedTemp).StartsWith('task-center-conformance-')) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
