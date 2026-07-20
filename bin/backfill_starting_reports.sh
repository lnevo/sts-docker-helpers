#!/usr/bin/env bash
# Rename old Starting reports → Pre, then create post-load_unload Starting
# (and refresh End of session) for sessions 3–10 without replaying recipes.
#
# Usage:
#   bin/backfill_starting_reports.sh           # sessions 3-10
#   bin/backfill_starting_reports.sh 3 4       # only sessions 3-4
set -euo pipefail
_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

FROM_SESSION="${1:-3}"
TO_SESSION="${2:-10}"
WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "STS web container is not running." >&2
  exit 1
fi

SESSIONS_ROOT="${BACKUPS_DIR}/session_state/sessions"
DIAG="${DIAGNOSTICS_DIR}/backfill_session_car_reports.php"
DIAG_START="${DIAGNOSTICS_DIR}/backfill_post_load_starting.php"
UNDO_NAME="rewind_undo_starting_backfill_$(date +%Y%m%d_%H%M%S)"

echo "==> Safety dump live DB → ${BACKUPS_DIR}/${UNDO_NAME}"
"${BIN_DIR}/snapshot_session_db.sh" --name "${UNDO_NAME}"

echo "==> Rename Starting → Pre and drop End phases for sessions ${FROM_SESSION}-${TO_SESSION}"
export SESSIONS_ROOT FROM_SESSION TO_SESSION
python3 <<'PY'
import json, re, os
from pathlib import Path
from datetime import datetime, timezone

root = Path(os.environ["SESSIONS_ROOT"])
lo = int(os.environ["FROM_SESSION"])
hi = int(os.environ["TO_SESSION"])
for n in range(lo, hi + 1):
    d = root / f"session_{n}"
    man_path = d / "manifest.json"
    if not man_path.exists():
        print(f"skip session_{n} (no manifest)")
        continue
    data = json.loads(man_path.read_text())
    changed = False
    for key in ("station_reports", "wheel_reports"):
        rows = data.get(key) or []
        keep = []
        for row in rows:
            info = (row.get("info") or "").strip()
            label = (row.get("label") or "").strip()
            if info == "End of session" or label == "End of session":
                f = d / (row.get("file") or "")
                if f.is_file():
                    f.unlink()
                    print(f"  session_{n}: removed {f.name}")
                changed = True
                continue
            if info == "Starting" or label == "Starting":
                row["info"] = "Pre"
                row["label"] = "Pre"
                changed = True
                f = d / (row.get("file") or "")
                if f.is_file():
                    html = f.read_text(encoding="utf-8", errors="replace")
                    html2 = html.replace("— Starting —", "— Pre —")
                    html2 = html2.replace(">Starting<", ">Pre<")
                    html2 = re.sub(
                        r"(Station Car Report|Wheel Report)\s+[—-]\s+Starting",
                        r"\1 — Pre",
                        html2,
                    )
                    if html2 != html:
                        f.write_text(html2, encoding="utf-8")
                        print(f"  session_{n}: retitled {f.name} Starting→Pre")
            keep.append(row)
        data[key] = keep
    for alias in ("station_report.html", "wheel_report.html"):
        ap = d / alias
        if ap.is_file():
            ap.unlink()
    if changed:
        data["updated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00")
        man_path.write_text(json.dumps(data, indent=4) + "\n")
        print(f"session_{n}: manifest updated")
    else:
        print(f"session_{n}: no Starting/End changes needed")
PY

docker cp "${DIAG}" "${WEB_CID}:/tmp/backfill_session_car_reports.php"
docker cp "${DIAG_START}" "${WEB_CID}:/tmp/backfill_post_load_starting.php"

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
  "${BIN_DIR}/apply_hart_seed.sh" --sql-file "${dump}" >/tmp/backfill_restore_${n}_start.log

  echo "==> Session ${n}: load_unload + snap Starting"
  docker exec -u www-data "${WEB_CID}" php /tmp/backfill_post_load_starting.php "${n}"

  echo "==> Session ${n}: restore end dump + snap End of session"
  "${BIN_DIR}/apply_hart_seed.sh" --sql-file "${end_dump}" >/tmp/backfill_restore_${n}_end.log
  docker exec -u www-data "${WEB_CID}" php /tmp/backfill_session_car_reports.php snap "${n}" "End of session"
done

echo ""
echo "==> Restore live DB to session 10 end"
LIVE10="$(sts_resolve_session_end_dump 10 || true)"
if [[ -z "${LIVE10}" ]]; then
  echo "Missing end-of-session-10 dump" >&2
  exit 1
fi
"${BIN_DIR}/apply_hart_seed.sh" --sql-file "${LIVE10}" >/tmp/backfill_restore_live.log
docker exec "${WEB_CID}" php -r '
require "/var/www/html/sts/open_db.php";
$d=open_db();
$r=mysqli_fetch_row(mysqli_query($d,"SELECT setting_value FROM settings WHERE setting_name=\"session_nbr\""));
echo "restored live session_nbr=", $r[0] ?? "?", "\n";
'

echo "==> Summary"
export SESSIONS_ROOT FROM_SESSION TO_SESSION
python3 <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ["SESSIONS_ROOT"])
lo = int(os.environ["FROM_SESSION"])
hi = int(os.environ["TO_SESSION"])
for n in range(lo, hi + 1):
    m = root / f"session_{n}" / "manifest.json"
    if not m.exists():
        continue
    data = json.loads(m.read_text())
    st = [(r.get("info"), r.get("file")) for r in data.get("station_reports", [])]
    print(f"session_{n}: {st}")
PY

echo "Done. Undo dump: ${BACKUPS_DIR}/${UNDO_NAME}"
