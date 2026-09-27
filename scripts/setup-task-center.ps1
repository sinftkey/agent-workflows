[CmdletBinding()]
param(
    [string]$RepoPath = (Get-Location).Path,
    [string]$SourcePath = (Split-Path -Parent $PSScriptRoot),
    [string]$Branch = $(if ($env:TASK_BRANCH) { $env:TASK_BRANCH } else { 'task-center' }),
    [string]$WorktreeName = $(if ($env:TASK_WORKTREE_NAME) { $env:TASK_WORKTREE_NAME } else { 'task-center' }),
    [string]$BackupDirectory,
    [string]$RestoreBundlePath,
    [switch]$Repair,
    [switch]$DryRun,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) { $PSNativeCommandUseErrorActionPreference = $false }
$script:LockOwned = $false
$script:LastGitExitCode = 0
$script:GitRoot = $null
$script:CommonDir = $null
$script:MainWorktree = $null
$script:Registration = $null
$script:RuntimeDir = $null
$script:LockPath = $null

function Stop-Setup([string]$Message) { throw $Message }

function Invoke-Git([string]$At, [string[]]$GitArgs, [switch]$AllowFailure) {
    $output = @(& git -c core.quotepath=false -C $At @GitArgs)
    $code = $LASTEXITCODE
    $script:LastGitExitCode = $code
    if ($code -ne 0 -and -not $AllowFailure) {
        Stop-Setup ("git {0} 失败（退出码 {1}）" -f ($GitArgs -join ' '), $code)
    }
    return $output
}

function Get-CanonicalPath([string]$Path, [string]$Base) {
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $Base $Path }
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Get-Worktrees {
    $lines = @(Invoke-Git $script:GitRoot @('worktree', 'list', '--porcelain'))
    $items = [System.Collections.Generic.List[object]]::new()
    $item = $null
    foreach ($line in $lines) {
        if ($line -match '^worktree (.+)$') {
            if ($item) { $items.Add($item) }
            $item = [ordered]@{ Path = Get-CanonicalPath $Matches[1] $script:GitRoot; Branch = ''; Head = ''; Detached = $false; Bare = $false }
        } elseif ($item -and $line -match '^HEAD (.+)$') { $item.Head = $Matches[1] }
        elseif ($item -and $line -match '^branch refs/heads/(.+)$') { $item.Branch = $Matches[1] }
        elseif ($item -and $line -eq 'detached') { $item.Detached = $true }
        elseif ($item -and $line -eq 'bare') { $item.Bare = $true }
    }
    if ($item) { $items.Add($item) }
    return $items.ToArray()
}

function Read-Registration {
    $registrationPath = $script:Registration
    if (-not (Test-Path -LiteralPath $registrationPath -PathType Leaf)) {
        $legacyRegistration = Join-Path $script:RuntimeDir 'registration'
        if (-not (Test-Path -LiteralPath $legacyRegistration -PathType Leaf)) { return $null }
        $registrationPath = $legacyRegistration
    }
    $lines = @(Get-Content -LiteralPath $registrationPath -Encoding UTF8)
    if ($lines.Count -gt 0 -and $lines[0] -notmatch '^format=') { return @{ path = $lines[0] } }
    $values = @{}
    foreach ($line in $lines) {
        if ($line -match '^([^=]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] }
    }
    return $values
}

function Write-Registration([string]$Path, [string]$Head) {
    $parent = Split-Path -Parent $script:Registration
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = "$script:Registration.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, ($Path + "`n"), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $script:Registration) {
        $backup = "$script:Registration.$([guid]::NewGuid().ToString('N')).bak"
        [IO.File]::Replace($temp, $script:Registration, $backup)
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
    else { [IO.File]::Move($temp, $script:Registration) }
}

function Add-Exclude([string]$Path) {
    $excludeRaw = @(Invoke-Git $script:GitRoot @('rev-parse', '--git-path', 'info/exclude'))[0]
    $exclude = Get-CanonicalPath $excludeRaw $script:GitRoot
    $rootPrefix = $script:MainWorktree.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $Path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { return }
    $relative = $Path.Substring($rootPrefix.Length).Replace('\', '/')
    $pattern = "/$relative/"
    if (-not (Test-Path -LiteralPath $exclude)) { New-Item -ItemType File -Path $exclude -Force | Out-Null }
    $existing = [IO.File]::ReadAllLines($exclude)
    if ($existing -contains $pattern) { return }
    $content = [IO.File]::ReadAllText($exclude)
    $newline = if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) { "`n" } else { '' }
    [IO.File]::AppendAllText($exclude, ($newline + $pattern + "`n"), [Text.UTF8Encoding]::new($false))
}

function Enter-WriteLock {
    New-Item -ItemType Directory -Path $script:RuntimeDir -Force | Out-Null
    try {
        New-Item -ItemType Directory -Path $script:LockPath -ErrorAction Stop | Out-Null
    } catch {
        $ownerPath = Join-Path $script:LockPath 'owner'
        $owner = if (Test-Path -LiteralPath $ownerPath) { (Get-Content -LiteralPath $ownerPath -Raw -ErrorAction SilentlyContinue) } else { '锁状态尚未写入或无法读取' }
        Stop-Setup "任务中心写锁已占用：$($script:LockPath)`n$owner`n确认持有进程已退出后，才可手工移除锁目录。"
    }
    $script:LockOwned = $true
    $ownerText = "identity=setup-task-center`npid=$PID`nstarted=$([DateTime]::UtcNow.ToString('o'))`ncommand=setup-task-center`n"
    try { [IO.File]::WriteAllText((Join-Path $script:LockPath 'owner'), $ownerText, [Text.UTF8Encoding]::new($false)) }
    catch { Exit-WriteLock; throw }
}

function Exit-WriteLock {
    if ($script:LockOwned) {
        $ownerPath = Join-Path $script:LockPath 'owner'
        Remove-Item -LiteralPath $ownerPath -Force -ErrorAction SilentlyContinue
        try { [IO.Directory]::Delete($script:LockPath, $false) } catch { }
        $script:LockOwned = $false
    }
}

function Get-SourceAssets {
    $source = Get-CanonicalPath $SourcePath (Get-Location).Path
    if (Test-Path -LiteralPath (Join-Path $source 'templates/task-center/TASK-CENTER.md')) {
        $source = Join-Path $source 'templates/task-center'
    }
    $required = @('TASK-CENTER.md', 'task-file.md', 'INDEX.md', 'scripts/task.sh', 'scripts/task.ps1', '.task-center/version', '.task-center/next-id')
    foreach ($item in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $item) -PathType Leaf)) { Stop-Setup "模板来源缺少必需资产：$(Join-Path $source $item)" }
    }
    $script:SourceRoot = $source
    $versionLines = Get-Content -LiteralPath (Join-Path $source '.task-center/version') -Encoding UTF8
    $version = @{}
    foreach ($line in $versionLines) { if ($line -match '^([^:]+):\s*(.*)$') { $version[$Matches[1]] = $Matches[2] } }
    if (-not $version['tool-version'] -or -not $version['schema-version']) { Stop-Setup '模板版本文件必须包含 tool-version 与 schema-version。' }
    $script:ToolVersion = $version['tool-version']
    $script:SchemaVersion = $version['schema-version']
    $sourceRepo = $source
    while ($sourceRepo -and -not (Test-Path -LiteralPath (Join-Path $sourceRepo '.git'))) {
        $parent = Split-Path -Parent $sourceRepo
        if (-not $parent -or $parent -eq $sourceRepo) { $sourceRepo = ''; break }
        $sourceRepo = $parent
    }
    if ($sourceRepo) {
        $sourceSafePath = $sourceRepo.Replace('\', '/')
        $sourceGit = @(& git -c "safe.directory=$sourceSafePath" -C $sourceRepo rev-parse --show-toplevel)
        $sourceCode = $LASTEXITCODE
        if ($sourceCode -eq 0 -and $sourceGit.Count -gt 0) {
            $sourceStatus = @(& git -c "safe.directory=$sourceSafePath" -C $sourceRepo status --porcelain --untracked-files=all)
            if ($LASTEXITCODE -ne 0) { Stop-Setup '无法检查模板来源工作区状态。' }
            if ($sourceStatus.Count -eq 0) {
                $script:SourceRevision = @(& git -c "safe.directory=$sourceSafePath" -C $sourceRepo rev-parse HEAD)[0]
                if ($LASTEXITCODE -ne 0) { Stop-Setup '无法读取模板来源提交号。' }
            } else {
                $script:SourceRevision = 'local-source'
                Write-Host '模板来源工作区有本地修改；版本文件会记录 local-source。' -ForegroundColor Yellow
            }
        } else { $script:SourceRevision = 'local-source' }
    } else { $script:SourceRevision = 'local-source' }
    if ($version.ContainsKey('source-revision') -and $version['source-revision'] -ne 'template' -and $script:SourceRevision -eq 'local-source') {
        $script:SourceRevision = $version['source-revision']
    }
}

function Get-TaskCenterCandidate {
    $worktrees = @(Get-Worktrees)
    $envPath = $env:TASK_CENTER_PATH
    if ($envPath) {
        $candidatePath = Get-CanonicalPath $envPath $script:GitRoot
        $match = $worktrees | Where-Object { $_.Path -eq $candidatePath }
        if (-not $match) { Stop-Setup "TASK_CENTER_PATH 不是当前克隆登记的 worktree：$candidatePath" }
        if ($match.Branch -ne $Branch) { Stop-Setup "TASK_CENTER_PATH 分支冲突：期望 $Branch，实际 $($match.Branch)" }
        return $match
    }
    $registration = Read-Registration
    if ($registration -and $registration.path) {
        $registeredPath = Get-CanonicalPath $registration.path $script:GitRoot
        $match = $worktrees | Where-Object { $_.Path -eq $registeredPath }
        if ($match) {
            if ($match.Branch -eq $Branch) { return $match }
            Write-Host "登记路径当前位于 $($match.Branch)；将按目标分支重新发现任务中心。" -ForegroundColor Yellow
        }
        if (-not $match) { Write-Host "登记的任务中心 worktree 已缺失：$registeredPath" -ForegroundColor Yellow }
    }
    $matches = @($worktrees | Where-Object { $_.Branch -eq $Branch })
    if ($matches.Count -gt 1) { Stop-Setup "发现多个 $Branch worktree，拒绝静默选择。" }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Get-DefaultWorktreePath {
    $worktrees = @(Get-Worktrees)
    if ($worktrees.Count -eq 0) { Stop-Setup 'Git 未返回主工作树路径。' }
    $mainPath = $worktrees[0].Path
    return Get-CanonicalPath (Join-Path $mainPath ".worktrees/$WorktreeName") $mainPath
}

function Assert-CommitIdentity {
    $ident = @(Invoke-Git $script:GitRoot @('var', 'GIT_AUTHOR_IDENT') -AllowFailure)
    if ($LASTEXITCODE -ne 0 -or $ident.Count -eq 0) { Stop-Setup 'Git 未配置提交身份；请设置 user.name 与 user.email 后重试。' }
}

function Set-VersionFile([string]$Root) {
    $version = @("tool-version: $script:ToolVersion", "schema-version: $script:SchemaVersion", "source-revision: $script:SourceRevision")
    [IO.File]::WriteAllLines((Join-Path $Root '.task-center/version'), $version, [Text.UTF8Encoding]::new($false))
}

function Write-AgentGuidance {
    Write-Host ''
    Write-Host '可复制到工具支持的用户级指令位置的通用引导（请先核对该工具自己的指令机制；本脚本不会修改用户全局指令文件）：'
    Write-Host '识别当前 Git 克隆，并查找已登记的任务中心或 task-center worktree；若已启用，先阅读其中的 TASK-CENTER.md，再使用能区分并发会话的 TASK_IDENTITY 运行 init、list 和 check。日常任务只通过 task.sh 或 task.ps1 命令操作；不要手工编辑任务文件或 INDEX。未启用时明确告知用户，不要静默安装。任务中心只在当前克隆内共享。'
}

function Copy-SeedAssets([string]$Target, [switch]$PreserveTasks) {
    foreach ($file in @('TASK-CENTER.md', 'scripts/task.sh', 'scripts/task.ps1')) {
        $dest = Join-Path $Target $file
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:SourceRoot $file) -Destination $dest -Force
    }
    New-Item -ItemType Directory -Path (Join-Path $Target '.task-center') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:SourceRoot '.task-center/next-id') -Destination (Join-Path $Target '.task-center/next-id') -Force
    Set-VersionFile $Target
    New-Item -ItemType Directory -Path (Join-Path $Target 'docs/tasks/archive') -Force | Out-Null
    if (-not $PreserveTasks) { Copy-Item -LiteralPath (Join-Path $script:SourceRoot 'INDEX.md') -Destination (Join-Path $Target 'docs/tasks/INDEX.md') -Force }
}

function Get-TaskInventory([string]$Root) {
    $files = @()
    $tasksPath = Join-Path $Root 'docs/tasks'
    foreach ($area in @('', 'archive')) {
        $dir = if ($area) { Join-Path $tasksPath $area } else { $tasksPath }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $dir -File -Filter '*.md') {
            if ($file.Name -eq 'INDEX.md' -or $file.Name -match '^INDEX\.legacy') { continue }
            if ($file.Name -notmatch '^(\d+)-(.+)\.md$') { Stop-Setup "未知任务文件名：$($file.FullName)" }
            $id = [int]$Matches[1]
            $text = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n").Replace("`r", "`n")
            $heading = [regex]::Match($text, '(?m)^#\s+任务\s+#0*([0-9]+)\s+(.+)$')
            if (-not $heading.Success -or [int]$heading.Groups[1].Value -ne $id) { Stop-Setup "文件名与标题编号不一致：$($file.FullName)" }
            $files += [pscustomobject]@{ Id = $id; File = $file; Text = $text; Heading = $heading.Groups[2].Value; Archived = [bool]$area }
        }
    }
    $dupes = $files | Group-Object Id | Where-Object Count -gt 1
    if ($dupes) { Stop-Setup ("活跃和归档任务存在重复编号：" + (($dupes | ForEach-Object { $_.Name }) -join ', ')) }
    return $files
}

function Assert-OrphanHistory([string]$Path) {
    $roots = @(Invoke-Git $Path @('rev-list','--max-parents=0','HEAD'))
    if ($roots.Count -ne 1) { Stop-Setup '任务中心历史没有唯一的根提交；需要 repair 流程。' }
    $mainHead = @(Invoke-Git $script:MainWorktree @('rev-parse','HEAD'))[0]
    $null = Invoke-Git $Path @('merge-base','HEAD',$mainHead) -AllowFailure
    if ($script:LastGitExitCode -eq 0) { Stop-Setup '任务中心历史与项目代码历史共享祖先；需要 repair 流程。' }
    if ($script:LastGitExitCode -ne 1) { Stop-Setup '无法验证任务中心与项目代码历史的边界。' }
}

function Get-Field([string]$Text, [string]$Name) {
    $matches = [regex]::Matches($Text, "(?m)^$([regex]::Escape($Name))：([^`r`n]*)$")
    if ($matches.Count -gt 1) { Stop-Setup "任务文件字段重复：$Name" }
    if ($matches.Count -eq 0) { return '' }
    return ($matches[0].Groups[1].Value.Trim() -replace '\s+#\s.*$', '').Trim()
}

function Get-MigrationFileName([object]$Task) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($Task.File.Name)
    $dash = $stem.IndexOf('-')
    $slug = if ($dash -ge 0) { $stem.Substring($dash + 1) } else { $stem }
    $slug = [regex]::Replace($slug.ToLowerInvariant(), '[^a-z0-9-]+', '-')
    $slug = [regex]::Replace($slug, '-+', '-').Trim('-')
    if (-not $slug) { $slug = "task-$($Task.Id)" }
    return "$($Task.Id.ToString('D4'))-$slug.md"
}

function Get-TaskRemarks([string]$IndexPath) {
    $remarks = @{}
    if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) { return $remarks }
    foreach ($line in Get-Content -LiteralPath $IndexPath -Encoding UTF8) {
        if ($line -match '^\|\s*(\d+)\s*\|') {
            $parts = $line.Trim('|').Split('|') | ForEach-Object { $_.Trim() }
            if ($parts.Count -ge 7 -and $parts[0] -match '^\d+$' -and $parts[6] -and $parts[6] -ne '备注') { $remarks[[int]$parts[0]] = $parts[6] }
        }
    }
    return $remarks
}

function Get-MigrationPlan([string]$Root) {
    $tasks = @(Get-TaskInventory $Root)
    $remarks = Get-TaskRemarks (Join-Path $Root 'docs/tasks/INDEX.md')
    $plans = [System.Collections.Generic.List[object]]::new()
    foreach ($task in $tasks) {
        $status = Get-Field $task.Text '状态'
        $owner = Get-Field $task.Text 'owner'
        $oldRole = Get-Field $task.Text '角色'
        $current = Get-Field $task.Text '当前负责人'
        $blockFrom = Get-Field $task.Text '阻塞前状态'
        $blockReason = Get-Field $task.Text '阻塞原因'
        $waitingFor = Get-Field $task.Text '等待对象'
        $missing = [System.Collections.Generic.List[string]]::new()
        $blockers = [System.Collections.Generic.List[string]]::new()
        $migrationNotes = [System.Collections.Generic.List[string]]::new()
        if ($status -notin @('待办','已认领','进行中','待审核','待测试','待合并','已完成','阻塞','已取消')) { Stop-Setup "任务 $($task.Id) 状态未知，停止自动迁移：$status" }
        if ($status -in @('待办','已完成','已取消')) { $current = '未分配' }
        elseif (-not $current -or $current -in @('未分配','-','无')) {
            if ($status -in @('已认领','进行中') -and $owner -and $owner -ne '未认领') { $current = $owner }
            else { $current = '待补'; $missing.Add('当前负责人无法从旧数据可靠推导') }
        }
        if ($status -eq '待办') { $owner = '未认领' }
        elseif (-not $owner -or $owner -in @('-','无') -or ($status -notin @('已完成','已取消') -and $owner -eq '未认领')) {
            $owner = '待补'; $missing.Add('owner 缺失或与当前状态冲突')
        }
        if ($status -eq '阻塞') {
            if ($blockFrom -notin @('已认领','进行中','待审核','待测试','待合并')) {
                $blockers.Add('阻塞前状态缺失或无效；需维护者确认后再修复')
                $blockFrom = '进行中'
            }
            if (-not $blockReason -or $blockReason -eq '无') { $blockReason = '待补：旧格式未记录阻塞原因'; $missing.Add('阻塞原因需补齐') }
            if (-not $waitingFor -or $waitingFor -eq '无') { $waitingFor = '待补'; $missing.Add('等待对象需补齐') }
            if ($blockReason -match '[\r\n\t|]' -or $waitingFor -match '[\r\n\t|]') {
                $blockers.Add('阻塞原因或等待对象包含客户端不接受的字符')
                $blockReason = '待补'; $waitingFor = '待补'
            }
        }
        if ($status -in @('待审核','待测试','待合并') -and $oldRole -and $oldRole -notmatch '^(审核|测试|维护者|开发)$') { $missing.Add("旧角色值需人工核对：$oldRole") }
        $bodyStart = [regex]::Match($task.Text, '(?m)^##\s+')
        $body = if ($bodyStart.Success) { $task.Text.Substring($bodyStart.Index).TrimEnd("`r", "`n") } else { "## 迁移记录`n`n（旧任务文件未包含正文分区）" }
        $created = Get-Field $task.Text '创建'
        if (-not $created -or $created -notmatch '^\d{4}-\d{2}-\d{2}\s+.+$') {
            $blockers.Add('创建日期或登记身份缺失/无效；不能安全推断')
            $created = '2000-01-01 待补'
        }
        if ($created -match '[\r\n\t|]') { $blockers.Add('创建字段包含客户端不接受的字符'); $created = '2000-01-01 待补' }
        $priority = Get-Field $task.Text '优先级'
        if ($priority -notin @('高','中','低')) { if ($priority) { $migrationNotes.Add("旧优先级：$priority") }; $priority = '中'; $missing.Add('优先级需核对') }
        $depends = Get-Field $task.Text '依赖'; if (-not $depends) { $depends = '无' }
        if ($depends -match '[\r\n\t|]') { $blockers.Add('依赖字段格式无效'); $depends = '无' }
        $branchValue = Get-Field $task.Text '分支'
        $pr = Get-Field $task.Text 'PR'
        $external = Get-Field $task.Text '外部'
        $note = Get-Field $task.Text '备注'
        if (-not $note -and $remarks.ContainsKey($task.Id)) { $note = $remarks[$task.Id] }
        if ($external -and $external -ne '无' -and $external -notmatch '^https?://\S+$') {
            $migrationNotes.Add("旧外部字段：$external"); $external = '无'; $missing.Add('旧外部字段格式需核对')
        }
        if (-not $external) { $external = '无' }
        foreach ($fieldName in @('分支','PR','备注')) {
            $fieldValue = switch ($fieldName) { '分支' { $branchValue } 'PR' { $pr } '备注' { $note } }
            if ($fieldValue -match '[\r\n\t|]') {
                $migrationNotes.Add("旧$fieldName 字段需核对：$fieldValue")
                switch ($fieldName) { '分支' { $branchValue = '无' } 'PR' { $pr = '无' } '备注' { $note = '无' } }
                $missing.Add("$fieldName 字段格式需核对")
            }
        }
        if (-not $branchValue) { $branchValue = '无' }
        if (-not $pr) { $pr = '无' }
        if (-not $note) { $note = '无' }
        if ($owner -match '[\r\n\t|]' -or $current -match '[\r\n\t|]') {
            $blockers.Add('owner 或当前负责人包含客户端不接受的字符')
            $owner = '待补'; $current = '待补'
        }
        if ($status -ne '阻塞') { $blockFrom = '无'; $blockReason = '无'; $waitingFor = '无' }
        $header = @(
            "# 任务 #$($task.Id) $($task.Heading)", '',
            "状态：$status", "owner：$owner", "当前负责人：$current", "优先级：$priority", "依赖：$depends",
            "分支：$branchValue", "PR：$pr", "外部：$external", "备注：$note",
            "阻塞前状态：$blockFrom", "阻塞原因：$blockReason", "等待对象：$waitingFor", "创建：$created", ''
        ) -join "`n"
        if ($task.Heading -match '[\r\n\t|]') { $blockers.Add('任务标题包含客户端不接受的字符') }
        $acceptHeading = [regex]::Match($body, '(?m)^## 验收标准\s*$')
        if (-not $acceptHeading.Success) {
            $body += "`n`n## 验收标准`n"
            $acceptHeading = [regex]::Match($body, '(?m)^## 验收标准\s*$')
        }
        $acceptStart = $acceptHeading.Index + $acceptHeading.Length
        $nextHeading = [regex]::Match($body.Substring($acceptStart), '(?m)^##\s+')
        $acceptEnd = if ($nextHeading.Success) { $acceptStart + $nextHeading.Index } else { $body.Length }
        $acceptText = $body.Substring($acceptStart, $acceptEnd - $acceptStart)
        if ($acceptText -notmatch '(?m)^-[ \t]+\[[ xX]\][ \t]+.+$') {
            if ($status -eq '已完成') { $blockers.Add('已完成任务缺少验收项，需人工核实') }
            $box = if ($status -eq '已完成') { '[x]' } else { '[ ]' }
            $body = $body.Insert($acceptEnd, "`n- $box 待补充验收条件`n")
            $missing.Add('验收条件需核对或补齐')
        }
        if ($body -notmatch '(?m)^## 进度\s*$') { $body += "`n`n## 进度`n`n- 迁移记录；下一步：核对迁移待补项" }
        if ($status -eq '已完成' -and $body -match '(?m)^-[ \t]+\[ \]') { $blockers.Add('已完成任务仍有未勾选验收项，需先核实状态') }
        if ($status -in @('待审核','待测试','待合并','已完成') -and $body -notmatch '证据：[^无（)]') {
            $blockers.Add("$status 任务缺少证据记录，需维护者补充")
            $body += "`n`n## 迁移核对`n`n证据：待补充（旧记录未包含证据）"
        }
        if ($migrationNotes.Count -gt 0) { $body += "`n`n## 迁移核对`n`n" + ($migrationNotes -join "`n") }
        $expectedRole = switch ($status) {
            { $_ -in @('已认领','进行中') } { '开发'; break }
            '待审核' { '审核'; break }
            '待测试' { '测试'; break }
            '待合并' { '维护者'; break }
            '阻塞' { switch ($blockFrom) { '待审核' {'审核'} '待测试' {'测试'} '待合并' {'维护者'} default {'开发'} }; break }
            default { '' }
        }
        if ($oldRole -and $expectedRole -and $oldRole -ne $expectedRole) { $missing.Add("旧角色「$oldRole」与状态推导角色「$expectedRole」不一致") }
        if ($oldRole) { $body = "## 旧角色字段（迁移核对）`n`n$oldRole`n`n$body" }
        $mustArchive = $status -in @('已完成','已取消')
        if ($task.Archived -and -not $mustArchive) { Stop-Setup "归档目录中的任务 $($task.Id) 不是终态，自动迁移存在歧义。" }
        $plans.Add([pscustomobject]@{ Id = $task.Id; File = $task.File; OutputName = (Get-MigrationFileName $task); Archived = ($task.Archived -or $mustArchive); Text = $header + $body + "`n"; Missing = @($missing); Blockers = @($blockers); OldRole = $oldRole })
    }
    return $plans.ToArray()
}

function Write-GeneratedIndex([string]$Root, [object[]]$Plans) {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @('# 任务索引','','> 本文件由任务文件生成并提交。禁止手工维护表格行；使用 `task index --rebuild` 重建。','','## 活跃任务','','| # | 标题 | 状态 | owner | 当前负责人 | 备注 |','|---:|---|---|---|---|---|')) { $lines.Add($line) }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($plan in @($Plans | Where-Object { -not $_.Archived })) {
        $status = Get-Field $plan.Text '状态'; $owner = Get-Field $plan.Text 'owner'; $assignee = Get-Field $plan.Text '当前负责人'; $note = Get-Field $plan.Text '备注'
        $title = [regex]::Match($plan.Text, '(?m)^#\s+任务\s+#\d+\s+(.+)$').Groups[1].Value
        $rows.Add([pscustomobject]@{ Id = $plan.Id; Line = "| TC-$('{0:d4}' -f $plan.Id) | $title | $status | $owner | $assignee | $note |" })
    }
    foreach ($row in ($rows | Sort-Object Id)) { $lines.Add($row.Line) }
    foreach ($line in @('','## 已完成','','已归档任务保存在 `archive/`，编号永久保留。')) { $lines.Add($line) }
    [IO.File]::WriteAllText((Join-Path $Root 'docs/tasks/INDEX.md'), (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

function Assert-AssetLayout([string]$Path, [string]$ExpectedBranch) {
    $branchOut = @(Invoke-Git $Path @('branch', '--show-current'))
    if ($branchOut[0] -ne $ExpectedBranch) { Stop-Setup "worktree 分支错误：$($branchOut[0])" }
    $status = @(Invoke-Git $Path @('status', '--porcelain'))
    if ($status.Count -gt 0 -and $status[0]) { Stop-Setup "任务中心有暂存、未提交或未跟踪内容，停止操作：$Path" }
    $files = @(Invoke-Git $Path @('ls-tree', '-r', '--name-only', 'HEAD'))
    $required = @('TASK-CENTER.md','scripts/task.sh','scripts/task.ps1','.task-center/version','.task-center/next-id','docs/tasks/INDEX.md')
    foreach ($file in $required) { if ($files -notcontains $file) { Stop-Setup "任务中心缺少必要资产：$file" } }
    foreach ($file in $files) {
        $allowed = $file -in $required -or $file -match '^docs/tasks/(archive/)?\d+-.+\.md$'
        if (-not $allowed) { Stop-Setup "任务中心包含清单外文件：$file" }
    }
    Assert-OrphanHistory $Path
    $versionText = [IO.File]::ReadAllText((Join-Path $Path '.task-center/version'))
    $schemaMatch = [regex]::Match($versionText,'(?m)^schema-version:\s*(\d+)\s*$')
    if (-not $schemaMatch.Success) { Stop-Setup '任务中心 schema-version 缺失或格式无效。' }
    if ([int]$schemaMatch.Groups[1].Value -gt [int]$script:SchemaVersion) { Stop-Setup "任务中心数据格式版本过新（schema $($schemaMatch.Groups[1].Value)；当前来源支持 $script:SchemaVersion）。" }
    $null = Get-TaskInventory $Path
}

function Invoke-CurrentTaskCheck([string]$Path, [string]$ExpectedBranch) {
    $taskScript = Join-Path $Path 'scripts/task.ps1'
    $engineName = if ($PSVersionTable.PSEdition -eq 'Core') { if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' } } else { 'powershell.exe' }
    $engine = Join-Path $PSHOME $engineName
    if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { Stop-Setup "无法定位 PowerShell 命令行引擎：$engine；拒绝切换 repair 分支。" }
    $oldCenterPath = $env:TASK_CENTER_PATH
    $oldBranch = $env:TASK_BRANCH
    $locationPushed = $false
    try {
        $env:TASK_CENTER_PATH = $Path
        $env:TASK_BRANCH = $ExpectedBranch
        # Discover the owning project from its real checkout; the candidate worktree
        # is selected explicitly and still has its temporary repair branch here.
        Push-Location -LiteralPath $script:GitRoot
        $locationPushed = $true
        & $engine -NoLogo -NoProfile -NonInteractive -File $taskScript check
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { Stop-Setup "repair 输出未通过当前 task.ps1 check（退出码 $exitCode）；拒绝切换分支。" }
        Write-Host '当前 task.ps1 check 通过；继续切换。'
    } finally {
        if ($locationPushed) { Pop-Location }
        if ($null -eq $oldCenterPath) { Remove-Item Env:TASK_CENTER_PATH -ErrorAction SilentlyContinue }
        else { $env:TASK_CENTER_PATH = $oldCenterPath }
        if ($null -eq $oldBranch) { Remove-Item Env:TASK_BRANCH -ErrorAction SilentlyContinue }
        else { $env:TASK_BRANCH = $oldBranch }
    }
}

function Get-UnknownPaths([string]$Path) {
    $tracked = @(Invoke-Git $Path @('ls-tree','-r','--name-only','HEAD'))
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $tracked) {
        $allowed = $file -in @('TASK-CENTER.md','scripts/task.sh','scripts/task.ps1','.task-center/version','.task-center/next-id','docs/tasks/INDEX.md') -or $file -match '^docs/tasks/(archive/)?\d+-.+\.md$'
        if (-not $allowed) { $unknown.Add($file) }
    }
    return $unknown.ToArray()
}

function Assert-NoHistoricalIdReuse([string]$Path) {
    $paths = @(Invoke-Git $Path @('log','--all','--format=','--name-only','--','docs/tasks'))
    $seen = @{}
    foreach ($item in $paths) {
        if ($item -match '^docs/tasks/(?:archive/)?(\d+)-(.+)\.md$') {
            $id = [int]$Matches[1]; $name = $Matches[2]
            if ($seen.ContainsKey($id) -and $seen[$id] -ne $name) { Stop-Setup "历史中编号 $id 对应多个任务文件名（$($seen[$id]) / $name），需维护者提供映射后再迁移。" }
            $seen[$id] = $name
        }
    }
}

function Get-TargetBranchState {
    $refExists = Invoke-Git $script:GitRoot @('show-ref','--verify','--quiet',"refs/heads/$Branch") -AllowFailure
    if ($script:LastGitExitCode -eq 0) { return @(Invoke-Git $script:GitRoot @('rev-parse',"refs/heads/$Branch"))[0] }
    return ''
}

function Get-RemoteBranchRefs {
    return @(Invoke-Git $script:GitRoot @('for-each-ref','--format=%(refname)',"refs/remotes/*/$Branch"))
}

function Setup-Install {
    $remoteRefs = @(Get-RemoteBranchRefs)
    if ($remoteRefs.Count -gt 0) { Write-Host "发现远端跟踪分支（不读取、不修改）：$($remoteRefs -join ', ')" -ForegroundColor Yellow }
    $candidate = Get-TaskCenterCandidate
    if ($candidate) {
        Write-Host "发现任务中心 worktree：$($candidate.Path) [$Branch]"
        try { Assert-AssetLayout $candidate.Path $Branch }
        catch { Write-Host "安装需要诊断或修复：$($_.Exception.Message)" -ForegroundColor Yellow; Write-Host '运行 setup-task-center -Repair 先查看修复计划。'; throw }
        Add-Exclude $candidate.Path
        $head = @(Invoke-Git $candidate.Path @('rev-parse','HEAD'))[0]
        Write-Registration $candidate.Path $head
        Write-Host '任务中心已就绪；已保留现有协议、脚本和任务数据。'
        return
    }
    $head = Get-TargetBranchState
    $destination = Get-DefaultWorktreePath
    if (Test-Path -LiteralPath $destination) { Stop-Setup "目标路径已存在但不是可识别的任务中心 worktree，拒绝覆盖：$destination" }
    Assert-CommitIdentity
    if ($head) {
        Write-Host "本地分支 $Branch 已存在；接入现有分支并检查其内容。"
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        $null = Invoke-Git $script:GitRoot @('worktree','add',$destination,$Branch)
        Assert-AssetLayout $destination $Branch
    } else {
        $buildPath = Join-Path $script:RuntimeDir ("bootstrap-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        $null = Invoke-Git $script:GitRoot @('worktree','add','--detach',$buildPath,'HEAD')
        try {
            $null = Invoke-Git $buildPath @('switch','--orphan',$Branch)
            Copy-SeedAssets $buildPath
            $null = Invoke-Git $buildPath @('add','--','TASK-CENTER.md','scripts/task.sh','scripts/task.ps1','.task-center/version','.task-center/next-id','docs/tasks/INDEX.md')
            $null = Invoke-Git $buildPath @('commit','-m','docs(tasks): initialize local task center')
            Assert-AssetLayout $buildPath $Branch
            $null = Invoke-Git $script:GitRoot @('worktree','move',$buildPath,$destination)
        } catch {
            Write-Host "安装未完成；中间 worktree 保留在 $buildPath 供检查与恢复。" -ForegroundColor Yellow
            throw
        }
    }
    Add-Exclude $destination
    $finalHead = @(Invoke-Git $destination @('rev-parse','HEAD'))[0]
    Write-Registration $destination $finalHead
    Write-Host "任务中心已安装：$destination [$Branch]"
}

function Restore-Bundle {
    $bundle = Get-CanonicalPath $RestoreBundlePath (Get-Location).Path
    if (-not (Test-Path -LiteralPath $bundle -PathType Leaf)) { Stop-Setup "恢复 bundle 不存在：$bundle" }
    $refs = Invoke-Git $script:GitRoot @('bundle','list-heads',$bundle)
    if (-not ($refs | Where-Object { $_ -match "\srefs/heads/$([regex]::Escape($Branch))$" })) { Stop-Setup "bundle 不包含 refs/heads/$Branch。" }
    $existing = Get-TargetBranchState
    if ($existing) { Stop-Setup "本地分支 $Branch 已存在；恢复不会覆盖现有分支。" }
    $destination = Get-DefaultWorktreePath
    if (Test-Path -LiteralPath $destination) { Stop-Setup "恢复目标路径已存在，拒绝覆盖：$destination" }
    Enter-WriteLock
    try {
        $null = Invoke-Git $script:GitRoot @('bundle','verify',$bundle)
        $refspec = "refs/heads/${Branch}:refs/heads/${Branch}"
        $null = Invoke-Git $script:GitRoot @('fetch','--no-tags',$bundle,$refspec)
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        $null = Invoke-Git $script:GitRoot @('worktree','add',$destination,$Branch)
        $tasks = @(Get-TaskInventory $destination)
        Add-Exclude $destination
        $head = @(Invoke-Git $destination @('rev-parse','HEAD'))[0]
        Write-Registration $destination $head
        Write-Host "恢复完成：$destination [$Branch]；扫描到 $($tasks.Count) 个任务文件。"
        Write-Host '旧格式将保留原样；如需整理历史，先运行 setup-task-center -Repair 预览。'
    } finally { Exit-WriteLock }
}

function Get-BackupPlan([string]$CenterPath, [string]$OldHead) {
    $outside = if ($BackupDirectory) { Get-CanonicalPath $BackupDirectory (Get-Location).Path } else { Join-Path ([IO.Path]::GetTempPath()) 'task-center-backups' }
    $repoPrefix = $script:GitRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($outside.Equals($script:GitRoot, [StringComparison]::OrdinalIgnoreCase) -or $outside.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) { Stop-Setup "备份目录必须位于当前克隆之外：$outside" }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    return [pscustomobject]@{ Directory = $outside; Stamp = $stamp; Bundle = Join-Path $outside "task-center-$stamp.bundle"; Manifest = Join-Path $outside "task-center-$stamp.manifest.txt"; OldHead = $OldHead }
}

function Invoke-Repair {
    $candidate = Get-TaskCenterCandidate
    if (-not $candidate) { Stop-Setup "未找到本地 $Branch worktree；先运行 setup-task-center 安装任务中心。" }
    $center = $candidate.Path
    $branchHead = @(Invoke-Git $center @('rev-parse','HEAD'))[0]
    $status = @(Invoke-Git $center @('status','--porcelain'))
    $tasks = @(Get-TaskInventory $center)
    $plans = @(Get-MigrationPlan $center)
    Assert-NoHistoricalIdReuse $center
    $unknown = @(Get-UnknownPaths $center)
    $trackedPaths = @(Invoke-Git $center @('ls-tree','-r','--name-only','HEAD'))
    $requiredAssets = @('TASK-CENTER.md','scripts/task.sh','scripts/task.ps1','.task-center/version','.task-center/next-id','docs/tasks/INDEX.md')
    $missingAssets = @($requiredAssets | Where-Object { $trackedPaths -notcontains $_ })
    $manifest = Get-BackupPlan $center $branchHead
    $localAssets = @('TASK-CENTER.md','scripts/task.sh','scripts/task.ps1') | Where-Object {
        (Test-Path -LiteralPath (Join-Path $center $_)) -and (Test-Path -LiteralPath (Join-Path $script:SourceRoot $_)) -and
        ((Get-FileHash -LiteralPath (Join-Path $center $_) -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $script:SourceRoot $_) -Algorithm SHA256).Hash)
    }
    $upstreamRemote = @(Invoke-Git $script:GitRoot @('config','--get',"branch.$Branch.remote") -AllowFailure)
    $hasUpstream = $script:LastGitExitCode -eq 0 -and $upstreamRemote.Count -gt 0
    $remoteRefs = @(Get-RemoteBranchRefs)
    Write-Host "修复预览：$center [$Branch]"
    Write-Host "  当前提交：$branchHead"
    Write-Host "  活跃及归档任务：$($tasks.Count)；预计待补字段：$(($plans | ForEach-Object { $_.Missing.Count } | Measure-Object -Sum).Sum)"
    $historyRoots = @(Invoke-Git $center @('rev-list','--max-parents=0','HEAD'))
    $mainHead = @(Invoke-Git $script:MainWorktree @('rev-parse','HEAD'))[0]
    $null = Invoke-Git $center @('merge-base','HEAD',$mainHead) -AllowFailure
    if ($script:LastGitExitCode -eq 0) { Write-Host '  历史边界：旧任务历史与项目代码历史共享祖先；修复会切断该关联。' -ForegroundColor Yellow }
    elseif ($script:LastGitExitCode -eq 1 -and $historyRoots.Count -eq 1) { Write-Host '  历史边界：旧任务历史已有独立孤儿根；修复会建立新的根提交。' }
    elseif ($script:LastGitExitCode -eq 1) { Write-Host "  历史边界：发现 $($historyRoots.Count) 个历史根；修复会建立新的根提交。" -ForegroundColor Yellow }
    else { Stop-Setup '无法读取旧任务历史边界。' }
    Write-Host "  备份位置：$($manifest.Bundle)（仅 --apply 时创建）"
    if ($localAssets.Count -gt 0) { Write-Host "  与来源模板不同的本地资产：$($localAssets -join ', ')；将保留差异清单并采用指定来源版本。" -ForegroundColor Yellow }
    if ($unknown.Count -gt 0) { Write-Host "  新历史将不复制以下清单外路径（其旧历史完整保存在 bundle）：" -ForegroundColor Yellow; foreach ($path in $unknown) { Write-Host "    $path" } }
    if ($missingAssets.Count -gt 0) { Write-Host "  缺失的标准资产（将从指定来源补入）：$($missingAssets -join ', ')" -ForegroundColor Yellow }
    if ($remoteRefs.Count -gt 0) { Write-Host "  发现远端跟踪分支（仅诊断，不读取、不修改）：$($remoteRefs -join ', ')" -ForegroundColor Yellow }
    if ($hasUpstream) { Write-Host "  远端跟踪配置：$($upstreamRemote[0])；执行 repair 时仅清除本地 upstream，不触碰远端。" -ForegroundColor Yellow }
    if ($status.Count -gt 0 -and $status[0]) { Write-Host '  阻断项：任务中心有暂存、未提交或未跟踪内容。' -ForegroundColor Red }
    foreach ($plan in $plans) { if ($plan.Missing.Count -gt 0) { Write-Host "  TC-$('{0:d4}' -f $plan.Id)：$($plan.Missing -join '；')" -ForegroundColor Yellow } }
    foreach ($plan in $plans) { if ($plan.Blockers.Count -gt 0) { Write-Host "  TC-$('{0:d4}' -f $plan.Id) 需人工处理：$($plan.Blockers -join '；')" -ForegroundColor Red } }
    if ($localAssets.Count -gt 0) {
        Write-Host '  本地资产差异（新分支将使用指定来源版本；完整旧版保存在 bundle）：' -ForegroundColor Yellow
        foreach ($file in $localAssets) {
            Write-Host "--- $file (installed)"
            & git diff --no-index -- (Join-Path $script:SourceRoot $file) (Join-Path $center $file)
            if ($LASTEXITCODE -gt 1) { Stop-Setup "无法读取本地资产差异：$file" }
        }
    }
    if (-not $Apply) { Write-Host '预览未修改分支、任务文件或本地登记；确认计划后使用 -Repair -Apply 执行。'; return }
    if ($status.Count -gt 0 -and $status[0]) { Stop-Setup '修复已停止：任务中心存在未提交内容；请先提交、备份或手工整理。' }
    $blockingPlans = @($plans | Where-Object { $_.Blockers.Count -gt 0 })
    if ($blockingPlans.Count -gt 0) { Stop-Setup '迁移计划含无法安全推断的数据；请先处理预览中标记的阻断任务，再重新运行 repair。' }
    Assert-CommitIdentity
    Enter-WriteLock
    try {
        $nowHead = @(Invoke-Git $center @('rev-parse','HEAD'))[0]
        if ($nowHead -ne $branchHead) { Stop-Setup '预览后旧分支 HEAD 已变化，请重新运行 repair 预览。' }
        New-Item -ItemType Directory -Path $manifest.Directory -Force | Out-Null
        $null = Invoke-Git $script:GitRoot @('bundle','create',$manifest.Bundle,"refs/heads/$Branch")
        $null = Invoke-Git $script:GitRoot @('bundle','verify',$manifest.Bundle)
        $paths = @(Invoke-Git $center @('ls-tree','-r','--name-only','HEAD'))
        $manifestLines = @("branch=$Branch", "head=$branchHead", "worktree=$center", "created-utc=$([DateTime]::UtcNow.ToString('o'))", 'tracked-paths=') + $paths
        [IO.File]::WriteAllLines($manifest.Manifest,$manifestLines,[Text.UTF8Encoding]::new($false))
        $newPath = Get-CanonicalPath (Join-Path (Split-Path -Parent $center) ("task-center-repaired-$($manifest.Stamp)")) $script:GitRoot
        if (Test-Path -LiteralPath $newPath) { Stop-Setup "修复目标目录已存在，拒绝覆盖：$newPath" }
        $tempBranch = "task-center-repair-$($manifest.Stamp)"
        $null = Invoke-Git $script:GitRoot @('worktree','add','--detach',$newPath,'HEAD')
        try {
            $null = Invoke-Git $newPath @('switch','--orphan',$tempBranch)
            Copy-SeedAssets $newPath -PreserveTasks
            $newPlans = [System.Collections.Generic.List[object]]::new()
            foreach ($plan in $plans) {
                $relativeTaskPath = if ($plan.Archived) { "docs/tasks/archive/$($plan.OutputName)" } else { "docs/tasks/$($plan.OutputName)" }
                $newFile = Join-Path $newPath $relativeTaskPath
                New-Item -ItemType Directory -Path (Split-Path -Parent $newFile) -Force | Out-Null
                [IO.File]::WriteAllText($newFile,$plan.Text,[Text.UTF8Encoding]::new($false))
                $newPlans.Add([pscustomobject]@{ Id=$plan.Id; File=$newFile; Text=$plan.Text; Archived=$plan.Archived; Missing=$plan.Missing })
            }
            Write-GeneratedIndex $newPath $newPlans.ToArray()
            $maxId = if ($newPlans.Count) { ($newPlans | Measure-Object -Property Id -Maximum).Maximum } else { 0 }
            [IO.File]::WriteAllText((Join-Path $newPath '.task-center/next-id'), "$($maxId + 1)`n", [Text.UTF8Encoding]::new($false))
            $null = Invoke-Git $newPath @('add','--','TASK-CENTER.md','scripts/task.sh','scripts/task.ps1','.task-center/version','.task-center/next-id','docs/tasks')
            $null = Invoke-Git $newPath @('commit','-m','docs(tasks): migrate local task center')
            Assert-AssetLayout $newPath $tempBranch
            Invoke-CurrentTaskCheck $newPath $tempBranch
            $newHead = @(Invoke-Git $newPath @('rev-parse','HEAD'))[0]
            $backupBranch = "$Branch-backup-$($manifest.Stamp)"
            $null = Invoke-Git $center @('switch','--detach',$branchHead)
            $null = Invoke-Git $script:GitRoot @('branch','-m',$Branch,$backupBranch)
            try { $null = Invoke-Git $script:GitRoot @('branch','-m',$tempBranch,$Branch) }
            catch {
                $null = Invoke-Git $script:GitRoot @('branch','-m',$backupBranch,$Branch) -AllowFailure
                $null = Invoke-Git $center @('switch',$Branch) -AllowFailure
                Stop-Setup "修复切换失败；旧分支仍在 $backupBranch，恢复 bundle 在 $($manifest.Bundle)。"
            }
            if ($hasUpstream) { $null = Invoke-Git $script:GitRoot @('branch','--unset-upstream',$backupBranch) }
            Add-Exclude $newPath
            Write-Registration $newPath $newHead
            Write-Host "修复完成：新任务中心 $newPath [$Branch]"
            Write-Host "旧历史保留为 $backupBranch；bundle 与清单：$($manifest.Bundle) / $($manifest.Manifest)"
            Write-Host "新克隆恢复命令：& '<template-source>\scripts\setup-task-center.ps1' -RepoPath '<new-clone>' -SourcePath '<template-source>' -RestoreBundlePath '$($manifest.Bundle)'"
            Write-Host '随后运行 task.ps1 init 与 task.ps1 list，确认登记和任务可见。'
            Write-AgentGuidance
        } catch {
            Write-Host "修复构建未完成；临时 worktree 保留在 $newPath，旧分支未删除。" -ForegroundColor Yellow
            throw
        }
    } finally { Exit-WriteLock }
}

try {
    if ($Apply -and -not $Repair) { Stop-Setup '-Apply 只能与 -Repair 一起使用。' }
    if ($DryRun -and -not $Repair) { Stop-Setup '-DryRun 只能与 -Repair 一起使用。' }
    if ($Apply -and $DryRun) { Stop-Setup '-Apply 与 -DryRun 不能同时使用。' }
    if ($RestoreBundlePath -and ($Repair -or $Apply -or $DryRun)) { Stop-Setup '-RestoreBundlePath 不能与 repair 参数同时使用。' }
    $gitRoot = @(Invoke-Git (Get-CanonicalPath $RepoPath (Get-Location).Path) @('rev-parse','--show-toplevel'))
    $script:GitRoot = Get-CanonicalPath $gitRoot[0] (Get-Location).Path
    $bare = @(Invoke-Git $script:GitRoot @('rev-parse','--is-bare-repository'))[0]
    if ($bare -eq 'true') { Stop-Setup '不支持 bare 仓库。' }
    $gitVersion = @(Invoke-Git $script:GitRoot @('--version'))[0]
    if ($gitVersion -notmatch '([0-9]+)\.([0-9]+)') { Stop-Setup "无法识别 Git 版本：$gitVersion" }
    $major=[int]$Matches[1]; $minor=[int]$Matches[2]
    if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 23)) { Stop-Setup "Git 版本过旧（检测到 $gitVersion；最低目标为 2.23）。" }
    $null = Invoke-Git $script:GitRoot @('rev-parse','--verify','HEAD')
    $commonRaw = @(Invoke-Git $script:GitRoot @('rev-parse','--git-common-dir'))[0]
    $script:CommonDir = Get-CanonicalPath $commonRaw $script:GitRoot
    $worktrees = @(Get-Worktrees)
    if ($worktrees.Count -eq 0) { Stop-Setup 'Git 未返回主工作树路径。' }
    $script:MainWorktree = $worktrees[0].Path
    if ($WorktreeName -notmatch '^[A-Za-z0-9._-]+$') { Stop-Setup 'worktree 名称只允许字母、数字、点、下划线和连字符。' }
    $branchCheck = Invoke-Git $script:GitRoot @('check-ref-format','--branch',$Branch) -AllowFailure
    if ($script:LastGitExitCode -ne 0) { Stop-Setup "分支名称无效：$Branch" }
    $script:RuntimeDir = Join-Path $script:CommonDir 'task-center-runtime'
    $script:Registration = Join-Path (Join-Path $script:CommonDir 'task-center') 'install-path'
    $script:LockPath = Join-Path $script:CommonDir 'task-center-write.lock'
    Get-SourceAssets
    $worktrees = @(Get-Worktrees)
    if ($worktrees.Count -eq 0) { Stop-Setup 'Git 未返回主工作树路径。' }
    $script:MainWorktree = $worktrees[0].Path
    if ($RestoreBundlePath) { Restore-Bundle; Write-AgentGuidance }
    elseif ($Repair) { Invoke-Repair }
    else {
        Enter-WriteLock
        try { Setup-Install } finally { Exit-WriteLock }
        Write-AgentGuidance
    }
} catch {
    Write-Error ("setup-task-center: " + $_.Exception.Message)
    exit 1
}
