#!/usr/bin/env bash
set -euo pipefail
if ((BASH_VERSINFO[0] < 4)); then
  printf 'task-center: Bash 4 or newer is required.\n' >&2
  exit 8
fi
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python="${TASK_PYTHON:-python3}"
if command -v cygpath >/dev/null 2>&1 && [[ "$python" =~ ^[A-Za-z]: ]]; then
  python="$(cygpath -u "$python")"
fi
if ! command -v "$python" >/dev/null 2>&1; then
  printf 'task-center: configure TASK_PYTHON with supported CPython; no automatic installation.\n' >&2
  exit 8
fi
arguments=("$@")
entry="$script_dir/task.py"
if command -v cygpath >/dev/null 2>&1 && [[ "$(uname -s)" =~ ^(MINGW|MSYS|CYGWIN) ]]; then
  entry="$(cygpath -w "$entry")"
  for ((i=0;i<${#arguments[@]};i++)); do
    case "${arguments[i]}" in
      --root|--request-file|--query-file|--response-file|--actor-file|--isolation-file|--repo|--destination|--policy-file|--runtime-dir|--backup-dir|--plan-file|--approval-file)
        ((i+=1))
        if ((i<${#arguments[@]})); then arguments[i]="$(cygpath -w "${arguments[i]}")"; fi ;;
    esac
  done
  for variable in TASK_CENTER_PATH TASK_RUNTIME_PATH; do
    if [[ -n "${!variable:-}" ]]; then printf -v "$variable" '%s' "$(cygpath -w "${!variable}")"; export "$variable"; fi
  done
fi
export PYTHONDONTWRITEBYTECODE=1
exec "$python" -I -B "$entry" "${arguments[@]}"
