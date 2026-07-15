#!/usr/bin/env bash
# Compare coke bulk both-every-session vs odd/even stagger.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

SESSIONS="${1:-40}"
WORKFLOW="${2:-hart_session}"
SEED_SCRIPT="${HELPERS_ROOT}/seed/generate_hart_seed.py"
CONFIG="${HELPERS_ROOT}/seed/hart_seed_config.json"
SEED_OUT="${BACKUPS_DIR}/hart_seed0"
LOG="${BACKUPS_DIR}/session_editor/coke_stagger_compare_$(date +%Y%m%d_%H%M%S).log"

WEB_CID="$("${COMPOSE[@]}" ps -q web)"
if [[ -z "${WEB_CID}" ]]; then
  echo "STS web container is not running." >&2
  exit 1
fi

echo "==> Regenerating seed (nvl_steady profile in config)" | tee "${LOG}"
python3 "${SEED_SCRIPT}" --config "${CONFIG}" --output "${SEED_OUT}" >> "${LOG}" 2>&1
"${BIN_DIR}/apply_hart_seed.sh" >> "${LOG}" 2>&1

docker cp "${DIAGNOSTICS_DIR}/coke_stagger_compare.php" "${WEB_CID}:/var/www/html/sts/coke_stagger_compare.php"
docker cp "${STS_DOCKER}/sts/session_helpers.php" "${WEB_CID}:/var/www/html/sts/session_helpers.php"
docker cp "${STS_DOCKER}/sts/operations_stats.php" "${WEB_CID}:/var/www/html/sts/operations_stats.php"
docker cp "${BACKUPS_DIR}/session_editor/." "${WEB_CID}:/var/www/html/sts/backups/session_editor/"

echo "==> Coke stagger comparison (${SESSIONS} sessions/mode)" | tee -a "${LOG}"
docker exec "${WEB_CID}" php /var/www/html/sts/coke_stagger_compare.php "${SESSIONS}" "${WORKFLOW}" \
  2>&1 | tee -a "${LOG}"

echo "==> Done. Log: ${LOG}" | tee -a "${LOG}"
