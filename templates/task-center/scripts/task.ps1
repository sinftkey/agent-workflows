# Task center ops script (PowerShell; task.sh is the bash version, same interface).
# See TASK-CENTER.md for usage. The script only does mechanical work
# (numbering, appending, committing, pushing); status validity and role
# permissions are enforced by the protocol and review.
# Note: both task scripts print Chinese (unlike adapt.ps1, see its header).
# Encoding: this file keeps a UTF-8 BOM on purpose -- unlike adapt.ps1 it is
# always executed as a local file (never via irm | iex), and Windows
# PowerShell 5.1 mis-parses non-ASCII without a BOM.

param()

$ErrorActionPreference = "Stop"

$Branch = if ($env:TASK_BRANCH) { $env:TASK_BRANCH } else { "task-center" }
$WorktreeName = if ($env:TASK_WORKTREE_NAME) { $env:TASK_WORKTREE_NAME } else { "task-center" }
$Identity = $env:TASK_IDENTITY

function Usage {
    $usageText = @"
用法：task.ps1 <命令> [参数]   （需先设置 `$env:TASK_IDENTITY）

  init                          初始化 / 更新 worktree
  list                          查看活跃任务（INDEX）
  new "<标题>" [slug]           登记新任务（取号 + 建任务文件 + INDEX 登记）
  claim <编号>                  认领（填 owner、状态「已认领」，同步 INDEX 行）
  progress <编号> "<内容>" [--status <状态>]   追加进度，可同时改状态（同步 INDEX 行）
  status <编号> <状态>          仅改状态行（同步 INDEX 行）
  done <编号>                   完成归档：状态「已完成」+ 移 archive/ + INDEX 删行（维护者）

环境变量：TASK_IDENTITY（必填）、TASK_BRANCH（默认 task-center）、TASK_WORKTREE_NAME（默认 task-center）
"@
    Write-Host $usageText -ForegroundColor Yellow
    exit 2
}

function Die($msg) { Write-Host "错误：$msg" -ForegroundColor Red; exit 1 }

if ($args.Count -lt 1) { Usage }
$Cmd = $args[0]
$Rest = @($args | Select-Object -Skip 1)

$RepoRoot = (& git rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0) { Die "请在 git 仓库内运行本脚本" }
$WT = Join-Path $RepoRoot ".worktrees/$WorktreeName"
$TasksDir = Join-Path $WT "docs/tasks"
$Index = Join-Path $TasksDir "INDEX.md"

function Require-Identity { if (-not $Identity) { Die "请先设置 `$env:TASK_IDENTITY（Agent 工具名或人员名，与任务中心约定一致）" } }
function Require-Worktree { if (-not (Test-Path -LiteralPath $WT)) { Die "任务中心 worktree 不存在，先运行：task.ps1 init" } }
function Require-Index { if (-not (Test-Path -LiteralPath $Index)) { Die "$Index 不存在，请先按 TASK-CENTER.md 初始化任务中心" } }
function Pull-Rebase { & git -C $WT pull --rebase origin $Branch | Out-Null }
function Push { & git -C $WT push origin $Branch | Out-Null }

function Commit-All($msg) {
    & git -C $WT add -A | Out-Null
    & git -C $WT diff --cached --quiet
    if ($LASTEXITCODE -ne 0) { & git -C $WT commit -m $msg | Out-Null }
}

function Write-File($path, $content) {
    ($content -join "`n") + "`n" | Out-File -LiteralPath $path -Encoding UTF8 -NoNewline
}

function Set-Line($prefix, $replacement, $file) {
    $lines = Get-Content -LiteralPath $file -Encoding UTF8
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^$prefix") { $lines[$i] = $replacement }
    }
    Write-File $file $lines
}

function Update-IndexRow($id, $status, $owner) {
    # 更新 INDEX 活跃表中该任务的行（列：| # | 标题 | 状态 | owner | 分支 | PR | 备注 |）
    $lines = Get-Content -LiteralPath $Index -Encoding UTF8
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\| $id ") {
            $cols = $lines[$i] -split "\|"
            if ($status) { $cols[3] = " $status " }
            if ($owner) { $cols[4] = " $owner " }
            $lines[$i] = "|" + ($cols[1..7] -join "|") + "|"
        }
    }
    Write-File $Index $lines
}

function Get-TaskFile($id) {
    $idNz = [int]$id
    $f = Get-ChildItem -Path $TasksDir -Filter "*.md" -File | Where-Object { $_.Name -match "^0*$idNz-.*\.md$" } | Select-Object -First 1
    if (-not $f) { Die "任务 #$id 不存在（$TasksDir 下无对应文件）" }
    return $f.FullName
}

function Get-NextId {
    $max = 0
    Select-String -Path $Index -Pattern '^\| (\d+) ' | ForEach-Object {
        $n = [int]$_.Matches[0].Groups[1].Value
        if ($n -gt $max) { $max = $n }
    }
    return $max + 1
}

function Cmd-Init {
    if (-not (Test-Path -LiteralPath $WT)) {
        # PS 5.1 下对原生命令重定向 stderr（2>$null）会把 stderr 行升级为 ErrorRecord
        # 并在 ErrorActionPreference=Stop 时中断；这里不 redirect，按退出码判断
        & git -C $RepoRoot fetch origin $Branch | Out-Null
        if ($LASTEXITCODE -ne 0) { Die "远程不存在分支 $Branch；请维护者先创建（见 TASK-CENTER.md §2.1）" }
        & git -C $RepoRoot worktree add $WT $Branch | Out-Null
    }
    Pull-Rebase
    New-Item -ItemType Directory -Force -Path (Join-Path $TasksDir "archive") | Out-Null
    Write-Host "任务中心就绪：$WT（分支 $Branch）"
}

function Cmd-List {
    Require-Worktree; Require-Index
    $inTable = $false
    Get-Content -LiteralPath $Index -Encoding UTF8 | ForEach-Object {
        if ($_ -match "^## 活跃任务") { $inTable = $true; return }
        if ($_ -match "^## " -and $inTable) { $inTable = $false; return }
        if ($inTable) { Write-Host $_ }
    }
}

function Cmd-New($title, $slug) {
    Require-Identity; Require-Worktree; Require-Index
    if (-not $title) { Die "缺少标题：task.ps1 new `"<标题>`" [slug]" }
    Pull-Rebase
    $id = Get-NextId
    $pad = "{0:d4}" -f $id
    if (-not $slug) { $slug = "task" }
    $file = Join-Path $TasksDir "$pad-$slug.md"
    if (Test-Path -LiteralPath $file) { Die "$file 已存在" }
    $today = Get-Date -Format "yyyy-MM-dd"
    Write-File $file @(
        "# 任务 #$id $title",
        "",
        "状态：待办",
        "owner：未认领",
        "角色：",
        "优先级：中",
        "依赖：无",
        "分支：",
        "PR：",
        "创建：$today $Identity",
        "",
        "## 验收标准",
        "",
        "- [ ] <待填写>",
        "",
        "## 进度",
        "",
        "- $today ${Identity}：任务登记；下一步：待认领"
    )

    # INDEX 登记：插在最后一个以 | 开头的行之后（活跃表末尾）
    $lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $Index -Encoding UTF8)
    $last = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^\|") { $last = $i } }
    if ($last -ge 0) { $lines.Insert($last + 1, "| $id | $title | 待办 | 未认领 |  |  |  |") }
    Write-File $Index $lines

    Commit-All "docs(tasks): 新建任务 #$id $title"
    Push
    Write-Host "已登记任务 #$id：$file"
}

function Cmd-Claim($id) {
    Require-Identity; Require-Worktree; Require-Index
    if (-not $id) { Usage }
    Pull-Rebase
    $f = Get-TaskFile $id
    Set-Line "owner：" "owner：$Identity" $f
    Set-Line "状态：" "状态：已认领" $f
    Add-Content -LiteralPath $f -Encoding UTF8 -Value ("- " + (Get-Date -Format "yyyy-MM-dd") + " ${Identity}：认领任务")
    Update-IndexRow $id "已认领" $Identity
    Commit-All "docs(tasks): #$id 认领（$Identity）"
    Push
}

function Cmd-Progress($id, $content, $status) {
    Require-Identity; Require-Worktree; Require-Index
    if (-not $id -or -not $content) { Die "缺少参数：task.ps1 progress <编号> `"<内容>`" [--status <状态>]" }
    Pull-Rebase
    $f = Get-TaskFile $id
    Add-Content -LiteralPath $f -Encoding UTF8 -Value ("- " + (Get-Date -Format "yyyy-MM-dd") + " ${Identity}：$content")
    if ($status) {
        Set-Line "状态：" "状态：$status" $f
        Update-IndexRow $id $status ""
    }
    Commit-All "docs(tasks): #$id 进度"
    Push
}

function Cmd-Status($id, $status) {
    Require-Identity; Require-Worktree; Require-Index
    if (-not $id -or -not $status) { Die "缺少参数：task.ps1 status <编号> <状态>" }
    Pull-Rebase
    $f = Get-TaskFile $id
    Set-Line "状态：" "状态：$status" $f
    Update-IndexRow $id $status ""
    Commit-All "docs(tasks): #$id 状态改为 $status"
    Push
}

function Cmd-Done($id) {
    Require-Identity; Require-Worktree; Require-Index
    if (-not $id) { Usage }
    Pull-Rebase
    $f = Get-TaskFile $id
    Set-Line "状态：" "状态：已完成" $f
    $base = Split-Path $f -Leaf
    & git -C $WT mv "docs/tasks/$base" "docs/tasks/archive/$base" | Out-Null
    $idNz = [int]$id
    Write-File $Index @(Get-Content -LiteralPath $Index -Encoding UTF8 | Where-Object { $_ -notmatch "^\| $idNz " })
    Commit-All "docs(tasks): #$id 完成归档"
    Push
}

switch ($Cmd) {
    "init"     { Cmd-Init }
    "list"     { Cmd-List }
    "new"      { Cmd-New $Rest[0] $Rest[1] }
    "claim"    { Cmd-Claim $Rest[0] }
    "progress" {
        $status = $null
        if ($Rest.Count -ge 4 -and $Rest[2] -eq "--status") { $status = $Rest[3] }
        Cmd-Progress $Rest[0] $Rest[1] $status
    }
    "status"   { Cmd-Status $Rest[0] $Rest[1] }
    "done"     { Cmd-Done $Rest[0] }
    default    { Usage }
}
