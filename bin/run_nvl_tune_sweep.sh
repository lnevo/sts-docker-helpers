#!/usr/bin/env bash
# NVL / Shenango mainstay shipment tuning — compares island vs IX demand profiles.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

SESSIONS="${1:-25}"
WORKFLOW="${2:-hart_session}"
SCENARIOS="${BACKUPS_DIR}/session_editor/nvl_tune_scenarios.json"
CONFIG="${HELPERS_ROOT}/seed/hart_seed_config.json"
SEED_SCRIPT="${HELPERS_ROOT}/seed/generate_hart_seed.py"
SEED_OUT="${BACKUPS_DIR}/hart_seed"
TMP_CONFIG="${BACKUPS_DIR}/session_editor/_nvl_tune_config.json"
LOG="${BACKUPS_DIR}/session_editor/nvl_tune_sweep_$(date +%Y%m%d_%H%M%S).log"

WEB_CID="$("${COMPOSE[@]}" ps -q web)"
if [[ -z "${WEB_CID}" ]]; then
  echo "STS web container is not running." >&2
  exit 1
fi

if [[ ! -f "${SCENARIOS}" ]]; then
  echo "Missing ${SCENARIOS}" >&2
  exit 1
fi

deploy_runtime() {
  docker cp "${DIAGNOSTICS_DIR}/nvl_tune_round.php" "${WEB_CID}:/var/www/html/sts/nvl_tune_round.php"
  docker cp "${BACKUPS_DIR}/session_editor/." "${WEB_CID}:/var/www/html/sts/backups/session_editor/"
}

apply_coke_bulk() {
  local key="$1" val="$2"
  python3 - "${TMP_CONFIG}" "${key}" "${val}" <<'PY'
import json, sys
path, key, val = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = json.load(open(path))
for row in cfg.get("coke_shipments", []):
    if row.get("code") in ("COKE-USS-BULK", "COKE-CLEV-BULK"):
        row[key] = val
json.dump(cfg, open(path, "w"), indent=2)
PY
}

build_scenario_config() {
  local id="$1"
  python3 - "${SCENARIOS}" "${CONFIG}" "${TMP_CONFIG}" "${id}" <<'PY'
import json, sys
scenarios = json.load(open(sys.argv[1]))
base = json.load(open(sys.argv[2]))
s = scenarios[sys.argv[4]]
base["traffic_mult"] = s["traffic_mult"]
base["island_traffic_mult"] = s.get("island_traffic_mult", 1.0)
base["ix_traffic_mult"] = s.get("ix_traffic_mult", 1.0)
bulk = s.get("coke_bulk", {})
for row in base.get("coke_shipments", []):
    if row.get("code") in ("COKE-USS-BULK", "COKE-CLEV-BULK"):
        for k, v in bulk.items():
            row[k] = v
json.dump(base, open(sys.argv[3], "w"), indent=2)
print(scenarios[sys.argv[4]]["label"])
PY
}

score_line() {
  python3 - "$@" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
sessions = int(s["sessions"])
notes = []
if s["neville_avg"] > 20: notes.append("Neville stuck")
if s["scully_avg"] > 10: notes.append("Scully stuck")
if s["nvl_lists_avg"] < sessions * 0.9: notes.append("NVL thin")
if s["ck1_pickup_avg"] < sessions * 4: notes.append("coke thin")
if s["gen_zero"] > sessions * 0.35: notes.append("gen quiet")
score = (
    s["nvl_move_avg"] * 10
    - s["nvl_cv"] * 25
    - s["gen_zero"] * 2
    + min(s["ck1_pickup_avg"], sessions * 8) * 0.5
    - max(0, s["neville_avg"] - 18) * 2
)
s["score"] = round(score, 1)
s["notes"] = "ok" if not notes else ", ".join(notes)
print(json.dumps(s))
PY
}

echo "==> NVL shipment tuning sweep (${SESSIONS} sessions/scenario)" | tee "${LOG}"
echo "    Workflow: ${WORKFLOW}" | tee -a "${LOG}"
echo | tee -a "${LOG}"

deploy_runtime

declare -a RESULT_LINES=()
declare -a SCENARIO_IDS=()

while IFS= read -r sid; do
  [[ -z "${sid}" ]] && continue
  SCENARIO_IDS+=("${sid}")
done < <(python3 -c "import json; print('\n'.join(json.load(open('${SCENARIOS}')).keys()))")

printf "%-14s | %-6s %-5s %-5s %-5s %-4s | %-5s %-5s %-5s | %s\n" \
  "Scenario" "NVLmv" "CV" "Lists" "CK1pu" "Gen0" "Nev" "Shen" "Unfl" "Notes" \
  | tee -a "${LOG}"
printf "%s\n" "$(printf '%.0s-' {1..95})" | tee -a "${LOG}"

for sid in "${SCENARIO_IDS[@]}"; do
  label="$(build_scenario_config "${sid}")"
  echo "==> ${sid}: ${label}" | tee -a "${LOG}"

  python3 "${SEED_SCRIPT}" --config "${TMP_CONFIG}" \
    --traffic-mult "$(python3 -c "import json; print(json.load(open('${TMP_CONFIG}'))['traffic_mult'])")" \
    --output "${SEED_OUT}" >> "${LOG}" 2>&1

  "${BIN_DIR}/apply_hart_seed.sh" >> "${LOG}" 2>&1

  OUT="$(docker exec "${WEB_CID}" php /var/www/html/sts/nvl_tune_round.php \
    "${SESSIONS}" "${WORKFLOW}" "${sid}" 2>&1)"
  echo "${OUT}" >> "${LOG}"
  JSON_LINE="$(echo "${OUT}" | grep '^NVL_TUNE_JSON=' | sed 's/^NVL_TUNE_JSON=//')"
  if [[ -z "${JSON_LINE}" ]]; then
    echo "WARN: no metrics for ${sid}" | tee -a "${LOG}"
    continue
  fi
  SCORED="$(score_line "${JSON_LINE}")"
  RESULT_LINES+=("${SCORED}")

  python3 - "${SCORED}" "${sid}" <<'PY' | tee -a "${LOG}"
import json, sys
s = json.loads(sys.argv[1])
sid = sys.argv[2]
print(f"{sid:14s} | {s['nvl_move_avg']:6.1f} {s['nvl_cv']:5.2f} {s['nvl_lists_avg']:5.1f} {s['ck1_pickup_avg']:5.1f} {s['gen_zero']:4d} | {s['neville_avg']:5.0f} {s['shenango_avg']:5.0f} {s['unfilled_last']:5d} | {s['notes']}")
PY
done

echo | tee -a "${LOG}"
WINNER="$(python3 - "${RESULT_LINES[@]}" <<'PY'
import json, sys
lines = [json.loads(x) for x in sys.argv[1:] if x.strip()]
if not lines:
    print("")
    sys.exit(0)
best = max(lines, key=lambda s: s.get("score", 0))
print(best["scenario"])
PY
)"

if [[ -n "${WINNER}" ]]; then
  echo "Recommended profile: ${WINNER}" | tee -a "${LOG}"
  python3 - "${SCENARIOS}" "${WINNER}" <<'PY' | tee -a "${LOG}"
import json, sys
s = json.load(open(sys.argv[1]))[sys.argv[2]]
print(f"  {s['label']}")
print(f"  traffic_mult={s['traffic_mult']} island_mult={s.get('island_traffic_mult',1)} ix_mult={s.get('ix_traffic_mult',1)}")
b = s.get('coke_bulk',{})
print(f"  coke bulk: interval {b.get('min_interval')}-{b.get('max_interval')}, amount {b.get('min_amount')}-{b.get('max_amount')}")
PY
fi

echo "==> Restoring baseline seed from config" | tee -a "${LOG}"
python3 "${SEED_SCRIPT}" --config "${CONFIG}" --output "${SEED_OUT}" >> "${LOG}" 2>&1
"${BIN_DIR}/apply_hart_seed.sh" >> "${LOG}" 2>&1

echo "==> Done. Log: ${LOG}" | tee -a "${LOG}"
