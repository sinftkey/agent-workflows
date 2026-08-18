#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-https://github.com/<owner>/agent-workflows.git}"
SOURCE="${1:-}"
TARGET="${TARGET:-.}"

TMP=""
if [ -z "$SOURCE" ]; then
  TMP="$(mktemp -d)/agent-workflows"
  echo "克隆模板仓库到 $TMP ..."
  git clone --depth 1 "$REPO" "$TMP"
  SOURCE="$TMP"
fi

if [ ! -d "$SOURCE/templates" ]; then
  echo "错误：模板目录不存在：$SOURCE/templates" >&2
  exit 1
fi

DOCS_DIR="$TARGET/docs/development"
mkdir -p "$DOCS_DIR"
cp -r "$SOURCE/templates/." "$DOCS_DIR/"

AGENTS_DEST="$TARGET/AGENTS.md"
if [ -f "$AGENTS_DEST" ]; then
  echo "警告：AGENTS.md 已存在，跳过覆盖；请手动比对合并（保留更具体、更严格的一条）。" >&2
else
  cp "$SOURCE/templates/AGENTS.template.md" "$AGENTS_DEST"
fi

if [ -n "$TMP" ]; then
  rm -rf "$(dirname "$TMP")"
fi

echo ""
echo "=== 落位完成 ==="
echo "templates/*  ->  $DOCS_DIR"
echo "AGENTS.template.md  ->  $AGENTS_DEST"
echo ""
echo "=== 残留占位符清单（请逐一替换）==="
grep -rno '<[^<>]\+>' "$DOCS_DIR" "$AGENTS_DEST" 2>/dev/null | sort -u || echo "（无残留占位符）"

echo ""
echo "机械步骤已完成。请继续按 AGENT-ADAPT-GUIDE.md 第 3~5 节执行："
echo "  3. 适配：替换占位符、换实际命令、修正链接、删除不适用章节"
echo "  4. 校验：占位符无残留、链接有效、无密钥"
echo "  5. 提交：分支前缀 <角色>/，Conventional Commits"