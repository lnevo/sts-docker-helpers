#!/usr/bin/env bash
# 20-lever traffic diagnosis from locked end-of-session-2.
# Isolates: max_new / reposition / max_unfilled gate / coke demand / IX boost /
# stagger — then ranks by SCORE and tags holdup (shipments/gate, stuck yards,
# reloads, fill lag).
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

LOCK="${BACKUPS_DIR}/hart_session2_locked"
WF_SRC="${BACKUPS_DIR}/session_editor/hart_session.workflow.json"
WF_TMP="${BACKUPS_DIR}/session_editor/_traffic_levers20.workflow.json"
LOG="${BACKUPS_DIR}/session_editor/traffic_s2_levers20_$(date +%Y%m%d_%H%M%S).log"
SCORES="${LOG}.scores"
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
  local fill_pct="$5"
  python3 - <<PY
import json
from pathlib import Path

src = Path("${WF_SRC}")
dst = Path("${WF_TMP}")
recipe = json.loads(src.read_text())
steps = recipe.get("steps", [])
max_new = "${max_new}"
repo = "${repo}"
max_unfilled = "${max_unfilled}"
stagger = "${stagger}" == "1"
fill_pct = "${fill_pct}"

for step in steps:
    fn = step.get("function", "")
    p = step.setdefault("params", {})
    if fn == "generate_orders":
        ship = (p.get("shipment") or "").strip()
        if ship == "":
            p["max_new"] = max_new
            if max_unfilled == "NONE":
                p["max_unfilled"] = ""
            elif max_unfilled:
                p["max_unfilled"] = max_unfilled
    if fn == "reposition_empties":
        p["percent"] = repo
    if fn == "fill_orders" and fill_pct:
        p["percent"] = fill_pct

if stagger:
    out = []
    for step in steps:
        fn = step.get("function", "")
        ship = (step.get("params") or {}).get("shipment", "")
        if fn == "generate_orders" and ship == "COKE-CLEV-BULK":
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
  docker exec "${WEB_CID}" php -r '
chdir("/var/www/html/sts");
require "open_db.php";
$d=open_db();
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

loosen_general() {
  # Lengthen non-coke intervals → fewer general shipments
  docker exec "${WEB_CID}" php -r '
chdir("/var/www/html/sts");
require "open_db.php";
$d=open_db();
$sql = "UPDATE shipments SET min_interval = min_interval + 1,
  max_interval = max_interval + 1
  WHERE code NOT LIKE \"COKE%\" AND min_interval < 40";
mysqli_query($d,$sql);
echo "loosen_general rows=".mysqli_affected_rows($d)."\n";
'
}

tighten_general() {
  docker exec "${WEB_CID}" php -r '
chdir("/var/www/html/sts");
require "open_db.php";
$d=open_db();
$sql = "UPDATE shipments SET min_interval = GREATEST(1, min_interval - 1),
  max_interval = GREATEST(min_interval, max_interval - 1)
  WHERE code NOT LIKE \"COKE%\" AND min_interval < 40";
mysqli_query($d,$sql);
echo "tighten_general rows=".mysqli_affected_rows($d)."\n";
'
}

patch_criteria() {
  # Locked s2 may still have same-yard pickup steps; neutralize after restore.
  docker exec -u www-data "${WEB_CID}" php -r '
chdir("/var/www/html/sts");
require "open_db.php";
$d=open_db();
@mysqli_query($d, "UPDATE NVL SET pickup=0 WHERE step_number=10");
@mysqli_query($d, "UPDATE D749 SET pickup=0 WHERE step_number=90");
'
}

run_case() {
  local id="$1"
  shift
  # args: max_new repo gate stagger fill coke_mi coke_ma coke_amin coke_amax do_ix do_gen_tune
  # do_gen_tune: 0=none 1=tighten 2=loosen
  local max_new="$1" repo="$2" gate="$3" stagger="$4" fill="$5"
  local cmin_i="$6" cmax_i="$7" cmin_a="$8" cmax_a="$9"
  local do_ix="${10}" do_gen="${11}"

  echo "==> CASE ${id}: new=${max_new} repo=${repo} gate=${gate} stag=${stagger} fill=${fill} coke=${cmin_i}-${cmax_i}/${cmin_a}-${cmax_a} ix=${do_ix} gen=${do_gen}" \
    | tee -a "${LOG}"

  "${BIN_DIR}/apply_hart_seed.sh" --sql-file "${LOCK}" >> "${LOG}" 2>&1
  patch_criteria
  patch_workflow "${max_new}" "${repo}" "${gate}" "${stagger}" "${fill}"
  apply_coke "${cmin_i}" "${cmax_i}" "${cmin_a}" "${cmax_a}" | tee -a "${LOG}"
  if [[ "${do_ix}" == "1" ]]; then
    boost_ix | tee -a "${LOG}"
  fi
  if [[ "${do_gen}" == "1" ]]; then
    tighten_general | tee -a "${LOG}"
  elif [[ "${do_gen}" == "2" ]]; then
    loosen_general | tee -a "${LOG}"
  fi

  OUT="$(docker exec -u www-data "${WEB_CID}" php /var/www/html/sts/traffic_from_session2.php \
    "${TO_SESSION}" hart_session 2>&1)" || true
  echo "${OUT}" >> "${LOG}"
  echo "${OUT}" | grep -E '^(SCORE|HOLDUP|NOTES)=' | tee -a "${LOG}"
  SCORE_LINE="$(echo "${OUT}" | grep '^SCORE=' || true)"
  HOLDUP_LINE="$(echo "${OUT}" | grep '^HOLDUP=' || true)"
  JSON_LINE="$(echo "${OUT}" | grep '^TRAFFIC_JSON=' | sed 's/^TRAFFIC_JSON=//' || true)"
  echo "RESULT ${id}: ${SCORE_LINE}" | tee -a "${LOG}"
  echo "         ${HOLDUP_LINE}" | tee -a "${LOG}"
  if [[ -n "${JSON_LINE}" ]]; then
    # id|label_meta|json
    echo "${id}|new=${max_new}/repo=${repo}/gate=${gate}/stag=${stagger}/fill=${fill}/coke=${cmin_i}-${cmax_i}x${cmin_a}-${cmax_a}/ix=${do_ix}/gen=${do_gen}|${JSON_LINE}" >> "${SCORES}"
  fi
  echo | tee -a "${LOG}"
}

deploy
: > "${SCORES}"
echo "==> 20-lever traffic sweep from hart_session2_locked (sessions 3-${TO_SESSION})" | tee "${LOG}"
echo "    Log: ${LOG}" | tee -a "${LOG}"
echo | tee -a "${LOG}"

# id  max_new repo gate  stag fill  cmi cma cmina cmaxa ix gen_tune
# Current workflow defaults after dest-assign work: max_new=16 gate=30 repo=85
run_case cur_16_85_30     16 85  30   0 100  1 2 2 4  0 0
run_case prior_14_100     14 100 NONE 0 100  1 2 2 4  0 0
run_case max10            10 85  30   0 100  1 2 2 4  0 0
run_case max12            12 85  30   0 100  1 2 2 4  0 0
run_case max18            18 85  30   0 100  1 2 2 4  0 0
run_case max22            22 85  30   0 100  1 2 2 4  0 0
run_case repo50           16 50  30   0 100  1 2 2 4  0 0
run_case repo65           16 65  30   0 100  1 2 2 4  0 0
run_case repo100          16 100 30   0 100  1 2 2 4  0 0
run_case gate20           16 85  20   0 100  1 2 2 4  0 0
run_case gate40           16 85  40   0 100  1 2 2 4  0 0
run_case gateNONE         16 85  NONE 0 100  1 2 2 4  0 0
run_case coke_quiet       16 85  30   0 100  2 3 1 2  0 0
run_case coke_hot         16 85  30   0 100  1 1 3 4  0 0
run_case coke_stagger     16 85  30   1 100  1 1 3 3  0 0
run_case ix_boost         16 85  30   0 100  1 2 2 4  1 0
run_case gen_tight        16 85  30   0 100  1 2 2 4  0 1
run_case gen_loose        16 85  30   0 100  1 2 2 4  0 2
run_case fill70           16 85  30   0 70   1 2 2 4  0 0
run_case flood_stag_ix    20 90  35   1 100  1 1 3 4  1 1

echo "==> Ranking" | tee -a "${LOG}"
python3 - <<PY | tee -a "${LOG}"
import json
from pathlib import Path
p = Path("${SCORES}")
rows = []
for line in p.read_text().splitlines():
    parts = line.split("|", 2)
    if len(parts) < 3:
        continue
    sid, meta, js = parts
    d = json.loads(js)
    rows.append((d.get("score", 0), sid, meta, d))
rows.sort(reverse=True)
print(f"{'score':>6}  {'id':16s}  {'holdup':14s}  gen  fill  unf  rld%  Nev  Dem  NVLO  empty  meta")
for score, sid, meta, d in rows:
    wgh = max(0.01, float(d.get("wgh_avg") or 0))
    rldp = 100.0 * float(d.get("rld_avg") or 0) / wgh if wgh > 0.05 else 0.0
    print(
        f"{score:6.1f}  {sid:16s}  {str(d.get('holdup','')):14s}  "
        f"{d.get('gen_avg',0):4.1f} {d.get('fill_avg',0):4.1f} {d.get('unf_avg',0):4.1f} "
        f"{rldp:4.0f}% {d.get('nev_avg',0):4.0f} {d.get('dem_avg',0):4.0f} "
        f"{d.get('nvlo_avg',0):4.1f} {d.get('nvlo_empty',0):5d}  {meta}"
    )
if rows:
    best = rows[0]
    print(f"BEST={best[1]} score={best[0]:.1f} holdup={best[3].get('holdup')}")
    # Holdup vote across all cases
    from collections import Counter
    votes = Counter(d.get("holdup") for _,_,_,d in rows)
    print("HOLDUP_VOTES=" + ", ".join(f"{k}:{v}" for k,v in votes.most_common()))
PY

echo
echo "Log: ${LOG}"
echo "Scores: ${SCORES}"
