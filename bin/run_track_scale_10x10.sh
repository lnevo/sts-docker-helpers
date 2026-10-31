#!/usr/bin/env bash
# Reset hart_seed, deploy benchmark runner, run 10x10 workflow sampling with track-scale stats.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"
WORKFLOW="${BACKUPS_DIR}/session_editor/start_session.workflow.json"
COMPOSE="${STS_DOCKER}/docker-compose.yml"
ROUNDS="${1:-10}"
SESSIONS="${2:-10}"
LOG="${BACKUPS_DIR}/session_editor/sim_10x_track_scale_$(date +%Y%m%d_%H%M%S).log"

WEB_CID="$(docker compose -f "${COMPOSE}" --profile build ps -q web)"
if [[ -z "${WEB_CID}" ]]; then
  echo "STS web container is not running." >&2
  exit 1
fi

echo "==> Track-scale 10x10 benchmark"
echo "    Workflow: ${WORKFLOW}"
echo "    Rounds: ${ROUNDS} x ${SESSIONS} sessions"
echo "    Log: ${LOG}"
echo

{
  echo "==> Restoring hart_seed (moderate home split)"
  "${HELPERS_ROOT}/bin/apply_hart_seed.sh"

  docker cp "${HELPERS_ROOT}/diagnostics/track_scale_10x10.php" \
    "${WEB_CID}:/var/www/html/sts/track_scale_10x10.php"
  # Deploy the edited weigh paths (sts/ is baked into the image, not mounted),
  # so the automated track-scale step applies balance_shift -> reloads route.
  # The whole track_scale plugin is deployed as a unit (helpers, warm-start,
  # dispatch, GUI) so edits to any part take effect.
  docker cp "${STS_DOCKER}/sts/plugins/track_scale/." \
    "${WEB_CID}:/var/www/html/sts/plugins/track_scale/"
  docker cp "${STS_DOCKER}/sts/warm_start_helpers.php" \
    "${WEB_CID}:/var/www/html/sts/warm_start_helpers.php"
  # calibrate_track_scale step (dispatch + catalog) lives here.
  docker cp "${STS_DOCKER}/sts/operational_steps_catalog.php" \
    "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.php"
  docker cp "${WORKFLOW}" \
    "${WEB_CID}:/var/www/html/sts/backups/session_editor/start_session.workflow.json"

  docker exec "${WEB_CID}" php /var/www/html/sts/track_scale_10x10.php \
    /var/www/html/sts/backups/session_editor/start_session.workflow.json \
    "${ROUNDS}" "${SESSIONS}"
} 2>&1 | tee "${LOG}"

echo
echo "==> Done. Log saved to ${LOG}"
