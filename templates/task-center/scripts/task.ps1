# Task center client. Keep behavior aligned with task.sh.
# UTF-8 BOM is required for Windows PowerShell 5.1 to parse non-ASCII source.
param()
$ErrorActionPreference = 'Continue'
$Branch = if ($env:TASK_BRANCH) { $env:TASK_BRANCH } else { 'task-center' }
$Identity = $env:TASK_IDENTITY
$ToolVersion = '1'
$SchemaVersion = '2'
$LockTimeout = if ($env:TASK_LOCK_TIMEOUT) { [int]$env:TASK_LOCK_TIMEOUT } else { 10 }

function Die([string]$Message) { [Console]::Error.WriteLine("错误：$Message"); exit 1 }
function Usage {
    [Console]::Error.WriteLine(@'
用法：task.ps1 <命令> [参数]
  init | list [--all] | check
  new <标题> [--slug <短名>] [--priority 高|中|低] [--depends <编号列表>] [--acceptance <文本>] [--external <完整链接>]
  claim <编号> | progress <编号> <内容> [--evidence <证据>]
  status <编号> <状态> [--assignee <身份>] [--reason <原因>] [--evidence <证据>]
  assign <编号> <新owner> --reason <原因> | handoff <编号> <新负责人> --reason <原因>
  block <编号> --reason <原因> --waiting-for <对象> | unblock <编号> [--evidence <证据>]
  done <编号> --evidence <证据> | cancel <编号> --reason <原因>
  edit <编号> --export <路径> | --import <路径> --base <提交>
  index --rebuild | recover [--show|--abort|--commit]
写命令需 TASK_IDENTITY；授权变量：TASK_MAINTAINERS、TASK_REVIEWERS、TASK_TESTERS、TASK_MERGE_AUTHORIZED。
'@)
    exit 2
}
function Invoke-Git([string]$Path, [string[]]$GitArgs, [int[]]$AllowedExitCodes = @(0)) {
    $output = @(& git -C $Path @GitArgs 2>&1)
    $code = $LASTEXITCODE
    if ($AllowedExitCodes -notcontains $code) { Die "Git 命令失败（git -C $Path $($GitArgs -join ' ')）：$($output -join "`n")" }
    return ($output -join "`n")
}
function Test-CachedChanges([string]$Path) {
    $output = @(& git -C $Path diff --cached --quiet 2>&1); $code = $LASTEXITCODE
    if ($code -notin @(0,1)) { Die "无法检查暂存差异：$($output -join "`n")" }
    return ($code -eq 1)
}
function Assert-TransactionIndex([string[]]$Paths) {
    $staged = @(& git -C $WT diff --cached --name-only 2>$null); $code = $LASTEXITCODE
    if ($code -ne 0) { Die '无法检查事务暂存路径' }
    foreach ($path in @($staged -split "`r?`n" | Where-Object { $_ })) {
        if ($Paths -notcontains $path) { Die "暂存区含事务外路径，拒绝提交：$path" }
    }
}
function Test-GitAncestor([string]$Path, [string]$Ancestor, [string]$Commit) {
    $output = @(& git -C $Path merge-base --is-ancestor $Ancestor $Commit 2>&1); $code = $LASTEXITCODE
    if ($code -eq 0) { return $true }; if ($code -eq 1) { return $false }
    Die "无法检查 Git 历史基线：$($output -join "`n")"
}
function Resolve-FullPath([string]$Path) { return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
function Read-Text([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { $callers = (Get-PSCallStack | Select-Object -Skip 1 | ForEach-Object { $_.Command }) -join ' -> '; Die "读取文件时路径为空；调用链：$callers" }
    try { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)).Replace("`r`n", "`n").Replace("`r", "`n") }
    catch { Die "读取文件失败：$Path；$($_.Exception.Message)" }
}
function Write-Text([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
function Write-Atomic([string]$Path, [string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Path)) { $callers = (Get-PSCallStack | Select-Object -Skip 1 | ForEach-Object { $_.Command }) -join ' -> '; Die "原子写入时路径为空；调用链：$callers" }
    $temp = "$Path.tmp.$PID"
    Write-Text $temp $Text
    try {
        if (Test-Path -LiteralPath $Path) { $backup = "$Path.bak.$PID"; [IO.File]::Replace($temp, $Path, $backup); if (Test-Path -LiteralPath $backup) { [IO.File]::Delete($backup) } }
        else { [IO.File]::Move($temp, $Path) }
    } catch { Die "原子写入失败：$Path；$($_.Exception.Message)" }
}
function Find-TaskCenter {
    $script:Root = Resolve-FullPath (Invoke-Git (Get-Location).Path @('rev-parse','--show-toplevel'))
    $common = Invoke-Git $Root @('rev-parse','--git-common-dir')
    if (-not [IO.Path]::IsPathRooted($common)) { $common = Join-Path $Root $common }
    $script:Common = Resolve-FullPath $common
    $script:Runtime = Join-Path $Common 'task-center-runtime'
    $script:Lock = Join-Path $Common 'task-center-write.lock'
    $candidate = $env:TASK_CENTER_PATH
    if (-not $candidate) {
        $registration = Join-Path $Common 'task-center/install-path'
        if (Test-Path -LiteralPath $registration) { $candidate = (Read-Text $registration).Trim(); if (-not $candidate) { Die '任务中心安装登记为空' } }
        else {
            $blocks = (Invoke-Git $Root @('worktree','list','--porcelain')) -split "`r?`n`r?`n"
            $matches = @()
            foreach ($block in $blocks) {
                $path = ''; $branch = ''
                foreach ($line in ($block -split "`r?`n")) {
                    if ($line.StartsWith('worktree ')) { $path = $line.Substring(9) }
                    if ($line.StartsWith('branch refs/heads/')) { $branch = $line.Substring(18) }
                }
                if ($path -and $branch -eq $Branch) { $matches += $path }
            }
            if ($matches.Count -gt 1) { Die '发现多个目标任务中心 worktree，请设置 TASK_CENTER_PATH' }
            if ($matches.Count -eq 1) { $candidate = $matches[0] }
        }
    }
    if (-not $candidate) { Die "找不到本地分支 $Branch 的任务中心 worktree；先运行安装引导器" }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { Die "登记的任务中心目录不存在：$candidate" }
    $script:WT = Resolve-FullPath $candidate
    $centerCommon = Invoke-Git $WT @('rev-parse','--git-common-dir')
    if (-not [IO.Path]::IsPathRooted($centerCommon)) { $centerCommon = Join-Path $WT $centerCommon }
    if ((Resolve-FullPath $centerCommon) -ne $script:Common) { Die '任务中心候选目录属于另一份克隆' }
    $centerBranch = Invoke-Git $WT @('symbolic-ref','--short','HEAD')
    if ($centerBranch -ne $Branch) { Die "任务中心分支不匹配：期望 $Branch，实际 $centerBranch" }
    $script:Tasks = Join-Path $WT 'docs/tasks'
    $script:Meta = Join-Path $WT '.task-center'
    $script:Index = Join-Path $Tasks 'INDEX.md'
    $script:Version = Join-Path $Meta 'version'
    $script:NextId = Join-Path $Meta 'next-id'
}
function Check-Version {
    if (-not (Test-Path -LiteralPath $Version -PathType Leaf)) { Die '缺少 .task-center/version；需先完成安装或迁移' }
    $data = @{}
    foreach ($line in (Read-Text $Version) -split "`r?`n") { if ($line -match '^([^:]+):\s*(.*)$') { $data[$matches[1]] = $matches[2] } }
    if ($data['tool-version'] -ne $ToolVersion) { Die "不支持工具版本：$($data['tool-version'])（本脚本 $ToolVersion）" }
    if ($data['schema-version'] -ne $SchemaVersion) { Die "不支持数据格式版本：$($data['schema-version'])（本脚本 $SchemaVersion）；请运行迁移引导器" }
    if (-not $data['source-revision']) { Die 'version 缺少 source-revision' }
    if (-not (Test-Path -LiteralPath $NextId -PathType Leaf)) { Die '缺少 .task-center/next-id' }
}
function Assert-Clean {
    $stateLines = @(& git -C $WT status --porcelain --untracked-files=all)
    $code = $LASTEXITCODE
    if ($code -ne 0) { Die '无法读取任务中心工作区状态' }
    $state = $stateLines -join "`n"
    if ($state) { Die "任务中心工作区有暂存、未提交或未知文件；先检查并处理：`n$state" }
}
function Require-Identity { if (-not $Identity) { Die '请先设置 TASK_IDENTITY（须能区分并发会话）' }; if (-not (Valid-Text $Identity)) { Die 'TASK_IDENTITY 不得包含换行、制表符或 |' } }
function Valid-Text([string]$Text) { return ($Text -notmatch '[\r\n\t|]') }
function Normalize-Id([string]$Value) {
    $value = $Value -replace '^(?i:TC-)',''
    if ($value -notmatch '^\d+$') { Die "无效任务编号：$Value" }
    return [int]$value
}
function Format-Id([int]$Id) { return $Id.ToString('D4') }
function Get-Field([string]$Path, [string]$Name) {
    $prefix = "$Name："; $values = [Collections.Generic.List[string]]::new(); $body = $false
    foreach ($line in (Read-Text $Path) -split "`r?`n") { if ($line.StartsWith('## ')) { $body = $true }; if (-not $body -and $line.StartsWith($prefix)) { $values.Add($line.Substring($prefix.Length)) } }
    if ($values.Count -ne 1) { return '' }; return $values[0]
}
function Get-TaskId([string]$Path) { $first = ((Read-Text $Path) -split "`r?`n")[0]; if ($first -match '^# 任务 #([0-9]+) .+$') { return [int]$matches[1] }; return 0 }
function Get-TaskTitle([string]$Path) { $first = ((Read-Text $Path) -split "`r?`n")[0]; if ($first -match '^# 任务 #[0-9]+ (.+)$') { return $matches[1] }; return '' }
function Get-TaskFile([int]$Id) {
    $found = @()
    foreach ($dir in @($Tasks, (Join-Path $Tasks 'archive'))) {
        if (Test-Path -LiteralPath $dir) { foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.md' -File | Sort-Object Name)) { if ($file.Name -ne 'INDEX.md' -and (Get-TaskId $file.FullName) -eq $Id) { $found += $file.FullName } } }
    }
    if ($found.Count -eq 0) { Die "任务 TC-$(Format-Id $Id) 不存在" }
    if ($found.Count -gt 1) { Die "任务编号 $Id 匹配多个文件" }
    return $found[0]
}
function Has-Role([string]$List, [string]$Who = $Identity) { return (@($List -split ',' | ForEach-Object { $_.Trim() }) -contains $Who) }
function Require-Role([string]$Variable) { $value = [Environment]::GetEnvironmentVariable($Variable); if (-not (Has-Role $value)) { Die "身份 $Identity 未获授权角色：$Variable" } }
function Require-AssigneeRole([string]$Who, [string]$Variable) { $value = [Environment]::GetEnvironmentVariable($Variable); if (-not (Has-Role $value $Who)) { Die "目标身份 $Who 未获授权角色：$Variable" } }
function Check-Error([string]$Message) { $script:CheckErrors.Add($Message) }

function Validate-Task([string]$Path) {
    $name = [IO.Path]::GetFileName($Path); $id = Get-TaskId $Path
    if ($name -notmatch '^0*([0-9]+)-[a-z0-9][a-z0-9-]*\.md$') { Check-Error "$Path：文件名必须是 <编号>-<ASCII slug>.md" }
    elseif ([int]$matches[1] -ne $id) { Check-Error "$Path：文件名和标题编号不一致" }
    if (-not $id) { Check-Error "$Path：标题缺少编号"; return }
    if ($id -lt 1) { Check-Error "$Path：任务编号必须为正整数" }
    if (-not (Valid-Text (Get-TaskTitle $Path))) { Check-Error "$Path：标题不得包含换行、制表符或 |" }
    $labels = @('状态','owner','当前负责人','优先级','依赖','分支','PR','外部','备注','阻塞前状态','阻塞原因','等待对象','创建')
    $body = $false; $counts = @{}; $known = @{}; foreach ($label in $labels) { $known["$label："] = $true }
    foreach ($line in (Read-Text $Path) -split "`r?`n") {
        if ($line.StartsWith('## ')) { $body = $true; continue }
        if (-not $body -and $line -match '^([^#\s][^：]*：)') { $key = $matches[1]; if (-not $known.ContainsKey($key)) { Check-Error "$Path：存在未知字段 $key" }; if (-not $counts.ContainsKey($key)) { $counts[$key] = 0 }; $counts[$key]++ }
    }
    foreach ($label in $labels) { if ($counts["$label："] -ne 1) { Check-Error "$Path：字段 $label 必须在正文前恰好出现一次" } }
    $status = Get-Field $Path '状态'; $owner = Get-Field $Path 'owner'; $assignee = Get-Field $Path '当前负责人'; $priority = Get-Field $Path '优先级'
    $from = Get-Field $Path '阻塞前状态'; $reason = Get-Field $Path '阻塞原因'; $waiting = Get-Field $Path '等待对象'
    if (@('待办','已认领','进行中','待审核','待测试','待合并','阻塞','已完成','已取消') -notcontains $status) { Check-Error "$Path：未知状态 $status" }
    if (@('高','中','低') -notcontains $priority) { Check-Error "$Path：优先级必须是高、中或低" }
    if (-not $owner -or -not $assignee) { Check-Error "$Path：owner 和当前负责人不能为空" }
    if ($status -eq '待办' -and $owner -ne '未认领') { Check-Error "$Path：待办任务的 owner 必须是未认领" }
    if ($status -notin @('待办','已完成','已取消') -and $owner -eq '未认领') { Check-Error "$Path：已认领任务必须记录 owner" }
    foreach ($value in @($status,$owner,$assignee,$priority,(Get-Field $Path '依赖'),(Get-Field $Path '分支'),(Get-Field $Path 'PR'),(Get-Field $Path '外部'),(Get-Field $Path '备注'),$from,$reason,$waiting,(Get-Field $Path '创建'))) { if ($value -match '[\r\n\t|]') { Check-Error "$Path：字段值不得含换行、表格分隔符或制表符" } }
    $external = Get-Field $Path '外部'; if ($external -ne '无' -and $external -notmatch '^https?://\S+$') { Check-Error "$Path：外部字段必须是完整 HTTP(S) 链接或无" }
    if ((Get-Field $Path '创建') -notmatch '^\d{4}-\d{2}-\d{2}\s+.+$') { Check-Error "$Path：创建字段格式应为日期与登记身份" }
    if ($Path.Replace('\','/') -match '/archive/') { if ($status -notin @('已完成','已取消')) { Check-Error "$Path：归档目录只能包含终态任务" } }
    elseif ($status -in @('已完成','已取消')) { Check-Error "$Path：终态任务必须位于归档目录" }
    if (@('待办','已完成','已取消') -contains $status) { if ($assignee -ne '未分配') { Check-Error "$Path：$status 状态的当前负责人必须是未分配" } }
    elseif ($status -eq '阻塞') {
        if (@('已认领','进行中','待审核','待测试','待合并') -notcontains $from) { Check-Error "$Path：阻塞前状态无效" }
        if (-not $reason -or $reason -eq '无' -or -not $waiting -or $waiting -eq '无') { Check-Error "$Path：阻塞原因和等待对象必填" }
        if ($assignee -eq '未分配') { Check-Error "$Path：阻塞任务必须保留当前负责人" }
    } else {
        if ($from -ne '无' -or $reason -ne '无' -or $waiting -ne '无') { Check-Error "$Path：非阻塞任务的阻塞字段必须是无" }
        if ($assignee -eq '未分配') { Check-Error "$Path：活跃任务必须有当前负责人" }
    }
    $content = Read-Text $Path
    if ($content -notmatch '(?m)^## 验收标准$' -or $content -notmatch '(?m)^## 进度$') { Check-Error "$Path：必须包含验收标准与进度分区" }
    if ($content -notmatch '(?m)^-[ \t]+\[[ xX]\][ \t]+.+$') { Check-Error "$Path：至少需要一条验收条件" }
    if ($status -in @('待审核','待测试','待合并','已完成') -and $content -notmatch '证据：[^无（)]') { Check-Error "$Path：$status 阶段缺少证据记录" }
    if ($status -eq '已完成' -and $content -match '(?m)^-[ \t]+\[ \]') { Check-Error "$Path：已完成任务仍有未勾选验收条件" }
}
function Get-TaskFiles([string]$TaskRoot) {
    $files = [Collections.Generic.List[string]]::new()
    foreach ($dir in @($TaskRoot, (Join-Path $TaskRoot 'archive'))) {
        if (Test-Path -LiteralPath $dir) { foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.md' -File)) { if ($file.Name -ne 'INDEX.md') { $files.Add($file.FullName) } } }
    }
    return $files.ToArray()
}
function Generate-Index([string]$TaskRoot, [string]$OutputPath) {
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in @('# 任务索引','','> 本文件由任务文件生成并提交。禁止手工维护表格行；使用 `task index --rebuild` 重建。','','## 活跃任务','','| # | 标题 | 状态 | owner | 当前负责人 | 备注 |','|---:|---|---|---|---|---|')) { $lines.Add($line) }
    $rows = [Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $TaskRoot) {
        foreach ($file in (Get-ChildItem -LiteralPath $TaskRoot -Filter '*.md' -File | Sort-Object Name)) {
            if ($file.Name -eq 'INDEX.md') { continue }; $id = Get-TaskId $file.FullName; if (-not $id) { continue }
            $rows.Add([pscustomobject]@{Id=$id;Line="| TC-$(Format-Id $id) | $(Get-TaskTitle $file.FullName) | $(Get-Field $file.FullName '状态') | $(Get-Field $file.FullName 'owner') | $(Get-Field $file.FullName '当前负责人') | $(Get-Field $file.FullName '备注') |"})
        }
    }
    foreach ($row in ($rows | Sort-Object Id)) { $lines.Add($row.Line) }
    foreach ($line in @('','## 已完成','','已归档任务保存在 `archive/`，编号永久保留。')) { $lines.Add($line) }
    Write-Text $OutputPath (($lines -join "`n") + "`n")
}
function Check-Data([string]$DataRoot) {
    $script:CheckErrors = [Collections.Generic.List[string]]::new()
    $taskRoot = Join-Path $DataRoot 'docs/tasks'; $versionFile = Join-Path $DataRoot '.task-center/version'; $nextFile = Join-Path $DataRoot '.task-center/next-id'; $indexFile = Join-Path $taskRoot 'INDEX.md'
    if (-not (Test-Path -LiteralPath $versionFile)) { Check-Error '缺少版本文件' }
    if (-not (Test-Path -LiteralPath $nextFile)) { Check-Error '缺少编号种子文件' }
    if (-not (Test-Path -LiteralPath $taskRoot)) { Check-Error '缺少 docs/tasks'; return $false }
    if (Test-Path -LiteralPath $versionFile) {
        $versionData = @{}; foreach ($line in ((Read-Text $versionFile) -split "`r?`n")) { if ($line -match '^([^:]+):\s*(.*)$') { $versionData[$matches[1]] = $matches[2] } }
        if ($versionData['tool-version'] -ne $ToolVersion -or $versionData['schema-version'] -ne $SchemaVersion -or -not $versionData['source-revision']) { Check-Error 'version 标记与当前工具/数据格式不符' }
    }
    if (-not (Test-Path -LiteralPath $indexFile)) { Check-Error '缺少 docs/tasks/INDEX.md' }
    $files = @(Get-TaskFiles $taskRoot); $ids = @{}; $max = 0
    foreach ($file in $files) {
        Validate-Task $file; $id = Get-TaskId $file
        if ($id) { if ($ids.ContainsKey([string]$id)) { Check-Error "任务编号重复：$id" } else { $ids[[string]$id] = $file }; if ($id -gt $max) { $max = $id } }
    }
    if (Test-Path -LiteralPath $nextFile) { $raw = (Read-Text $nextFile).Trim(); if ($raw -notmatch '^[1-9][0-9]*$') { Check-Error 'next-id 必须是正整数' } elseif ([int]$raw -le $max) { Check-Error "next-id ($raw) 不大于已用编号 ($max)" } }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("task-index-" + [guid]::NewGuid().ToString('N'))
    Generate-Index $taskRoot $temp
    if ((Test-Path -LiteralPath $indexFile) -and ((Read-Text $temp) -cne (Read-Text $indexFile))) { Check-Error 'INDEX 与活跃任务文件生成结果不一致' }
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    $deps = @{}
    foreach ($file in $files) {
        $id = Get-TaskId $file; $raw = Get-Field $file '依赖'; $list = @()
        if ($raw -and $raw -ne '无') { foreach ($item in $raw.Split(',')) { $dep = Normalize-Id $item.Trim(); $list += $dep; if ($dep -eq $id) { Check-Error "依赖自指：$id" }; if (-not $ids.ContainsKey([string]$dep)) { Check-Error "依赖不存在：$id -> $dep" } } }
        $deps[[string]$id] = $list
    }
    $colors = @{}
    function Visit-Dependency([string]$Node) {
        if ($colors[$Node] -eq 1) { Check-Error "依赖循环：$Node"; return }
        if ($colors[$Node] -eq 2) { return }
        $colors[$Node] = 1
        foreach ($child in $deps[$Node]) { if ($ids.ContainsKey([string]$child)) { Visit-Dependency ([string]$child) } }
        $colors[$Node] = 2
    }
    foreach ($node in $deps.Keys) { Visit-Dependency $node }
    return ($script:CheckErrors.Count -eq 0)
}
function Check-Layout([string]$Path) {
    foreach ($file in (Get-ChildItem -LiteralPath $Path -Force -File -Recurse)) {
        $relative = $file.FullName.Substring($Path.Length + 1).Replace('\','/')
        if ($relative -eq '.git') { continue }
        if ($relative -match '^(TASK-CENTER\.md|scripts/task\.(sh|ps1)|\.task-center/(version|next-id)|docs/tasks/INDEX\.md|docs/tasks/[0-9]+-[a-z0-9][a-z0-9-]*\.md|docs/tasks/archive/[0-9]+-[a-z0-9][a-z0-9-]*\.md)$') { continue }
        Die "任务中心含清单外文件：$relative"
    }
}
function Check-History([string]$Path, [switch]$Full) {
    Check-Layout $Path
    $head = Invoke-Git $Path @('rev-parse','HEAD'); $fullScan = $true; $commits = @()
    $baselinePath = Join-Path $Runtime 'validated-history'
    if (-not $Full -and (Test-Path -LiteralPath $baselinePath)) {
        $baseline = (Read-Text $baselinePath).Trim()
        if ($baseline -match '^[0-9a-fA-F]{40,64}$') {
            if (Test-GitAncestor $Path $baseline 'HEAD') { $commits = @((Invoke-Git $Path @('rev-list','HEAD',"^$baseline")) -split "`r?`n" | Where-Object { $_ }); $fullScan = $false }
        }
    }
    if ($fullScan) {
        $roots = @((Invoke-Git $Path @('rev-list','--max-parents=0','HEAD')) -split "`r?`n" | Where-Object { $_ })
        if ($roots.Count -ne 1) { Die '任务中心历史必须只有一个根提交' }
        $commits = (Invoke-Git $Path @('rev-list','HEAD')) -split "`r?`n"
    }
    foreach ($commit in $commits) {
        if (-not $commit) { continue }
        $parents = (Invoke-Git $Path @('rev-list','--parents','-n','1',$commit)) -split ' '
        if ($parents.Count -gt 2) { Die "任务中心历史含 merge commit：$commit" }
        $paths = (Invoke-Git $Path @('diff-tree','--root','--no-commit-id','--name-only','-r',$commit)) -split "`r?`n"
        foreach ($relative in $paths) {
            if (-not $relative) { continue }
            if ($relative -notmatch '^(TASK-CENTER\.md|scripts/task\.(sh|ps1)|\.task-center/(version|next-id)|docs/tasks/INDEX\.md|docs/tasks/[0-9]+-[a-z0-9][a-z0-9-]*\.md|docs/tasks/archive/[0-9]+-[a-z0-9][a-z0-9-]*\.md)$') { Die "历史提交含允许清单外路径：${commit}:$relative" }
        }
    }
    $branches = (Invoke-Git $Path @('for-each-ref',"--format=%(refname:short)",'refs/heads')) -split "`r?`n"
    foreach ($branch in $branches) {
        if (-not $branch -or $branch -eq $Branch) { continue }
        $base = Invoke-Git $Path @('merge-base','HEAD',$branch) @(0,1)
        if ($base) { Die "任务中心分支与本地代码分支 $branch 共享历史提交 $base" }
    }
    $upstream = Invoke-Git $Path @('config','--get',"branch.$Branch.remote") @(0,1)
    if ($upstream) { Die "任务中心分支不得设置 upstream：$upstream" }
}
function Require-Option([string]$Name, [string[]]$Values) {
    for ($i=0; $i -lt $Values.Count; $i++) { if ($Values[$i] -eq $Name) { if ($i+1 -ge $Values.Count) { Die "$Name 缺少值" }; return $Values[$i+1] } }
    Die "缺少必需参数 $Name"
}
function Find-Option([string]$Name, [string[]]$Values, [string]$Default = '') {
    for ($i=0; $i -lt $Values.Count; $i++) { if ($Values[$i] -eq $Name) { if ($i+1 -ge $Values.Count) { Die "$Name 缺少值" }; return $Values[$i+1] } }
    return $Default
}
function Assert-Options([string[]]$Values, [string[]]$Allowed) {
    $seen = @{}
    for ($i=0; $i -lt $Values.Count; $i++) {
        $option = $Values[$i]
        if (-not $option.StartsWith('--') -or $Allowed -notcontains $option) { Die "未知参数：$option" }
        if ($seen.ContainsKey($option)) { Die "参数重复：$option" }; $seen[$option] = $true
        if ($i+1 -ge $Values.Count -or $Values[$i+1].StartsWith('--')) { Die "$option 缺少值" }
        $i++
    }
}
function Acquire-Lock {
    [IO.Directory]::CreateDirectory($Runtime) | Out-Null
    $elapsed = 0
    while ($true) {
        try { New-Item -ItemType Directory -Path $Lock -ErrorAction Stop | Out-Null; break } catch { }
        if ($elapsed -ge $LockTimeout) { $owner = '(没有锁记录)'; $ownerPath = Join-Path $Lock 'owner'; if (Test-Path $ownerPath) { $owner = (Read-Text $ownerPath).Trim() }; Die "等待全局写锁超时；占用信息：$owner。确认持有进程已退出后再处理锁目录" }
        Start-Sleep -Seconds 1; $elapsed++
    }
    $script:LockOwned = $true
    Write-Text (Join-Path $Lock 'owner') "identity=$Identity`npid=$PID`nstarted=$([DateTime]::UtcNow.ToString('o'))`ncommand=$Command`n"
}
function Release-Lock { if ($script:LockOwned -and (Test-Path -LiteralPath $Lock)) { Remove-Item -LiteralPath $Lock -Recurse -Force -ErrorAction SilentlyContinue; $script:LockOwned = $false } }
function New-Transaction {
    Assert-Clean; [IO.Directory]::CreateDirectory((Join-Path $Runtime 'transactions')) | Out-Null
    $script:TxId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$PID-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $script:TxToken = "task-center-$TxId"; $script:TxDir = Join-Path (Join-Path $Runtime 'transactions') $TxId
    $work = Join-Path $TxDir 'work'; [IO.Directory]::CreateDirectory($work) | Out-Null
    $script:TxBase = Invoke-Git $WT @('rev-parse','HEAD')
    Write-Text (Join-Path $TxDir 'manifest') "journal-version=1`nid=$TxId`ntoken=$TxToken`nbase=$TxBase`nmessage=`n"
    Write-Text (Join-Path $TxDir 'paths') ''; Write-Text (Join-Path $TxDir 'state') "work-copy`n"
    Copy-Item -LiteralPath (Join-Path $WT 'docs') -Destination (Join-Path $work 'docs') -Recurse
    Copy-Item -LiteralPath (Join-Path $WT '.task-center') -Destination (Join-Path $work '.task-center') -Recurse
    $script:Tasks = Join-Path $work 'docs/tasks'; $script:Meta = Join-Path $work '.task-center'; $script:Index = Join-Path $Tasks 'INDEX.md'; $script:NextId = Join-Path $Meta 'next-id'
}
function Tx-Commit([string]$Message, [string[]]$Paths) {
    $script:TxCommitted = $false
    if (-not $Paths.Count) { Die '事务没有修改路径' }
    $beforeRoot = Join-Path $TxDir 'before'; $afterRoot = Join-Path $TxDir 'after'; [IO.Directory]::CreateDirectory($beforeRoot) | Out-Null; [IO.Directory]::CreateDirectory($afterRoot) | Out-Null
    Write-Text (Join-Path $TxDir 'manifest') "journal-version=1`nid=$TxId`ntoken=$TxToken`nbase=$TxBase`nmessage=$Message`n"
    Write-Text (Join-Path $TxDir 'paths') (($Paths -join "`n") + "`n"); Write-Text (Join-Path $TxDir 'before-absent') ''; Write-Text (Join-Path $TxDir 'after-absent') ''
    foreach ($relative in $Paths) {
        if ($relative -notmatch '^(docs/tasks|\.task-center)/[A-Za-z0-9._/-]+$' -or $relative.Contains('..')) { Die "事务路径不在允许清单内：$relative" }
        $source = Join-Path (Join-Path $TxDir 'work') $relative; $current = Join-Path $WT $relative
        if (Test-Path -LiteralPath $current -PathType Leaf) { $target = Join-Path $beforeRoot $relative; [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null; Copy-Item -LiteralPath $current -Destination $target }
        else { [IO.File]::AppendAllText((Join-Path $TxDir 'before-absent'), "$relative`n", [Text.UTF8Encoding]::new($false)) }
        if (Test-Path -LiteralPath $source -PathType Leaf) { $target = Join-Path $afterRoot $relative; [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null; Copy-Item -LiteralPath $source -Destination $target }
        else { [IO.File]::AppendAllText((Join-Path $TxDir 'after-absent'), "$relative`n", [Text.UTF8Encoding]::new($false)) }
    }
    Write-Text (Join-Path $TxDir 'state') "prepared`n"
    foreach ($relative in $Paths) {
        $source = Join-Path $afterRoot $relative; $target = Join-Path $WT $relative
        if (Test-Path -LiteralPath $source -PathType Leaf) { Install-FileAtomically $source $target $TxId }
        elseif (Test-Path -LiteralPath $target) { [IO.File]::Delete($target) }
    }
    $gitPaths = @('add','--') + $Paths; Invoke-Git $WT $gitPaths | Out-Null
    Assert-TransactionIndex $Paths
    $hasChanges = Test-CachedChanges $WT
    if (-not $hasChanges) { Remove-Item -LiteralPath $TxDir -Recurse -Force; return }
    Invoke-Git $WT @('commit','-m',$Message,'-m',"Task-Transaction: $TxToken") | Out-Null
    Write-Text (Join-Path $Runtime 'validated-history') ((Invoke-Git $WT @('rev-parse','HEAD')) + "`n")
    $script:TxCommitted = $true
    Remove-Item -LiteralPath $TxDir -Recurse -Force
}
function Get-PendingTransaction {
    $root = Join-Path $Runtime 'transactions'; $dirs = @()
    if (Test-Path -LiteralPath $root) { $dirs = @(Get-ChildItem -LiteralPath $root -Directory) }
    if ($dirs.Count -gt 1) { Die '发现多个未完成事务目录；请检查共同 Git 目录下的 task-center-runtime/transactions' }
    if (-not $dirs.Count) { return $null }
    $dir = $dirs[0].FullName
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'manifest'))) { Die "发现未完成事务初始化目录 $dir；请维护者检查后处理" }
    if ((Test-Path -LiteralPath (Join-Path $dir 'state')) -and (Read-Text (Join-Path $dir 'state')).Trim() -eq 'work-copy') { Remove-Item -LiteralPath $dir -Recurse -Force; return $null }
    $fields = @{}; foreach ($line in ((Read-Text (Join-Path $dir 'manifest')) -split "`n")) { $splitAt = $line.IndexOf('='); if ($splitAt -gt 0) { $fields[$line.Substring(0,$splitAt)] = $line.Substring($splitAt+1) } }
    if ($fields['journal-version'] -ne '1') { Die "不支持事务日志版本：$($fields['journal-version'])" }
    if ($fields['id'] -ne (Split-Path -Leaf $dir) -or $fields['id'] -notmatch '^[A-Za-z0-9._-]+$') { Die '事务日志 ID 与目录名不一致或格式无效' }
    $manifest = [pscustomobject]@{id=$fields['id'];token=$fields['token'];base=$fields['base'];message=$fields['message'];paths=@((Get-Content -LiteralPath (Join-Path $dir 'paths') -ErrorAction SilentlyContinue | Where-Object { $_ }));beforeAbsent=@((Get-Content -LiteralPath (Join-Path $dir 'before-absent') -ErrorAction SilentlyContinue | Where-Object { $_ }));afterAbsent=@((Get-Content -LiteralPath (Join-Path $dir 'after-absent') -ErrorAction SilentlyContinue | Where-Object { $_ }))}
    $head = Invoke-Git $WT @('rev-parse','HEAD')
    if ($head -ne $manifest.base) {
        $body = Invoke-Git $WT @('show','-s','--format=%B','HEAD')
        $parent = Invoke-Git $WT @('show','-s','--format=%P','HEAD')
        if ($parent -eq $manifest.base -and $body.Contains("Task-Transaction: $($manifest.token)")) { Write-Text (Join-Path $Runtime 'validated-history') "$head`n"; Remove-Item -LiteralPath $dir -Recurse -Force; return $null }
        Die "存在未完成事务 $dir，HEAD 已变化且无法证明提交归属；请维护者检查"
    }
    return [pscustomobject]@{Dir=$dir;Manifest=$manifest}
}
function Matches-Snapshot([string]$Relative, [string]$SnapshotRoot, [string[]]$Absent,[string]$TransactionId = '') {
    $snap = Join-Path $SnapshotRoot $Relative; $target = Join-Path $WT $Relative
    if (Test-Path -LiteralPath $snap -PathType Leaf) {
        $expected = (Get-FileHash -LiteralPath $snap -Algorithm SHA256).Hash
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $expected) { return $true }
        $temp = "$target.tmp.$TransactionId"
        if ($TransactionId -and -not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $temp -PathType Leaf) -and (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -eq $expected) { return $true }
        return $false
    }
    if ($Absent -contains $Relative) { return -not (Test-Path -LiteralPath $target) }
    return $false
}
function Install-FileAtomically([string]$Source,[string]$Target,[string]$TransactionId) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Target)) | Out-Null
    $temp = "$Target.tmp.$TransactionId"; $backup = "$Target.bak.$TransactionId"
    if ([IO.File]::Exists($backup)) { if ([IO.File]::Exists($Target)) { [IO.File]::Delete($backup) } else { [IO.File]::Move($backup,$Target) } }
    try {
        [IO.File]::Copy($Source,$temp,$true)
        if ([IO.File]::Exists($Target)) { [IO.File]::Replace($temp,$Target,$backup) }
        else { [IO.File]::Move($temp,$Target) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        if ([IO.File]::Exists($backup)) { if ([IO.File]::Exists($Target)) { [IO.File]::Delete($backup) } else { [IO.File]::Move($backup,$Target) } }
    }
}
function Remove-TransactionTemps([string[]]$Paths,[string]$TransactionId) {
    foreach ($relative in $Paths) { $target = Join-Path $WT $relative; foreach ($suffix in @('.tmp.','.bak.')) { $temp = "$target$suffix$TransactionId"; if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } } }
}
function Recover-Command([string]$Action) {
    Acquire-Lock; $pending = Get-PendingTransaction
    if (-not $pending) { Write-Host '没有待恢复事务'; return }
    $m = $pending.Manifest; $dir = $pending.Dir
    if ($Action -eq '--show') { Write-Host "待恢复事务：$dir`n基线：$($m.base)`n标记：$($m.token)"; return }
    if ($Action -notin @('--abort','--commit')) { Usage }
    if ((Invoke-Git $WT @('rev-parse','HEAD')) -ne $m.base) { Die 'HEAD 已变化，不能安全回滚或重试' }
    foreach ($relative in $m.paths) { if ($relative -notmatch '^(docs/tasks|\.task-center)/[A-Za-z0-9._/-]+$' -or $relative.Contains('..')) { Die "事务路径无效：$relative" } }
    if ($Action -eq '--abort') {
        foreach ($relative in $m.paths) { if (-not (Matches-Snapshot $relative (Join-Path $dir 'before') $m.beforeAbsent $m.id) -and -not (Matches-Snapshot $relative (Join-Path $dir 'after') $m.afterAbsent $m.id)) { Die "文件与事务快照不符，停止回滚：$relative" } }
        $reset = @('reset','-q','HEAD','--') + @($m.paths); Invoke-Git $WT $reset | Out-Null
        foreach ($relative in $m.paths) { $source = Join-Path (Join-Path $dir 'before') $relative; $target = Join-Path $WT $relative; if (Test-Path -LiteralPath $source) { Install-FileAtomically $source $target $m.id } elseif (Test-Path -LiteralPath $target) { [IO.File]::Delete($target) } }
        Remove-TransactionTemps $m.paths $m.id
        Remove-Item -LiteralPath $dir -Recurse -Force; Write-Host '事务已按修改前快照回滚'
    } else {
        Assert-TransactionIndex $m.paths
        foreach ($relative in $m.paths) { if (-not (Matches-Snapshot $relative (Join-Path $dir 'before') $m.beforeAbsent $m.id) -and -not (Matches-Snapshot $relative (Join-Path $dir 'after') $m.afterAbsent $m.id)) { Die "文件与事务快照不符，停止提交：$relative" } }
        foreach ($relative in $m.paths) { $source = Join-Path (Join-Path $dir 'after') $relative; $target = Join-Path $WT $relative; if (Test-Path -LiteralPath $source -PathType Leaf) { Install-FileAtomically $source $target $m.id } elseif (Test-Path -LiteralPath $target) { [IO.File]::Delete($target) } }
        Remove-TransactionTemps $m.paths $m.id
        if (-not (Check-Data $WT)) { Die "事务结果未通过 check（$($script:CheckErrors.Count) 项）；未提交" }
        $add = @('add','--') + @($m.paths); Invoke-Git $WT $add | Out-Null
        Assert-TransactionIndex $m.paths
        if (Test-CachedChanges $WT) { Invoke-Git $WT @('commit','-m',[string]$m.message,'-m',"Task-Transaction: $($m.token)") | Out-Null; Write-Text (Join-Path $Runtime 'validated-history') "$(Invoke-Git $WT @('rev-parse','HEAD'))`n" }
        Remove-Item -LiteralPath $dir -Recurse -Force; Write-Host '事务已完成并提交'
    }
}
function Begin-Write([string]$Mode = '') {
    Require-Identity; Acquire-Lock; $pending = Get-PendingTransaction
    if ($pending) { Die "有未完成事务 $($pending.Dir)；先运行 recover --show / --abort / --commit" }
    Assert-Clean; Check-History $WT
    if ($Mode -ne '--rebuild-index' -and -not (Check-Data $WT)) { Die "写入前 check 失败：`n$($script:CheckErrors -join "`n")" }
    New-Transaction
}
function Finish-Write([string]$Message, [string[]]$Paths) {
    if (-not (Check-Data (Join-Path $TxDir 'work'))) { Die "写入候选未通过 check：`n$($script:CheckErrors -join "`n")" }
    Tx-Commit $Message $Paths; if ($script:TxCommitted) { Write-Host '事务已提交' } else { Write-Host '没有数据变化；未创建提交' }
}
function Set-Field([string]$Path, [string]$Name, [string]$Value) {
    $prefix = "$Name："; $lines = (Read-Text $Path).TrimEnd([char]10) -split "`n"; $found = $false
    for ($i=0; $i -lt $lines.Count; $i++) { if (-not $found -and $lines[$i].StartsWith($prefix)) { $lines[$i] = $prefix + $Value; $found = $true } }
    if (-not $found) { Die "字段不存在：$Name" }; Write-Atomic $Path (($lines -join "`n") + "`n")
}
function Append-Progress([string]$Path,[string]$Old,[string]$New,[string]$Action,[string]$Evidence) {
    $text = Read-Text $Path; $line = "`n- $([DateTime]::UtcNow.ToString('yyyy-MM-dd')) $Identity：$Action（状态：$Old → $New；证据：$(if ($Evidence) {$Evidence} else {'无'})）`n"
    Write-Atomic $Path ($text.TrimEnd("`r","`n") + $line)
}
function Check-UnfinishedDeps([string]$Raw) {
    if ($Raw -eq '无') { return }
    foreach ($item in $Raw.Split(',')) { $dep = Normalize-Id $item.Trim(); $file = Get-TaskFile $dep; if ((Get-Field $file '状态') -ne '已完成') { Die "依赖 TC-$(Format-Id $dep) 尚未完成" } }
}
function Cmd-New([string[]]$Rest) {
    if (-not $Rest.Count) { Usage }; $title = $Rest[0]; if (-not (Valid-Text $title)) { Die '标题不得包含换行、制表符或 |' }
    $options = @($Rest | Select-Object -Skip 1); Assert-Options $options @('--slug','--priority','--depends','--acceptance','--external')
    $slug = Find-Option '--slug' $options 'task'; $priority = Find-Option '--priority' $options '中'; $deps = Find-Option '--depends' $options '无'; $acceptance = Find-Option '--acceptance' $options '<逐条填写>'; $external = Find-Option '--external' $options '无'
    if ($slug -notmatch '^[a-z0-9][a-z0-9-]*$') { Die 'slug 只允许小写 ASCII 字母、数字和连字符' }; if (@('高','中','低') -notcontains $priority) { Die 'priority 必须是高、中或低' }
    if (-not (Valid-Text $acceptance) -or -not (Valid-Text $external)) { Die '字段不得包含换行、制表符或 |' }; if ($external -ne '无' -and $external -notmatch '^https?://\S+$') { Die 'external 必须是完整 HTTP(S) 链接' }
    Begin-Write; $max = [int](Read-Text $NextId).Trim(); foreach ($file in (Get-TaskFiles $Tasks)) { $used = Get-TaskId $file; if ($used -ge $max) { $max = $used + 1 } }
    $id = $max; $pad = Format-Id $id; $file = Join-Path $Tasks "$pad-$slug.md"; if (Test-Path -LiteralPath $file) { Die "任务文件已存在：$file" }
    $archive = Join-Path $Tasks 'archive'; [IO.Directory]::CreateDirectory($archive) | Out-Null
    $date = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
    $content = @("# 任务 #$id $title",'','状态：待办','owner：未认领','当前负责人：未分配',"优先级：$priority","依赖：$deps",'分支：无','PR：无',"外部：$external",'备注：无','阻塞前状态：无','阻塞原因：无','等待对象：无',"创建：$date $Identity",'','## 验收标准','',('- [ ] ' + $acceptance),'','## 进度','',('- ' + $date + ' ' + $Identity + '：任务登记（状态：待办 → 待办；证据：无）；下一步：待认领')) -join "`n"
    Write-Text $file ($content + "`n"); Write-Text $NextId (($id + 1).ToString() + "`n"); Generate-Index $Tasks $Index
    Finish-Write "docs(tasks): 登记 TC-$(Format-Id $id) $title" @("docs/tasks/$pad-$slug.md",'docs/tasks/INDEX.md','.task-center/next-id'); Write-Host "已登记 TC-$(Format-Id $id)"
}
function Cmd-Claim([string[]]$Rest) {
    if ($Rest.Count -ne 1) { Usage }; $id = Normalize-Id $Rest[0]; Begin-Write; $file = Get-TaskFile $id
    if ((Get-Field $file '状态') -ne '待办' -or (Get-Field $file 'owner') -ne '未认领') { Die '仅可认领尚未认领的待办任务' }; Check-UnfinishedDeps (Get-Field $file '依赖')
    Set-Field $file 'owner' $Identity; Set-Field $file '当前负责人' $Identity; Set-Field $file '状态' '已认领'; Append-Progress $file '待办' '已认领' '认领任务' '无'; Generate-Index $Tasks $Index
    $relative = $file.Substring((Join-Path $TxDir 'work').Length + 1).Replace('\','/'); Finish-Write "docs(tasks): TC-$(Format-Id $id) 认领" @($relative,'docs/tasks/INDEX.md')
}
function Cmd-Progress([string[]]$Rest) {
    if ($Rest.Count -lt 2) { Usage }; $id = Normalize-Id $Rest[0]; $content = $Rest[1]; if (-not (Valid-Text $content)) { Die '进度不得包含换行、制表符或 |' }; $opts = @($Rest | Select-Object -Skip 2); $evidence = Find-Option '--evidence' $opts '无'
    Assert-Options $opts @('--evidence')
    if (-not (Valid-Text $evidence)) { Die '证据字段格式错误' }
    Begin-Write; $file = Get-TaskFile $id; $status = Get-Field $file '状态'; $owner = Get-Field $file 'owner'; $assignee = Get-Field $file '当前负责人'
    if ($Identity -ne $owner -and $Identity -ne $assignee) { Die '只有 owner 或当前负责人可以追加进度' }; if (@('已完成','已取消') -contains $status) { Die '终态任务不可修改' }
    Append-Progress $file $status $status $content $evidence; Generate-Index $Tasks $Index; $relative = $file.Substring((Join-Path $TxDir 'work').Length + 1).Replace('\','/')
    Finish-Write "docs(tasks): TC-$(Format-Id $id) 追加进度" @($relative,'docs/tasks/INDEX.md')
}
function Cmd-Status([string[]]$Rest) {
    if ($Rest.Count -lt 2) { Usage }; $id = Normalize-Id $Rest[0]; $target = $Rest[1]; $opts = @($Rest | Select-Object -Skip 2); $assigneeArg = Find-Option '--assignee' $opts ''; $reason = Find-Option '--reason' $opts ''; $evidence = Find-Option '--evidence' $opts '无'
    Assert-Options $opts @('--assignee','--reason','--evidence')
    foreach ($value in @($assigneeArg,$reason,$evidence)) { if (-not (Valid-Text $value)) { Die '参数值不得包含换行、制表符或 |' } }
    Begin-Write; $file = Get-TaskFile $id; $old = Get-Field $file '状态'; $owner = Get-Field $file 'owner'; $assignee = Get-Field $file '当前负责人'; $to = $assigneeArg
    switch ("$old`:$target") {
        '已认领:进行中' { if ($Identity -ne $owner) { Die '只有 owner 可开始执行' }; Check-UnfinishedDeps (Get-Field $file '依赖'); if ((Read-Text $file).Contains('- [ ] <逐条填写>')) { Die '请先明确验收标准' } }
        '进行中:待审核' { if ($Identity -ne $owner) { Die '只有 owner 可提交审核' }; if (-not $to) { $to = Require-Option '--assignee' $opts }; Require-AssigneeRole $to 'TASK_REVIEWERS'; if ($evidence -eq '无') { Die '进入待审核必须提供 --evidence' }; if ((Read-Text $file).Contains('- [ ] <逐条填写>')) { Die '请先明确验收标准' }; Set-Field $file '当前负责人' $to }
        '待审核:待测试' { if ($Identity -ne $assignee -or -not (Has-Role $env:TASK_REVIEWERS)) { Die '只有当前审核负责人可转交测试' }; if (-not $to) { $to = Require-Option '--assignee' $opts }; Require-AssigneeRole $to 'TASK_TESTERS'; if ($evidence -eq '无') { Die '进入待测试必须提供 --evidence' }; Set-Field $file '当前负责人' $to }
        '待审核:进行中' { if ($Identity -ne $assignee -or -not (Has-Role $env:TASK_REVIEWERS)) { Die '只有授权的当前审核负责人可打回' }; if (-not $reason) { Die '打回必须提供 --reason' }; Set-Field $file '当前负责人' $owner }
        '待测试:进行中' { if ($Identity -ne $assignee -or -not (Has-Role $env:TASK_TESTERS)) { Die '只有授权的当前测试负责人可打回' }; if (-not $reason) { Die '打回必须提供 --reason' }; Set-Field $file '当前负责人' $owner }
        '待测试:待合并' { if ($Identity -ne $assignee -or -not (Has-Role $env:TASK_TESTERS)) { Die '只有当前测试负责人可提交合并' }; if (-not $to) { $to = Require-Option '--assignee' $opts }; Require-AssigneeRole $to 'TASK_MERGE_AUTHORIZED'; if ($evidence -eq '无') { Die '进入待合并必须提供 --evidence' }; Set-Field $file '当前负责人' $to }
        default { Die "非法状态迁移：$old → $target；请使用专用命令" }
    }
    Set-Field $file '状态' $target; Append-Progress $file $old $target "状态流转$(if($reason){'：'+$reason})" $evidence; Generate-Index $Tasks $Index
    $relative = $file.Substring((Join-Path $TxDir 'work').Length + 1).Replace('\','/'); Finish-Write "docs(tasks): TC-$(Format-Id $id) $old -> $target" @($relative,'docs/tasks/INDEX.md')
}
function Cmd-RoleTransition([string]$Kind,[string[]]$Rest) {
    if ($Rest.Count -lt 2) { Usage }; $id = Normalize-Id $Rest[0]; $targetIdentity = $Rest[1]; $opts = @($Rest | Select-Object -Skip 2)
    Assert-Options $opts @('--reason')
    $reason = Require-Option '--reason' $opts; if (-not (Valid-Text $reason) -or -not (Valid-Text $targetIdentity)) { Die '转交身份或原因格式错误' }; Begin-Write; $file = Get-TaskFile $id; $status = Get-Field $file '状态'; $owner = Get-Field $file 'owner'; $assignee = Get-Field $file '当前负责人'
    if ($Kind -eq 'assign') {
        Require-Role 'TASK_MAINTAINERS'; if (@('已完成','已取消','待办') -contains $status) { Die '该状态不可转交 owner' }
        Set-Field $file 'owner' $targetIdentity; if ($assignee -eq $owner) { Set-Field $file '当前负责人' $targetIdentity }; $action = "owner 由 $owner 转交给 $targetIdentity：$reason"
    } else {
        if (@('已完成','已取消','待办','阻塞') -contains $status) { Die '该状态不接受负责人交接' }; if ($Identity -ne $assignee) { Require-Role 'TASK_MAINTAINERS' }
        switch ($status) { '待审核' { Require-AssigneeRole $targetIdentity 'TASK_REVIEWERS' }; '待测试' { Require-AssigneeRole $targetIdentity 'TASK_TESTERS' }; '待合并' { Require-AssigneeRole $targetIdentity 'TASK_MERGE_AUTHORIZED' } }
        Set-Field $file '当前负责人' $targetIdentity; $action = "当前负责人交接给 $targetIdentity：$reason"
    }
    Append-Progress $file $status $status $action '无'; Generate-Index $Tasks $Index; $relative = $file.Substring((Join-Path $TxDir 'work').Length + 1).Replace('\','/')
    Finish-Write "docs(tasks): TC-$(Format-Id $id) $Kind" @($relative,'docs/tasks/INDEX.md')
}
function Cmd-Block([string[]]$Rest) {
    if (-not $Rest.Count) { Usage }; $id = Normalize-Id $Rest[0]; $opts = @($Rest | Select-Object -Skip 1); $reason = Require-Option '--reason' $opts; $waiting = Require-Option '--waiting-for' $opts
    Assert-Options $opts @('--reason','--waiting-for')
    if (-not (Valid-Text $reason) -or -not (Valid-Text $waiting)) { Die '阻塞字段格式错误' }; Begin-Write; $file = Get-TaskFile $id; $old = Get-Field $file '状态'; if (@('已认领','进行中','待审核','待测试','待合并') -notcontains $old) { Die '只有活跃阶段可以阻塞' }; if ($Identity -ne (Get-Field $file '当前负责人')) { Die '只有当前负责人可记录阻塞' }
    Set-Field $file '阻塞前状态' $old; Set-Field $file '阻塞原因' $reason; Set-Field $file '等待对象' $waiting; Set-Field $file '状态' '阻塞'; Append-Progress $file $old '阻塞' "阻塞：$reason；等待：$waiting" '无'; Generate-Index $Tasks $Index
    $relative = $file.Substring((Join-Path $TxDir 'work').Length + 1).Replace('\','/'); Finish-Write "docs(tasks): TC-$(Format-Id $id) 阻塞" @($relative,'docs/tasks/INDEX.md')
}
function Cmd-Unblock([string[]]$Rest) {
    if (-not $Rest.Count) { Usage }; $id = Normalize-Id $Rest[0]; $opts = @($Rest | Select-Object -Skip 1); Assert-Options $opts @('--evidence'); $evidence = Find-Option '--evidence' $opts '无'; if (-not (Valid-Text $evidence)) { Die '证据字段格式错误' }; Begin-Write; $file = Get-TaskFile $id
    if ((Get-Field $file '状态') -ne '阻塞') { Die '任务当前未阻塞' }; if ($Identity -ne (Get-Field $file '当前负责人')) { Die '只有当前负责人可解除阻塞' }; $target = Get-Field $file '阻塞前状态'
    Set-Field $file '状态' $target; Set-Field $file '阻塞前状态' '无'; Set-Field $file '阻塞原因' '无'; Set-Field $file '等待对象' '无'; Append-Progress $file '阻塞' $target '解除阻塞' $evidence; Generate-Index $Tasks $Index
    $relative = $file.Substring((Join-Path $TxDir 'work').Length + 1).Replace('\','/'); Finish-Write "docs(tasks): TC-$(Format-Id $id) 解除阻塞" @($relative,'docs/tasks/INDEX.md')
}
function Archive-Task([string]$File,[string]$Target,[string]$Action,[string]$Evidence) {
    $old = Get-Field $File '状态'; Append-Progress $File $old $Target $Action $Evidence; Set-Field $File '状态' $Target; Set-Field $File '当前负责人' '未分配'; $dest = Join-Path (Join-Path $Tasks 'archive') ([IO.Path]::GetFileName($File)); if (Test-Path -LiteralPath $dest) { Die "归档目标已存在：$dest" }; [IO.Directory]::CreateDirectory((Split-Path -Parent $dest)) | Out-Null; Move-Item -LiteralPath $File -Destination $dest; Generate-Index $Tasks $Index; return $dest
}
function Cmd-Done([string[]]$Rest) {
    if (-not $Rest.Count) { Usage }; $id = Normalize-Id $Rest[0]; $opts = @($Rest | Select-Object -Skip 1); Assert-Options $opts @('--evidence'); $evidence = Require-Option '--evidence' $opts; if (-not (Valid-Text $evidence)) { Die '证据格式错误' }; Begin-Write; $file = Get-TaskFile $id
    Assert-Options @($Rest | Select-Object -Skip 1) @('--evidence')
    if ((Get-Field $file '状态') -ne '待合并') { Die '仅待合并任务可完成' }; if ($Identity -ne (Get-Field $file '当前负责人')) { Die '只有当前合并负责人可完成' }; if (-not (Has-Role $env:TASK_MERGE_AUTHORIZED)) { Die '当前负责人未获授权合并角色' }; if ((Read-Text $file) -match '(?m)^-[ \t]+\[ \]') { Die '仍有未完成验收条件' }
    $dest = Archive-Task $file '已完成' '完成并归档' $evidence; $sourceRel = $file.Substring((Join-Path $TxDir 'work').Length + 1).Replace('\','/'); Finish-Write "docs(tasks): TC-$(Format-Id $id) 完成归档" @($sourceRel,"docs/tasks/archive/$(Split-Path -Leaf $dest)",'docs/tasks/INDEX.md')
}
function Cmd-Cancel([string[]]$Rest) {
    if (-not $Rest.Count) { Usage }; $id = Normalize-Id $Rest[0]; $opts = @($Rest | Select-Object -Skip 1); Assert-Options $opts @('--reason'); $reason = Require-Option '--reason' $opts; if (-not (Valid-Text $reason)) { Die '取消原因格式错误' }; Begin-Write; Require-Role 'TASK_MAINTAINERS'; $file = Get-TaskFile $id
    Assert-Options @($Rest | Select-Object -Skip 1) @('--reason')
    if (@('已完成','已取消') -contains (Get-Field $file '状态')) { Die '任务已处于终态' }; $dest = Archive-Task $file '已取消' "维护者取消：$reason" '无'; $sourceRel = $file.Substring((Join-Path $TxDir 'work').Length + 1).Replace('\','/')
    Finish-Write "docs(tasks): TC-$(Format-Id $id) 取消归档" @($sourceRel,"docs/tasks/archive/$(Split-Path -Leaf $dest)",'docs/tasks/INDEX.md')
}
function Cmd-Edit([string[]]$Rest) {
    if ($Rest.Count -lt 3) { Usage }; $id = Normalize-Id $Rest[0]; $mode = $Rest[1]; $draftPath = [IO.Path]::GetFullPath($Rest[2]); $options = @($Rest | Select-Object -Skip 3)
    $wtPrefix = (Resolve-FullPath $WT) + [IO.Path]::DirectorySeparatorChar
    if ($mode -eq '--export') {
        if ($options.Count) { Usage }; Require-Identity; Acquire-Lock; $pending = Get-PendingTransaction; if ($pending) { Die "有未完成事务 $($pending.Dir)；先运行 recover" }; Assert-Clean; Check-History $WT
        if (-not (Check-Data $WT)) { Die "check 失败：`n$($script:CheckErrors -join "`n")" }; $file = Get-TaskFile $id
        if ($file.StartsWith((Join-Path $Tasks 'archive'), [StringComparison]::OrdinalIgnoreCase)) { Die '终态任务不可导出编辑草稿' }
        if ($draftPath.StartsWith($wtPrefix, [StringComparison]::OrdinalIgnoreCase)) { Die '编辑草稿必须位于任务中心 worktree 外' }
        if ((Test-Path -LiteralPath $draftPath) -or (Test-Path -LiteralPath "$draftPath.base")) { Die '草稿或基线文件已存在；请指定新路径' }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $draftPath)) | Out-Null; Write-Text $draftPath (Read-Text $file)
        Write-Text "$draftPath.base" "$(Invoke-Git $WT @('rev-parse','HEAD')) $id`n"; Write-Host "草稿已导出：$draftPath（基线记录：$draftPath.base）"; return
    }
    if ($mode -ne '--import' -or $options.Count -ne 2 -or $options[0] -ne '--base') { Die '用法：edit <编号> --import <路径> --base <提交>，或 --export <路径>' }
    $base = $options[1]; Begin-Write
    if (-not (Test-Path -LiteralPath $draftPath -PathType Leaf)) { Die "草稿文件不存在：$draftPath" }
    if ($draftPath.StartsWith($wtPrefix, [StringComparison]::OrdinalIgnoreCase)) { Die '编辑草稿必须位于任务中心 worktree 外' }
    if ($base -ne $TxBase) { Die "草稿基线 $base 与当前提交 $TxBase 不同，请重新导出并合并" }
    if ((Test-Path -LiteralPath "$draftPath.base") -and ((Read-Text "$draftPath.base").Split(' ')[0] -ne $base)) { Die '草稿基线文件与 --base 不一致' }
    $file = Get-TaskFile $id; if ($file.StartsWith((Join-Path $Tasks 'archive'), [StringComparison]::OrdinalIgnoreCase)) { Die '终态任务不可编辑' }
    $original = Read-Text $file; $draft = Read-Text $draftPath; $acceptHeading = '## 验收标准'; $progressHeading = '## 进度'
    $oa = $original.IndexOf($acceptHeading, [StringComparison]::Ordinal); $op = $original.IndexOf($progressHeading, [StringComparison]::Ordinal)
    $da = $draft.IndexOf($acceptHeading, [StringComparison]::Ordinal); $dp = $draft.IndexOf($progressHeading, [StringComparison]::Ordinal)
    if ($oa -lt 0 -or $op -lt $oa -or $da -lt 0 -or $dp -lt $da) { Die '任务草稿缺少验收标准或进度分区' }
    if ($original.Substring(0,$oa) -cne $draft.Substring(0,$da)) { Die '草稿字段区有变化；只允许编辑验收标准' }
    if ($original.Substring($op) -cne $draft.Substring($dp)) { Die '进度区只允许通过 progress 命令追加' }
    $acceptance = $draft.Substring($da, $dp - $da)
    if ($acceptance -notmatch '(?m)^-[ \t]+\[[ xX]\][ \t]+.+$') { Die '草稿缺少有效验收标准' }
    $updated = $original.Substring(0,$oa) + $acceptance + $original.Substring($op)
    Write-Atomic $file $updated; $status = Get-Field $file '状态'; Append-Progress $file $status $status '导入并更新验收标准' '无'; Generate-Index $Tasks $Index
    $relative = $file.Substring((Join-Path $TxDir 'work').Length + 1).Replace('\','/')
    Finish-Write "docs(tasks): TC-$(Format-Id $id) 更新验收标准" @($relative,'docs/tasks/INDEX.md')
}
function Cmd-List([string[]]$Rest) {
    Assert-Clean; $all = $Rest -contains '--all'; Write-Host '编号 | 标题 | 状态 | owner | 当前负责人 | 依赖'
    foreach ($file in (Get-ChildItem -LiteralPath $Tasks -Filter '*.md' -File | Sort-Object Name)) {
        if ($file.Name -eq 'INDEX.md') { continue }; $status = Get-Field $file.FullName '状态'; if (-not $all -and @('已完成','已取消') -contains $status) { continue }
        $deps = Get-Field $file.FullName '依赖'; $warning = ''; if ($deps -and $deps -ne '无') { foreach ($item in $deps.Split(',')) { $depFile = Get-TaskFile (Normalize-Id $item.Trim()); if ((Get-Field $depFile '状态') -ne '已完成') { $warning = '（依赖未完成）' } } }
        Write-Host "TC-$(Format-Id (Get-TaskId $file.FullName)) | $(Get-TaskTitle $file.FullName) | $status$warning | $(Get-Field $file.FullName 'owner') | $(Get-Field $file.FullName '当前负责人') | $deps"
    }
    if ($all) { foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $Tasks 'archive') -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) { Write-Host "TC-$(Format-Id (Get-TaskId $file.FullName)) | $(Get-TaskTitle $file.FullName) | $(Get-Field $file.FullName '状态') | $(Get-Field $file.FullName 'owner') | $(Get-Field $file.FullName '当前负责人') | $(Get-Field $file.FullName '依赖')" } }
}
function Cmd-Check {
    Assert-Clean; Check-History $WT -Full; if (Check-Data $WT) { Write-Host 'check 通过' } else { Die "check 发现 $($script:CheckErrors.Count) 项问题：`n$($script:CheckErrors -join "`n")" }
}
function Cmd-RebuildIndex {
    Begin-Write '--rebuild-index'; $script:CheckErrors = [Collections.Generic.List[string]]::new(); $files = Get-TaskFiles $Tasks; foreach ($file in $files) { Validate-Task $file }; if ($script:CheckErrors.Count) { Die "任务数据无效，无法重建索引：$($script:CheckErrors -join '; ')" }
    Generate-Index $Tasks $Index; Finish-Write 'docs(tasks): 重建任务索引' @('docs/tasks/INDEX.md')
}

if (-not $args.Count) { Usage }; $Command = $args[0]; $Rest = @($args | Select-Object -Skip 1)
try {
    Find-TaskCenter; if ($Command -ne 'recover') { Check-Version }
    switch ($Command) {
        'init' { Assert-Clean; Check-History $WT -Full; if (Check-Data $WT) { Write-Host "任务中心就绪：$WT（本地分支 $Branch）" } else { Die "check 发现 $($script:CheckErrors.Count) 项问题：`n$($script:CheckErrors -join "`n")" } }
        'list' { if ($Rest.Count -gt 1 -or ($Rest.Count -eq 1 -and $Rest[0] -ne '--all')) { Usage }; Cmd-List $Rest }
        'check' { Cmd-Check }
        'new' { Cmd-New $Rest }
        'claim' { Cmd-Claim $Rest }
        'progress' { Cmd-Progress $Rest }
        'status' { Cmd-Status $Rest }
        'assign' { Cmd-RoleTransition 'assign' $Rest }
        'handoff' { Cmd-RoleTransition 'handoff' $Rest }
        'block' { Cmd-Block $Rest }
        'unblock' { Cmd-Unblock $Rest }
        'done' { Cmd-Done $Rest }
        'cancel' { Cmd-Cancel $Rest }
        'edit' { Cmd-Edit $Rest }
        'index' { if ($Rest.Count -ne 1 -or $Rest[0] -ne '--rebuild') { Usage }; Cmd-RebuildIndex }
        'recover' { if ($Rest.Count -gt 1) { Usage }; $action = if ($Rest.Count) { $Rest[0] } else { '--show' }; Recover-Command $action }
        default { Usage }
    }
} finally { Release-Lock }
