#!/usr/bin/env bash
# Aggressive lever sweep from locked end-of-session-3 → sessions 4..TO.
# Restores hart_session3_locked for each case; ranks by SCORE; optionally
# re-runs the winner and leaves it live on the DB (--apply-best).
#
# Usage:
#   run_traffic_from_s3_levers.sh [to_session=10] [--apply-best]
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

LOCK="$(sts_resolve_session_end_dump 3 || true)"
if [[ -z "${LOCK}" ]]; then
  echo "Missing end-of-session-3 dump (tried hart_session_post3[_locked], hart_session3[_locked])" >&2
  exit 1
fi
WF_SRC="${BACKUPS_DIR}/session_editor/hart_session.workflow.json"
WF_TMP="${BACKUPS_DIR}/session_editor/_traffic_s3_levers.workflow.json"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="${BACKUPS_DIR}/session_editor/traffic_s3_levers_${STAMP}.log"
SCORES="${LOG}.scores"
TO_SESSION=10
APPLY_BEST=0

for arg in "$@"; do
  case "${arg}" in
    --apply-best) APPLY_BEST=1 ;;
    ''|*[!0-9]*) ;;
    *) TO_SESSION="${arg}" ;;
  esac
done

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container not running" >&2
  exit 1
fi
if [[ ! -f "${LOCK}" ]]; then
  echo "Missing lock: ${LOCK}" >&2
  exit 1
fi
if [[ ! -f "${WF_SRC}" ]]; then
  echo "Missing workflow: ${WF_SRC}" >&2
  exit 1
fi

deploy() {
  docker cp "${DIAGNOSTICS_DIR}/traffic_from_session2.php" \
    "${WEB_CID}:/var/www/html/sts/traffic_from_session2.php"
  docker cp "${STS_DOCKER}/sts/drain_unfilled_orders.php" \
    "${WEB_CID}:/var/www/html/sts/drain_unfilled_orders.php" 2>/dev/null || true
  docker cp "${STS_DOCKER}/sts/operational_steps_catalog.php" \
    "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.php"
  docker cp "${STS_DOCKER}/sts/session_helpers.php" \
    "${WEB_CID}:/var/www/html/sts/session_helpers.php"
  docker cp "${STS_DOCKER}/sts/generate_order_helpers.php" \
    "${WEB_CID}:/var/www/html/sts/generate_order_helpers.php"
}

# Patch WF: gate/max_new/repo/cancel/fill. cancel=OFF removes the step.
patch_case() {
  local max_new="$1" repo="$2" gate="$3" cancel="$4" fill="$5" order="$6"
  python3 - <<PY
import json
from copy import deepcopy
from pathlib import Path

src = Path("${WF_SRC}")
dst = Path("${WF_TMP}")
recipe = json.loads(src.read_text())
steps = recipe.get("steps", [])
max_new, repo, gate = "${max_new}", "${repo}", "${gate}"
cancel, fill, order = "${cancel}", "${fill}", "${order}"

# Strip stagger guards if any
clean = []
for step in steps:
    fn = step.get("function", "")
    var = ((step.get("params") or {}).get("variable") or "").strip()
    if fn == "if_then" and var in ("session_is_even", "session_is_odd"):
        continue
    if fn == "cancel_orders" and cancel == "OFF":
        continue
    clean.append(deepcopy(step))
steps = clean

for step in steps:
    fn = step.get("function", "")
    p = step.setdefault("params", {})
    if fn == "generate_orders" and not (p.get("shipment") or "").strip():
        p["max_new"] = max_new
        p["max_unfilled"] = "" if gate == "NONE" else gate
    if fn == "reposition_empties":
        p["percent"] = repo
    if fn == "fill_orders":
        p["percent"] = fill
    if fn == "cancel_orders" and cancel != "OFF":
        # cancel format THRESH:TARGET
        th, tg = cancel.split(":", 1)
        p["threshold"] = th
        p["target"] = tg
        p["order"] = order
        p["keep_coke"] = "1"

recipe["steps"] = steps
recipe["name"] = "hart_session_s3_levers"
dst.write_text(json.dumps(recipe, indent=4) + "\n")
print(f"patched steps={len(steps)} new={max_new} repo={repo} gate={gate} cancel={cancel} fill={fill} order={order}")
PY
  # Deploy temp WF into editor dir name used by harness
  cp -f "${WF_TMP}" "${BACKUPS_DIR}/session_editor/hart_session_s3_levers.workflow.json"
}

# coke amounts: amin-amax (both USS+CLEV bulk)
patch_coke() {
  local amin="$1" amax="$2"
  docker exec -u www-data "${WEB_CID}" php -r "
chdir('/var/www/html/sts');
require 'open_db.php';
\$d = open_db();
\$amin = ${amin}; \$amax = ${amax};
mysqli_query(\$d, \"UPDATE shipments SET min_amount=\$amin, max_amount=\$amax WHERE code IN ('COKE-USS-BULK','COKE-CLEV-BULK')\");
\$r = mysqli_query(\$d, \"SELECT code,min_amount,max_amount FROM shipments WHERE code LIKE 'COKE-%BULK'\");
while (\$row = mysqli_fetch_assoc(\$r)) {
  echo \$row['code'].' '.\$row['min_amount'].'-'.\$row['max_amount'].PHP_EOL;
}
"
}

# Re-apply scarce-lane floors after restore (idempotent GREATEST)
patch_scarce() {
  local sql="${MIGRATIONS_DIR}/tune_fleet_scarce_lanes.sql"
  if [[ ! -f "${sql}" ]]; then
    sql="${HELPERS_ROOT}/migrations/tune_fleet_scarce_lanes.sql"
  fi
  if [[ -f "${sql}" ]]; then
    local db_cid
    db_cid="$("${COMPOSE[@]}" ps -q db)"
    docker exec -i "${db_cid}" mariadb -usts -psts sts_db3 < "${sql}" >/dev/null 2>&1 \
      || docker exec -i "${db_cid}" mysql -usts -psts sts_db3 < "${sql}" >/dev/null 2>&1 \
      || true
  fi
}

restore_baseline() {
  "${BIN_DIR}/apply_hart_seed.sh" --sql-file "${LOCK}" >/tmp/s3_restore.log 2>&1
  tail -3 /tmp/s3_restore.log
  patch_scarce
}

run_case() {
  local id="$1" max_new="$2" repo="$3" gate="$4" cancel="$5" fill="$6" order="$7" coke="$8" scarce_env="$9"
  local amin amax
  IFS=- read -r amin amax <<<"${coke}"

  echo "" | tee -a "${LOG}"
  echo "==> CASE ${id}: new=${max_new} repo=${repo} gate=${gate} cancel=${cancel} fill=${fill} order=${order} coke=${coke} scarce=${scarce_env}" | tee -a "${LOG}"

  restore_baseline
  patch_coke "${amin}" "${amax}"
  patch_case "${max_new}" "${repo}" "${gate}" "${cancel}" "${fill}" "${order}"

  local env_prefix=()
  if [[ "${scarce_env}" == "ON" ]]; then
    env_prefix=(-e STS_SCARCE_PAUSE_UNFILLED=35 -e STS_SCARCE_PAUSE_CODES=HC,XM,FM,GA,GD,FC,TA)
  fi

  local OUT
  if [[ ${#env_prefix[@]} -gt 0 ]]; then
    OUT="$(docker exec -u www-data "${env_prefix[@]}" "${WEB_CID}" \
      php /var/www/html/sts/traffic_from_session2.php \
      "${TO_SESSION}" hart_session_s3_levers 2>>"${LOG}")"
  else
    OUT="$(docker exec -u www-data "${WEB_CID}" \
      php /var/www/html/sts/traffic_from_session2.php \
      "${TO_SESSION}" hart_session_s3_levers 2>>"${LOG}")"
  fi
  echo "${OUT}" | tee -a "${LOG}" | grep -E '^(SCORE|HOLDUP|NOTES)=' || true

  local JSON_LINE
  JSON_LINE="$(echo "${OUT}" | grep '^TRAFFIC_JSON=' | sed 's/^TRAFFIC_JSON=//' || true)"
  local SCORE_LINE
  SCORE_LINE="$(echo "${OUT}" | grep '^SCORE=' || true)"
  echo "RESULT ${id}: ${SCORE_LINE}" | tee -a "${LOG}"
  if [[ -n "${JSON_LINE}" ]]; then
    echo "${id}|new=${max_new}/repo=${repo}/gate=${gate}/cancel=${cancel}/fill=${fill}/order=${order}/coke=${coke}/scarce=${scarce_env}|${JSON_LINE}" >> "${SCORES}"
  fi
}

: > "${SCORES}"
{
  echo "==> Traffic lever sweep from hart_session3_locked → sessions 4-${TO_SESSION}"
  echo "    log=${LOG}"
  echo "    wf=${WF_SRC}"
} | tee "${LOG}"

deploy

# -------- Phase 1: baseline + one-at-a-time --------
# baseline (parked WF-ish): gate35 new12 repo65 cancel40:30 oldest fill100 coke2-4 scarce OFF
run_case B00 12 65 35 "40:30" 100 oldest_first "2-4" OFF

# gate sweep
run_case G30 12 65 30 "40:30" 100 oldest_first "2-4" OFF
run_case G40 12 65 40 "40:30" 100 oldest_first "2-4" OFF
run_case G50 12 65 50 "40:30" 100 oldest_first "2-4" OFF
run_case GNONE 12 65 NONE "40:30" 100 oldest_first "2-4" OFF

# max_new sweep
run_case N08 8 65 35 "40:30" 100 oldest_first "2-4" OFF
run_case N16 16 65 35 "40:30" 100 oldest_first "2-4" OFF
run_case N20 20 65 35 "40:30" 100 oldest_first "2-4" OFF

# reposition sweep
run_case R40 12 40 35 "40:30" 100 oldest_first "2-4" OFF
run_case R80 12 80 35 "40:30" 100 oldest_first "2-4" OFF
run_case R100 12 100 35 "40:30" 100 oldest_first "2-4" OFF

# cancel sweep
run_case C_OFF 12 65 35 OFF 100 oldest_first "2-4" OFF
run_case C3525 12 65 35 "35:25" 100 oldest_first "2-4" OFF
run_case C4535 12 65 35 "45:35" 100 oldest_first "2-4" OFF
run_case C_NEW 12 65 35 "40:30" 100 newest_first "2-4" OFF

# coke amount sweep
run_case K23 12 65 35 "40:30" 100 oldest_first "2-3" OFF
run_case K34 12 65 35 "40:30" 100 oldest_first "3-4" OFF
run_case K22 12 65 35 "40:30" 100 oldest_first "2-2" OFF

# scarce pause
run_case S_ON 12 65 35 "40:30" 100 oldest_first "2-4" ON

# fill percent
run_case F80 12 65 35 "40:30" 80 oldest_first "2-4" OFF

# -------- Phase 2: cross top OAT winners (computed) --------
python3 - "${SCORES}" <<'PY' | tee -a "${LOG}"
from pathlib import Path
import json
from collections import defaultdict

scores_path = Path(__import__("sys").argv[1])
rows = []
for line in scores_path.read_text().splitlines():
    if "|" not in line:
        continue
    parts = line.split("|", 2)
    if len(parts) < 3:
        continue
    cid, levers, js = parts
    try:
        data = json.loads(js)
    except Exception:
        continue
    rows.append((float(data.get("score") or -1), cid, levers, data.get("holdup"), data))

rows.sort(reverse=True)
print("\n=== PHASE1 RANKING ===")
for i, (sc, cid, levers, holdup, _) in enumerate(rows[:12], 1):
    print(f"{i:2d}. {sc:5.1f}  {cid:6s}  {levers}  holdup={holdup}")

def parse_levers(s):
    out = {}
    for bit in s.split("/"):
        if "=" in bit:
            k, v = bit.split("=", 1)
            out[k] = v
    return out

top = rows[: max(5, len(rows)//2)]
by = defaultdict(list)
for sc, cid, levers, holdup, data in top:
    L = parse_levers(levers)
    for k, v in L.items():
        by[k].append((sc, v))

best = {}
for k, pairs in by.items():
    bucket = defaultdict(list)
    for sc, v in pairs:
        bucket[v].append(sc)
    best[k] = max(bucket.items(), key=lambda kv: sum(kv[1]) / len(kv[1]))[0]
    print(f"factor_best {k}={best[k]} (from top)")

Path("/tmp/s3_lever_best_factors.json").write_text(json.dumps(best, indent=2))
cross = []
if rows:
    L = parse_levers(rows[0][2])
    cross.append(("XBEST", L))
cross.append(("XFACT", best))
cross.append(("XCAP", {
    "new": best.get("new", "16"),
    "repo": best.get("repo", "80"),
    "gate": "50",
    "cancel": best.get("cancel", "40:30"),
    "fill": "100",
    "order": best.get("order", "oldest_first"),
    "coke": best.get("coke", "2-3"),
    "scarce": best.get("scarce", "OFF"),
}))
cross.append(("XTIGHT", {
    "new": "12",
    "repo": best.get("repo", "65"),
    "gate": "30",
    "cancel": "35:25",
    "fill": "100",
    "order": "oldest_first",
    "coke": best.get("coke", "2-3"),
    "scarce": "ON",
}))
Path("/tmp/s3_lever_cross.json").write_text(json.dumps(cross, indent=2))
print("cross cases:", [c[0] for c in cross])
PY

while IFS= read -r line; do
  # shell-friendly: id|new|repo|gate|cancel|fill|order|coke|scarce
  [[ -z "${line}" ]] && continue
  IFS='|' read -r xid xnew xrepo xgate xcancel xfill xorder xcoke xscarce <<<"${line}"
  run_case "${xid}" "${xnew}" "${xrepo}" "${xgate}" "${xcancel}" "${xfill}" "${xorder}" "${xcoke}" "${xscarce}"
done < <(python3 - <<'PY'
import json
from pathlib import Path
cross = json.loads(Path("/tmp/s3_lever_cross.json").read_text())
seen = set()
for cid, L in cross:
    key = tuple(L.get(k, "") for k in ("new","repo","gate","cancel","fill","order","coke","scarce"))
    if key in seen:
        continue
    seen.add(key)
    print("|".join([
        cid,
        str(L.get("new", "12")),
        str(L.get("repo", "65")),
        str(L.get("gate", "35")),
        str(L.get("cancel", "40:30")),
        str(L.get("fill", "100")),
        str(L.get("order", "oldest_first")),
        str(L.get("coke", "2-4")),
        str(L.get("scarce", "OFF")),
    ]))
PY
)

# -------- Final ranking + apply best --------
python3 - "${SCORES}" <<'PY' | tee -a "${LOG}"
from pathlib import Path
import json

rows = []
for line in Path(__import__("sys").argv[1]).read_text().splitlines():
    parts = line.split("|", 2)
    if len(parts) < 3:
        continue
    cid, levers, js = parts
    try:
        data = json.loads(js)
    except Exception:
        continue
    rows.append((float(data.get("score") or -1), cid, levers, data.get("holdup"), data))
rows.sort(reverse=True)
print("\n=== FINAL RANKING ===")
for i, (sc, cid, levers, holdup, data) in enumerate(rows[:15], 1):
    print(f"{i:2d}. {sc:5.1f}  {cid:6s}  holdup={holdup}  {levers}")
    print(f"     coke_avg={data.get('coke_avg'):.1f} nvlo={data.get('nvlo_avg'):.1f} gen={data.get('gen_avg'):.1f} fill={data.get('fill_avg'):.1f} unf={data.get('unf_avg'):.1f}")

if not rows:
    raise SystemExit("no scores")
best = rows[0]
Path("/tmp/s3_lever_winner.json").write_text(json.dumps({
    "score": best[0],
    "id": best[1],
    "levers": best[2],
    "holdup": best[3],
    "metrics": {k: best[4].get(k) for k in (
        "coke_avg","coke_var","nvlo_avg","nvlo_empty","d749s_avg","d749o_avg",
        "gen_avg","fill_avg","unf_avg","coke_mr","coke_mp"
    )},
}, indent=2))
print(f"\nWINNER: {best[1]} score={best[0]:.1f}")
print(best[2])
PY

if [[ "${APPLY_BEST}" -eq 1 ]]; then
  echo "" | tee -a "${LOG}"
  echo "==> Re-running WINNER onto live DB (leave sessions for review)" | tee -a "${LOG}"
  python3 - <<'PY'
import json
from pathlib import Path
w = json.loads(Path("/tmp/s3_lever_winner.json").read_text())
L = {}
for bit in w["levers"].split("/"):
    if "=" in bit:
        k, v = bit.split("=", 1)
        L[k] = v
# emit shell exports
print(f"WIN_ID={w['id']}")
print(f"WIN_NEW={L.get('new','12')}")
print(f"WIN_REPO={L.get('repo','65')}")
print(f"WIN_GATE={L.get('gate','35')}")
print(f"WIN_CANCEL={L.get('cancel','40:30')}")
print(f"WIN_FILL={L.get('fill','100')}")
print(f"WIN_ORDER={L.get('order','oldest_first')}")
print(f"WIN_COKE={L.get('coke','2-4')}")
print(f"WIN_SCARCE={L.get('scarce','OFF')}")
print(f"WIN_SCORE={w['score']}")
PY
  # shellcheck disable=SC1091
  eval "$(python3 - <<'PY'
import json
from pathlib import Path
w = json.loads(Path("/tmp/s3_lever_winner.json").read_text())
L = {}
for bit in w["levers"].split("/"):
    if "=" in bit:
        k, v = bit.split("=", 1)
        L[k] = v
print(f"WIN_ID={w['id']}")
print(f"WIN_NEW={L.get('new','12')}")
print(f"WIN_REPO={L.get('repo','65')}")
print(f"WIN_GATE={L.get('gate','35')}")
print(f"WIN_CANCEL={L.get('cancel','40:30')}")
print(f"WIN_FILL={L.get('fill','100')}")
print(f"WIN_ORDER={L.get('order','oldest_first')}")
print(f"WIN_COKE={L.get('coke','2-4')}")
print(f"WIN_SCARCE={L.get('scarce','OFF')}")
print(f"WIN_SCORE={w['score']}")
PY
)"
  # Patch canonical hart_session workflow to winner levers for live leave-behind
  python3 - <<PY
import json
from copy import deepcopy
from pathlib import Path

src = Path("${WF_SRC}")
recipe = json.loads(src.read_text())
steps = recipe.get("steps", [])
cancel = "${WIN_CANCEL}"
order = "${WIN_ORDER}"
gate = "${WIN_GATE}"
max_new = "${WIN_NEW}"
repo = "${WIN_REPO}"
fill = "${WIN_FILL}"

clean = []
for step in steps:
    fn = step.get("function", "")
    if fn == "cancel_orders" and cancel == "OFF":
        continue
    clean.append(deepcopy(step))
steps = clean
for step in steps:
    fn = step.get("function", "")
    p = step.setdefault("params", {})
    if fn == "generate_orders" and not (p.get("shipment") or "").strip():
        p["max_new"] = max_new
        p["max_unfilled"] = "" if gate == "NONE" else gate
    if fn == "reposition_empties":
        p["percent"] = repo
    if fn == "fill_orders":
        p["percent"] = fill
    if fn == "cancel_orders" and cancel != "OFF":
        th, tg = cancel.split(":", 1)
        p["threshold"] = th
        p["target"] = tg
        p["order"] = order
        p["keep_coke"] = "1"
recipe["steps"] = steps
src.write_text(json.dumps(recipe, indent=4) + "\n")
# keep start_session in sync
Path(str(src).replace("hart_session.workflow.json", "start_session.workflow.json")).write_text(
    json.dumps(recipe, indent=4) + "\n"
)
print("updated hart_session + start_session workflow to winner levers")
PY
  # Also write temp WF and re-run onto live
  patch_case "${WIN_NEW}" "${WIN_REPO}" "${WIN_GATE}" "${WIN_CANCEL}" "${WIN_FILL}" "${WIN_ORDER}"
  restore_baseline
  IFS=- read -r amin amax <<<"${WIN_COKE}"
  patch_coke "${amin}" "${amax}"
  env_prefix=()
  if [[ "${WIN_SCARCE}" == "ON" ]]; then
    env_prefix=(-e STS_SCARCE_PAUSE_UNFILLED=35 -e STS_SCARCE_PAUSE_CODES=HC,XM,FM,GA,GD,FC,TA)
  fi
  # Use canonical hart_session after patch
  cp -f "${WF_SRC}" "${BACKUPS_DIR}/session_editor/hart_session_s3_levers.workflow.json"
  if [[ ${#env_prefix[@]} -gt 0 ]]; then
    docker exec -u www-data "${env_prefix[@]}" "${WEB_CID}" \
      php /var/www/html/sts/traffic_from_session2.php \
      "${TO_SESSION}" hart_session 2>>"${LOG}" | tee -a "${LOG}" | grep -E '^(SCORE|HOLDUP|NOTES|s[0-9])' || true
  else
    docker exec -u www-data "${WEB_CID}" \
      php /var/www/html/sts/traffic_from_session2.php \
      "${TO_SESSION}" hart_session 2>>"${LOG}" | tee -a "${LOG}" | grep -E '^(SCORE|HOLDUP|NOTES|s[0-9])' || true
  fi
  docker exec -u www-data "${WEB_CID}" php -r '
  chdir("/var/www/html/sts"); require "open_db.php"; $d=open_db();
  $r=mysqli_query($d,"SELECT setting_value FROM settings WHERE setting_name=\"session_nbr\"");
  echo "LIVE_SESSION=".mysqli_fetch_row($r)[0]."\n";
  '
  echo "Winner left live. Score was ${WIN_SCORE} (${WIN_ID}). Log: ${LOG}" | tee -a "${LOG}"
fi

echo ""
echo "Done. Scores: ${SCORES}"
echo "Log: ${LOG}"
