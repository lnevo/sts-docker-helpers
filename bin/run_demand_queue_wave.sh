#!/usr/bin/env bash
# Compare queue gates and demand-based reposition from locked session 3.
# 6 cases × 10 sessions (s4..s13). Default one seed for a true 6×10; set
# SEEDS="11 22 33" for a 3-seed average.
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
TARGET_SESSION="${TARGET_SESSION:-13}"
SCORE_FROM="${SCORE_FROM:-4}"
# shellcheck disable=SC2206
SEEDS=(${SEEDS:-22})
CASES=(
  wave1_BASE_M6_G40_R25.workflow.json
  wave1_Q20_M10_R25.workflow.json
  wave1_Q25_M10_R25.workflow.json
  wave1_BASE_M6_G40_DYNAMIC.workflow.json
  wave1_Q20_M10_DYNAMIC.workflow.json
  wave1_Q25_M10_DYNAMIC.workflow.json
)

STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${BACKUPS_DIR}/session_editor"
LOG="${LOG_DIR}/traffic_demand_queue_wave_${STAMP}.log"
RESULTS="${LOG_DIR}/traffic_demand_queue_wave_${STAMP}.tsv"

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

python3 "${TOOLS_DIR}/prepare_demand_queue_wave.py"
docker cp \
  "${BACKUPS_DIR}/session_editor/." \
  "${WEB_CID}:/var/www/html/sts/backups/session_editor/"
docker cp \
  "${DIAGNOSTICS_DIR}/traffic_from_session2.php" \
  "${WEB_CID}:/var/www/html/sts/traffic_from_session2.php"

restore_s3() {
  "${BIN_DIR}/apply_hart_seed.sh" --sql-file "${LOCK}" >/tmp/demand_queue_restore.log 2>&1
  if [[ -f "${MIGRATIONS_DIR}/tune_fleet_scarce_lanes.sql" ]]; then
    docker exec -i "${DB_CID}" sh -c \
      'mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' \
      <"${MIGRATIONS_DIR}/tune_fleet_scarce_lanes.sql" >/dev/null
  fi
}

cleanup() {
  echo "==> Restoring locked session 3" | tee -a "${LOG}"
  restore_s3 || true
}
trap cleanup EXIT

printf "case\tseed\tscore\topen_end\tunfilled_end\tgen_avg\tfill_avg\trepo_avg\tcoke_avg\tnvlo_avg\td749s_avg\td749o_avg\n" \
  >"${RESULTS}"

echo "Demand/queue wave: locked s3 -> s${TARGET_SESSION}; score s${SCORE_FROM}-${TARGET_SESSION}; seeds=${SEEDS[*]}" \
  | tee "${LOG}"

for workflow in "${CASES[@]}"; do
  [[ -f "${LOG_DIR}/${workflow}" ]] || {
    echo "Missing workflow: ${workflow}" >&2
    exit 1
  }
  case_id="${workflow%.workflow.json}"
  case_id="${case_id#wave1_}"

  for seed in "${SEEDS[@]}"; do
    echo "==> ${case_id} seed=${seed}" | tee -a "${LOG}"
    restore_s3
    case_log="$(mktemp)"
    docker exec -u www-data \
      -e STS_TRAFFIC_SEED="${seed}" \
      -e STS_SCORE_FROM="${SCORE_FROM}" \
      "${WEB_CID}" php /var/www/html/sts/traffic_from_session2.php \
      "${TARGET_SESSION}" "${workflow}" \
      | tee "${case_log}" | tee -a "${LOG}"

    python3 - "${case_id}" "${seed}" "${case_log}" >>"${RESULTS}" <<'PY'
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
rows = payload.get("rows") or []
end = rows[-1] if rows else {}
values = [
    case_id,
    seed,
    payload.get("score", ""),
    end.get("open", ""),
    end.get("unfilled", ""),
    payload.get("gen_avg", ""),
    payload.get("fill_avg", ""),
    payload.get("rep_avg", ""),
    payload.get("coke_avg", ""),
    payload.get("nvlo_avg", ""),
    payload.get("d749s_avg", ""),
    payload.get("d749o_avg", ""),
]
print("\t".join(map(str, values)))
PY
    rm -f "${case_log}"
  done
done

echo "==> Results: ${RESULTS}" | tee -a "${LOG}"
python3 - "${RESULTS}" <<'PY' | tee -a "${LOG}"
import csv
import statistics
import sys
from collections import defaultdict

groups = defaultdict(list)
with open(sys.argv[1], newline="") as handle:
    for row in csv.DictReader(handle, delimiter="\t"):
        groups[row["case"]].append(row)

print("\nMean results:")
for case, rows in groups.items():
    mean = lambda key: statistics.mean(float(row[key]) for row in rows)
    print(
        f"{case:28s} score={mean('score'):5.1f} "
        f"end open/unfilled={mean('open_end'):4.1f}/{mean('unfilled_end'):4.1f} "
        f"gen/fill/repo={mean('gen_avg'):4.1f}/{mean('fill_avg'):4.1f}/{mean('repo_avg'):4.1f}"
    )
PY
