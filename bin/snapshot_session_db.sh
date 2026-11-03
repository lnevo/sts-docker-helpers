#!/usr/bin/env bash
# Capture a full, restorable DB snapshot for the current (or a named) operating
# session. Writes a `#`-delimited SQL dump (same format as STS Database
# Maintenance -> Backup) to sts-docker-data/backups/db_session_<N>.
#
# This is the enabling prerequisite for rewind_session.sh: to reliably roll a
# session back you must have captured the DB state at the END of the previous
# session. Run this right before you start generating/working the next session
# (i.e. while session_nbr still reflects the session you just finished).
#
#   snapshot_session_db.sh                 # snapshot current session_nbr
#   snapshot_session_db.sh --name my_dump  # snapshot under a custom name
#   snapshot_session_db.sh --to 10         # label the dump as session 10
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

CUSTOM_NAME=""
FORCE_SESSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) CUSTOM_NAME="$2"; shift 2 ;;
    --to)   FORCE_SESSION="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# shellcheck source=../lib/sts_api.sh
source "${_script_home}/../lib/sts_api.sh"
sts_api_guard || exit 1

# Current operating session number from the settings table.
CURRENT_SESSION="$(sts_session_nbr)"

SESSION_LABEL="${FORCE_SESSION:-${CURRENT_SESSION}}"
BACKUP_NAME="${CUSTOM_NAME:-db_session_${SESSION_LABEL}}"

echo "==> Snapshotting DB (session_nbr=${CURRENT_SESSION}) -> backups/${BACKUP_NAME}"
sts_api POST /admin/backups "{\"name\":\"${BACKUP_NAME}\",\"overwrite\":true}" >/dev/null
_total() { sts_api_raw GET "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["meta"]["total"])'; }
echo "    cars=$(_total '/cars?limit=1') car_orders=$(_total '/car-orders?status=all&limit=1') session_nbr=$(sts_session_nbr)" >&2

SNAP_PATH="${BACKUPS_DIR}/${BACKUP_NAME}"
if [[ -f "${SNAP_PATH}" ]]; then
  echo "==> Wrote ${SNAP_PATH} ($(wc -c < "${SNAP_PATH}" | tr -d ' ') bytes)"
else
  echo "WARNING: expected snapshot not visible at ${SNAP_PATH}" >&2
fi
echo "Done."
