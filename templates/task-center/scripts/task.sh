#!/usr/bin/env bash
# 任务中心操作脚本（bash 版；task.ps1 为 PowerShell 版，接口一致）。
# 用法见 TASK-CENTER.md。机械操作只做取号 / 追加 / 提交 / push，
# 状态合法性与角色权限由协议约束 + review 把关。
set -euo pipefail

BRANCH="${TASK_BRANCH:-task-center}"
WORKTREE_NAME="${TASK_WORKTREE_NAME:-task-center}"

usage() {
  cat >&2 <<'EOF'
用法：task.sh <命令> [参数]   （需先设置 TASK_IDENTITY 环境变量）

  init                          初始化 / 更新 worktree
  list                          查看活跃任务（INDEX）
  new "<标题>" [slug]           登记新任务（取号 + 建任务文件 + INDEX 登记）
  claim <编号>                  认领（填 owner、状态「已认领」，同步 INDEX 行）
  progress <编号> "<内容>" [--status <状态>]   追加进度，可同时改状态（同步 INDEX 行）
  status <编号> <状态>          仅改状态行（同步 INDEX 行）
  done <编号>                   完成归档：状态「已完成」+ 移 archive/ + INDEX 删行（维护者）

环境变量：TASK_IDENTITY（必填）、TASK_BRANCH（默认 task-center）、TASK_WORKTREE_NAME（默认 task-center）
EOF
  exit 2
}

die() { echo "错误：$1" >&2; exit 1; }

[ $# -ge 1 ] || usage
CMD="$1"; shift

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "请在 git 仓库内运行本脚本"
WT="$REPO_ROOT/.worktrees/$WORKTREE_NAME"
TASKS_DIR="$WT/docs/tasks"
INDEX="$TASKS_DIR/INDEX.md"
IDENTITY="${TASK_IDENTITY:-}"

identity() { [ -n "$IDENTITY" ] || die "请先设置 TASK_IDENTITY（Agent 工具名或人员名，与任务中心约定一致）"; }
require_worktree() { [ -d "$WT" ] || die "任务中心 worktree 不存在，先运行：task.sh init"; }
require_index() { [ -f "$INDEX" ] || die "$INDEX 不存在，请先按 TASK-CENTER.md 初始化任务中心"; }
pull_rebase() { git -C "$WT" pull --rebase origin "$BRANCH"; }
push() { git -C "$WT" push origin "$BRANCH"; }

commit_all() { # $1 = message
  git -C "$WT" add -A
  git -C "$WT" diff --cached --quiet && return 0
  git -C "$WT" commit -m "$1"
}

sed_replace() { # $1 = 匹配前缀（行首正则） $2 = 整行替换 $3 = 文件
  local tmp; tmp="$(mktemp)"
  sed "s|^$1.*|$2|" "$3" > "$tmp" && mv "$tmp" "$3"
}

task_file() { # $1 = 编号 -> 输出任务文件路径
  local id_nz f
  id_nz=$((10#$1))
  f="$(ls "$TASKS_DIR" | grep -E "^0*${id_nz}-.*\.md$" | head -1)"
  [ -n "$f" ] || die "任务 #$1 不存在（$TASKS_DIR 下无对应文件）"
  echo "$TASKS_DIR/$f"
}

next_id() {
  local max
  max="$(grep -oE '^\| [0-9]+ ' "$INDEX" | grep -oE '[0-9]+' | sort -n | tail -1)"
  echo $(( ${max:-0} + 1 ))
}

index_update() { # $1 = 编号 $2 = 状态（可空） $3 = owner（可空）；更新 INDEX 活跃表中该任务的行
  local tmp; tmp="$(mktemp)"
  awk -v id="$1" -v st="$2" -v ow="$3" -F'|' '
    $0 ~ "^\\| " id " " {
      if (st != "") $4 = " " st " "
      if (ow != "") $5 = " " ow " "
      out = ""
      for (i = 2; i < NF; i++) out = out "|" $i
      print out "|"
      next
    }
    { print }
  ' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"
}

cmd_init() {
  if [ ! -d "$WT" ]; then
    git -C "$REPO_ROOT" fetch origin "$BRANCH" 2>/dev/null \
      || die "远程不存在分支 $BRANCH；请维护者先创建（见 TASK-CENTER.md §2.1）"
    git -C "$REPO_ROOT" worktree add "$WT" "$BRANCH"
  fi
  pull_rebase
  mkdir -p "$TASKS_DIR/archive"
  echo "任务中心就绪：$WT（分支 $BRANCH）"
}

cmd_list() {
  require_worktree; require_index
  sed -n '/^## 活跃任务/,/^## /{ /^## /!p; }' "$INDEX"
}

cmd_new() { # $1 = 标题 $2 = slug（可选）
  identity; require_worktree; require_index
  [ $# -ge 1 ] || die "缺少标题：task.sh new \"<标题>\" [slug]"
  pull_rebase
  local id pad slug file
  id="$(next_id)"; pad="$(printf "%04d" "$id")"; slug="${2:-task}"
  file="$TASKS_DIR/$pad-$slug.md"
  [ ! -f "$file" ] || die "$file 已存在"
  cat > "$file" <<EOF
# 任务 #$id $1

状态：待办
owner：未认领
角色：
优先级：中
依赖：无
分支：
PR：
创建：$(date +%F) $IDENTITY

## 验收标准

- [ ] <待填写>

## 进度

- $(date +%F) $IDENTITY：任务登记；下一步：待认领
EOF
  # INDEX 登记：插在最后一个以 | 开头的行之后（活跃表末尾）
  local tmp; tmp="$(mktemp)"
  awk -v row="| $id | $1 | 待办 | 未认领 |  |  |  |" '
    { lines[NR] = $0 }
    END {
      last = 0
      for (i = 1; i <= NR; i++) if (lines[i] ~ /^\|/) last = i
      for (i = 1; i <= NR; i++) { print lines[i]; if (i == last) print row }
    }' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"
  commit_all "docs(tasks): 新建任务 #$id $1"
  push
  echo "已登记任务 #$id：$file"
}

cmd_claim() { # $1 = 编号
  identity; require_worktree; require_index
  [ $# -ge 1 ] || usage
  pull_rebase
  local f; f="$(task_file "$1")"
  sed_replace "owner：" "owner：$IDENTITY" "$f"
  sed_replace "状态：" "状态：已认领" "$f"
  echo "- $(date +%F) $IDENTITY：认领任务" >> "$f"
  index_update "$1" "已认领" "$IDENTITY"
  commit_all "docs(tasks): #$1 认领（$IDENTITY）"
  push
}

cmd_progress() { # $1 = 编号 $2 = 内容 [--status <状态>]
  identity; require_worktree; require_index
  [ $# -ge 2 ] || die "缺少参数：task.sh progress <编号> \"<内容>\" [--status <状态>]"
  pull_rebase
  local f status=""; f="$(task_file "$1")"
  if [ $# -ge 4 ] && [ "$3" = "--status" ]; then status="$4"; fi
  echo "- $(date +%F) $IDENTITY：$2" >> "$f"
  if [ -n "$status" ]; then
    sed_replace "状态：" "状态：$status" "$f"
    index_update "$1" "$status" ""
  fi
  commit_all "docs(tasks): #$1 进度"
  push
}

cmd_status() { # $1 = 编号 $2 = 状态
  identity; require_worktree; require_index
  [ $# -ge 2 ] || die "缺少参数：task.sh status <编号> <状态>"
  pull_rebase
  local f; f="$(task_file "$1")"
  sed_replace "状态：" "状态：$2" "$f"
  index_update "$1" "$2" ""
  commit_all "docs(tasks): #$1 状态改为 $2"
  push
}

cmd_done() { # $1 = 编号（维护者）
  identity; require_worktree; require_index
  [ $# -ge 1 ] || usage
  pull_rebase
  local f base id_nz tmp; f="$(task_file "$1")"; base="$(basename "$f")"; id_nz=$((10#$1))
  sed_replace "状态：" "状态：已完成" "$f"
  git -C "$WT" mv "docs/tasks/$base" "docs/tasks/archive/$base"
  tmp="$(mktemp)"
  grep -v "^| $id_nz " "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"
  commit_all "docs(tasks): #$1 完成归档"
  push
}

case "$CMD" in
  init)     cmd_init "$@" ;;
  list)     cmd_list "$@" ;;
  new)      cmd_new "$@" ;;
  claim)    cmd_claim "$@" ;;
  progress) cmd_progress "$@" ;;
  status)   cmd_status "$@" ;;
  done)     cmd_done "$@" ;;
  *)        usage ;;
esac
