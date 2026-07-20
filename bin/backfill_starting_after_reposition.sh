#!/usr/bin/env bash
# Recreate "Starting" station/wheel reports for sessions 3–10 at the new
# workflow point (after fill + reposition), without rebuilding switchlists.
#
# For each session N:
#   1. Restore hart_session{N-1} (end of previous)
#   2. Run load_unload → coke gates/orders → generate → fill → reposition
#   3. Snap Starting into session_N (replaces prior Starting via compact)
#   4. Restore hart_session{N} so End-of-session DB state is unchanged
#
# Live DB is snapshotted first and restored to hart_session20 (or --live dump).
#
# Usage:
#   bin/backfill_starting_after_reposition.sh           # sessions 3-10
#   bin/backfill_starting_after_reposition.sh 3 4       # only 3-4
#   bin/backfill_starting_after_reposition.sh 3 10 --live hart_session20
set -euo pipefail
_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

FROM_SESSION="${1:-3}"
TO_SESSION="${2:-10}"
LIVE_DUMP="${3:-}"
if [[ "${LIVE_DUMP}" == "--live" ]]; then
  LIVE_DUMP="${4:-hart_session20}"
elif [[ -z "${LIVE_DUMP}" ]]; then
  LIVE_DUMP="hart_session20"
fi

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "STS web container is not running." >&2
  exit 1
fi

DIAG="${DIAGNOSTICS_DIR}/backfill_post_reposition_starting.php"
UNDO_NAME="rewind_undo_starting_repo_backfill_$(date +%Y%m%d_%H%M%S)"

if [[ ! -f "${DIAG}" ]]; then
  echo "Missing ${DIAG}" >&2
  exit 1
fi

echo "==> Safety dump live DB → ${BACKUPS_DIR}/${UNDO_NAME}"
"${BIN_DIR}/snapshot_session_db.sh" --name "${UNDO_NAME}"

docker cp "${DIAG}" "${WEB_CID}:/tmp/backfill_post_reposition_starting.php"

for n in $(seq "${FROM_SESSION}" "${TO_SESSION}"); do
  prev=$((n - 1))
  dump="$(sts_resolve_session_end_dump "${prev}" || true)"
  end_dump="$(sts_resolve_session_end_dump "${n}" || true)"
  if [[ -z "${dump}" || ! -f "${dump}" ]]; then
    echo "MISSING start dump for session ${prev} — skip session ${n}" >&2
    continue
  fi
  if [[ -z "${end_dump}" || ! -f "${end_dump}" ]]; then
    echo "MISSING end dump for session ${n} — skip session ${n}" >&2
    continue
  fi

  echo ""
  echo "==> Session ${n}: restore end of ${prev} (${dump##*/})"
  "${BIN_DIR}/apply_hart_seed.sh" --sql-file "${dump}" >/tmp/backfill_repo_start_${n}.log

  echo "==> Session ${n}: load_unload…reposition + snap Starting"
  docker exec -u www-data "${WEB_CID}" php /tmp/backfill_post_reposition_starting.php "${n}"

  echo "==> Session ${n}: restore end dump (${end_dump##*/}) — leave End reports as-is"
  "${BIN_DIR}/apply_hart_seed.sh" --sql-file "${end_dump}" >/tmp/backfill_repo_end_${n}.log
done

LIVE_PATH="${BACKUPS_DIR}/${LIVE_DUMP}"
if [[ ! -f "${LIVE_PATH}" ]]; then
  echo "MISSING live restore ${LIVE_PATH}; restoring undo ${UNDO_NAME}" >&2
  LIVE_PATH="${BACKUPS_DIR}/${UNDO_NAME}"
fi

echo ""
echo "==> Restore live DB → ${LIVE_PATH##*/}"
"${BIN_DIR}/apply_hart_seed.sh" --sql-file "${LIVE_PATH}" >/tmp/backfill_repo_live.log
docker exec "${WEB_CID}" php -r '
require "/var/www/html/sts/open_db.php";
$d=open_db();
$r=mysqli_fetch_row(mysqli_query($d,"SELECT setting_value FROM settings WHERE setting_name=\"session_nbr\""));
echo "restored live session_nbr=", $r[0] ?? "?", "\n";
'

echo "==> Summary"
export SESSIONS_ROOT="${BACKUPS_DIR}/session_state/sessions"
export FROM_SESSION TO_SESSION
python3 <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ["SESSIONS_ROOT"])
lo = int(os.environ["FROM_SESSION"])
hi = int(os.environ["TO_SESSION"])
for n in range(lo, hi + 1):
    m = root / f"session_{n}" / "manifest.json"
    if not m.exists():
        print(f"session_{n}: missing manifest")
        continue
    data = json.loads(m.read_text())
    st = [(r.get("info"), r.get("file"), (r.get("generated_at") or "")[:19]) for r in data.get("station_reports", [])]
    print(f"session_{n}: {st}")
PY

echo "Done. Undo dump: ${BACKUPS_DIR}/${UNDO_NAME}"
