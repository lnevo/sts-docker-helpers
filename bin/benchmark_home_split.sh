#!/usr/bin/env bash
# Benchmark car home-split scenarios: regenerate seed per mode, run 10x10 sims.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SEED_DIR="${ROOT}/sts-docker-helpers/seed"
BACKUP="${ROOT}/sts-backups/hart_seed"
WORKFLOW="${ROOT}/sts-backups/session_editor/start_session.workflow.json"
COMPOSE="${ROOT}/sts-docker/docker-compose.yml"

MODES=(south_only demand ix_focus moderate)
ROUNDS="${1:-10}"
SESSIONS="${2:-10}"

WEB_CID="$(docker compose -f "${COMPOSE}" --profile build ps -q web)"
if [[ -z "${WEB_CID}" ]]; then
  echo "STS web container is not running." >&2
  exit 1
fi

echo "==> Home-split benchmark: ${ROUNDS} seeds x ${SESSIONS} sessions"
echo "    Workflow: ${WORKFLOW}"
echo

for mode in "${MODES[@]}"; do
  echo "######################################################################"
  echo "# Generating seed: car_home_split.mode=${mode}"
  echo "######################################################################"
  python3 "${SEED_DIR}/generate_hart_seed.py" \
    --home-split "${mode}" \
    --output "${BACKUP}"

  docker cp "${ROOT}/sts-docker-helpers/diagnostics/home_split_benchmark.php" \
    "${WEB_CID}:/var/www/html/sts/home_split_benchmark.php"

  docker exec "${WEB_CID}" php /var/www/html/sts/home_split_benchmark.php \
    /var/www/html/sts/backups/session_editor/start_session.workflow.json \
    "${ROUNDS}" "${SESSIONS}" "${mode}"
  echo
done

echo "==> Done. Restore baseline seed (south_only)."
python3 "${SEED_DIR}/generate_hart_seed.py" --home-split south_only --output "${BACKUP}"
