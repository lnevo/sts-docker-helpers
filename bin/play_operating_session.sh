#!/usr/bin/env bash
# Play through one operating session (locals, CK1, bookend staging).
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"


usage() {
  cat <<'EOF'
Usage: play_operating_session.sh [options]

Run D749/NVL/CK1 and session-end bookend staging for the current operating session.
Call after begin_session has opened the session. Leaves STG-SCULLY backlog for the next begin_session.

Options:
  --backup-name NAME   Save backup after play (default: none)
  -h, --help           Show help
EOF
}

BACKUP_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-name) BACKUP_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# shellcheck source=../lib/sts_api.sh
source "${_script_home}/../lib/sts_api.sh"
sts_api_guard || exit 1

BODY='{}'
if [[ -n "${BACKUP_NAME}" ]]; then
  BODY="{\"backup\":\"${BACKUP_NAME}\"}"
fi

echo "==> Playing operating session"
STS_TASK_DROP='^(task [^ ]+ \(.*\) started|task finished)$' \
  sts_task_run POST /admin/sessions/play "${BODY}"

SESSION="$(sts_session_nbr)"
echo "==> Session ${SESSION} play complete (STG-SCULLY backlog ready for next begin_session)"
