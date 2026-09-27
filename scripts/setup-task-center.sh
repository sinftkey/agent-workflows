#!/usr/bin/env bash
# Install, diagnose, migrate, and locally restore a task center.
set -euo pipefail

BRANCH="${TASK_BRANCH:-task-center}"
WORKTREE_NAME="${TASK_WORKTREE_NAME:-task-center}"
REPO_ARG="$(pwd -P)"
SOURCE_ARG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BACKUP_DIR="${TASK_CENTER_BACKUP_DIR:-}"
RESTORE_BUNDLE=""
REPAIR=0
APPLY=0

usage() {
  cat <<'EOF'
Usage: setup-task-center.sh [options]
  --repo PATH             project clone (default: current directory)
  --source PATH           fixed local template checkout or task-center asset directory
  --branch NAME           local task-center branch (default: task-center)
  --worktree-name NAME    default worktree directory name (default: task-center)
  --repair                preview migration and history repair (read-only)
  --dry-run               explicit alias for the default repair preview
  --apply                 execute repair; requires --repair
  --backup-dir PATH       clone-external bundle directory
  --restore-bundle PATH   validate and restore this local bundle
  --help

No remote is read or written. A repair creates a verified local Git bundle before
building a clean orphan history. See TASK-CENTER.md for the local workflow.
EOF
}

print_agent_guidance() {
  cat <<'EOF'

可复制到工具支持的用户级指令位置的通用引导（请先核对该工具自己的指令机制；本脚本不会修改用户全局指令文件）：
识别当前 Git 克隆，并查找已登记的任务中心或 task-center worktree；若已启用，先阅读其中的 TASK-CENTER.md，再使用能区分并发会话的 TASK_IDENTITY 运行 init、list 和 check。日常任务只通过 task.sh 或 task.ps1 命令操作；不要手工编辑任务文件或 INDEX。未启用时明确告知用户，不要静默安装。任务中心只在当前克隆内共享。
EOF
}

die() { printf 'setup-task-center: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --repo) (($# >= 2)) || die 'missing value for --repo'; REPO_ARG="$2"; shift 2 ;;
    --source) (($# >= 2)) || die 'missing value for --source'; SOURCE_ARG="$2"; shift 2 ;;
    --branch) (($# >= 2)) || die 'missing value for --branch'; BRANCH="$2"; shift 2 ;;
    --worktree-name) (($# >= 2)) || die 'missing value for --worktree-name'; WORKTREE_NAME="$2"; shift 2 ;;
    --backup-dir) (($# >= 2)) || die 'missing value for --backup-dir'; BACKUP_DIR="$2"; shift 2 ;;
    --restore-bundle) (($# >= 2)) || die 'missing value for --restore-bundle'; RESTORE_BUNDLE="$2"; shift 2 ;;
    --repair) REPAIR=1; shift ;;
    --dry-run) REPAIR=1; shift ;;
    --apply) APPLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

(( APPLY == 0 || REPAIR == 1 )) || die '--apply requires --repair.'
[[ -z "$RESTORE_BUNDLE" || ( $REPAIR == 0 && $APPLY == 0 ) ]] || die '--restore-bundle cannot be combined with repair.'

canonical_existing() {
  local path
  path="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$path"; else printf '%s\n' "$path"; fi
}
normalize_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1 && [[ "$path" =~ ^[A-Za-z]:[\\/] ]]; then path="$(cygpath -u "$path")"; fi
  if [[ -d "$path" ]]; then canonical_existing "$path"; else printf '%s\n' "$path"; fi
}
canonical_target() {
  local path="$1" parent base
  parent="$(dirname "$path")"; base="$(basename "$path")"
  mkdir -p "$parent" || return 1
  printf '%s/%s\n' "$(canonical_existing "$parent")" "$base"
}
canonical_future() {
  local path="$1" parent base
  if [[ -d "$path" ]]; then canonical_existing "$path"; return; fi
  parent="$(canonical_existing "$(dirname "$path")")" || return 1
  base="$(basename "$path")"
  printf '%s/%s\n' "$parent" "$base"
}

command -v git >/dev/null 2>&1 || die 'Git was not found.'
REPO_ARG="$(canonical_existing "$REPO_ARG")" || die "repository path does not exist: $REPO_ARG"
GIT_ROOT="$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null)" || die 'run from a Git repository.'
GIT_ROOT="$(canonical_existing "$GIT_ROOT")"
[[ "$(git -C "$GIT_ROOT" rev-parse --is-bare-repository)" == false ]] || die 'bare repositories are not supported.'
GIT_VERSION="$(git --version | sed -E 's/.* ([0-9]+)\.([0-9]+).*/\1 \2/')"
read -r GIT_MAJOR GIT_MINOR <<<"$GIT_VERSION"
(( GIT_MAJOR > 2 || (GIT_MAJOR == 2 && GIT_MINOR >= 23) )) || die "Git 2.23 or newer is required (found: $(git --version))."
git -C "$GIT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1 || die 'the clone needs at least one commit; setup does not create the project’s first commit.'
git -C "$GIT_ROOT" var GIT_AUTHOR_IDENT >/dev/null 2>&1 || die 'configure Git user.name and user.email before installation or repair.'
SOURCE_ARG="$(normalize_path "$SOURCE_ARG")"
if [[ -n "$RESTORE_BUNDLE" ]]; then RESTORE_BUNDLE="$(normalize_path "$RESTORE_BUNDLE")"; fi

[[ "$WORKTREE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die 'worktree name may contain only letters, digits, dot, underscore, and hyphen.'
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "invalid branch name: $BRANCH"

COMMON_RAW="$(git -C "$GIT_ROOT" rev-parse --git-common-dir)"
if [[ "$COMMON_RAW" = /* || "$COMMON_RAW" =~ ^[A-Za-z]:[\\/] ]]; then COMMON_DIR="$COMMON_RAW"; else COMMON_DIR="$GIT_ROOT/$COMMON_RAW"; fi
COMMON_DIR="$(canonical_existing "$COMMON_DIR")"
RUNTIME_DIR="$COMMON_DIR/task-center-runtime"
REGISTRATION="$COMMON_DIR/task-center/install-path"
LOCK_DIR="$COMMON_DIR/task-center-write.lock"
LOCK_OWNED=0

if [[ -f "$SOURCE_ARG/templates/task-center/TASK-CENTER.md" ]]; then SOURCE_ROOT="$SOURCE_ARG/templates/task-center"
elif [[ -f "$SOURCE_ARG/TASK-CENTER.md" ]]; then SOURCE_ROOT="$SOURCE_ARG"
else die "template source is missing TASK-CENTER.md: $SOURCE_ARG"; fi
for asset in TASK-CENTER.md task-file.md INDEX.md scripts/task.sh scripts/task.ps1 .task-center/version .task-center/next-id; do
  [[ -f "$SOURCE_ROOT/$asset" ]] || die "template source is missing required asset: $SOURCE_ROOT/$asset"
done
TOOL_VERSION="$(awk -F: '$1 == "tool-version" {sub(/^[[:space:]]+/,"",$2); print $2; exit}' "$SOURCE_ROOT/.task-center/version")"
SCHEMA_VERSION="$(awk -F: '$1 == "schema-version" {sub(/^[[:space:]]+/,"",$2); print $2; exit}' "$SOURCE_ROOT/.task-center/version")"
[[ -n "$TOOL_VERSION" && -n "$SCHEMA_VERSION" ]] || die 'version file must define tool-version and schema-version.'
SOURCE_REVISION="local-source"
SOURCE_REPO=""
probe="$SOURCE_ROOT"
if command -v cygpath >/dev/null 2>&1; then probe="$(cygpath -u "$probe")"; fi
while [[ ! -e "$probe/.git" ]]; do
  parent="$(dirname "$probe")"
  [[ "$parent" != "$probe" ]] || break
  probe="$parent"
done
if [[ -e "$probe/.git" ]]; then
  if git -c "safe.directory=$probe" -C "$probe" rev-parse --verify HEAD >/dev/null 2>&1; then
    if [[ -z "$(git -c "safe.directory=$probe" -C "$probe" status --porcelain --untracked-files=all)" ]]; then
      SOURCE_REVISION="$(git -c "safe.directory=$probe" -C "$probe" rev-parse HEAD)"
    else
      printf 'Warning: template checkout has local changes; recording source-revision=local-source.\n' >&2
    fi
  fi
fi

gitc() { git -c core.quotepath=false -C "$1" "${@:2}"; }

worktree_lines() { gitc "$GIT_ROOT" worktree list --porcelain; }
get_main_worktree() { canonical_existing "$(worktree_lines | awk '/^worktree / {sub(/^worktree /, ""); print; exit}')"; }
get_worktree_for_branch() {
  local result
  result="$(worktree_lines | awk -v wanted="refs/heads/$BRANCH" '
    /^worktree / { path=substr($0,10); next }
    /^branch / && $2 == wanted { print path; count++ }
    END { if (count > 1) exit 2 }')" || return 2
  if [[ -n "$result" ]]; then canonical_existing "$result"; fi
}
remote_branch_refs() { git -C "$GIT_ROOT" for-each-ref --format='%(refname)' "refs/remotes/*/$BRANCH"; }
read_registered_path() {
  local registration="$REGISTRATION" first=''
  if [[ ! -f "$registration" ]]; then
    registration="$RUNTIME_DIR/registration"
    [[ -f "$registration" ]] || return 0
  fi
  IFS= read -r first < "$registration" || true
  if [[ "$first" == format=* ]]; then sed -n 's/^path=//p' "$registration" | head -n 1
  else printf '%s\n' "$first"; fi
}

write_registration() {
  local path="$1" tmp="$REGISTRATION.$$.tmp"
  if command -v cygpath >/dev/null 2>&1; then path="$(cygpath -am "$path")"; fi
  mkdir -p "$(dirname "$REGISTRATION")"
  printf '%s\n' "$path" >"$tmp" || die 'could not write task-center registration.'
  mv -f "$tmp" "$REGISTRATION"
}

add_exclude() {
  local path="$1" main="$2" exclude relative pattern
  case "$path" in "$main"/*) relative="${path#"$main"/}" ;; *) die "task-center worktree must be under the main worktree for info/exclude: $path" ;; esac
  relative="${relative//\\//}"
  pattern="/$relative/"
  exclude="$(git -C "$GIT_ROOT" rev-parse --git-path info/exclude)"
  [[ "$exclude" = /* ]] || exclude="$GIT_ROOT/$exclude"
  mkdir -p "$(dirname "$exclude")"
  touch "$exclude"
  grep -Fqx -- "$pattern" "$exclude" || { [[ ! -s "$exclude" ]] || printf '\n' >>"$exclude"; printf '%s\n' "$pattern" >>"$exclude"; }
}

release_lock() {
  (( LOCK_OWNED )) || return 0
  LOCK_OWNED=0
  rm -f -- "$LOCK_DIR/owner" || true
  rmdir -- "$LOCK_DIR" 2>/dev/null || true
}

enter_lock() {
  mkdir -p "$RUNTIME_DIR"
  if ! mkdir -- "$LOCK_DIR" 2>/dev/null; then
    printf 'Task-center write lock is held: %s\n' "$LOCK_DIR" >&2
    cat "$LOCK_DIR/owner" >&2 2>/dev/null || true
    die 'confirm the owner process has ended before removing the lock directory.'
  fi
  LOCK_OWNED=1
  trap 'release_lock' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  printf 'identity=setup-task-center\npid=%s\nstarted=%s\ncommand=setup-task-center\n' \
    "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$LOCK_DIR/owner" || die 'could not write task-center lock owner.'
}

version_file() {
  printf 'tool-version: %s\nschema-version: %s\nsource-revision: %s\n' "$TOOL_VERSION" "$SCHEMA_VERSION" "$SOURCE_REVISION" >"$1/.task-center/version"
}

seed_assets() {
  local target="$1"
  mkdir -p "$target/scripts" "$target/.task-center" "$target/docs/tasks/archive"
  cp "$SOURCE_ROOT/TASK-CENTER.md" "$target/TASK-CENTER.md"
  cp "$SOURCE_ROOT/scripts/task.sh" "$target/scripts/task.sh"
  cp "$SOURCE_ROOT/scripts/task.ps1" "$target/scripts/task.ps1"
  cp "$SOURCE_ROOT/.task-center/next-id" "$target/.task-center/next-id"
  version_file "$target"
  if [[ "${2:-}" != preserve-tasks ]]; then cp "$SOURCE_ROOT/INDEX.md" "$target/docs/tasks/INDEX.md"; fi
}

task_files() {
  local root="$1" f
  shopt -s nullglob
  for f in "$root"/docs/tasks/*.md "$root"/docs/tasks/archive/*.md; do
    [[ "$(basename "$f")" == INDEX.md || "$(basename "$f")" == INDEX.legacy* ]] && continue
    printf '%s\n' "$f"
  done
  shopt -u nullglob
}

field_value() {
  local file="$1" key="$2"
  awk -v key="$key" '
    index($0, key "：") == 1 {
      if (found++) exit 2
      sub("^" key "：", "")
      sub(/[[:space:]]+#.*/, "")
      sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "")
      value=$0
    }
    END { if (found > 1) exit 2; print value }
  ' "$file"
}

task_id() {
  local name
  name="$(basename "$1")"
  [[ "$name" =~ ^([0-9]+)-.+\.md$ ]] || die "unknown task filename: $name"
  local number="$((10#${BASH_REMATCH[1]}))"
  (( number > 0 )) || die "task numbers must be positive: $name"
  printf '%s\n' "$number"
}

assert_task_inventory() {
  local root="$1" f id heading seen=''
  local ids=()
  while IFS= read -r f; do
    id="$(task_id "$f")"
    heading="$(sed -nE 's/^#[[:space:]]+任务[[:space:]]+#0*([0-9]+)[[:space:]]+(.+)$/\1/p' "$f" | head -n 1)"
    [[ -n "$heading" && "$((10#$heading))" == "$id" ]] || die "filename and heading number differ: $f"
    ids+=("$id")
  done < <(task_files "$root")
  if ((${#ids[@]})); then
    seen="$(printf '%s\n' "${ids[@]}" | awk 'seen[$0]++ { print $0 }')"
    [[ -z "$seen" ]] || die "duplicate task numbers across active/archive data: $seen"
  fi
}

assert_clean_layout() {
  local path="$1" expected_branch="$2" status file root_count main main_head merge_code
  [[ "$(gitc "$path" branch --show-current)" == "$expected_branch" ]] || die "worktree is not on expected branch $expected_branch: $path"
  status="$(gitc "$path" status --porcelain)"
  [[ -z "$status" ]] || die "task-center worktree has staged, modified, or untracked content: $path"
  local required=(TASK-CENTER.md scripts/task.sh scripts/task.ps1 .task-center/version .task-center/next-id docs/tasks/INDEX.md)
  local tracked
  tracked="$(gitc "$path" ls-tree -r --name-only HEAD)"
  for file in "${required[@]}"; do grep -Fqx -- "$file" <<<"$tracked" || die "task center is missing required asset: $file"; done
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    case "$file" in TASK-CENTER.md|scripts/task.sh|scripts/task.ps1|.task-center/version|.task-center/next-id|docs/tasks/INDEX.md|docs/tasks/[0-9]*.md|docs/tasks/archive/[0-9]*.md) ;;
      *) die "task center contains an asset outside the allowlist: $file" ;;
    esac
  done <<<"$tracked"
  root_count="$(gitc "$path" rev-list --max-parents=0 HEAD | awk 'NF { n++ } END { print n+0 }')"
  [[ "$root_count" -eq 1 ]] || die 'task-center history does not have a single orphan root; use repair.'
  main="$(get_main_worktree)"
  main_head="$(gitc "$main" rev-parse HEAD)"
  if gitc "$path" merge-base HEAD "$main_head" >/dev/null; then
    die 'task-center history shares an ancestor with the project code history; use repair.'
  else
    merge_code=$?
    [[ "$merge_code" -eq 1 ]] || die 'could not verify the task-center and project history boundary.'
  fi
  assert_task_inventory "$path"
}

run_current_task_check() {
  local path="$1" expected_branch="$2"
  if ! (cd "$path" && TASK_CENTER_PATH="$path" TASK_BRANCH="$expected_branch" bash scripts/task.sh check); then
    die 'repair output failed current task.sh check; refusing branch cutover.'
  fi
  printf 'Current task.sh check passed; continuing cutover.\n'
}

find_candidate() {
  local env_path registered registered_root matches main
  if [[ -n "${TASK_CENTER_PATH:-}" ]]; then
    env_path="$(canonical_existing "$TASK_CENTER_PATH")" || die "TASK_CENTER_PATH does not exist: $TASK_CENTER_PATH"
    [[ "$(gitc "$env_path" branch --show-current)" == "$BRANCH" ]] || die "TASK_CENTER_PATH is not on $BRANCH"
    printf '%s\n' "$env_path"; return 0
  fi
  registered="$(read_registered_path)"
  if [[ -n "$registered" ]]; then registered="$(normalize_path "$registered")"; fi
  if [[ -n "$registered" && -d "$registered" ]]; then
    registered_root="$(git -C "$registered" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$registered_root" ]]; then registered_root="$(canonical_existing "$registered_root" 2>/dev/null || true)"; fi
    if [[ "$registered_root" == "$registered" && "$(gitc "$registered" branch --show-current 2>/dev/null || true)" == "$BRANCH" ]]; then
      printf '%s\n' "$registered"; return 0
    fi
    printf 'Registered task-center path is stale; searching this clone for %s.\n' "$BRANCH" >&2
  fi
  matches="$(get_worktree_for_branch)" || die "multiple worktrees are checked out on $BRANCH."
  if [[ -n "$matches" ]]; then printf '%s\n' "$matches"; return 0; fi
  return 1
}

branch_head() {
  git -C "$GIT_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" && git -C "$GIT_ROOT" rev-parse "refs/heads/$BRANCH" || true
}

install_or_register() {
  local candidate main destination head build
  local remote_refs
  remote_refs="$(remote_branch_refs)"
  [[ -z "$remote_refs" ]] || printf '发现远端跟踪分支（不读取、不修改）：\n%s\n' "$remote_refs" >&2
  candidate="$(find_candidate || true)"
  main="$(get_main_worktree)"
  [[ -n "$main" ]] || die 'Git did not report a main worktree.'
  if [[ -n "$candidate" ]]; then
    printf 'Found task-center worktree: %s [%s]\n' "$candidate" "$BRANCH"
    assert_clean_layout "$candidate" "$BRANCH"
    add_exclude "$candidate" "$main"
    head="$(gitc "$candidate" rev-parse HEAD)"
    write_registration "$candidate" "$head"
    printf 'Task center is ready; existing protocol, scripts, and task data were preserved.\n'
    return
  fi
  destination="$(canonical_target "$main/.worktrees/$WORKTREE_NAME")"
  [[ ! -e "$destination" ]] || die "target path exists but is not a registered task-center worktree; refusing to overwrite: $destination"
  head="$(branch_head)"
  if [[ -n "$head" ]]; then
    mkdir -p "$(dirname "$destination")"
    git -C "$GIT_ROOT" worktree add "$destination" "$BRANCH"
    assert_clean_layout "$destination" "$BRANCH"
  else
    build="$RUNTIME_DIR/bootstrap-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    git -C "$GIT_ROOT" worktree add --detach "$build" HEAD
    if ! gitc "$build" switch --orphan "$BRANCH"; then die "orphan branch creation failed; inspect temporary worktree: $build"; fi
    seed_assets "$build"
    gitc "$build" add -- TASK-CENTER.md scripts/task.sh scripts/task.ps1 .task-center/version .task-center/next-id docs/tasks/INDEX.md
    gitc "$build" commit -m 'docs(tasks): initialize local task center'
    assert_clean_layout "$build" "$BRANCH"
    mkdir -p "$(dirname "$destination")"
    git -C "$GIT_ROOT" worktree move "$build" "$destination" || die "installation built but could not move into place; worktree remains at $build"
  fi
  add_exclude "$destination" "$main"
  head="$(gitc "$destination" rev-parse HEAD)"
  write_registration "$destination" "$head"
  printf 'Task center installed: %s [%s]\n' "$destination" "$BRANCH"
}

index_remark() {
  local index="$1" id="$2"
  # With the leading pipe, column 2 is the task id and column 8 is the seventh data column (备注).
  [[ -f "$index" ]] || return 0
  awk -F'|' -v wanted="$id" '
    $2 ~ /^[[:space:]]*[0-9]+[[:space:]]*$/ { n=$2; gsub(/[[:space:]]/,"",n); if(n==wanted){gsub(/^[[:space:]]+|[[:space:]]+$/, "", $8); print $8; exit} }
  ' "$index"
}

migrate_task() {
  local source="$1" destination="$2" remark="$3" name id title status owner current role priority depends branch pr external note block_from block_reason waiting created body expected_role final_status
  name="$(basename "$source")"; id="$(task_id "$source")"
  title="$(sed -nE 's/^#[[:space:]]+任务[[:space:]]+#0*[0-9]+[[:space:]]+(.+)$/\1/p' "$source" | head -n 1)"
  status="$(field_value "$source" 状态)" || die "duplicate 状态 field: $source"
  owner="$(field_value "$source" owner)" || die "duplicate owner field: $source"
  role="$(field_value "$source" 角色)" || die "duplicate 角色 field: $source"
  current="$(field_value "$source" 当前负责人)" || die "duplicate 当前负责人 field: $source"
  block_from="$(field_value "$source" 阻塞前状态)" || die "duplicate blocked state field: $source"
  block_reason="$(field_value "$source" 阻塞原因)" || die "duplicate blocked reason field: $source"
  waiting="$(field_value "$source" 等待对象)" || die "duplicate waiting field: $source"
  priority="$(field_value "$source" 优先级)"; depends="$(field_value "$source" 依赖)"
  branch="$(field_value "$source" 分支)"; pr="$(field_value "$source" PR)"
  external="$(field_value "$source" 外部)"; note="$(field_value "$source" 备注)"
  created="$(field_value "$source" 创建)"
  case "$status" in 待办|已认领|进行中|待审核|待测试|待合并|已完成|阻塞|已取消) ;; *) die "unknown status in task $id: $status" ;; esac
  if [[ "$status" == 待办 ]]; then owner='未认领'
  elif [[ -z "$owner" || "$owner" == '-' || "$owner" == '无' || ( "$status" != 已完成 && "$status" != 已取消 && "$owner" == 未认领 ) ]]; then owner='待补'; fi
  if [[ "$status" == 待办 || "$status" == 已完成 || "$status" == 已取消 ]]; then current='未分配'
  elif [[ -z "$current" || "$current" == '-' || "$current" == '无' || "$current" == 未分配 ]]; then
    case "$status" in
      已认领|进行中) if [[ -n "$owner" && "$owner" != 未认领 ]]; then current="$owner"; else current='待补'; printf '待补 TC-%04d: owner/current负责人 cannot be inferred\n' "$id" >&2; fi ;;
      待审核|待测试|待合并|阻塞) current='待补'; printf '待补 TC-%04d: current负责人 cannot be inferred from legacy data\n' "$id" >&2 ;;
      *) current='待补' ;;
    esac
  fi
  if [[ "$status" == 阻塞 ]]; then
    [[ -n "$block_from" ]] || { block_from='待补'; printf '待补 TC-%04d: blocked-from state\n' "$id" >&2; }
    [[ -n "$block_reason" ]] || { block_reason='待补：旧格式未记录阻塞原因'; printf '待补 TC-%04d: blocked reason\n' "$id" >&2; }
    [[ -n "$waiting" ]] || { waiting='待补'; printf '待补 TC-%04d: waiting object\n' "$id" >&2; }
  else block_from='无'; block_reason='无'; waiting='无'; fi
  expected_role=''
  case "$status" in 已认领|进行中) expected_role='开发' ;; 待审核) expected_role='审核' ;; 待测试) expected_role='测试' ;; 待合并) expected_role='维护者' ;; esac
  if [[ -n "$role" && -n "$expected_role" && "$role" != "$expected_role" ]]; then printf '待核对 TC-%04d: legacy role %s differs from status-derived role %s\n' "$id" "$role" "$expected_role" >&2; fi
  [[ -n "$created" ]] || { created='待补'; printf '待补 TC-%04d: creation metadata\n' "$id" >&2; }
  [[ -n "$priority" ]] || priority='中'; [[ -n "$depends" ]] || depends='无'
  [[ -n "$branch" ]] || branch='无'; [[ -n "$pr" ]] || pr='无'; [[ -n "$external" ]] || external='无'
  [[ -n "$note" ]] || note="$remark"; [[ -n "$note" ]] || note='-'
  body="$(sed -n '/^##[[:space:]]/,$p' "$source")"
  [[ -n "$body" ]] || body=$'## 迁移记录\n\n（旧任务文件未包含正文分区）'
  {
    printf '# 任务 #%s %s\n\n状态：%s\nowner：%s\n当前负责人：%s\n优先级：%s\n依赖：%s\n分支：%s\nPR：%s\n外部：%s\n备注：%s\n阻塞前状态：%s\n阻塞原因：%s\n等待对象：%s\n创建：%s\n\n' \
      "$id" "$title" "$status" "${owner:-未认领}" "$current" "$priority" "$depends" "$branch" "$pr" "$external" "$note" "$block_from" "$block_reason" "$waiting" "$created"
    if [[ -n "$role" ]]; then printf '## 旧角色字段（迁移核对）\n\n%s\n\n' "$role"; fi
    printf '%s\n' "$body"
  } >"$destination"
}

scan_migration() {
  local center="$1" f id status current owner role expected_role missing=0 count=0 stem oldname path
  local ids=() historical
  while IFS= read -r f; do
    count=$((count + 1)); id="$(task_id "$f")"; ids+=("$id")
    status="$(field_value "$f" 状态)" || die "duplicate 状态 field in $f"
    current="$(field_value "$f" 当前负责人)" || die "duplicate current负责人 field in $f"
    owner="$(field_value "$f" owner)" || die "duplicate owner field in $f"
    role="$(field_value "$f" 角色)" || die "duplicate 角色 field in $f"
    case "$status" in 待办|已认领|进行中|待审核|待测试|待合并|已完成|阻塞|已取消) ;; *) die "unknown status in task $id: $status" ;; esac
    if [[ "$f" == */archive/* && "$status" != 已完成 && "$status" != 已取消 ]]; then die "non-terminal task is in archive and needs manual review: $f"; fi
    if [[ -z "$current" && "$status" =~ ^(待审核|待测试|待合并|阻塞)$ ]]; then printf '  TC-%04d: current负责人 cannot be inferred; marked 待补\n' "$id"; missing=$((missing + 1)); fi
    if [[ "$status" == 阻塞 ]]; then
      [[ -n "$(field_value "$f" 阻塞前状态)" ]] || { printf '  TC-%04d: blocked-from state missing\n' "$id"; missing=$((missing + 1)); }
      [[ -n "$(field_value "$f" 阻塞原因)" ]] || { printf '  TC-%04d: blocked reason missing\n' "$id"; missing=$((missing + 1)); }
      [[ -n "$(field_value "$f" 等待对象)" ]] || { printf '  TC-%04d: waiting object missing\n' "$id"; missing=$((missing + 1)); }
    fi
    expected_role=''
    case "$status" in 已认领|进行中) expected_role='开发' ;; 待审核) expected_role='审核' ;; 待测试) expected_role='测试' ;; 待合并) expected_role='维护者' ;; esac
    if [[ -n "$role" && -n "$expected_role" && "$role" != "$expected_role" ]]; then printf '  TC-%04d: legacy role differs from status-derived role (%s / %s)\n' "$id" "$role" "$expected_role"; missing=$((missing + 1)); fi
    if [[ -z "$(field_value "$f" 创建)" ]]; then printf '  TC-%04d: creation metadata missing\n' "$id"; missing=$((missing + 1)); fi
  done < <(task_files "$center")
  if ((${#ids[@]})); then
    oldname="$(printf '%s\n' "${ids[@]}" | awk 'seen[$0]++ { print $0 }')"
    [[ -z "$oldname" ]] || die "duplicate active/archive task number(s): $oldname"
  fi
  printf '  task files: %s; fields requiring follow-up: %s\n' "$count" "$missing"
  historical="$(gitc "$center" log --all --format= --name-only -- docs/tasks | awk '
    /^docs\/tasks\/(archive\/)?[0-9]+-.+\.md$/ { p=$0; sub(/^docs\/tasks\/(archive\/)?/,"",p); id=p; sub(/-.*/,"",id); name=p; sub(/^[0-9]+-/,"",name); sub(/\.md$/,"",name); if(id in seen && seen[id]!=name){print id ": " seen[id] " / " name; bad=1} seen[id]=name }
    END { if(bad) exit 1 }')" || die "historical task number reuse requires a maintainer mapping: $historical"
  printf '%s\n' "$historical"
}

generate_index() {
  local root="$1" out f id pad title status owner current note i j swap
  local -a active_files=() active_ids=()
  out="$root/docs/tasks/INDEX.md"
  while IFS= read -r f; do
    [[ "$f" == */archive/* ]] && continue
    id="$(task_id "$f")"
    active_files+=("$f"); active_ids+=("$id")
  done < <(task_files "$root")
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
      f="${active_files[i]}"; id="${active_ids[i]}"; pad="$(printf '%04d' "$id")"
      title="$(sed -nE 's/^#[[:space:]]+任务[[:space:]]+#0*[0-9]+[[:space:]]+(.+)$/\1/p' "$f" | head -n 1)"
      status="$(field_value "$f" 状态)"; owner="$(field_value "$f" owner)"; current="$(field_value "$f" 当前负责人)"; note="$(field_value "$f" 备注)"
      printf '| TC-%s | %s | %s | %s | %s | %s |\n' "$pad" "$title" "$status" "$owner" "$current" "$note"
    done
    printf '\n## 已完成\n\n已归档任务保存在 `archive/`，编号永久保留。\n'
  } >"$out"
}

migration_file_name() {
  local source="$1" name stem id slug pad
  name="$(basename "$source")"; stem="${name%.md}"; id="$(task_id "$source")"; slug="${stem#*-}"
  slug="$(printf '%s' "$slug" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-|-$//g')"
  [[ -n "$slug" ]] || slug="task-$id"
  pad="$(printf '%04d' "$id")"
  printf '%s-%s.md\n' "$pad" "$slug"
}

repair_task_center() {
  local center old_head main status tasks unknown backup_dir stamp bundle manifest new_path temp_branch backup_branch path f id remark dest max_id=0 files='' upstream
  local local_assets=()
  center="$(find_candidate)" || die "local $BRANCH worktree was not found; run setup first."
  old_head="$(gitc "$center" rev-parse HEAD)"
  status="$(gitc "$center" status --porcelain)"
  main="$(get_main_worktree)"
  printf 'Repair preview: %s [%s]\n  current commit: %s\n' "$center" "$BRANCH" "$old_head"
  tasks="$(scan_migration "$center")"; printf '%s\n' "$tasks"
  unknown="$(gitc "$center" ls-tree -r --name-only HEAD | while IFS= read -r f; do case "$f" in TASK-CENTER.md|scripts/task.sh|scripts/task.ps1|.task-center/version|.task-center/next-id|docs/tasks/INDEX.md|docs/tasks/[0-9]*.md|docs/tasks/archive/[0-9]*.md) ;; *) printf '%s\n' "$f" ;; esac; done)"
  [[ -z "$unknown" ]] || { printf '  new orphan history will omit allowlist-external paths (retained in bundle):\n%s\n' "$unknown"; }
  upstream="$(git -C "$GIT_ROOT" config --get "branch.$BRANCH.remote" || true)"
  [[ -z "$upstream" ]] || printf '  local upstream: %s (repair clears only this local setting)\n' "$upstream"
  local remote_refs
  remote_refs="$(remote_branch_refs)"
  [[ -z "$remote_refs" ]] || printf '  remote-tracking refs (diagnostic only; not read or changed):\n%s\n' "$remote_refs"
  for path in TASK-CENTER.md scripts/task.sh scripts/task.ps1; do
    if [[ -f "$center/$path" && -f "$SOURCE_ROOT/$path" ]]; then
      local_hash="$(git hash-object "$center/$path")"; source_hash="$(git hash-object "$SOURCE_ROOT/$path")"
      if [[ "$local_hash" != "$source_hash" ]]; then local_assets+=("$path"); fi
    fi
  done
  if ((${#local_assets[@]})); then
    printf '  local asset differences (new orphan uses the selected source; bundle keeps the old versions):\n'
    for path in "${local_assets[@]}"; do git diff --no-index -- "$SOURCE_ROOT/$path" "$center/$path" || [[ $? -eq 1 ]]; done
  fi
  local root_count main_head merge_code
  root_count="$(gitc "$center" rev-list --max-parents=0 HEAD | awk 'NF { n++ } END { print n+0 }')"
  main_head="$(gitc "$main" rev-parse HEAD)"
  if gitc "$center" merge-base HEAD "$main_head" >/dev/null; then
    printf '  history boundary: old task history shares an ancestor with project code; repair will cut that link.\n'
  else
    merge_code=$?
    [[ "$merge_code" -eq 1 ]] || die 'could not verify the task-center and project history boundary.'
    if (( root_count == 1 )); then printf '  history boundary: old task history already has an independent orphan root; repair will create a new root.\n'
    else printf '  history boundary: found %s history roots; repair will create a new orphan root.\n' "$root_count"; fi
  fi
  if [[ -n "$status" ]]; then printf '  BLOCKER: worktree has staged, modified, or untracked files.\n' >&2; fi
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  backup_dir="${BACKUP_DIR:-${TEMP:-${TMPDIR:-/tmp}}/task-center-backups}"
  backup_dir="$(normalize_path "$backup_dir")"
  backup_dir="$(canonical_future "$backup_dir")" || die "backup directory parent does not exist: $backup_dir"
  case "$backup_dir" in "$GIT_ROOT"|"$GIT_ROOT"/*) die "backup directory must be outside the clone: $backup_dir" ;; esac
  bundle="$backup_dir/task-center-$stamp.bundle"
  manifest="$backup_dir/task-center-$stamp.manifest.txt"
  printf '  verified bundle: %s (created only with --apply)\n' "$bundle"
  if (( APPLY == 0 )); then printf 'Preview made no branch, task-data, or registration changes. Re-run with --repair --apply to execute.\n'; return; fi
  [[ -z "$status" ]] || die 'repair stopped because the task-center worktree has uncommitted content.'
  enter_lock
  [[ "$(gitc "$center" rev-parse HEAD)" == "$old_head" ]] || die 'old branch changed after preview; run repair preview again.'
  mkdir -p "$backup_dir"
  git -C "$GIT_ROOT" bundle create "$bundle" "refs/heads/$BRANCH"
  git -C "$GIT_ROOT" bundle verify "$bundle"
  {
    printf 'branch=%s\nhead=%s\nworktree=%s\ncreated-utc=%s\ntracked-paths:\n' "$BRANCH" "$old_head" "$center" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gitc "$center" ls-tree -r --name-only HEAD
  } >"$manifest"
  new_path="$(canonical_target "$(dirname "$center")/task-center-repaired-$stamp")"
  [[ ! -e "$new_path" ]] || die "repair target already exists; refusing to overwrite: $new_path"
  temp_branch="task-center-repair-$stamp"
  git -C "$GIT_ROOT" worktree add --detach "$new_path" HEAD
  gitc "$new_path" switch --orphan "$temp_branch"
  seed_assets "$new_path" preserve-tasks
  while IFS= read -r f; do
    id="$(task_id "$f")"; remark="$(index_remark "$center/docs/tasks/INDEX.md" "$id")"
    status="$(field_value "$f" 状态)"
    local migrated_name
    migrated_name="$(migration_file_name "$f")"
    if [[ "$f" == */archive/* || "$status" == 已完成 || "$status" == 已取消 ]]; then dest="$new_path/docs/tasks/archive/$migrated_name"; else dest="$new_path/docs/tasks/$migrated_name"; fi
    mkdir -p "$(dirname "$dest")"
    migrate_task "$f" "$dest" "$remark"
    (( id > max_id )) && max_id=$id
  done < <(task_files "$center")
  generate_index "$new_path"
  printf '%s\n' "$((max_id + 1))" >"$new_path/.task-center/next-id"
  gitc "$new_path" add -- TASK-CENTER.md scripts/task.sh scripts/task.ps1 .task-center/version .task-center/next-id docs/tasks
  gitc "$new_path" commit -m 'docs(tasks): migrate local task center'
  assert_clean_layout "$new_path" "$temp_branch"
  run_current_task_check "$new_path" "$temp_branch"
  local new_head
  new_head="$(gitc "$new_path" rev-parse HEAD)"
  backup_branch="$BRANCH-backup-$stamp"
  gitc "$center" switch --detach "$old_head"
  git -C "$GIT_ROOT" branch -m "$BRANCH" "$backup_branch"
  if ! git -C "$GIT_ROOT" branch -m "$temp_branch" "$BRANCH"; then
    git -C "$GIT_ROOT" branch -m "$backup_branch" "$BRANCH" || true
    gitc "$center" switch "$BRANCH" || true
    die "cutover failed; old branch restore attempted, bundle: $bundle"
  fi
  [[ -z "$upstream" ]] || git -C "$GIT_ROOT" branch --unset-upstream "$backup_branch"
  add_exclude "$new_path" "$main"
  write_registration "$new_path" "$new_head"
  printf 'Repair complete: %s [%s]\nOld history retained as %s. Bundle and manifest: %s / %s\n' "$new_path" "$BRANCH" "$backup_branch" "$bundle" "$manifest"
  printf 'Recovery in a new clone: <template-source>/scripts/setup-task-center.sh --repo <new-clone> --source <template-source> --restore-bundle "%s"\n' "$bundle"
  printf 'Then run task.sh init and task.sh list to confirm registration and task visibility.\n'
  print_agent_guidance
}

restore_bundle() {
  local bundle="$1" main destination refs tasks head
  [[ -f "$bundle" ]] || die "bundle does not exist: $bundle"
  refs="$(git -C "$GIT_ROOT" bundle list-heads "$bundle")"
  grep -Eq "[[:space:]]refs/heads/$BRANCH$" <<<"$refs" || die "bundle does not contain refs/heads/$BRANCH."
  [[ -z "$(branch_head)" ]] || die "local branch $BRANCH already exists; restore will not overwrite it."
  main="$(get_main_worktree)"
  destination="$main/.worktrees/$WORKTREE_NAME"
  [[ ! -e "$destination" ]] || die "restore target exists; refusing to overwrite: $destination"
  enter_lock
  git -C "$GIT_ROOT" bundle verify "$bundle"
  git -C "$GIT_ROOT" fetch --no-tags "$bundle" "refs/heads/$BRANCH:refs/heads/$BRANCH"
  mkdir -p "$(dirname "$destination")"
  git -C "$GIT_ROOT" worktree add "$destination" "$BRANCH"
  assert_task_inventory "$destination"
  tasks=0
  while IFS= read -r f; do tasks=$((tasks + 1)); done < <(task_files "$destination")
  add_exclude "$destination" "$main"
  head="$(gitc "$destination" rev-parse HEAD)"
  write_registration "$destination" "$head"
  printf 'Restored %s task files to %s [%s].\n' "$tasks" "$destination" "$BRANCH"
  printf 'The bundle was restored without rewriting its contents. Run repair preview before changing legacy data.\n'
}

if [[ -n "$RESTORE_BUNDLE" ]]; then restore_bundle "$RESTORE_BUNDLE"; print_agent_guidance
elif (( REPAIR )); then repair_task_center
else enter_lock; install_or_register; print_agent_guidance
fi
