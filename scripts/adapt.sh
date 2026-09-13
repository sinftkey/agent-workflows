#!/usr/bin/env bash
set -euo pipefail

# 输出语言说明：本脚本（bash）输出中文，adapt.ps1 输出英文。
# 原因：irm | iex 管道执行时 PowerShell 的 UTF-8 中文输出在部分 Windows
# 终端编码不稳，英文更稳健；两个脚本文案一一对应，修改时请同步。
#
# 参数接口（与 adapt.ps1 一致）：
#   环境变量：ADAPT_REPO / ADAPT_SOURCE / ADAPT_TARGET
#   命令行：  -Repo <url> / -Source <dir> / -Target <dir>
#   优先级：环境变量 > 命令行参数 > 默认值

REPO="https://github.com/sinftkey/agent-workflows.git"
SOURCE=""
TARGET="."

while [ $# -gt 0 ]; do
  case "$1" in
    -Repo)   shift; REPO="${1:?-Repo 需要一个参数}" ;;
    -Source) shift; SOURCE="${1:?-Source 需要一个参数}" ;;
    -Target) shift; TARGET="${1:?-Target 需要一个参数}" ;;
    *)       if [ -z "$SOURCE" ]; then SOURCE="$1"; fi ;;
  esac
  shift
done

if [ -n "${ADAPT_REPO:-}" ]; then REPO="$ADAPT_REPO"; fi
if [ -n "${ADAPT_SOURCE:-}" ]; then SOURCE="$ADAPT_SOURCE"; fi
if [ -n "${ADAPT_TARGET:-}" ]; then TARGET="$ADAPT_TARGET"; fi

# 由仓库地址推导 raw 文件地址，用于「已存在跳过」时给用户留比对来源
RAW_BASE=""
case "$REPO" in
  https://github.com/*/*)
    RAW_BASE="${REPO#https://github.com/}"
    RAW_BASE="https://raw.githubusercontent.com/${RAW_BASE%.git}/main" ;;
esac

compare_hint() {
  if [ -n "$RAW_BASE" ]; then
    echo "  模板原文（用于手动比对）：$RAW_BASE/$1"
  else
    echo "  模板原文（用于手动比对）：$SOURCE/$1"
  fi
}

TMP=""
if [ -z "$SOURCE" ]; then
  TMP="$(mktemp -d)/agent-workflows"
  echo "克隆模板仓库到 $TMP ..."
  git clone --depth 1 -b main "$REPO" "$TMP"
  SOURCE="$TMP"
fi

if [ ! -d "$SOURCE/templates" ]; then
  echo "错误：模板目录不存在：$SOURCE/templates" >&2
  exit 1
fi

DOCS_DIR="$TARGET/docs/development"
mkdir -p "$DOCS_DIR"
cp -r "$SOURCE/templates/." "$DOCS_DIR/"
rm -f "$DOCS_DIR/AGENTS.md"

AGENTS_DEST="$TARGET/AGENTS.md"
if [ -f "$AGENTS_DEST" ]; then
  {
    echo "警告：AGENTS.md 已存在，跳过覆盖；请手动比对合并（保留更具体、更严格的一条）。"
    compare_hint "templates/AGENTS.md"
  } >&2
else
  cp "$SOURCE/templates/AGENTS.md" "$AGENTS_DEST"
fi

for f in .gitattributes .gitignore; do
  if [ -f "$SOURCE/$f" ]; then
    if [ -f "$TARGET/$f" ]; then
      {
        echo "警告：$f 已存在，跳过覆盖；如有需要请手动合并。"
        compare_hint "$f"
      } >&2
    else
      cp "$SOURCE/$f" "$TARGET/$f"
    fi
  fi
done

if [ -n "$TMP" ]; then
  rm -rf "$(dirname "$TMP")"
fi

echo ""
echo "=== 落位完成 ==="
echo "templates/*（除 templates/AGENTS.md）  ->  $DOCS_DIR"
echo "templates/AGENTS.md  ->  $AGENTS_DEST（仅此一份）"
echo ".gitattributes / .gitignore  ->  $TARGET（已存在则跳过）"
echo ""
echo "=== 残留 {{...}} 适配占位符清单（请逐一替换；<...> 为语法占位符，不在清单内）==="
grep -rno '{{[^{}]\+}}' "$DOCS_DIR" "$AGENTS_DEST" 2>/dev/null | sort -u || echo "（无残留适配占位符）"

echo ""
echo "机械步骤已完成。请继续按 AGENT-ADAPT-GUIDE.md 第 3~5 节执行："
echo "  3. 适配：替换 {{...}} 占位符、换实际命令、修正链接、删除不适用章节、抽取 PR 模板"
echo "  4. 校验：{{...}} 无残留、链接有效、无密钥"
echo "  5. 提交：分支前缀 {{身份}}/，Conventional Commits"
