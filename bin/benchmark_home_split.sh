#!/usr/bin/env bash
# Benchmark car home-split scenarios: regenerate seed per mode, run 10x10 sims.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"
SEED_DIR="${HELPERS_ROOT}/seed"
BACKUP="${BACKUPS_DIR}/hart_seed0"
WORKFLOW="${BACKUPS_DIR}/session_editor/start_session.workflow.json"
COMPOSE="${STS_DOCKER}/docker-compose.yml"

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

  docker cp "${HELPERS_ROOT}/diagnostics/home_split_benchmark.php" \
    "${WEB_CID}:/var/www/html/sts/home_split_benchmark.php"

  docker exec "${WEB_CID}" php /var/www/html/sts/home_split_benchmark.php \
    /var/www/html/sts/backups/session_editor/start_session.workflow.json \
    "${ROUNDS}" "${SESSIONS}" "${mode}"
  echo
done

echo "==> Done. Restore baseline seed (south_only)."
python3 "${SEED_DIR}/generate_hart_seed.py" --home-split south_only --output "${BACKUP}"
