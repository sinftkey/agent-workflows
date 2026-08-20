# 本脚本不带 param() 块：irm | iex 管道执行时 iex 不允许 param，
# 传参改用环境变量（ADAPT_REPO / ADAPT_SOURCE / ADAPT_TARGET）或 $args 命名参数。
# 优先级：环境变量 > 命令行参数 > 默认值。

$Repo = "https://github.com/sinftkey/agent-workflows.git"
$Source = ""
$Target = "."

$i = 0
while ($i -lt $args.Count) {
    $a = $args[$i]
    if ($a -eq "-Repo" -and $i + 1 -lt $args.Count) { $Repo = $args[++$i] }
    elseif ($a -eq "-Source" -and $i + 1 -lt $args.Count) { $Source = $args[++$i] }
    elseif ($a -eq "-Target" -and $i + 1 -lt $args.Count) { $Target = $args[++$i] }
    elseif ($a -notlike "-*" -and -not $Source) { $Source = $a }
    $i++
}
if ($env:ADAPT_REPO) { $Repo = $env:ADAPT_REPO }
if ($env:ADAPT_SOURCE) { $Source = $env:ADAPT_SOURCE }
if ($env:ADAPT_TARGET) { $Target = $env:ADAPT_TARGET }

$ErrorActionPreference = "Stop"

$tmp = ""
if (-not $Source) {
    $tmp = Join-Path $env:TEMP ("agent-workflows-" + [guid]::NewGuid().ToString("N"))
    Write-Host "克隆模板仓库到 $tmp ..."
    git clone --depth 1 $Repo $tmp
    if (-not $?) { throw "git clone 失败" }
    $Source = $tmp
}

if (-not (Test-Path -LiteralPath (Join-Path $Source "templates"))) {
    throw "模板目录不存在：$Source/templates"
}

$docsDir = Join-Path $Target "docs/development"
New-Item -ItemType Directory -Force -Path $docsDir | Out-Null
Copy-Item -Path (Join-Path $Source "templates\*") -Destination $docsDir -Recurse -Force
Remove-Item -LiteralPath (Join-Path $docsDir "AGENTS.template.md") -Force -ErrorAction SilentlyContinue

$agentsDest = Join-Path $Target "AGENTS.md"
if (Test-Path -LiteralPath $agentsDest) {
    Write-Warning "AGENTS.md 已存在，跳过覆盖；请手动比对合并（保留更具体、更严格的一条）。"
} else {
    Copy-Item -Path (Join-Path $Source "templates\AGENTS.template.md") -Destination $agentsDest
}

if ($tmp) {
    Remove-Item -Recurse -Force $tmp
}

Write-Host ""
Write-Host "=== 落位完成 ==="
Write-Host "templates/*（除 AGENTS.template.md）  ->  $docsDir"
Write-Host "AGENTS.template.md  ->  $agentsDest（仅此一份）"
Write-Host ""
Write-Host "=== 残留 {{...}} 适配占位符清单（请逐一替换；<...> 为语法占位符，不在清单内）==="
$files = @(Get-ChildItem -Path $docsDir -Filter *.md) + @(Get-Item -LiteralPath $agentsDest)
$placeholderLines = foreach ($f in $files) {
    if (Test-Path -LiteralPath $f.FullName) {
        Select-String -Path $f.FullName -Pattern '\{\{[^{}]+\}\}' | ForEach-Object {
            "{0}:{1}: {2}" -f $f.Name, $_.LineNumber, $_.Line.Trim()
        }
    }
}
if ($placeholderLines) {
    $placeholderLines | Sort-Object -Unique | ForEach-Object { Write-Host $_ }
} else {
    Write-Host "（无残留适配占位符）"
}

Write-Host ""
Write-Host "机械步骤已完成。请继续按 AGENT-ADAPT-GUIDE.md 第 3~5 节执行："
Write-Host "  3. 适配：替换 {{...}} 占位符、换实际命令、修正链接、删除不适用章节"
Write-Host "  4. 校验：{{...}} 无残留、链接有效、无密钥"
Write-Host "  5. 提交：分支前缀 {{身份}}/，Conventional Commits"