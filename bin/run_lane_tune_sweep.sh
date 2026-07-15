#!/usr/bin/env bash
# Island vs interchange lane tuning — uses finalized workflow (max_new=14, no gate, random seed).
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

SESSIONS="${1:-10}"
WORKFLOW="${2:-hart_session}"
SCENARIOS="${BACKUPS_DIR}/session_editor/lane_tune_scenarios.json"
CONFIG="${HELPERS_ROOT}/seed/hart_seed_config.json"
SEED_SCRIPT="${HELPERS_ROOT}/seed/generate_hart_seed.py"
SEED_OUT="${BACKUPS_DIR}/hart_seed0"
TMP_CONFIG="${BACKUPS_DIR}/session_editor/_lane_tune_config.json"
LOG="${BACKUPS_DIR}/session_editor/lane_tune_sweep_$(date +%Y%m%d_%H%M%S).log"

WEB_CID="$("${COMPOSE[@]}" ps -q web)"
if [[ -z "${WEB_CID}" ]]; then
  echo "STS web container is not running." >&2
  exit 1
fi

deploy_runtime() {
  docker cp "${DIAGNOSTICS_DIR}/lane_tune_round.php" "${WEB_CID}:/var/www/html/sts/lane_tune_round.php"
  docker cp "${BACKUPS_DIR}/session_editor/hart_session.workflow.json" \
    "${WEB_CID}:/var/www/html/sts/backups/session_editor/hart_session.workflow.json"
  docker cp "${STS_DOCKER}/sts/generate_order_helpers.php" "${WEB_CID}:/var/www/html/sts/generate_order_helpers.php"
  docker cp "${STS_DOCKER}/sts/operational_steps_catalog.php" "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.php"
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

echo "==> Lane tune sweep (${SESSIONS} sessions/scenario, max_new=14 workflow)" | tee "${LOG}"
echo "    Workflow: ${WORKFLOW}" | tee -a "${LOG}"
echo | tee -a "${LOG}"

deploy_runtime

declare -a RESULT_LINES=()
declare -a SCENARIO_IDS=()

while IFS= read -r sid; do
  [[ -z "${sid}" ]] && continue
  SCENARIO_IDS+=("${sid}")
done < <(python3 -c "import json; print('\n'.join(json.load(open('${SCENARIOS}')).keys()))")

printf "%-14s | %-5s %-5s %-5s %-5s | %-5s %-5s %-4s | %-4s %-4s %-4s | %s\n" \
  "Scenario" "Gen" "Sout" "NVL" "IX" "Nev" "Dem" "Unfl" "NVLact" "Dem" "Scul" "Score" \
  | tee -a "${LOG}"
printf "%s\n" "$(printf '%.0s-' {1..100})" | tee -a "${LOG}"

for sid in "${SCENARIO_IDS[@]}"; do
  label="$(build_scenario_config "${sid}")"
  echo "==> ${sid}: ${label}" | tee -a "${LOG}"

  python3 "${SEED_SCRIPT}" --config "${TMP_CONFIG}" \
    --traffic-mult "$(python3 -c "import json; print(json.load(open('${TMP_CONFIG}'))['traffic_mult'])")" \
    --output "${SEED_OUT}" >> "${LOG}" 2>&1

  "${BIN_DIR}/apply_hart_seed.sh" >> "${LOG}" 2>&1

  OUT="$(docker exec "${WEB_CID}" php /var/www/html/sts/lane_tune_round.php \
    "${SESSIONS}" "${WORKFLOW}" "${sid}" 2>&1)"
  echo "${OUT}" >> "${LOG}"
  JSON_LINE="$(echo "${OUT}" | grep '^LANE_TUNE_JSON=' | sed 's/^LANE_TUNE_JSON=//')"
  if [[ -z "${JSON_LINE}" ]]; then
    echo "WARN: no metrics for ${sid}" | tee -a "${LOG}"
    continue
  fi
  RESULT_LINES+=("${JSON_LINE}")

  python3 - "${JSON_LINE}" "${sid}" <<'PY' | tee -a "${LOG}"
import json, sys
s = json.loads(sys.argv[1])
sid = sys.argv[2]
print(f"{sid:14s} | {s['gen_avg']:5.1f} {s['sout_avg']:5.1f} {s['nvl_move_avg']:5.1f} {s['ix_move_avg']:5.1f} | {s['neville_avg']:5.0f} {s['demmler_avg']:5.0f} {s['unfilled_last']:4d} | {s['nvl_island_actions']:4d} {s['ix_demmler_actions']:4d} {s['ix_scully_actions']:4d} | {s['score']:.1f}")
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
  echo "Recommended lane profile: ${WINNER}" | tee -a "${LOG}"
  python3 - "${SCENARIOS}" "${WINNER}" "${RESULT_LINES[@]}" <<'PY' | tee -a "${LOG}"
import json, sys
scenarios = json.load(open(sys.argv[1]))
winner = sys.argv[2]
s = scenarios[winner]
print(f"  {s['label']}")
print(f"  island_traffic_mult={s.get('island_traffic_mult')} ix_traffic_mult={s.get('ix_traffic_mult')}")

# Print per-station table for winner
for arg in sys.argv[3:]:
    if not arg.strip():
        continue
    row = json.loads(arg)
    if row.get("scenario") != winner:
        continue
    print()
    print("  Per-station actions (10 sessions):")
    print(f"  {'Station':22s} | {'Pickup':7s} {'Setout':7s} {'Assign':7s} {'Weigh':7s} | end")
    print("  " + "-" * 62)
    actions = row.get("station_actions", {})
    yards = row.get("yards_last", {})
    stations = sorted(set(list(actions.keys()) + list(yards.keys())), key=str.casefold)
    for st in stations:
        a = actions.get(st, {})
        end = yards.get(st, "-")
        print(f"  {st:22s} | {a.get('pickup',0):7d} {a.get('setout',0):7d} {a.get('assign',0):7d} {a.get('weigh',0):7d} | {end}")
    break
PY
fi

echo "==> Done. Log: ${LOG}" | tee -a "${LOG}"
