#!/usr/bin/env bash
# Coke-balance + gen_loose plan sweep from locked end-of-session-2.
# Compares odd/even stagger (one lane/session) vs both lanes every session,
# with amount/interval levers aimed at equal MR (CLEV) vs MP (USS) outbound.
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
WF_LIVE="${BACKUPS_DIR}/session_editor/hart_session.workflow.json"
WF_BASE="${BACKUPS_DIR}/session_editor/_coke20_base.workflow.json"
WF_TMP="${BACKUPS_DIR}/session_editor/_coke20_case.workflow.json"
LOG="${BACKUPS_DIR}/session_editor/traffic_s2_coke20_$(date +%Y%m%d_%H%M%S).log"
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
  docker cp "${STS_DOCKER}/sts/session_helpers.php" \
    "${WEB_CID}:/var/www/html/sts/session_helpers.php"
  docker cp "${STS_DOCKER}/sts/operational_steps_catalog.php" \
    "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.php"
  docker cp "${STS_DOCKER}/sts/warm_start_helpers.php" \
    "${WEB_CID}:/var/www/html/sts/warm_start_helpers.php"
}

# Normalize live workflow: strip broken coke stagger → clean both-lanes block,
# reset generate/repo to defaults. Cases re-apply stagger/gates from here.
build_base() {
  python3 - <<PY
import json
from copy import deepcopy
from pathlib import Path

src = Path("${WF_LIVE}")
dst = Path("${WF_BASE}")
recipe = json.loads(src.read_text())
steps = recipe.get("steps", [])

# Drop all session_is_even / session_is_odd if_then steps (coke stagger only).
clean = []
for step in steps:
    fn = step.get("function", "")
    p = step.get("params") or {}
    var = (p.get("variable") or "").strip()
    if fn == "if_then" and var in ("session_is_even", "session_is_odd"):
        continue
    clean.append(deepcopy(step))

# Ensure both coke bulk generates exist once, before the general generate_orders.
has_clev = any(
    s.get("function") == "generate_orders"
    and (s.get("params") or {}).get("shipment") == "COKE-CLEV-BULK"
    for s in clean
)
has_uss = any(
    s.get("function") == "generate_orders"
    and (s.get("params") or {}).get("shipment") == "COKE-USS-BULK"
    for s in clean
)

def mk_ship(code):
    return {
        "function": "generate_orders",
        "params": {
            "shipment": code,
            "increment_session": "",
            "max_unfilled": "",
            "max_new": "",
            "seed": "",
        },
        "catalog_description": "Auto-generate car orders.",
    }

if not has_clev or not has_uss:
    # Insert before first empty-shipment generate_orders
    insert_at = None
    for i, s in enumerate(clean):
        if s.get("function") == "generate_orders" and not (s.get("params") or {}).get("shipment", "").strip():
            insert_at = i
            break
    if insert_at is None:
        insert_at = 0
    extras = []
    if not has_clev:
        extras.append(mk_ship("COKE-CLEV-BULK"))
    if not has_uss:
        extras.append(mk_ship("COKE-USS-BULK"))
    clean = clean[:insert_at] + extras + clean[insert_at:]

# Default levers for base
for step in clean:
    fn = step.get("function", "")
    p = step.setdefault("params", {})
    if fn == "generate_orders" and not (p.get("shipment") or "").strip():
        p["max_new"] = "14"
        p["max_unfilled"] = "30"
    if fn == "reposition_empties":
        p["percent"] = "65"
    if fn == "fill_orders":
        p["percent"] = "100"

recipe["steps"] = clean
dst.write_text(json.dumps(recipe, indent=4) + "\n")
print(f"base steps={len(clean)} (both coke, no stagger)")
PY
}

patch_case() {
  local max_new="$1"
  local repo="$2"
  local gate="$3"
  local coke_mode="$4"   # stagger | both
  local do_loose="$5"    # 1=loosen non-coke intervals after restore
  python3 - <<PY
import json
from copy import deepcopy
from pathlib import Path

src = Path("${WF_BASE}")
dst = Path("${WF_TMP}")
recipe = json.loads(src.read_text())
steps = recipe.get("steps", [])
max_new = "${max_new}"
repo = "${repo}"
gate = "${gate}"
coke_mode = "${coke_mode}"

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
            # Even sessions skip CLEV → CLEV on odd only
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
            # Odd sessions skip USS → USS on even only
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

# Per-lane coke settings: uss_mi uss_ma uss_amin uss_amax clev_mi clev_ma clev_amin clev_amax
apply_coke_lanes() {
  local umi="$1" uma="$2" uamin="$3" uamax="$4"
  local cmi="$5" cma="$6" camin="$7" camax="$8"
  docker exec "${WEB_CID}" php -r "
chdir('/var/www/html/sts');
require 'open_db.php';
\$d=open_db();
mysqli_query(\$d, \"UPDATE shipments SET min_interval=${umi}, max_interval=${uma}, min_amount=${uamin}, max_amount=${uamax} WHERE code='COKE-USS-BULK'\");
echo 'USS -> ${umi}-${uma}/${uamin}-${uamax} rows='.mysqli_affected_rows(\$d).\"\\n\";
mysqli_query(\$d, \"UPDATE shipments SET min_interval=${cmi}, max_interval=${cma}, min_amount=${camin}, max_amount=${camax} WHERE code='COKE-CLEV-BULK'\");
echo 'CLEV -> ${cmi}-${cma}/${camin}-${camax} rows='.mysqli_affected_rows(\$d).\"\\n\";
"
}

loosen_general() {
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
  local id="$1"
  shift
  # max_new repo gate coke_mode loose
  # uss_mi uss_ma uss_amin uss_amax clev_mi clev_ma clev_amin clev_amax
  local max_new="$1" repo="$2" gate="$3" coke_mode="$4" loose="$5"
  local umi="$6" uma="$7" uamin="$8" uamax="$9"
  local cmi="${10}" cma="${11}" camin="${12}" camax="${13}"

  echo "==> CASE ${id}: new=${max_new} repo=${repo} gate=${gate} mode=${coke_mode} loose=${loose} USS=${umi}-${uma}x${uamin}-${uamax} CLEV=${cmi}-${cma}x${camin}-${camax}" \
    | tee -a "${LOG}"

  "${BIN_DIR}/apply_hart_seed.sh" --sql-file "${LOCK}" >> "${LOG}" 2>&1
  patch_criteria
  patch_case "${max_new}" "${repo}" "${gate}" "${coke_mode}" "${loose}"
  apply_coke_lanes "${umi}" "${uma}" "${uamin}" "${uamax}" "${cmi}" "${cma}" "${camin}" "${camax}" | tee -a "${LOG}"
  if [[ "${loose}" == "1" ]]; then
    loosen_general | tee -a "${LOG}"
  fi

  OUT="$(docker exec -u www-data "${WEB_CID}" php /var/www/html/sts/traffic_from_session2.php \
    "${TO_SESSION}" hart_session 2>&1)" || true
  echo "${OUT}" >> "${LOG}"
  echo "${OUT}" | grep -E '^(SCORE|HOLDUP|NOTES)=' | tee -a "${LOG}"
  SCORE_LINE="$(echo "${OUT}" | grep '^SCORE=' || true)"
  JSON_LINE="$(echo "${OUT}" | grep '^TRAFFIC_JSON=' | sed 's/^TRAFFIC_JSON=//' || true)"
  echo "RESULT ${id}: ${SCORE_LINE}" | tee -a "${LOG}"
  if [[ -n "${JSON_LINE}" ]]; then
    echo "${id}|mode=${coke_mode}/new=${max_new}/repo=${repo}/gate=${gate}/loose=${loose}/USS=${umi}-${uma}x${uamin}-${uamax}/CLEV=${cmi}-${cma}x${camin}-${camax}|${JSON_LINE}" >> "${SCORES}"
  fi
  echo | tee -a "${LOG}"
}

deploy
build_base
# Persist cleaned both-lanes base as the live workflow (fixes broken triple-stagger).
cp "${WF_BASE}" "${WF_LIVE}"
cp "${WF_BASE}" "${BACKUPS_DIR}/session_editor/start_session.workflow.json"

: > "${SCORES}"
echo "==> Coke balance 20-case sweep from hart_session2_locked (sessions 3-${TO_SESSION})" | tee "${LOG}"
echo "    CLEV→MR (15)  USS→MP (14). Stagger = one lane/session; both = both every session." | tee -a "${LOG}"
echo "    Base: gen max_new=14 gate=30 repo=65, coke block cleaned to BOTH (no stagger)." | tee -a "${LOG}"
echo "    Log: ${LOG}" | tee -a "${LOG}"
echo | tee -a "${LOG}"

# id                  new repo gate mode     loose  USS_int/_amt      CLEV_int/_amt
# --- Plan first (gen_loose + stagger) ---
run_case plan_stag_14     14 65 30 stagger 1   1 2 2 4   1 2 2 4
run_case plan_stag_12     12 65 30 stagger 1   1 2 2 4   1 2 2 4
run_case plan_stag_16     16 65 30 stagger 1   1 2 2 4   1 2 2 4
# --- Both every session, matched lanes ---
run_case both_half_14     14 65 30 both    1   1 2 1 2   1 2 1 2
run_case both_22_14       14 65 30 both    1   2 2 2 2   2 2 2 2
run_case both_11_14       14 65 30 both    1   1 1 1 1   1 1 1 1
run_case both_12int2_14   14 65 30 both    1   2 2 1 2   2 2 1 2
run_case both_22_12       12 65 30 both    1   2 2 2 2   2 2 2 2
run_case both_22_16       16 65 30 both    1   2 2 2 2   2 2 2 2
run_case both_22int1_14   14 65 30 both    1   1 1 2 2   1 1 2 2
# --- Asymmetric (push MR vs MP) ---
run_case asym_mp_hot      14 65 30 both    1   1 1 3 4   2 2 1 2
run_case asym_mr_hot      14 65 30 both    1   2 2 1 2   1 1 3 4
run_case asym_mp_mild     14 65 30 both    1   1 2 2 3   2 2 1 2
run_case asym_mr_mild     14 65 30 both    1   2 2 1 2   1 2 2 3
# --- Ablations ---
run_case both_noloose     14 65 30 both    0   2 2 2 2   2 2 2 2
run_case stag_noloose     14 65 30 stagger 0   1 2 2 4   1 2 2 4
run_case both_repo85      14 85 30 both    1   2 2 2 2   2 2 2 2
run_case both_gate35      14 65 35 both    1   2 2 2 2   2 2 2 2
run_case stag_hot         14 65 30 stagger 1   1 1 3 3   1 1 3 3
run_case both_quiet       14 65 30 both    1   3 3 1 2   3 3 1 2

echo "==> Ranking (score, then MR/MP balance)" | tee -a "${LOG}"
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
    mr = int(d.get("coke_mr") or 0)
    mp = int(d.get("coke_mp") or 0)
    tot = max(1, mr + mp)
    bal = 1.0 - abs(mr - mp) / tot
    d["_bal"] = bal
    d["_meta"] = meta
    rows.append((float(d.get("score") or 0), bal, sid, d))
rows.sort(key=lambda x: (x[0], x[1]), reverse=True)
print(f"{'score':>6} {'bal':>5} {'MR':>3}/{'MP':<3} {'coke':>4} {'var':>4} {'NVLO':>4} {'holdup':14s} {'id':18s} meta")
for score, bal, sid, d in rows:
    print(
        f"{score:6.1f} {bal:5.2f} {d.get('coke_mr',0):3d}/{d.get('coke_mp',0):<3d} "
        f"{d.get('coke_avg',0):4.1f} {d.get('coke_var',0):4.1f} {d.get('nvlo_avg',0):4.1f} "
        f"{str(d.get('holdup','')):14s} {sid:18s} {d.get('_meta','')}"
    )
if rows:
    best = rows[0]
    print(f"BEST={best[2]} score={best[0]:.1f} bal={best[1]:.2f} MR/MP={best[3].get('coke_mr')}/{best[3].get('coke_mp')}")
    # Best among both vs stagger
    both = [r for r in rows if "mode=both" in r[3].get("_meta","")]
    stag = [r for r in rows if "mode=stagger" in r[3].get("_meta","")]
    if both:
        b = both[0]
        print(f"BEST_BOTH={b[2]} score={b[0]:.1f} bal={b[1]:.2f} MR/MP={b[3].get('coke_mr')}/{b[3].get('coke_mp')}")
    if stag:
        s = stag[0]
        print(f"BEST_STAG={s[2]} score={s[0]:.1f} bal={s[1]:.2f} MR/MP={s[3].get('coke_mr')}/{s[3].get('coke_mp')}")
PY

echo
echo "Log: ${LOG}"
echo "Scores: ${SCORES}"
