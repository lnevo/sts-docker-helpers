#!/usr/bin/env bash
# Empty-management / gate lever sweep from hart_session3_locked.
# Phase A: 12 cases × 1 seed (score sessions 5..10)
# Phase B: winner (+ close runner-up) × 5 random seeds
# Phase C: final winner left at session 10
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
TARGET_SESSION="${TARGET_SESSION:-10}"
SCORE_FROM="${SCORE_FROM:-5}"
SWEEP_SEED="${SWEEP_SEED:-22}"
# shellcheck disable=SC2206
VALIDATE_SEEDS=(${VALIDATE_SEEDS:-41 73 19 88 56})
CLOSE_DELTA="${CLOSE_DELTA:-2.5}"

STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${BACKUPS_DIR}/session_editor"
LOG="${LOG_DIR}/traffic_empty_gate_wave_${STAMP}.log"
SWEEP_TSV="${LOG_DIR}/traffic_empty_gate_wave_${STAMP}_sweep.tsv"
VAL_TSV="${LOG_DIR}/traffic_empty_gate_wave_${STAMP}_validate.tsv"

CASES=(
  eg_BASE_M6_G40_R25
  eg_REPO10_M6_G40
  eg_REPO40_M6_G40
  eg_REPO50_M6_G40
  eg_DYNAMIC_M6_G40
  eg_FILL75_R40
  eg_M8_G35_R25
  eg_M4_G50_R25
  eg_M6_G30_R40
  eg_COKE_MR3_MP5_R25
  eg_COKE_MR5_MP3_R40
  eg_COKE_MR6_MP4_R25
)

WEB_CID="$("${COMPOSE[@]}" ps -q web)"
DB_CID="$("${COMPOSE[@]}" ps -q db)"
[[ -n "${WEB_CID}" && -n "${DB_CID}" ]] || {
  echo "Web/database containers are not running." >&2
  exit 1
}
[[ -f "${LOCK}" ]] || {
  echo "Missing locked baseline: ${LOCK}" >&2
  exit 1
}

python3 "${TOOLS_DIR}/prepare_empty_gate_wave.py"
docker cp "${DIAGNOSTICS_DIR}/traffic_from_session2.php" \
  "${WEB_CID}:/var/www/html/sts/traffic_from_session2.php"
docker cp "${BACKUPS_DIR}/session_editor/." \
  "${WEB_CID}:/var/www/html/sts/backups/session_editor/"

restore_s3() {
  "${BIN_DIR}/apply_hart_seed.sh" --sql-file "${LOCK}" >/tmp/empty_gate_restore.log 2>&1
}

extract_json() {
  local case_id="$1" seed="$2" case_log="$3" out_tsv="$4"
  python3 - "$case_id" "$seed" "$case_log" >>"${out_tsv}" <<'PY'
import json
import sys

case_id, seed, path = sys.argv[1:]
payload = None
with open(path) as handle:
    for line in handle:
        if line.startswith("TRAFFIC_JSON="):
            payload = json.loads(line.split("=", 1)[1])
if payload is None:
    raise SystemExit(f"No TRAFFIC_JSON in {path}")
job_avgs = payload.get("job_avgs") or {}
shorts = payload.get("job_shorts") or {}
# Prefer CK1 / NVLO empties for ranking notes
ck1 = 0.0
nvlo = 0.0
for key, avg in job_avgs.items():
    short = shorts.get(key, key)
    if short == "CK1":
        ck1 = float(avg)
    if short == "NVLO":
        nvlo = float(avg)
values = [
    case_id,
    seed,
    round(float(payload.get("score") or 0), 2),
    payload.get("holdup", ""),
    round(float(payload.get("coke_avg") or 0), 2),
    round(float(payload.get("coke_var") or 0), 2),
    payload.get("coke_mr", ""),
    payload.get("coke_mp", ""),
    payload.get("nvlo_empty", ""),
    round(ck1, 2),
    round(nvlo, 2),
    round(float(payload.get("unf_avg") or 0), 2),
    round(float(payload.get("gen_avg") or 0), 2),
    round(float(payload.get("fill_avg") or 0), 2),
    round(float(payload.get("rep_avg") or 0), 2),
]
print("\t".join(map(str, values)))
PY
}

run_case() {
  local case_id="$1" seed="$2" out_tsv="$3"
  local wf="${case_id}.workflow.json"
  [[ -f "${LOG_DIR}/${wf}" ]] || {
    echo "Missing workflow: ${wf}" >&2
    exit 1
  }
  echo "==> ${case_id} seed=${seed}" | tee -a "${LOG}"
  restore_s3
  local case_log
  case_log="$(mktemp)"
  docker exec -u www-data \
    -e STS_TRAFFIC_SEED="${seed}" \
    -e STS_SCORE_FROM="${SCORE_FROM}" \
    "${WEB_CID}" php /var/www/html/sts/traffic_from_session2.php \
    "${TARGET_SESSION}" "${wf}" \
    | tee "${case_log}" | tee -a "${LOG}"
  extract_json "${case_id}" "${seed}" "${case_log}" "${out_tsv}"
  rm -f "${case_log}"
}

printf "case\tseed\tscore\tholdup\tcoke_avg\tcoke_var\tcoke_MR\tcoke_MP\tnvlo_empty\tck1_avg\tnvlo_avg\tunf_avg\tgen_avg\tfill_avg\trep_avg\n" \
  >"${SWEEP_TSV}"
printf "case\tseed\tscore\tholdup\tcoke_avg\tcoke_var\tcoke_MR\tcoke_MP\tnvlo_empty\tck1_avg\tnvlo_avg\tunf_avg\tgen_avg\tfill_avg\trep_avg\n" \
  >"${VAL_TSV}"

{
  echo "Empty/gate wave: locked s3 -> s${TARGET_SESSION}; score s${SCORE_FROM}-${TARGET_SESSION}"
  echo "Sweep seed=${SWEEP_SEED}; validate seeds=${VALIDATE_SEEDS[*]}; close_delta=${CLOSE_DELTA}"
  echo "Cases: ${CASES[*]}"
} | tee "${LOG}"

echo "" | tee -a "${LOG}"
echo "===== PHASE A: lever sweep (1 seed) =====" | tee -a "${LOG}"
for case_id in "${CASES[@]}"; do
  run_case "${case_id}" "${SWEEP_SEED}" "${SWEEP_TSV}"
done

# Rank by score, then coke_var (lower better), then |MR-MP|
mapfile -t RANKED < <(python3 - "${SWEEP_TSV}" <<'PY'
import csv
import sys
from pathlib import Path

path = Path(sys.argv[1])
rows = list(csv.DictReader(path.open(), delimiter="\t"))
def key(r):
    mr = float(r.get("coke_MR") or 0)
    mp = float(r.get("coke_MP") or 0)
    bal = abs(mr - mp) / max(1.0, mr + mp)
    return (-float(r["score"]), float(r.get("coke_var") or 99), bal)

rows.sort(key=key)
for r in rows:
    print(f"{r['case']}\t{r['score']}\t{r['coke_avg']}\t{r['coke_var']}\t{r['coke_MR']}/{r['coke_MP']}\tck1={r['ck1_avg']}\tnvlo_empty={r['nvlo_empty']}")
PY
)

echo "" | tee -a "${LOG}"
echo "===== SWEEP RANKING =====" | tee -a "${LOG}"
printf '%s\n' "${RANKED[@]}" | tee -a "${LOG}"

WINNER="$(printf '%s\n' "${RANKED[0]}" | cut -f1)"
WIN_SCORE="$(printf '%s\n' "${RANKED[0]}" | cut -f2)"
RUNNER=""
RUN_SCORE=""
if [[ ${#RANKED[@]} -gt 1 ]]; then
  RUNNER="$(printf '%s\n' "${RANKED[1]}" | cut -f1)"
  RUN_SCORE="$(printf '%s\n' "${RANKED[1]}" | cut -f2)"
fi

echo "" | tee -a "${LOG}"
echo "Winner: ${WINNER} (score ${WIN_SCORE})" | tee -a "${LOG}"

VALIDATE_CASES=("${WINNER}")
if [[ -n "${RUNNER}" ]]; then
  python3 - "${WIN_SCORE}" "${RUN_SCORE}" "${CLOSE_DELTA}" "${RUNNER}" <<'PY' | tee -a "${LOG}"
import sys
win, run, delta, name = sys.argv[1:5]
close = abs(float(win) - float(run)) <= float(delta)
print(f"Runner-up: {name} (score {run}) delta={abs(float(win)-float(run)):.2f} close={close}")
sys.exit(0 if close else 1)
PY
  if [[ $? -eq 0 ]]; then
    VALIDATE_CASES+=("${RUNNER}")
  else
    echo "Runner-up not close enough — skipping 5-seed validate for ${RUNNER}" | tee -a "${LOG}"
  fi
fi

echo "" | tee -a "${LOG}"
echo "===== PHASE B: 5-seed validation =====" | tee -a "${LOG}"
for case_id in "${VALIDATE_CASES[@]}"; do
  for seed in "${VALIDATE_SEEDS[@]}"; do
    run_case "${case_id}" "${seed}" "${VAL_TSV}"
  done
done

FINAL="$(python3 - "${VAL_TSV}" "${WINNER}" <<'PY'
import csv
import sys
from collections import defaultdict
from pathlib import Path

path = Path(sys.argv[1])
fallback = sys.argv[2]
rows = list(csv.DictReader(path.open(), delimiter="\t"))
if not rows:
    print(fallback)
    raise SystemExit(0)
by = defaultdict(list)
for r in rows:
    by[r["case"]].append(r)

def mean(vals):
    return sum(vals) / max(1, len(vals))

best = None
best_key = None
for case, items in by.items():
    scores = [float(x["score"]) for x in items]
    vars_ = [float(x["coke_var"]) for x in items]
    # Prefer higher mean score, then lower mean coke var, then CK1 steadiness (higher ck1_avg floor)
    ck1s = [float(x["ck1_avg"]) for x in items]
    empties = [int(float(x["nvlo_empty"])) for x in items]
    key = (-mean(scores), mean(vars_), -min(ck1s), sum(empties))
    print(f"VALIDATE {case}: mean_score={mean(scores):.2f} mean_var={mean(vars_):.2f} ck1={mean(ck1s):.2f} nvlo_empty_sum={sum(empties)} n={len(items)}", file=sys.stderr)
    if best_key is None or key < best_key:
        best_key = key
        best = case
print(best or fallback)
PY
)"

echo "" | tee -a "${LOG}"
echo "===== PHASE C: final winner ${FINAL} -> session ${TARGET_SESSION} =====" | tee -a "${LOG}"
restore_s3
docker exec -u www-data \
  -e STS_TRAFFIC_SEED="${SWEEP_SEED}" \
  -e STS_SCORE_FROM="${SCORE_FROM}" \
  "${WEB_CID}" php /var/www/html/sts/traffic_from_session2.php \
  "${TARGET_SESSION}" "${FINAL}.workflow.json" \
  | tee -a "${LOG}"

# Promote final workflow into hart_session + ACTIVE
docker cp "${LOG_DIR}/${FINAL}.workflow.json" \
  "${WEB_CID}:/var/www/html/sts/backups/session_editor/hart_session.workflow.json"
docker cp "${LOG_DIR}/${FINAL}.workflow.json" \
  "${WEB_CID}:/var/www/html/sts/backups/session_editor/start_session.workflow.json"
docker exec "${WEB_CID}" sh -c 'echo hart_session.workflow.json > /var/www/html/sts/backups/session_editor/ACTIVE'

# Also sync host mirrors from winner case (keep name hart_session)
python3 - "${LOG_DIR}/${FINAL}.workflow.json" <<'PY'
import json
from copy import deepcopy
from pathlib import Path
import sys
src = Path(sys.argv[1])
data = json.loads(src.read_text())
data["name"] = "hart_session"
data["source_workflow"] = "hart_session.workflow.json"
editor = Path("/Users/lnevo/Desktop/HART/Car Cards/sts-backups/session_editor")
helpers = Path("/Users/lnevo/Desktop/HART/Car Cards/sts-docker-helpers/backups/session_editor")
for path in (
    editor / "hart_session.workflow.json",
    editor / "start_session.workflow.json",
    helpers / "hart_session.workflow.json",
    helpers / "start_session.workflow.json",
):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=4) + "\n")
    print("synced", path)
PY

docker exec -u www-data "${WEB_CID}" php -r '
chdir("/var/www/html/sts");
require "open_db.php";
$d=open_db();
$r=mysqli_query($d,"SELECT setting_value FROM settings WHERE setting_name=\"session_nbr\"");
echo "final session_nbr=".mysqli_fetch_row($r)[0]."\n";
'

echo "" | tee -a "${LOG}"
echo "DONE final=${FINAL}" | tee -a "${LOG}"
echo "LOG=${LOG}"
echo "SWEEP_TSV=${SWEEP_TSV}"
echo "VAL_TSV=${VAL_TSV}"
