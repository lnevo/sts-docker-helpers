#!/usr/bin/env bash
# Reset hart_seed, deploy benchmark runner, run 10x10 workflow sampling with track-scale stats.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="${ROOT}/sts-backups/session_editor/start_session.workflow.json"
COMPOSE="${ROOT}/sts-docker/docker-compose.yml"
ROUNDS="${1:-10}"
SESSIONS="${2:-10}"
LOG="${ROOT}/sts-backups/session_editor/sim_10x_track_scale_$(date +%Y%m%d_%H%M%S).log"

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
  "${ROOT}/sts-docker-helpers/bin/apply_hart_seed.sh"

  docker cp "${ROOT}/sts-docker-helpers/diagnostics/track_scale_10x10.php" \
    "${WEB_CID}:/var/www/html/sts/track_scale_10x10.php"
  # Deploy the edited weigh paths (sts/ is baked into the image, not mounted),
  # so the automated track-scale step applies balance_shift -> reloads route.
  docker cp "${ROOT}/sts-docker/sts/track_scale_helpers.php" \
    "${WEB_CID}:/var/www/html/sts/track_scale_helpers.php"
  docker cp "${ROOT}/sts-docker/sts/warm_start_helpers.php" \
    "${WEB_CID}:/var/www/html/sts/warm_start_helpers.php"
  # calibrate_track_scale step (dispatch + catalog) lives here.
  docker cp "${ROOT}/sts-docker/sts/operational_steps_catalog.php" \
    "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.php"
  docker cp "${WORKFLOW}" \
    "${WEB_CID}:/var/www/html/sts/backups/session_editor/start_session.workflow.json"

  docker exec "${WEB_CID}" php /var/www/html/sts/track_scale_10x10.php \
    /var/www/html/sts/backups/session_editor/start_session.workflow.json \
    "${ROUNDS}" "${SESSIONS}"
} 2>&1 | tee "${LOG}"

echo
echo "==> Done. Log saved to ${LOG}"
