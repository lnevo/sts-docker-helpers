#!/usr/bin/env bash
# Focused lever sweep after South→Neville unclog.
# Sessions 3-10 from hart_session2_locked; ~15 cases around remaining knobs
# (max_new / gate / repo / coke both vs stagger / gen_loose).
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
WF_TMP="${BACKUPS_DIR}/session_editor/_post_south_levers.workflow.json"
LOG="${BACKUPS_DIR}/session_editor/traffic_post_south_levers_$(date +%Y%m%d_%H%M%S).log"
SCORES="${LOG}.scores"
TO_SESSION="${1:-10}"

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container not running" >&2
  exit 1
fi

# Guard: workflow must already have South→Neville
python3 - <<PY
import json
from pathlib import Path
r = json.loads(Path("${WF_SRC}").read_text())
ok = any(
    (s.get("function") == "auto_assign_locals"
     and (s.get("params") or {}).get("station") == "South Yard"
     and (s.get("params") or {}).get("destination") == "station::Neville Island")
    for s in r.get("steps", [])
)
if not ok:
    raise SystemExit("WF missing South→Neville Island assign — abort")
print("WF ok: South→Neville present, steps=", len(r.get("steps", [])))
PY

deploy() {
  docker cp "${DIAGNOSTICS_DIR}/traffic_from_session2.php" \
    "${WEB_CID}:/var/www/html/sts/traffic_from_session2.php"
  docker cp "${STS_DOCKER}/sts/session_helpers.php" \
    "${WEB_CID}:/var/www/html/sts/session_helpers.php"
  docker cp "${STS_DOCKER}/sts/operational_steps_catalog.php" \
    "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.php"
}

patch_case() {
  local max_new="$1" repo="$2" gate="$3" coke_mode="$4"
  python3 - <<PY
import json
from copy import deepcopy
from pathlib import Path

src = Path("${WF_SRC}")
dst = Path("${WF_TMP}")
recipe = json.loads(src.read_text())
steps = recipe.get("steps", [])
max_new, repo, gate, coke_mode = "${max_new}", "${repo}", "${gate}", "${coke_mode}"

# Strip any existing coke stagger guards (idempotent)
clean = []
for step in steps:
    fn = step.get("function", "")
    var = ((step.get("params") or {}).get("variable") or "").strip()
    if fn == "if_then" and var in ("session_is_even", "session_is_odd"):
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
        p["percent"] = "100"

if coke_mode == "stagger":
    out = []
    for step in steps:
        fn = step.get("function", "")
        ship = (step.get("params") or {}).get("shipment", "")
        if fn == "generate_orders" and ship == "COKE-CLEV-BULK":
            out.append({
                "function": "if_then",
                "params": {"variable": "session_is_even", "operator": "=", "value": "1", "_coke_skip": True},
                "catalog_description": "Skip CLEV bulk on even sessions (stagger).",
            })
            out.append(step)
            continue
        if fn == "generate_orders" and ship == "COKE-USS-BULK":
            out.append({
                "function": "if_then",
                "params": {"variable": "session_is_odd", "operator": "=", "value": "1", "_coke_skip": True},
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
else:
    recipe["steps"] = steps

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
  local umi="$1" uma="$2" uamin="$3" uamax="$4"
  local cmi="$5" cma="$6" camin="$7" camax="$8"
  docker exec "${WEB_CID}" php -r "
chdir('/var/www/html/sts');
require 'open_db.php';
\$d=open_db();
mysqli_query(\$d, \"UPDATE shipments SET min_interval=${umi}, max_interval=${uma}, min_amount=${uamin}, max_amount=${uamax} WHERE code='COKE-USS-BULK'\");
mysqli_query(\$d, \"UPDATE shipments SET min_interval=${cmi}, max_interval=${cma}, min_amount=${camin}, max_amount=${camax} WHERE code='COKE-CLEV-BULK'\");
echo \"coke USS ${umi}-${uma}x${uamin}-${uamax} / CLEV ${cmi}-${cma}x${camin}-${camax}\\n\";
"
}

loosen_general() {
  docker exec "${WEB_CID}" php -r '
chdir("/var/www/html/sts");
require "open_db.php";
$d=open_db();
mysqli_query($d, "UPDATE shipments SET min_interval=min_interval+1, max_interval=max_interval+1
  WHERE code NOT LIKE \"COKE%\" AND min_interval < 40");
echo "loosen_general rows=".mysqli_affected_rows($d)."\n";
'
}

patch_criteria() {
  docker exec -u www-data "${WEB_CID}" php -r '
chdir("/var/www/html/sts");
require "open_db.php";
$d=open_db();
@mysqli_query($d, "UPDATE NVL SET pickup=0 WHERE step_number=10");
@mysqli_query($d, "UPDATE D749 SET pickup=0 WHERE step_number=90");
'
}

run_case() {
  local id="$1"; shift
  local max_new="$1" repo="$2" gate="$3" coke_mode="$4" loose="$5"
  local umi="$6" uma="$7" uamin="$8" uamax="$9"
  local cmi="${10}" cma="${11}" camin="${12}" camax="${13}"

  echo "==> CASE ${id}: new=${max_new} repo=${repo} gate=${gate} mode=${coke_mode} loose=${loose} USS=${umi}-${uma}x${uamin}-${uamax} CLEV=${cmi}-${cma}x${camin}-${camax}" \
    | tee -a "${LOG}"

  "${BIN_DIR}/apply_hart_seed.sh" --sql-file "${LOCK}" >> "${LOG}" 2>&1
  patch_criteria
  patch_case "${max_new}" "${repo}" "${gate}" "${coke_mode}"
  apply_coke "${umi}" "${uma}" "${uamin}" "${uamax}" "${cmi}" "${cma}" "${camin}" "${camax}" | tee -a "${LOG}"
  if [[ "${loose}" == "1" ]]; then
    loosen_general | tee -a "${LOG}"
  fi

  OUT="$(docker exec -u www-data "${WEB_CID}" php /var/www/html/sts/traffic_from_session2.php \
    "${TO_SESSION}" hart_session 2>&1)" || true
  echo "${OUT}" >> "${LOG}"
  echo "${OUT}" | grep -E '^(SCORE|HOLDUP|NOTES)=' | tee -a "${LOG}"
  JSON_LINE="$(echo "${OUT}" | grep '^TRAFFIC_JSON=' | sed 's/^TRAFFIC_JSON=//' || true)"
  echo "RESULT ${id}: $(echo "${OUT}" | grep '^SCORE=' || true)" | tee -a "${LOG}"
  if [[ -n "${JSON_LINE}" ]]; then
    echo "${id}|new=${max_new}/repo=${repo}/gate=${gate}/mode=${coke_mode}/loose=${loose}/USS=${umi}-${uma}x${uamin}-${uamax}/CLEV=${cmi}-${cma}x${camin}-${camax}|${JSON_LINE}" >> "${SCORES}"
  fi
  echo | tee -a "${LOG}"
}

deploy
: > "${SCORES}"
echo "==> Post-South focused lever sweep (sessions 3-${TO_SESSION})" | tee "${LOG}"
echo "    Skip known losers (fill<100, gateNONE, max22 flood, extreme asym)." | tee -a "${LOG}"
echo "    Log: ${LOG}" | tee -a "${LOG}"
echo | tee -a "${LOG}"

# Baseline = current winner stack
run_case baseline_both22     14 65 30 both    0   2 2 2 2   2 2 2 2
# max_new neighborhood
run_case max12_both22        12 65 30 both    0   2 2 2 2   2 2 2 2
run_case max16_both22        16 65 30 both    0   2 2 2 2   2 2 2 2
run_case max18_both22        18 65 30 both    0   2 2 2 2   2 2 2 2
# gate neighborhood
run_case gate25_both22       14 65 25 both    0   2 2 2 2   2 2 2 2
run_case gate35_both22       14 65 35 both    0   2 2 2 2   2 2 2 2
# repo neighborhood
run_case repo50_both22       14 50 30 both    0   2 2 2 2   2 2 2 2
run_case repo85_both22       14 85 30 both    0   2 2 2 2   2 2 2 2
# gen_loose (helped pre-South; re-check)
run_case loose_both22        14 65 30 both    1   2 2 2 2   2 2 2 2
run_case loose_max12         12 65 30 both    1   2 2 2 2   2 2 2 2
# coke variants (both still, amounts)
run_case both_half           14 65 30 both    0   1 2 1 2   1 2 1 2
run_case both_hot            14 65 30 both    0   1 1 3 3   1 1 3 3
run_case both_quiet          14 65 30 both    0   3 3 1 2   3 3 1 2
# stagger control (confirm still unnecessary)
run_case stag_ctrl           14 65 30 stagger 0   1 2 2 4   1 2 2 4
# combo: mild gate up + max12
run_case max12_gate35        12 65 35 both    0   2 2 2 2   2 2 2 2

echo "==> Ranking" | tee -a "${LOG}"
python3 - <<PY | tee -a "${LOG}"
import json
from pathlib import Path
rows=[]
for line in Path("${SCORES}").read_text().splitlines():
    sid, meta, js = line.split("|", 2)
    d = json.loads(js)
    mr, mp = int(d.get("coke_mr") or 0), int(d.get("coke_mp") or 0)
    bal = 1.0 - abs(mr - mp) / max(1, mr + mp)
    rows.append((float(d.get("score") or 0), bal, sid, meta, d))
rows.sort(key=lambda x: (x[0], x[1]), reverse=True)
print(f"{'score':>6} {'bal':>5} {'MR':>3}/{'MP':<3} {'coke':>4} {'Sth':>4} {'NVLO':>4} {'unf':>4} {'holdup':14s} id")
for score, bal, sid, meta, d in rows:
    print(f"{score:6.1f} {bal:5.2f} {d.get('coke_mr',0):3d}/{d.get('coke_mp',0):<3d} "
          f"{d.get('coke_avg',0):4.1f} {d.get('sth_avg',0):4.0f} {d.get('nvlo_avg',0):4.1f} "
          f"{d.get('unf_avg',0):4.1f} {str(d.get('holdup','')):14s} {sid}")
if rows:
    b = rows[0]
    print(f"BEST={b[2]} score={b[0]:.1f} bal={b[1]:.2f} Sth={b[4].get('sth_avg'):.0f} meta={b[3]}")
PY

echo
echo "Log: ${LOG}"
