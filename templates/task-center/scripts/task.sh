#!/usr/bin/env bash
# Task center client. All writes are local, locked, journaled, and committed by path.
set -euo pipefail

BRANCH="${TASK_BRANCH:-task-center}"
IDENTITY="${TASK_IDENTITY:-}"
TOOL_VERSION=1
SCHEMA_VERSION=2
LOCK_TIMEOUT="${TASK_LOCK_TIMEOUT:-10}"

usage() {
  cat >&2 <<'EOF'
用法：task.sh <命令> [参数]
  init | list [--all] | check
  new <标题> [--slug <短名>] [--priority 高|中|低] [--depends <编号列表>] [--acceptance <文本>] [--external <完整链接>]
  claim <编号> | progress <编号> <内容> [--evidence <证据>]
  status <编号> <状态> [--assignee <身份>] [--reason <原因>] [--evidence <证据>]
  assign <编号> <新owner> --reason <原因> | handoff <编号> <新负责人> --reason <原因>
  block <编号> --reason <原因> --waiting-for <对象> | unblock <编号> [--evidence <证据>]
  done <编号> --evidence <证据> | cancel <编号> --reason <原因>
  edit <编号> --export <路径> | --import <路径> --base <提交>
  index --rebuild | recover [--show|--abort|--commit]

写命令需 TASK_IDENTITY；任务中心位置依 TASK_CENTER_PATH、安装登记和 TASK_BRANCH worktree 定位。
角色授权环境变量：TASK_MAINTAINERS、TASK_REVIEWERS、TASK_TESTERS、TASK_MERGE_AUTHORIZED。
EOF
  exit 2
}
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
check_error() { printf '错误：%s\n' "$*" >&2; CHECK_ERRORS=$((CHECK_ERRORS + 1)); }
git_run() {
  local out
  if ! out="$(git -C "$1" "${@:2}" 2>&1)"; then die "Git 命令失败（$*）：$out"; fi
  printf '%s' "$out"
}
git_code() { # git_code <allowed-exit-code> <path> <args...>
  local allowed="$1"; shift
  local out code
  set +e
  out="$(git -C "$1" "${@:2}" 2>&1)"; code=$?
  set -e
  if [ "$code" -ne 0 ] && [ "$code" -ne "$allowed" ]; then die "Git 命令失败（$*）：$out"; fi
  printf '%s' "$code"
}

[ $# -gt 0 ] || usage
CMD="$1"; shift
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die '请在 Git 仓库内运行'
ROOT="$(cd "$ROOT" && pwd -P)"
COMMON_RAW="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)" || die '无法取得共同 Git 目录'
case "$COMMON_RAW" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) COMMON="$COMMON_RAW" ;; *) COMMON="$ROOT/$COMMON_RAW" ;; esac
COMMON="$(cd "$COMMON" 2>/dev/null && pwd -P)" || die '共同 Git 目录不可访问'
RUNTIME="$COMMON/task-center-runtime"
LOCK="$COMMON/task-center-write.lock"

locate_center() {
  local candidate reg path branch found='' worktrees
  if [ -n "${TASK_CENTER_PATH:-}" ]; then
    candidate="$TASK_CENTER_PATH"
  elif [ -f "$COMMON/task-center/install-path" ]; then
    IFS= read -r candidate < "$COMMON/task-center/install-path"
    [ -n "$candidate" ] || die '任务中心安装登记为空'
  else
    worktrees="$(git_run "$ROOT" worktree list --porcelain)"
    while IFS= read -r reg; do
      case "$reg" in 'worktree '*) path="${reg#worktree }" ;; 'branch '*) branch="${reg#branch refs/heads/}"; if [ -n "${path:-}" ] && [ "$branch" = "$BRANCH" ]; then
          [ -z "$found" ] || die '发现多个目标任务中心 worktree，请设置 TASK_CENTER_PATH'
          found="$path"
        fi ;; '') path='' ;; esac
    done <<< "$worktrees"
    candidate="$found"
  fi
  [ -n "$candidate" ] || die "找不到本地分支 $BRANCH 的任务中心 worktree；先运行安装引导器"
  if command -v cygpath >/dev/null 2>&1 && [[ "$candidate" =~ ^[A-Za-z]:[\\/] ]]; then candidate="$(cygpath -u "$candidate")"; fi
  [ -d "$candidate" ] || die "登记的任务中心目录不存在：$candidate"
  WT="$(cd "$candidate" && pwd -P)" || die "无法访问任务中心目录：$candidate"
  local center_common center_branch
  center_common="$(git -C "$WT" rev-parse --git-common-dir 2>/dev/null)" || die '候选目录不是 Git worktree'
  case "$center_common" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;; *) center_common="$WT/$center_common" ;; esac
  center_common="$(cd "$center_common" 2>/dev/null && pwd -P)" || die '无法校验任务中心所属克隆'
  [ "$center_common" = "$COMMON" ] || die '任务中心候选目录属于另一份克隆'
  center_branch="$(git -C "$WT" symbolic-ref --short HEAD 2>/dev/null)" || die '任务中心必须检出本地分支，不能处于 detached HEAD'
  [ "$center_branch" = "$BRANCH" ] || die "任务中心分支不匹配：期望 $BRANCH，实际 $center_branch"
  TASK_ROOT="$WT"
  TASKS="$WT/docs/tasks"
  META="$WT/.task-center"
  INDEX="$TASKS/INDEX.md"
  VERSION="$META/version"
  NEXT_ID="$META/next-id"
}
locate_center

version_check() {
  [ -f "$VERSION" ] || die '缺少 .task-center/version；需先完成安装或迁移'
  local tv sv
  tv="$(sed -n 's/^tool-version:[[:space:]]*//p' "$VERSION" | head -1 | sed 's/\r$//')"
  sv="$(sed -n 's/^schema-version:[[:space:]]*//p' "$VERSION" | head -1 | sed 's/\r$//')"
  [ "$tv" = "$TOOL_VERSION" ] || die "不支持工具版本：$tv（本脚本 $TOOL_VERSION）"
  [ "$sv" = "$SCHEMA_VERSION" ] || die "不支持数据格式版本：$sv（本脚本 $SCHEMA_VERSION）；请运行迁移引导器"
  [ -f "$NEXT_ID" ] || die '缺少 .task-center/next-id'
}
if [ "$CMD" != recover ]; then version_check; fi

require_clean() {
  local state
  if ! state="$(git -C "$WT" status --porcelain --untracked-files=all)"; then die '无法读取任务中心工作区状态'; fi
  [ -z "$state" ] || die "任务中心工作区有暂存、未提交或未知文件；先检查并处理：\n$state"
}
require_identity() { [ -n "$IDENTITY" ] || die '请先设置 TASK_IDENTITY（须能区分并发会话）'; valid_text "$IDENTITY" || die 'TASK_IDENTITY 不得包含换行、制表符或 |'; }
valid_text() { [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* && "$1" != *'|'* ]]; }
trim_number() { local n="$1"; n="${n#TC-}"; n="${n#tc-}"; [[ "$n" =~ ^[0-9]+$ ]] || die "无效任务编号：$1"; echo "$((10#$n))"; }
fmt_id() { printf '%04d' "$1"; }
field() { # field <label> <file>
  awk -v key="$1：" '{sub(/\r$/,"",$0)} index($0,key)==1 { sub("^" key,"",$0); print; exit }' "$2"
}
task_header_id() { sed -n '1s/\r$//;1s/^# 任务 #\([0-9][0-9]*\) .*/\1/p' "$1"; }
task_title() { sed -n '1s/\r$//;1s/^# 任务 #[0-9][0-9]* //p' "$1"; }
task_file() {
  local id="$((10#$1))" header_id f match='' count=0 d
  for d in "$TASKS" "$TASKS/archive"; do
    for f in "$d"/0*-*.md "$d"/"$id"-*.md; do
      [ -f "$f" ] || continue
      header_id="$(task_header_id "$f")"
      [[ "$header_id" =~ ^[0-9]+$ ]] || continue
      if [ "$((10#$header_id))" -eq "$id" ]; then match="$f"; count=$((count + 1)); fi
    done
  done
  [ "$count" -eq 1 ] || { [ "$count" -eq 0 ] && die "任务 TC-$(fmt_id "$id") 不存在" || die "任务编号 $id 匹配多个文件"; }
  printf '%s' "$match"
}
role_has() {
  local role_list="$1" who="${2:-$IDENTITY}" item
  local -a roles
  IFS=, read -r -a roles <<< "$role_list"
  for item in "${roles[@]}"; do item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"; [ "$item" = "$who" ] && return 0; done
  return 1
}
require_role() { local variable="$1"; role_has "${!variable:-}" || die "身份 $IDENTITY 未获授权角色：$variable"; }
require_assignee_role() {
  local identity="$1" variable="$2" role_list
  role_list="${!variable:-}"
  role_has "$role_list" "$identity" || die "目标身份 $identity 未获授权角色：$variable"
}

LOCK_OWNED=0
release_lock() { if [ "$LOCK_OWNED" -eq 1 ]; then rm -f "$LOCK/owner"; rmdir "$LOCK" 2>/dev/null || true; LOCK_OWNED=0; fi; }
trap release_lock EXIT HUP INT TERM
acquire_lock() {
  local elapsed=0 owner
  mkdir -p "$RUNTIME"
  while ! mkdir "$LOCK" 2>/dev/null; do
    if [ "$elapsed" -ge "$LOCK_TIMEOUT" ]; then
      owner='(没有锁记录)'; [ ! -f "$LOCK/owner" ] || owner="$(cat "$LOCK/owner")"
      die "等待全局写锁超时；占用信息：$owner。确认持有进程已退出后再处理锁目录"
    fi
    sleep 1; elapsed=$((elapsed + 1))
  done
  LOCK_OWNED=1
  printf 'identity=%s\npid=%s\nstarted=%s\ncommand=%s\n' "$IDENTITY" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CMD" > "$LOCK/owner"
}

validate_task() {
  local f="$1" rel base id status owner assignee priority deps block_from reason waiting count
  base="$(basename "$f")"; id="$(task_header_id "$f")"
  [[ "$base" =~ ^0*([0-9]+)-[a-z0-9]+([a-z0-9-]*).md$ ]] || { check_error "$f：文件名必须是 <编号>-<ASCII slug>.md"; return; }
  [ -n "$id" ] || { check_error "$f：任务标题缺少编号"; return; }
  [ "$((10#$id))" -gt 0 ] || check_error "$f：任务编号必须为正整数"
  valid_text "$(task_title "$f")" || check_error "$f：标题不得包含换行、制表符或 |"
  [ "$((10#$id))" -eq "$((10#${BASH_REMATCH[1]}))" ] || check_error "$f：文件名和标题编号不一致"
  local labels=(状态 owner 当前负责人 优先级 依赖 分支 PR 外部 备注 阻塞前状态 阻塞原因 等待对象 创建)
  for rel in "${labels[@]}"; do
    count="$(awk -v p="$rel：" 'index($0,p)==1 && !body {n++} /^## / {body=1} END{print n+0}' "$f")"
    [ "$count" -eq 1 ] || check_error "$f：字段 $rel 必须在正文前恰好出现一次"
  done
  awk '
    /^## / {body=1; next}
    !body && /^[^#[:space:]][^：]*：/ { name=$0; sub(/：.*/,"：",name); if (name !~ /^(状态：|owner：|当前负责人：|优先级：|依赖：|分支：|PR：|外部：|备注：|阻塞前状态：|阻塞原因：|等待对象：|创建：)$/) {print "unknown"; exit} }
  ' "$f" | grep -q unknown && check_error "$f：存在未知字段"
  status="$(field 状态 "$f")"; owner="$(field owner "$f")"; assignee="$(field 当前负责人 "$f")"
  priority="$(field 优先级 "$f")"; deps="$(field 依赖 "$f")"; block_from="$(field 阻塞前状态 "$f")"
  reason="$(field 阻塞原因 "$f")"; waiting="$(field 等待对象 "$f")"
  case "$status" in 待办|已认领|进行中|待审核|待测试|待合并|阻塞|已完成|已取消) ;; *) check_error "$f：未知状态 $status" ;; esac
  case "$priority" in 高|中|低) ;; *) check_error "$f：优先级必须是高、中或低" ;; esac
  [ -n "$owner" ] && [ -n "$assignee" ] || check_error "$f：owner 和当前负责人不能为空"
  if [ "$status" = 待办 ]; then [ "$owner" = 未认领 ] || check_error "$f：待办任务的 owner 必须是未认领"; fi
  if [ "$status" != 待办 ] && [ "$status" != 已完成 ] && [ "$status" != 已取消 ]; then [ "$owner" != 未认领 ] || check_error "$f：已认领任务必须记录 owner"; fi
  for rel in "$status" "$owner" "$assignee" "$priority" "$deps" "$(field 分支 "$f")" "$(field PR "$f")" "$(field 外部 "$f")" "$(field 备注 "$f")" "$block_from" "$reason" "$waiting" "$(field 创建 "$f")"; do
    valid_text "$rel" || check_error "$f：字段值不得含换行、表格分隔符或制表符"
  done
  if [ "$(field 外部 "$f")" != 无 ] && [[ ! "$(field 外部 "$f")" =~ ^https?://[^[:space:]]+$ ]]; then check_error "$f：外部字段必须是完整 HTTP(S) 链接或无"; fi
  if [[ ! "$(field 创建 "$f")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]].+ ]]; then check_error "$f：创建字段格式应为日期与登记身份"; fi
  case "$f:$status" in */archive/*:已完成|*/archive/*:已取消) ;; */archive/*:*) check_error "$f：归档目录只能包含终态任务" ;; *:已完成|*:已取消) check_error "$f：终态任务必须位于归档目录" ;; esac
  if [ "$status" = 待办 ] || [ "$status" = 已完成 ] || [ "$status" = 已取消 ]; then
    [ "$assignee" = 未分配 ] || check_error "$f：$status 状态的当前负责人必须是未分配"
  elif [ "$status" = 阻塞 ]; then
    case "$block_from" in 已认领|进行中|待审核|待测试|待合并) ;; *) check_error "$f：阻塞前状态无效" ;; esac
    [ -n "$reason" ] && [ "$reason" != 无 ] && [ -n "$waiting" ] && [ "$waiting" != 无 ] || check_error "$f：阻塞原因和等待对象必填"
    [ "$assignee" != 未分配 ] || check_error "$f：阻塞任务必须保留当前负责人"
  else
    [ "$block_from" = 无 ] && [ "$reason" = 无 ] && [ "$waiting" = 无 ] || check_error "$f：非阻塞任务的阻塞字段必须是无"
    [ "$assignee" != 未分配 ] || check_error "$f：活跃任务必须有当前负责人"
  fi
  [ -f "$f" ] || check_error "$f：无法读取任务文件"
  if ! grep -q '^## 验收标准$' "$f" || ! grep -q '^## 进度$' "$f"; then check_error "$f：必须包含验收标准与进度分区"; fi
  grep -Eq '^-[[:space:]]+\[[ xX]\][[:space:]]+.+$' "$f" || check_error "$f：至少需要一条验收条件"
  case "$status" in 待审核|待测试|待合并|已完成) grep -Eq '证据：[^无（)]' "$f" || check_error "$f：$status 阶段缺少证据记录" ;; esac
  if [ "$status" = 已完成 ]; then grep -Eq '^-[[:space:]]+\[ \]' "$f" && check_error "$f：已完成任务仍有未勾选验收条件"; fi
}

collect_tasks() {
  local root="$1" d f
  TASK_FILES=()
  for d in "$root" "$root/archive"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.md; do [ -f "$f" ] || continue; [ "$(basename "$f")" = INDEX.md ] && continue; TASK_FILES+=("$f"); done
  done
}
generate_index() {
  local root="$1" out="$2" f id pad title status owner assignee note i j swap
  local -a active_files=() active_ids=()
  for f in "$root"/*.md; do
    [ -f "$f" ] || continue; [ "$(basename "$f")" = INDEX.md ] && continue
    id="$(task_header_id "$f")"; [[ "$id" =~ ^[0-9]+$ ]] || continue
    active_files+=("$f"); active_ids+=("$((10#$id))")
  done
  for ((i=0; i<${#active_files[@]}; i++)); do
    for ((j=i+1; j<${#active_files[@]}; j++)); do
      if (( active_ids[i] > active_ids[j] )); then
        swap="${active_files[i]}"; active_files[i]="${active_files[j]}"; active_files[j]="$swap"
        swap="${active_ids[i]}"; active_ids[i]="${active_ids[j]}"; active_ids[j]="$swap"
      fi
    done
  done
  {
    printf '# 任务索引\n\n> 本文件由任务文件生成并提交。禁止手工维护表格行；使用 `task index --rebuild` 重建。\n\n## 活跃任务\n\n| # | 标题 | 状态 | owner | 当前负责人 | 备注 |\n|---:|---|---|---|---|---|\n'
    for ((i=0; i<${#active_files[@]}; i++)); do
      f="${active_files[i]}"; id="${active_ids[i]}"
      pad="$(fmt_id "$id")"; title="$(task_title "$f")"; status="$(field 状态 "$f")"; owner="$(field owner "$f")"; assignee="$(field 当前负责人 "$f")"; note="$(field 备注 "$f")"
      printf '| TC-%s | %s | %s | %s | %s | %s |\n' "$pad" "$title" "$status" "$owner" "$assignee" "$note"
    done
    printf '\n## 已完成\n\n已归档任务保存在 `archive/`，编号永久保留。\n'
  } > "$out"
}
check_data() {
  local root="$1" f id ids max=0 next expected actual deps dep status rec id_status
  local -a files
  CHECK_ERRORS=0
  [ -f "$root/.task-center/version" ] || check_error '缺少版本文件'
  if [ -f "$root/.task-center/version" ]; then
    local tv sv sr
    tv="$(sed -n 's/^tool-version:[[:space:]]*//p' "$root/.task-center/version" | head -1 | sed 's/\r$//')"
    sv="$(sed -n 's/^schema-version:[[:space:]]*//p' "$root/.task-center/version" | head -1 | sed 's/\r$//')"
    sr="$(sed -n 's/^source-revision:[[:space:]]*//p' "$root/.task-center/version" | head -1 | sed 's/\r$//')"
    [ "$tv" = "$TOOL_VERSION" ] && [ "$sv" = "$SCHEMA_VERSION" ] && [ -n "$sr" ] || check_error 'version 标记与当前工具/数据格式不符'
  fi
  [ -f "$root/.task-center/next-id" ] || check_error '缺少编号种子文件'
  [ -d "$root/docs/tasks" ] || check_error '缺少 docs/tasks'
  [ -f "$root/docs/tasks/INDEX.md" ] || check_error '缺少 docs/tasks/INDEX.md'
  collect_tasks "$root/docs/tasks"
  ids=''
  for f in "${TASK_FILES[@]}"; do
    validate_task "$f"
    id="$(task_header_id "$f")"
    if [[ "$id" =~ ^[0-9]+$ ]]; then ids+="$((10#$id))\n"; [ "$((10#$id))" -gt "$max" ] && max="$((10#$id))"; fi
  done
  local dup
  dup="$(printf '%b' "$ids" | sed '/^$/d' | sort -n | uniq -d)"
  [ -z "$dup" ] || check_error "任务编号重复：$dup"
  if [ -f "$root/.task-center/next-id" ]; then
    next="$(tr -d '\r\n ' < "$root/.task-center/next-id")"
    [[ "$next" =~ ^[1-9][0-9]*$ ]] || check_error 'next-id 必须是正整数'
    if [[ "$next" =~ ^[0-9]+$ ]] && [ "$next" -le "$max" ]; then check_error "next-id ($next) 不大于已用编号 ($max)"; fi
  fi
  expected="$(mktemp)"; actual="$(mktemp)"
  generate_index "$root/docs/tasks" "$expected"
  [ ! -f "$root/docs/tasks/INDEX.md" ] || sed 's/\r$//' "$root/docs/tasks/INDEX.md" > "$actual"
  if ! cmp -s "$expected" "$actual"; then check_error 'INDEX 与活跃任务文件生成结果不一致'; fi
  rm -f "$expected" "$actual"
  # Validate dependency references and cycles from both active and archived tasks.
  local graph; graph="$(mktemp)"
  for f in "${TASK_FILES[@]}"; do
    id="$(task_header_id "$f")"; deps="$(field 依赖 "$f")"; status="$(field 状态 "$f")"
    printf '%s\t%s\t%s\n' "$((10#${id:-0}))" "$deps" "$status" >> "$graph"
  done
  local dependency_errors
  dependency_errors="$(awk -F '\t' '
    { exists[$1]=1; dep[$1]=$2; state[$1]=$3; n++ }
    END {
      for (id in dep) if (dep[id] != "无" && dep[id] != "") {
        count=split(dep[id], a, ","); for (i=1;i<=count;i++) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[i]); sub(/^TC-/, "", a[i]); sub(/^0+/, "", a[i]); if (a[i]=="") a[i]="0"; if (a[i]==id) {print "self:" id; bad=1} else if (!exists[a[i]]) {print "missing:" id ":" a[i]; bad=1} }
      }
      for (id in dep) visit(id)
      exit 0
    }
    function visit(id, count,i,a,k) {
      if (color[id]==1) {print "cycle:" id; bad=1; return}
      if (color[id]==2) return
      color[id]=1
      if (dep[id] != "无" && dep[id] != "") {count=split(dep[id],a,","); for(i=1;i<=count;i++){gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[i]); sub(/^TC-/,"",a[i]); sub(/^0+/,"",a[i]); if(a[i]=="")a[i]="0"; if(exists[a[i]]) visit(a[i])}}
      color[id]=2
    }
  ' "$graph")"
  if [ -n "$dependency_errors" ]; then while IFS= read -r rec; do check_error "依赖校验失败：$rec"; done <<< "$dependency_errors"; fi
  rm -f "$graph"
  [ "$CHECK_ERRORS" -eq 0 ]
}
check_layout() {
  local root="$1" file rel
  while IFS= read -r -d '' file; do
    rel="${file#"$root/"}"
    [ "$rel" = .git ] && continue
    case "$rel" in
      TASK-CENTER.md|scripts/task.sh|scripts/task.ps1|.task-center/version|.task-center/next-id|docs/tasks/INDEX.md) ;;
      docs/tasks/[0-9]*-[a-z0-9]*.md|docs/tasks/archive/[0-9]*-[a-z0-9]*.md) ;;
      *) die "任务中心含清单外文件：$rel" ;;
    esac
  done < <(find "$root" -type f -print0)
}
check_history() {
  local root="$1" mode="${2:-delta}" head roots commits commit parent rel branch merge baseline full=1 upstream commit_paths branches ancestor_code
  check_layout "$root"
  head="$(git_run "$root" rev-parse HEAD)"
  if [ "$mode" != --full ] && [ -f "$RUNTIME/validated-history" ]; then
    baseline="$(tr -d '\r\n ' < "$RUNTIME/validated-history")"
    if [[ "$baseline" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
      ancestor_code="$(git_code 1 "$root" merge-base --is-ancestor "$baseline" HEAD)"
      if [ "$ancestor_code" = 0 ]; then commits="$(git_run "$root" rev-list HEAD "^$baseline")"; full=0; fi
    fi
  fi
  if [ "$full" -eq 1 ]; then
    roots="$(git_run "$root" rev-list --max-parents=0 HEAD)"
    [ "$(printf '%s\n' "$roots" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] || die '任务中心历史必须只有一个根提交'
  commits="$(git_run "$root" rev-list HEAD)"
  fi
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    parent="$(git_run "$root" rev-list --parents -n 1 "$commit")"
    set -- $parent
    [ "$#" -le 2 ] || die "任务中心历史含 merge commit：$commit"
    commit_paths="$(git_run "$root" diff-tree --root --no-commit-id --name-only -r "$commit")"
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      case "$rel" in TASK-CENTER.md|scripts/task.sh|scripts/task.ps1|.task-center/version|.task-center/next-id|docs/tasks/INDEX.md|docs/tasks/[0-9]*-[a-z0-9]*.md|docs/tasks/archive/[0-9]*-[a-z0-9]*.md) ;; *) die "历史提交含允许清单外路径：$commit:$rel" ;; esac
    done <<< "$commit_paths"
  done <<< "$commits"
  branches="$(git_run "$root" for-each-ref --format='%(refname:short)' refs/heads)"
  while IFS= read -r branch; do
    [ -n "$branch" ] && [ "$branch" != "$BRANCH" ] || continue
    if merge="$(git -C "$root" merge-base HEAD "$branch" 2>/dev/null)"; then
      [ -z "$merge" ] || die "任务中心分支与本地代码分支 $branch 共享历史提交 $merge"
    else
      [ "$?" -eq 1 ] || die "无法检查与本地分支 $branch 的历史边界"
    fi
  done <<< "$branches"
  if upstream="$(git -C "$root" config --get "branch.$BRANCH.remote" 2>/dev/null)"; then
    die "任务中心分支不得设置 upstream：$upstream"
  else
    [ "$?" -eq 1 ] || die '读取任务中心 upstream 配置失败'
  fi
}

new_transaction() {
  local head
  require_clean
  mkdir -p "$RUNTIME/transactions"
  TXID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  TXTOKEN="task-center-$TXID"
  TXDIR="$RUNTIME/transactions/$TXID"
  head="$(git_run "$WT" rev-parse HEAD)"
  TXBASE="$head"
  mkdir -p "$TXDIR/work"
  printf 'journal-version=1\nid=%s\ntoken=%s\nbase=%s\nmessage=\n' "$TXID" "$TXTOKEN" "$TXBASE" > "$TXDIR/manifest"
  printf 'work-copy\n' > "$TXDIR/state"
  cp -R "$WT/docs" "$TXDIR/work/docs"
  cp -R "$WT/.task-center" "$TXDIR/work/.task-center"
}
tx_commit() { # message and changed relative paths
  local message="$1"; shift; TX_COMMITTED=0
  local rel
  [ $# -gt 0 ] || die '事务没有修改路径'
  mkdir -p "$TXDIR/before" "$TXDIR/after"
  printf 'journal-version=1\nid=%s\ntoken=%s\nbase=%s\nmessage=%s\n' "$TXID" "$TXTOKEN" "$TXBASE" "$message" > "$TXDIR/manifest"
  : > "$TXDIR/paths"
  for rel in "$@"; do
    [[ "$rel" =~ ^(docs/tasks|\.task-center)/[A-Za-z0-9._/-]+$ ]] || die "事务路径不在允许清单内：$rel"
    printf '%s\n' "$rel" >> "$TXDIR/paths"
    if [ -f "$WT/$rel" ]; then mkdir -p "$TXDIR/before/$(dirname "$rel")"; cp "$WT/$rel" "$TXDIR/before/$rel"; else printf '%s\n' "$rel" >> "$TXDIR/before-absent"; fi
    if [ -f "$TXDIR/work/$rel" ]; then mkdir -p "$TXDIR/after/$(dirname "$rel")"; cp "$TXDIR/work/$rel" "$TXDIR/after/$rel"; else printf '%s\n' "$rel" >> "$TXDIR/after-absent"; fi
  done
  # The complete before/after snapshots are durable before any destination is changed.
  printf 'prepared\n' > "$TXDIR/state"
  while IFS= read -r rel; do
    if [ -f "$TXDIR/after/$rel" ]; then
      install_snapshot "$TXDIR/after/$rel" "$WT/$rel" "$TXID"
    else rm -f "$WT/$rel"; fi
  done < "$TXDIR/paths"
  local args=(); while IFS= read -r rel; do args+=("$rel"); done < "$TXDIR/paths"
  git_run "$WT" add -- "${args[@]}" >/dev/null
  assert_transaction_index "${args[@]}"
  local staged; staged="$(git_code 1 "$WT" diff --cached --quiet)"
  if [ "$staged" = 0 ]; then rm -rf "$TXDIR"; return 0; fi
  git_run "$WT" commit -m "$message" -m "Task-Transaction: $TXTOKEN" >/dev/null
  git_run "$WT" rev-parse HEAD > "$RUNTIME/validated-history"
  TX_COMMITTED=1
  rm -rf "$TXDIR"
}
pending_transaction() {
  local dirs=()
  for d in "$RUNTIME"/transactions/*; do [ -d "$d" ] && dirs+=("$d"); done
  [ "${#dirs[@]}" -le 1 ] || die '发现多个未完成事务目录；请检查共同 Git 目录下的 task-center-runtime/transactions'
  PENDING="${dirs[0]:-}"
  if [ -n "$PENDING" ]; then
    [ -f "$PENDING/manifest" ] || die "发现未完成事务初始化目录 $PENDING；确认其中没有需要恢复的数据后由维护者检查并移除"
    if [ "$(cat "$PENDING/state" 2>/dev/null || true)" = work-copy ]; then rm -rf "$PENDING"; PENDING=''; return; fi
    [ "$(sed -n 's/^journal-version=//p' "$PENDING/manifest" | head -1)" = 1 ] || die "不支持事务日志版本：$PENDING/manifest"
    local base token head body
    base="$(sed -n 's/^base=//p' "$PENDING/manifest" | head -1)"; token="$(sed -n 's/^token=//p' "$PENDING/manifest" | head -1)"
    head="$(git_run "$WT" rev-parse HEAD)"
    if [ "$head" != "$base" ]; then
      body="$(git_run "$WT" show -s --format=%B HEAD)"
      local parent; parent="$(git_run "$WT" show -s --format=%P HEAD)"
      if [ "$parent" = "$base" ] && [[ "$body" == *"Task-Transaction: $token"* ]]; then rm -rf "$PENDING"; PENDING=''; else die "存在未完成事务 $PENDING，HEAD 已变化且无法证明提交归属；请维护者检查"; fi
    fi
  fi
}
matches_snapshot() { # path snapshot absent-list
  local rel="$1" snap="$2" absent="$3"
  local transaction_id="${4:-}" temp
  if [ -f "$snap/$rel" ]; then
    if [ -f "$WT/$rel" ] && cmp -s "$snap/$rel" "$WT/$rel"; then return 0; fi
    temp="$WT/$rel.tmp.$transaction_id"
    [ -n "$transaction_id" ] && [ ! -e "$WT/$rel" ] && [ -f "$temp" ] && cmp -s "$snap/$rel" "$temp"
    return
  fi
  if grep -Fxq "$rel" "$absent" 2>/dev/null; then [ ! -e "$WT/$rel" ]; return; fi
  return 1
}
install_snapshot() { # source target transaction-id; temp and target share a directory
  local source="$1" target="$2" transaction_id="$3" temp="$2.tmp.$3"
  mkdir -p "$(dirname "$target")"
  cp "$source" "$temp"
  mv -f "$temp" "$target"
}
remove_transaction_temps() {
  local transaction_id="$1" rel
  shift
  for rel in "$@"; do rm -f "$WT/$rel.tmp.$transaction_id" "$WT/$rel.bak.$transaction_id"; done
}
assert_transaction_index() {
  local staged rel expected allowed
  staged="$(git -C "$WT" diff --cached --name-only 2>/dev/null)" || die '无法检查事务暂存路径'
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    allowed=0
    for expected in "$@"; do [ "$rel" = "$expected" ] && { allowed=1; break; }; done
    [ "$allowed" -eq 1 ] || die "暂存区含事务外路径，拒绝提交：$rel"
  done <<< "$staged"
}
recover_cmd() {
  local action="${1:---show}" rel base token msg head body args=()
  acquire_lock; pending_transaction
  [ -n "$PENDING" ] || { echo '没有待恢复事务'; return 0; }
  base="$(sed -n 's/^base=//p' "$PENDING/manifest" | head -1)"; token="$(sed -n 's/^token=//p' "$PENDING/manifest" | head -1)"; msg="$(sed -n 's/^message=//p' "$PENDING/manifest" | head -1)"
  case "$action" in
    --show) printf '待恢复事务：%s\n基线：%s\n标记：%s\n' "$PENDING" "$base" "$token" ;;
    --abort|--commit)
      head="$(git_run "$WT" rev-parse HEAD)"; [ "$head" = "$base" ] || die 'HEAD 已变化，不能安全回滚或重试'
      while IFS= read -r rel; do args+=("$rel"); done < "$PENDING/paths"
      for rel in "${args[@]}"; do [[ "$rel" =~ ^(docs/tasks|\.task-center)/[A-Za-z0-9._/-]+$ && "$rel" != *..* ]] || die "事务路径无效：$rel"; done
      if [ "$action" = --abort ]; then
        while IFS= read -r rel; do
          matches_snapshot "$rel" "$PENDING/before" "$PENDING/before-absent" "$(basename "$PENDING")" || matches_snapshot "$rel" "$PENDING/after" "$PENDING/after-absent" "$(basename "$PENDING")" || die "文件与事务快照不符，停止回滚：$rel"
        done < "$PENDING/paths"
        git_run "$WT" reset -q HEAD -- "${args[@]}" >/dev/null
        while IFS= read -r rel; do if [ -f "$PENDING/before/$rel" ]; then install_snapshot "$PENDING/before/$rel" "$WT/$rel" "$(basename "$PENDING")"; else rm -f "$WT/$rel"; fi; done < "$PENDING/paths"
        remove_transaction_temps "$(basename "$PENDING")" "${args[@]}"
        rm -rf "$PENDING"; echo '事务已按修改前快照回滚'
      else
        assert_transaction_index "${args[@]}"
        while IFS= read -r rel; do matches_snapshot "$rel" "$PENDING/before" "$PENDING/before-absent" "$(basename "$PENDING")" || matches_snapshot "$rel" "$PENDING/after" "$PENDING/after-absent" "$(basename "$PENDING")" || die "文件与事务快照不符，停止提交：$rel"; done < "$PENDING/paths"
        while IFS= read -r rel; do if [ -f "$PENDING/after/$rel" ]; then install_snapshot "$PENDING/after/$rel" "$WT/$rel" "$(basename "$PENDING")"; else rm -f "$WT/$rel"; fi; done < "$PENDING/paths"
        remove_transaction_temps "$(basename "$PENDING")" "${args[@]}"
        check_data "$WT" || die '事务结果未通过 check；未提交'
        git_run "$WT" add -- "${args[@]}" >/dev/null
        assert_transaction_index "${args[@]}"
        local staged; staged="$(git_code 1 "$WT" diff --cached --quiet)"
        if [ "$staged" = 1 ]; then git_run "$WT" commit -m "$msg" -m "Task-Transaction: $token" >/dev/null; git_run "$WT" rev-parse HEAD > "$RUNTIME/validated-history"; fi
        rm -rf "$PENDING"; echo '事务已完成并提交'
      fi ;;
    *) usage ;;
  esac
}

check_command() {
  require_clean
  check_history "$WT" --full
  if check_data "$WT"; then echo 'check 通过'; else die "check 发现 $CHECK_ERRORS 项问题"; fi
}
list_command() {
  require_clean
  local all=0 f id status owner assignee deps dep depf depstatus
  [ "${1:-}" != --all ] || all=1
  printf '%s\n' '编号 | 标题 | 状态 | owner | 当前负责人 | 依赖'
  for f in "$TASKS"/*.md; do
    [ -f "$f" ] || continue; [ "$(basename "$f")" = INDEX.md ] && continue
    id="$(task_header_id "$f")"; status="$(field 状态 "$f")"; [ "$all" -eq 1 ] || [ "$status" != 已完成 ] && [ "$status" != 已取消 ] || continue
    owner="$(field owner "$f")"; assignee="$(field 当前负责人 "$f")"; deps="$(field 依赖 "$f")"
    local warning=''
    if [ "$deps" != 无 ]; then
      IFS=, read -r -a dep_list <<< "$deps"
      for dep in "${dep_list[@]}"; do dep="$(trim_number "$dep")"; depf="$(task_file "$dep")"; depstatus="$(field 状态 "$depf")"; [ "$depstatus" = 已完成 ] || warning='（依赖未完成）'; done
    fi
    printf 'TC-%s | %s | %s%s | %s | %s | %s\n' "$(fmt_id "$((10#$id))")" "$(task_title "$f")" "$status" "$warning" "$owner" "$assignee" "$deps"
  done
  if [ "$all" -eq 1 ]; then for f in "$TASKS"/archive/*.md; do [ -f "$f" ] || continue; printf 'TC-%s | %s | %s | %s | %s | %s\n' "$(fmt_id "$((10#$(task_header_id "$f")))")" "$(task_title "$f")" "$(field 状态 "$f")" "$(field owner "$f")" "$(field 当前负责人 "$f")" "$(field 依赖 "$f")"; done; fi
}
set_field() { # label value file
  local label="$1" value="$2" file="$3" temp
  temp="$file.tmp.$$"; awk -v p="$label：" -v v="$value" '{sub(/\r$/,"",$0)} index($0,p)==1 && !done {print p v; done=1; next} {print}' "$file" > "$temp"; mv -f "$temp" "$file"
}
append_progress() { # file old new action evidence
  local file="$1" old="$2" new="$3" action="$4" evidence="$5" temp
  temp="$file.tmp.$$"; sed 's/\r$//' "$file" > "$temp"
  printf '%s %s：%s（状态：%s → %s；证据：%s）\n' "- $(date -u +%F)" "$IDENTITY" "$action" "$old" "$new" "${evidence:-无}" >> "$temp"
  mv -f "$temp" "$file"
}
find_option() { # flag args...; returns following arg through OPTION_VALUE
  local want="$1"; shift; OPTION_VALUE=''
  while [ $# -gt 0 ]; do if [ "$1" = "$want" ]; then [ $# -ge 2 ] || die "$want 缺少值"; OPTION_VALUE="$2"; return 0; fi; shift; done
  return 1
}
require_option() { find_option "$1" "${@:2}" || die "缺少必需参数 $1"; }
validate_options() { # validate_options '<allowed options>' args...
  local allowed="$1" option seen=' '; shift
  while [ $# -gt 0 ]; do
    option="$1"
    case "$option" in --slug|--priority|--depends|--acceptance|--external|--evidence|--assignee|--reason|--waiting-for) ;; *) die "未知参数：$option" ;; esac
    case " $allowed " in *" $option "*) ;; *) die "未知参数：$option" ;; esac
    case "$seen" in *" $option "*) die "参数重复：$option" ;; esac
    [ $# -ge 2 ] || die "$option 缺少值"
    case "$2" in --*) die "$option 缺少值" ;; esac
    seen+="$option "; shift 2
  done
}
check_unfinished_deps() {
  local deps="$1" dep f st
  [ "$deps" = 无 ] && return 0
  IFS=, read -r -a dep_list <<< "$deps"
  for dep in "${dep_list[@]}"; do f="$(task_file "$(trim_number "$dep")")"; st="$(field 状态 "$f")"; [ "$st" = 已完成 ] || die "依赖 TC-$(fmt_id "$(trim_number "$dep")") 尚未完成"; done
}
begin_write() {
  local mode="${1:-}"
  require_identity; acquire_lock; pending_transaction; [ -z "$PENDING" ] || die "有未完成事务 $PENDING；先运行 recover --show / --abort / --commit"
  require_clean; check_history "$WT"
  if [ "$mode" != --rebuild-index ]; then check_data "$WT" || die "写入前 check 失败（$CHECK_ERRORS 项）"; fi
  new_transaction; TASKS="$TXDIR/work/docs/tasks"; META="$TXDIR/work/.task-center"; INDEX="$TASKS/INDEX.md"; NEXT_ID="$META/next-id"
}
finish_write() { local msg="$1"; shift; check_data "$TXDIR/work" || die "写入候选未通过 check（$CHECK_ERRORS 项）"; tx_commit "$msg" "$@"; if [ "$TX_COMMITTED" -eq 1 ]; then echo '事务已提交'; else echo '没有数据变化；未创建提交'; fi; }

cmd_new() {
  [ $# -ge 1 ] || usage
  local title="$1" slug=task priority=中 deps=无 acceptance='<逐条填写>' external=无 arg max id f exists=0
  valid_text "$title" || die '标题不得包含换行、制表符或 |'; shift
  validate_options '--slug --priority --depends --acceptance --external' "$@"
  while [ $# -gt 0 ]; do case "$1" in --slug|--priority|--depends|--acceptance|--external) [ $# -ge 2 ] || die "$1 缺少值"; case "$1" in --slug) slug="$2";; --priority) priority="$2";; --depends) deps="$2";; --acceptance) acceptance="$2";; --external) external="$2";; esac; shift 2;; *) die "未知参数：$1";; esac; done
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die 'slug 只允许小写 ASCII 字母、数字和连字符'
  case "$priority" in 高|中|低) ;; *) die 'priority 必须是高、中或低' ;; esac
  valid_text "$acceptance" && valid_text "$external" || die '字段不得包含换行、制表符或 |'
  [ "$external" = 无 ] || [[ "$external" =~ ^https?://[^[:space:]]+$ ]] || die 'external 必须是完整 HTTP(S) 链接'
  begin_write
  max="$(tr -d '\r\n ' < "$NEXT_ID")"; [[ "$max" =~ ^[1-9][0-9]*$ ]] || die 'next-id 格式错误'
  for f in "$TASKS"/*.md "$TASKS/archive"/*.md; do [ -f "$f" ] || continue; [ "$(basename "$f")" = INDEX.md ] && continue; id="$(task_header_id "$f")"; [[ "$id" =~ ^[0-9]+$ ]] || continue; [ "$((10#$id))" -lt "$max" ] || max=$((10#$id + 1)); done
  id="$max"; pad="$(fmt_id "$id")"; f="$TASKS/$pad-$slug.md"
  [ ! -e "$f" ] || die "任务文件已存在：$f"
  if [ "$deps" != 无 ]; then IFS=, read -r -a dep_list <<< "$deps"; for arg in "${dep_list[@]}"; do [ -n "$arg" ] || die '依赖编号列表格式错误'; exists=$((exists + 1)); done; fi
  mkdir -p "$TASKS/archive"
  cat > "$f" <<EOF
# 任务 #$id $title

状态：待办
owner：未认领
当前负责人：未分配
优先级：$priority
依赖：$deps
分支：无
PR：无
外部：$external
备注：无
阻塞前状态：无
阻塞原因：无
等待对象：无
创建：$(date -u +%F) $IDENTITY

## 验收标准

- [ ] $acceptance

## 进度

- $(date -u +%F) $IDENTITY：任务登记（状态：待办 → 待办；证据：无）；下一步：待认领
EOF
  printf '%s\n' "$((id + 1))" > "$NEXT_ID"
  generate_index "$TASKS" "$INDEX"
  finish_write "docs(tasks): 登记 TC-$(fmt_id "$id") $title" "docs/tasks/$pad-$slug.md" docs/tasks/INDEX.md .task-center/next-id
  echo "已登记 TC-$(fmt_id "$id")"
}
cmd_claim() {
  [ $# -eq 1 ] || usage; local id f owner status
  id="$(trim_number "$1")"; begin_write; f="$(task_file "$id")"; status="$(field 状态 "$f")"; owner="$(field owner "$f")"
  [ "$status" = 待办 ] && [ "$owner" = 未认领 ] || die '仅可认领尚未认领的待办任务'
  check_unfinished_deps "$(field 依赖 "$f")"
  set_field owner "$IDENTITY" "$f"; set_field 当前负责人 "$IDENTITY" "$f"; set_field 状态 已认领 "$f"
  append_progress "$f" 待办 已认领 '认领任务' 无; generate_index "$TASKS" "$INDEX"
  finish_write "docs(tasks): TC-$(fmt_id "$id") 认领" "${f#"$TXDIR/work/"}" docs/tasks/INDEX.md
}
cmd_progress() {
  [ $# -ge 2 ] || usage; local id f content evidence= status owner assignee
  id="$(trim_number "$1")"; content="$2"; shift 2; valid_text "$content" || die '进度不得包含换行、制表符或 |'
  validate_options '--evidence' "$@"
  evidence='无'; while [ $# -gt 0 ]; do case "$1" in --evidence) [ $# -ge 2 ] || die '--evidence 缺少值'; evidence="$2"; shift 2;; *) die "未知参数：$1";; esac; done
  valid_text "$evidence" || die '证据字段格式错误'; begin_write; f="$(task_file "$id")"; status="$(field 状态 "$f")"; owner="$(field owner "$f")"; assignee="$(field 当前负责人 "$f")"
  [ "$IDENTITY" = "$owner" ] || [ "$IDENTITY" = "$assignee" ] || die '只有 owner 或当前负责人可以追加进度'
  [ "$status" != 已完成 ] && [ "$status" != 已取消 ] || die '终态任务不可修改'
  append_progress "$f" "$status" "$status" "$content" "$evidence"; generate_index "$TASKS" "$INDEX"
  finish_write "docs(tasks): TC-$(fmt_id "$id") 追加进度" "${f#"$TXDIR/work/"}" docs/tasks/INDEX.md
}
cmd_status() {
  [ $# -ge 2 ] || usage; local id target f old owner assignee to reason='' evidence=无
  id="$(trim_number "$1")"; target="$2"; shift 2
  validate_options '--assignee --reason --evidence' "$@"
  while [ $# -gt 0 ]; do case "$1" in --assignee|--reason|--evidence) [ $# -ge 2 ] || die "$1 缺少值"; case "$1" in --assignee) to="$2";; --reason) reason="$2";; --evidence) evidence="$2";; esac; shift 2;; *) die "未知参数：$1";; esac; done
  valid_text "$reason" && valid_text "$evidence" && valid_text "${to:-}" || die '参数值不得包含换行、制表符或 |'
  begin_write; f="$(task_file "$id")"; old="$(field 状态 "$f")"; owner="$(field owner "$f")"; assignee="$(field 当前负责人 "$f")"
  case "$old:$target" in
    已认领:进行中) [ "$IDENTITY" = "$owner" ] || die '只有 owner 可开始执行'; check_unfinished_deps "$(field 依赖 "$f")"; [ "$(grep -Fxc -- '- [ ] <逐条填写>' "$f")" -eq 0 ] || die '请先明确验收标准';;
    进行中:待审核) [ "$IDENTITY" = "$owner" ] || die '只有 owner 可提交审核'; [ -n "$to" ] || die '进入待审核必须指定 --assignee'; require_assignee_role "$to" TASK_REVIEWERS; [ "$(grep -Fxc -- '- [ ] <逐条填写>' "$f")" -eq 0 ] || die '请先明确验收标准'; [ "$evidence" != 无 ] || die '进入待审核必须提供 --evidence'; set_field 当前负责人 "$to" "$f";;
    待审核:待测试) [ "$IDENTITY" = "$assignee" ] && role_has "${TASK_REVIEWERS:-}" || die '只有当前审核负责人可转交测试'; [ -n "$to" ] || die '进入待测试必须指定 --assignee'; require_assignee_role "$to" TASK_TESTERS; [ "$evidence" != 无 ] || die '进入待测试必须提供 --evidence'; set_field 当前负责人 "$to" "$f";;
    待审核:进行中) [ "$IDENTITY" = "$assignee" ] && role_has "${TASK_REVIEWERS:-}" || die '只有授权的当前审核负责人可打回'; [ -n "$reason" ] || die '打回必须提供 --reason'; set_field 当前负责人 "$owner" "$f";;
    待测试:进行中) [ "$IDENTITY" = "$assignee" ] && role_has "${TASK_TESTERS:-}" || die '只有授权的当前测试负责人可打回'; [ -n "$reason" ] || die '打回必须提供 --reason'; set_field 当前负责人 "$owner" "$f";;
    待测试:待合并) [ "$IDENTITY" = "$assignee" ] && role_has "${TASK_TESTERS:-}" || die '只有当前测试负责人可提交合并'; [ -n "$to" ] || die '进入待合并必须指定 --assignee'; require_assignee_role "$to" TASK_MERGE_AUTHORIZED; [ "$evidence" != 无 ] || die '进入待合并必须提供 --evidence'; set_field 当前负责人 "$to" "$f";;
    *) die "非法状态迁移：$old → $target；请使用 claim、block、unblock、done 或 cancel 专用命令";;
  esac
  set_field 状态 "$target" "$f"; append_progress "$f" "$old" "$target" "状态流转${reason:+：$reason}" "$evidence"; generate_index "$TASKS" "$INDEX"
  finish_write "docs(tasks): TC-$(fmt_id "$id") $old -> $target" "${f#"$TXDIR/work/"}" docs/tasks/INDEX.md
}
cmd_assign() {
  [ $# -ge 2 ] || usage; local id f new_owner reason
  id="$(trim_number "$1")"; new_owner="$2"; shift 2; validate_options '--reason' "$@"; require_option --reason "$@"; reason="$OPTION_VALUE"; valid_text "$reason" && valid_text "$new_owner" || die '转交身份或原因格式错误'
  begin_write; require_role TASK_MAINTAINERS; f="$(task_file "$id")"; local old owner status assignee
  old="$(field 状态 "$f")"; owner="$(field owner "$f")"; assignee="$(field 当前负责人 "$f")"; case "$old" in 已完成|已取消|待办) die '该状态不可转交 owner' ;; esac
  set_field owner "$new_owner" "$f"; [ "$assignee" != "$owner" ] || set_field 当前负责人 "$new_owner" "$f"
  append_progress "$f" "$old" "$old" "owner 由 $owner 转交给 $new_owner：$reason" 无; generate_index "$TASKS" "$INDEX"
  finish_write "docs(tasks): TC-$(fmt_id "$id") 转交 owner" "${f#"$TXDIR/work/"}" docs/tasks/INDEX.md
}
cmd_handoff() {
  [ $# -ge 2 ] || usage; local id f new_to reason old
  id="$(trim_number "$1")"; new_to="$2"; shift 2; validate_options '--reason' "$@"; require_option --reason "$@"; reason="$OPTION_VALUE"; valid_text "$reason" && valid_text "$new_to" || die '交接身份或原因格式错误'
  begin_write; f="$(task_file "$id")"; old="$(field 状态 "$f")"; case "$old" in 已完成|已取消|待办) die '该状态不接受负责人交接' ;; esac
  if [ "$IDENTITY" != "$(field 当前负责人 "$f")" ]; then require_role TASK_MAINTAINERS; fi
  case "$old" in 待审核) require_assignee_role "$new_to" TASK_REVIEWERS;; 待测试) require_assignee_role "$new_to" TASK_TESTERS;; 待合并) require_assignee_role "$new_to" TASK_MERGE_AUTHORIZED;; 阻塞) die '阻塞任务需先解除阻塞';; *) : ;; esac
  set_field 当前负责人 "$new_to" "$f"; append_progress "$f" "$old" "$old" "当前负责人交接给 $new_to：$reason" 无; generate_index "$TASKS" "$INDEX"
  finish_write "docs(tasks): TC-$(fmt_id "$id") 交接负责人" "${f#"$TXDIR/work/"}" docs/tasks/INDEX.md
}
cmd_block() {
  [ $# -ge 1 ] || usage; local id f reason waiting old assignee
  id="$(trim_number "$1")"; shift; validate_options '--reason --waiting-for' "$@"; require_option --reason "$@"; reason="$OPTION_VALUE"; require_option --waiting-for "$@"; waiting="$OPTION_VALUE"
  valid_text "$reason" && valid_text "$waiting" || die '阻塞字段格式错误'; begin_write; f="$(task_file "$id")"; old="$(field 状态 "$f")"; assignee="$(field 当前负责人 "$f")"
  case "$old" in 已认领|进行中|待审核|待测试|待合并) ;; *) die '只有活跃阶段可以阻塞' ;; esac
  [ "$IDENTITY" = "$assignee" ] || die '只有当前负责人可记录阻塞'
  set_field 阻塞前状态 "$old" "$f"; set_field 阻塞原因 "$reason" "$f"; set_field 等待对象 "$waiting" "$f"; set_field 状态 阻塞 "$f"
  append_progress "$f" "$old" 阻塞 "阻塞：$reason；等待：$waiting" 无; generate_index "$TASKS" "$INDEX"
  finish_write "docs(tasks): TC-$(fmt_id "$id") 阻塞" "${f#"$TXDIR/work/"}" docs/tasks/INDEX.md
}
cmd_unblock() {
  [ $# -ge 1 ] || usage; local id f old target evidence=无
  id="$(trim_number "$1")"; shift; validate_options '--evidence' "$@"; while [ $# -gt 0 ]; do case "$1" in --evidence) [ $# -ge 2 ] || die '--evidence 缺少值'; evidence="$2"; shift 2;; *) die "未知参数：$1";; esac; done
  begin_write; f="$(task_file "$id")"; [ "$(field 状态 "$f")" = 阻塞 ] || die '任务当前未阻塞'; [ "$IDENTITY" = "$(field 当前负责人 "$f")" ] || die '只有当前负责人可解除阻塞'
  target="$(field 阻塞前状态 "$f")"; old=阻塞; set_field 状态 "$target" "$f"; set_field 阻塞前状态 无 "$f"; set_field 阻塞原因 无 "$f"; set_field 等待对象 无 "$f"
  append_progress "$f" "$old" "$target" '解除阻塞' "$evidence"; generate_index "$TASKS" "$INDEX"
  finish_write "docs(tasks): TC-$(fmt_id "$id") 解除阻塞" "${f#"$TXDIR/work/"}" docs/tasks/INDEX.md
}
archive_task() {
  local id="$1" f="$2" target="$3" reason="$4" evidence="$5" old
  old="$(field 状态 "$f")"; append_progress "$f" "$old" "$target" "$reason" "$evidence"; set_field 状态 "$target" "$f"; set_field 当前负责人 未分配 "$f"
  local base dest; base="$(basename "$f")"; dest="$TASKS/archive/$base"; mkdir -p "$TASKS/archive"; [ ! -e "$dest" ] || die "归档目标已存在：$dest"; mv "$f" "$dest"
  generate_index "$TASKS" "$INDEX"
}
cmd_done() {
  [ $# -ge 1 ] || usage; local id f evidence
  id="$(trim_number "$1")"; shift; validate_options '--evidence' "$@"; require_option --evidence "$@"; evidence="$OPTION_VALUE"; valid_text "$evidence" || die '证据格式错误'
  begin_write; f="$(task_file "$id")"; [ "$(field 状态 "$f")" = 待合并 ] || die '仅待合并任务可完成'; [ "$IDENTITY" = "$(field 当前负责人 "$f")" ] || die '只有当前合并负责人可完成'; role_has "${TASK_MERGE_AUTHORIZED:-}" || die '当前负责人未获授权合并角色'
  grep -Eq '^-[[:space:]]\[ \]' "$f" && die '仍有未完成验收条件'
  archive_task "$id" "$f" 已完成 '完成并归档' "$evidence"
  finish_write "docs(tasks): TC-$(fmt_id "$id") 完成归档" "${f#"$TXDIR/work/"}" "docs/tasks/archive/$(basename "$f")" docs/tasks/INDEX.md
}
cmd_cancel() {
  [ $# -ge 1 ] || usage; local id f reason
  id="$(trim_number "$1")"; shift; validate_options '--reason' "$@"; require_option --reason "$@"; reason="$OPTION_VALUE"; valid_text "$reason" || die '取消原因格式错误'
  begin_write; require_role TASK_MAINTAINERS; f="$(task_file "$id")"; case "$(field 状态 "$f")" in 已完成|已取消) die '任务已处于终态' ;; esac
  archive_task "$id" "$f" 已取消 "维护者取消：$reason" 无
  finish_write "docs(tasks): TC-$(fmt_id "$id") 取消归档" "${f#"$TXDIR/work/"}" "docs/tasks/archive/$(basename "$f")" docs/tasks/INDEX.md
}
cmd_edit() {
  [ $# -ge 3 ] || usage
  local id f mode draft base resolved head sidecar original_prefix draft_prefix original_progress draft_progress acceptance old
  id="$(trim_number "$1")"; mode="$2"; draft="$3"; shift 3
  case "$mode" in
    --export)
      [ $# -eq 0 ] || usage; require_identity; acquire_lock; pending_transaction; [ -z "$PENDING" ] || die "有未完成事务 $PENDING；先运行 recover"
      require_clean; check_history "$WT"; check_data "$WT" || die "check 失败（$CHECK_ERRORS 项）"
      f="$(task_file "$id")"; case "$f" in "$TASKS"/archive/*) die '终态任务不可导出编辑草稿' ;; esac
      mkdir -p "$(dirname "$draft")"; resolved="$(cd "$(dirname "$draft")" && pwd -P)/$(basename "$draft")"
      case "$resolved" in "$WT"/*) die '编辑草稿必须位于任务中心 worktree 外' ;; esac
      [ ! -e "$resolved" ] && [ ! -e "$resolved.base" ] || die '草稿或基线文件已存在；请指定新路径'
      cp "$f" "$resolved"; printf '%s %s\n' "$(git_run "$WT" rev-parse HEAD)" "$id" > "$resolved.base"
      echo "草稿已导出：$resolved（基线记录：$resolved.base）" ;;
    --import)
      [ $# -eq 2 ] && [ "$1" = --base ] || die '导入草稿必须提供且仅提供 --base <提交>'
      require_option --base "$@"; base="$OPTION_VALUE"; valid_text "$base" || die '基线提交格式错误'
      begin_write; [ -f "$draft" ] || die "草稿文件不存在：$draft"; [ "$base" = "$TXBASE" ] || die "草稿基线 $base 与当前提交 $TXBASE 不同，请重新导出并合并"
      sidecar="$draft.base"; if [ -f "$sidecar" ] && [ "$(awk '{print $1}' "$sidecar")" != "$base" ]; then die '草稿基线文件与 --base 不一致'; fi
      f="$(task_file "$id")"; case "$f" in "$TASKS"/archive/*) die '终态任务不可编辑' ;; esac
      mkdir -p "$TXDIR/parts"
      awk '/^## 验收标准$/{exit}{print}' "$f" > "$TXDIR/parts/original-prefix"
      awk '/^## 验收标准$/{exit}{print}' "$draft" > "$TXDIR/parts/draft-prefix"
      cmp -s "$TXDIR/parts/original-prefix" "$TXDIR/parts/draft-prefix" || die '草稿字段区有变化；只允许编辑验收标准'
      awk '/^## 进度$/{p=1} p{print}' "$f" > "$TXDIR/parts/original-progress"
      awk '/^## 进度$/{p=1} p{print}' "$draft" > "$TXDIR/parts/draft-progress"
      cmp -s "$TXDIR/parts/original-progress" "$TXDIR/parts/draft-progress" || die '进度区只允许通过 progress 命令追加'
      awk '/^## 验收标准$/{p=1} /^## 进度$/{p=0} p{print}' "$draft" > "$TXDIR/parts/acceptance"
      grep -q '^## 验收标准$' "$TXDIR/parts/acceptance" && grep -Eq '^-[[:space:]]+\[[ xX]\][[:space:]]+.+$' "$TXDIR/parts/acceptance" || die '草稿缺少有效验收标准'
      awk '/^## 验收标准$/{exit}{print}' "$f" > "$TXDIR/parts/combined"
      cat "$TXDIR/parts/acceptance" "$TXDIR/parts/original-progress" >> "$TXDIR/parts/combined"
      mv "$TXDIR/parts/combined" "$f"
      old="$(field 状态 "$f")"; append_progress "$f" "$old" "$old" '导入并更新验收标准' 无
      generate_index "$TASKS" "$INDEX"
      finish_write "docs(tasks): TC-$(fmt_id "$id") 更新验收标准" "${f#"$TXDIR/work/"}" docs/tasks/INDEX.md ;;
    *) usage ;;
  esac
}
cmd_rebuild_index() {
  begin_write --rebuild-index; collect_tasks "$TASKS"; CHECK_ERRORS=0; for f in "${TASK_FILES[@]}"; do validate_task "$f"; done
  [ "${CHECK_ERRORS:-0}" -eq 0 ] || die "任务数据无效，无法重建索引（$CHECK_ERRORS 项）"
  generate_index "$TASKS" "$INDEX"
  finish_write 'docs(tasks): 重建任务索引' docs/tasks/INDEX.md
}

case "$CMD" in
  init) require_clean; check_history "$WT" --full; check_data "$WT" || die "check 发现 $CHECK_ERRORS 项问题"; echo "任务中心就绪：$WT（本地分支 $BRANCH）" ;;
  list) [ $# -le 1 ] || usage; list_command "${1:-}" ;;
  check) [ $# -eq 0 ] || usage; check_command ;;
  new) cmd_new "$@" ;;
  claim) cmd_claim "$@" ;;
  progress) cmd_progress "$@" ;;
  status) cmd_status "$@" ;;
  assign) cmd_assign "$@" ;;
  handoff) cmd_handoff "$@" ;;
  block) cmd_block "$@" ;;
  unblock) cmd_unblock "$@" ;;
  done) cmd_done "$@" ;;
  cancel) cmd_cancel "$@" ;;
  edit) cmd_edit "$@" ;;
  index) [ "${1:-}" = --rebuild ] && [ $# -eq 1 ] || usage; cmd_rebuild_index ;;
  recover) [ $# -le 1 ] || usage; recover_cmd "${1:---show}" ;;
  *) usage ;;
esac
