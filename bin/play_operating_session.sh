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

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container is not running. Start with:" >&2
  echo "  cd ${STS_DOCKER} && docker compose --profile build up -d" >&2
  exit 1
fi

echo "==> Syncing warm-start scripts into web container"
for php in warm_start_helpers.php play_operating_session.php simulate_ck1_weigh.php track_scale_helpers.php; do
  docker cp "${HELPERS_ROOT}/sts/${php}" "${WEB_CID}:/var/www/html/sts/${php}"
done

ARGS=()
if [[ -n "${BACKUP_NAME}" ]]; then
  ARGS+=(--backup="${BACKUP_NAME}")
fi

echo "==> Playing operating session"
docker exec "${WEB_CID}" php /var/www/html/sts/play_operating_session.php "${ARGS[@]}"

SESSION="$(
  docker exec "${WEB_CID}" php -r \
    'chdir("/var/www/html/sts"); require "open_db.php"; $d=open_db(); $r=mysqli_query($d,"SELECT setting_value FROM settings WHERE setting_name=\"session_nbr\""); echo mysqli_fetch_row($r)[0];'
)"
echo "==> Session ${SESSION} play complete (STG-SCULLY backlog ready for next begin_session)"
