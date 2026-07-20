#!/usr/bin/env bash
# Sweep traffic gate levers from locked end-of-session-2 restore.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

LOCK="$(sts_resolve_session_end_dump 2 || true)"
if [[ -z "${LOCK}" ]]; then
  echo "Missing end-of-session-2 dump (tried hart_session_post2[_locked], hart_session2[_locked])" >&2
  exit 1
fi
WF_SRC="${BACKUPS_DIR}/session_editor/hart_session.workflow.json"
WF_TMP="${BACKUPS_DIR}/session_editor/_traffic_sweep.workflow.json"
LOG="${BACKUPS_DIR}/session_editor/traffic_from_s2_sweep_$(date +%Y%m%d_%H%M%S).log"
TO_SESSION="${1:-10}"

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container not running" >&2
  exit 1
fi

deploy() {
  docker cp "${DIAGNOSTICS_DIR}/traffic_from_session2.php" \
    "${WEB_CID}:/var/www/html/sts/traffic_from_session2.php"
  docker cp "${STS_DOCKER}/sts/warm_start_helpers.php" \
    "${WEB_CID}:/var/www/html/sts/warm_start_helpers.php"
  docker cp "${STS_DOCKER}/sts/operational_steps_catalog.php" \
    "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.php"
  docker cp "${STS_DOCKER}/sts/session_helpers.php" \
    "${WEB_CID}:/var/www/html/sts/session_helpers.php"
}

patch_workflow() {
  local max_new="$1"
  local repo="$2"
  local max_unfilled="$3"
  local stagger="$4"
  python3 - <<PY
import json
from copy import deepcopy
from pathlib import Path

src = Path("${WF_SRC}")
dst = Path("${WF_TMP}")
recipe = json.loads(src.read_text())
steps = recipe.get("steps", [])
max_new = "${max_new}"
repo = "${repo}"
max_unfilled = "${max_unfilled}"
stagger = "${stagger}" == "1"

# patch generate/reposition
for step in steps:
    fn = step.get("function", "")
    p = step.setdefault("params", {})
    if fn == "generate_orders":
        ship = (p.get("shipment") or "").strip()
        if ship == "":
            p["max_new"] = max_new
            if max_unfilled:
                p["max_unfilled"] = max_unfilled
    if fn == "reposition_empties":
        p["percent"] = repo

if stagger:
    out = []
    for step in steps:
        fn = step.get("function", "")
        ship = (step.get("params") or {}).get("shipment", "")
        if fn == "generate_orders" and ship == "COKE-CLEV-BULK":
            # When even: jump past this generate (1-based target filled below).
            out.append({
                "function": "if_then",
                "params": {
                    "variable": "session_is_even",
                    "operator": "=",
                    "value": "1",
                    "_coke_skip": True,
                },
                "catalog_description": "Skip CLEV bulk on even sessions (stagger).",
            })
            out.append(step)
            continue
        if fn == "generate_orders" and ship == "COKE-USS-BULK":
            out.append({
                "function": "if_then",
                "params": {
                    "variable": "session_is_odd",
                    "operator": "=",
                    "value": "1",
                    "_coke_skip": True,
                },
                "catalog_description": "Skip USS bulk on odd sessions (stagger).",
            })
            out.append(step)
            continue
        out.append(step)
    for i, step in enumerate(out):
        p = step.get("params") or {}
        if p.get("_coke_skip"):
            # Guard at i, generate at i+1, continue at i+2 → 1-based step i+3
            p["step"] = str(i + 3)
            del p["_coke_skip"]
            step["params"] = p
    recipe["steps"] = out

dst.write_text(json.dumps(recipe, indent=4) + "\n")
PY
  docker cp "${WF_TMP}" \
    "${WEB_CID}:/var/www/html/sts/backups/session_editor/hart_session.workflow.json"
  docker cp "${WF_TMP}" \
    "${WEB_CID}:/var/www/html/sts/backups/session_editor/start_session.workflow.json"
  docker exec "${WEB_CID}" sh -c \
    'echo hart_session.workflow.json > /var/www/html/sts/backups/session_editor/ACTIVE'
}

apply_coke() {
  local min_i="$1" max_i="$2" min_a="$3" max_a="$4"
  docker exec "${WEB_CID}" php -r "
chdir('/var/www/html/sts');
require 'open_db.php';
\$d=open_db();
\$sql=\"UPDATE shipments SET min_interval=${min_i}, max_interval=${max_i}, min_amount=${min_a}, max_amount=${max_a}
      WHERE code IN ('COKE-USS-BULK','COKE-CLEV-BULK')\";
mysqli_query(\$d, \$sql);
echo 'coke bulk -> int ${min_i}-${max_i} amt ${min_a}-${max_a} rows='.mysqli_affected_rows(\$d).\"\\n\";
"
}

boost_ix() {
  # Slightly tighten Demmler/McKeesport-side intervals (IX / Demmler demand)
  docker exec "${WEB_CID}" php -r '
chdir("/var/www/html/sts");
require "open_db.php";
$d=open_db();
# Locations at Demmler (10) or Mckeesport (14)
$sql = "UPDATE shipments s
  JOIN locations load_loc ON load_loc.Id = s.loading_location
  JOIN locations unload_loc ON unload_loc.Id = s.unloading_location
  SET s.min_interval = GREATEST(1, s.min_interval - 1),
      s.max_interval = GREATEST(s.min_interval, s.max_interval - 1)
  WHERE s.code NOT LIKE \"COKE%\"
    AND s.min_interval < 40
    AND (
      load_loc.station IN (10,14) OR unload_loc.station IN (10,14)
      OR s.code LIKE \"IX-%\"
    )";
mysqli_query($d,$sql);
echo "ix boost rows=".mysqli_affected_rows($d)."\n";
'
}

run_case() {
  local id="$1"
  shift
  echo "==> CASE ${id}: $*" | tee -a "${LOG}"
  "${BIN_DIR}/apply_hart_seed.sh" --sql-file "${LOCK}" >> "${LOG}" 2>&1

  # Args encoded after id as named chunks — keep simple positional packages in caller
  # shellcheck disable=SC2068
  local max_new="$1" repo="$2" max_unfilled="$3" stagger="$4"
  local cmin_i="$5" cmax_i="$6" cmin_a="$7" cmax_a="$8"
  local do_ix="$9"

  patch_workflow "${max_new}" "${repo}" "${max_unfilled}" "${stagger}"
  apply_coke "${cmin_i}" "${cmax_i}" "${cmin_a}" "${cmax_a}" | tee -a "${LOG}"
  if [[ "${do_ix}" == "1" ]]; then
    boost_ix | tee -a "${LOG}"
  fi

  OUT="$(docker exec -u www-data "${WEB_CID}" php /var/www/html/sts/traffic_from_session2.php \
    "${TO_SESSION}" hart_session 2>&1)" || true
  echo "${OUT}" >> "${LOG}"
  echo "${OUT}" | tail -n 20 | tee -a "${LOG}"
  SCORE_LINE="$(echo "${OUT}" | grep '^SCORE=' || true)"
  JSON_LINE="$(echo "${OUT}" | grep '^TRAFFIC_JSON=' | sed 's/^TRAFFIC_JSON=//' || true)"
  echo "RESULT ${id}: ${SCORE_LINE}" | tee -a "${LOG}"
  if [[ -n "${JSON_LINE}" ]]; then
    echo "${id}|${JSON_LINE}" >> "${LOG}.scores"
  fi
  echo | tee -a "${LOG}"
}

deploy
: > "${LOG}.scores"
echo "==> Traffic sweep from hart_session2_locked (sessions 3-${TO_SESSION})" | tee "${LOG}"
echo | tee -a "${LOG}"

# id max_new repo max_unfilled stagger cmin_i cmax_i cmin_a cmax_a do_ix
run_case baseline      14 100 "" 0 1 2 2 4 0
run_case coke_steady   14 100 "" 0 2 2 2 3 0
run_case coke_stagger  14 100 "" 1 1 1 3 3 0
run_case gates_up      18 80  35 0 2 2 2 3 0
run_case gates_stag    18 80  35 1 1 1 3 3 0
run_case blend_ix      18 80  30 1 1 1 3 3 1

echo "==> Ranking" | tee -a "${LOG}"
python3 - <<'PY' | tee -a "${LOG}"
import json
from pathlib import Path
p = Path("${LOG}.scores")
rows=[]
for line in p.read_text().splitlines():
    if "|" not in line: continue
    sid, js = line.split("|",1)
    d=json.loads(js)
    rows.append((d.get("score",0), sid, d))
rows.sort(reverse=True)
for score, sid, d in rows:
    print(f"{score:6.1f}  {sid:12s}  coke_avg={d['coke_avg']:.1f} var={d['coke_var']:.1f} nvlo_avg={d['nvlo_avg']:.1f} empty={d['nvlo_empty']} d749s={d['d749s_avg']:.1f} d749o={d['d749o_avg']:.1f} MR/MP={d['coke_mr']}/{d['coke_mp']}")
if rows:
    best=rows[0][1]
    print(f"BEST={best}")
PY

echo
echo "Log: ${LOG}"
