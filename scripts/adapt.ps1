# No param() block: Invoke-Expression (irm | iex) does not allow param.
# Pass values via environment variables (ADAPT_REPO / ADAPT_SOURCE / ADAPT_TARGET)
# or via $args named params. Priority: env > args > defaults.

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
    Write-Host "Cloning template repo to $tmp ..."
    git clone --depth 1 $Repo $tmp
    if (-not $?) { throw "git clone failed" }
    $Source = $tmp
}

if (-not (Test-Path -LiteralPath (Join-Path $Source "templates"))) {
    throw "templates directory not found: $Source/templates"
}

$docsDir = Join-Path $Target "docs/development"
New-Item -ItemType Directory -Force -Path $docsDir | Out-Null
Copy-Item -Path (Join-Path $Source "templates\*") -Destination $docsDir -Recurse -Force
Remove-Item -LiteralPath (Join-Path $docsDir "AGENTS.template.md") -Force -ErrorAction SilentlyContinue

$agentsDest = Join-Path $Target "AGENTS.md"
if (Test-Path -LiteralPath $agentsDest) {
    Write-Warning "AGENTS.md already exists; skipped overwrite. Merge manually (keep the more specific/stricter one)."
} else {
    Copy-Item -Path (Join-Path $Source "templates\AGENTS.template.md") -Destination $agentsDest
}

if ($tmp) {
    Remove-Item -Recurse -Force $tmp
}

Write-Host ""
Write-Host "=== Placement done ==="
Write-Host "templates/* (except AGENTS.template.md)  ->  $docsDir"
Write-Host "AGENTS.template.md  ->  $agentsDest (single copy)"
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
Write-Host "  3. Adapt: replace {{...}} placeholders, swap real commands, fix links, drop inapplicable sections"
Write-Host "  4. Verify: no {{...}} left, links valid, no secrets"
Write-Host "  5. Commit: branch prefix {{identity}}/, Conventional Commits"