# No param() block: Invoke-Expression (irm | iex) does not allow param.
# Pass values via environment variables (ADAPT_REPO / ADAPT_SOURCE / ADAPT_TARGET)
# or via $args named params. Priority: env > args > defaults.
#
# Output language note: this script (PowerShell) prints English, adapt.sh prints
# Chinese. Reason: under irm | iex, UTF-8 Chinese output is unreliable on some
# Windows terminals, so English is used here. Keep the two scripts' text in sync.

$Repo = "https://github.com/sinftkey/agent-workflows.git"
$DefaultBranch = "main"
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

# Derive raw file base URL so skipped files still have a comparison source
$rawBase = ""
$m = [regex]::Match($Repo, '^https://github\.com/([^/]+)/([^/]+?)(\.git)?/?$')
if ($m.Success) { $rawBase = "https://raw.githubusercontent.com/$($m.Groups[1].Value)/$($m.Groups[2].Value)/$DefaultBranch" }
function CompareHint($relPath) {
    if ($rawBase) { Write-Warning "Template source for comparison: $rawBase/$relPath" }
    elseif ($Source) { Write-Warning "Template source for comparison: $(Join-Path $Source $relPath)" }
}

$tmp = ""
if (-not $Source) {
    $tmp = Join-Path $env:TEMP ("agent-workflows-" + [guid]::NewGuid().ToString("N"))
    Write-Host "Cloning template repo to $tmp ..."
    git clone --depth 1 -b $DefaultBranch $Repo $tmp
    if (-not $?) { throw "git clone failed" }
    $Source = $tmp
}

if (-not (Test-Path -LiteralPath (Join-Path $Source "templates"))) {
    throw "templates directory not found: $Source/templates"
}

$docsDir = Join-Path $Target "docs/development"
New-Item -ItemType Directory -Force -Path $docsDir | Out-Null
$templateDir = Join-Path $Source "templates"
foreach ($item in Get-ChildItem -LiteralPath $templateDir -Force) {
    if ($item.Name -eq "task-center") { continue }
    Copy-Item -LiteralPath $item.FullName -Destination $docsDir -Recurse -Force
}
Remove-Item -LiteralPath (Join-Path $docsDir "AGENTS.md") -Force -ErrorAction SilentlyContinue

$existingTaskCenter = Join-Path $docsDir "task-center"
if (Test-Path -LiteralPath $existingTaskCenter) {
    Write-Warning "An existing $existingTaskCenter was left untouched. Check that it is not a legacy task-center copy; current task-center installations belong in the local task-center worktree created by the standalone setup tool."
}
$legacyTasksProtocol = Join-Path (Join-Path $Target "docs") "tasks/TASK-CENTER.md"
if (Test-Path -LiteralPath $legacyTasksProtocol -PathType Leaf) {
    Write-Warning "A legacy task-center protocol was found at $legacyTasksProtocol and was left untouched. Have a maintainer review it and follow the task-center migration process; do not treat that copy as the current task center."
}

$agentsDest = Join-Path $Target "AGENTS.md"
if (Test-Path -LiteralPath $agentsDest) {
    Write-Warning "AGENTS.md already exists; skipped overwrite. Merge manually (keep the more specific/stricter one)."
    CompareHint "templates/AGENTS.md"
} else {
    Copy-Item -Path (Join-Path $Source "templates/AGENTS.md") -Destination $agentsDest
}

foreach ($dotFile in @(".gitattributes", ".gitignore")) {
    $dotSrc = Join-Path $Source $dotFile
    $dotDest = Join-Path $Target $dotFile
    if (-not (Test-Path -LiteralPath $dotSrc)) { continue }
    if (Test-Path -LiteralPath $dotDest) {
        Write-Warning "$dotFile already exists in target; skipped. Merge manually if needed."
        CompareHint $dotFile
    } else {
        Copy-Item -LiteralPath $dotSrc -Destination $dotDest
    }
}

if ($tmp) {
    Remove-Item -Recurse -Force $tmp
}

Write-Host ""
Write-Host "=== Placement done ==="
Write-Host "Generic templates/ content (excluding AGENTS.md and optional task-center/)  ->  $docsDir"
Write-Host "templates/task-center/ was not copied; use the standalone setup tool to enable it"
Write-Host "templates/AGENTS.md  ->  $agentsDest (single copy)"
Write-Host ".gitattributes / .gitignore  ->  $Target (skip if already exists)"
Write-Host ""
Write-Host "=== Remaining {{...}} placeholders to replace (<...> are syntax placeholders, not listed) ==="
$files = @(Get-ChildItem -Path $docsDir -Filter *.md) + @(Get-Item -LiteralPath $agentsDest)
$placeholderLines = foreach ($f in $files) {
    if (Test-Path -LiteralPath $f.FullName) {
        Select-String -Path $f.FullName -Pattern '\{\{[^{}]+\}\}' -Encoding UTF8 | ForEach-Object {
            "{0}:{1}: {2}" -f $f.Name, $_.LineNumber, $_.Line.Trim()
        }
    }
}
if ($placeholderLines) {
    $placeholderLines | Sort-Object -Unique | ForEach-Object { Write-Host $_ }
} else {
    Write-Host "(no remaining placeholders)"
}

Write-Host ""
Write-Host "Mechanical steps done. Continue with AGENT-ADAPT-GUIDE.md sections 3-5:"
Write-Host "  3. Adapt: replace {{...}} placeholders, swap real commands, fix links, drop inapplicable sections, extract PR template"
Write-Host "  4. Verify: no {{...}} left, links valid, no secrets"
Write-Host "  5. Commit: branch prefix {{identity}}/, Conventional Commits"
