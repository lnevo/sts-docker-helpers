#!/usr/bin/env bash
# Sweep shipment demand (traffic_mult) and run sims to find bottleneck thresholds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SEED_DIR="${ROOT}/sts-docker-helpers/seed"
BACKUP="${ROOT}/sts-backups/hart_seed"
WORKFLOW="${ROOT}/sts-backups/session_editor/start_session.workflow.json"
COMPOSE="${ROOT}/sts-docker/docker-compose.yml"
ROUNDS="${1:-5}"
SESSIONS="${2:-8}"
LOG_DIR="${ROOT}/sts-backups/session_editor"
LOG="${LOG_DIR}/traffic_extremes_$(date +%Y%m%d_%H%M%S).log"

# Demand multipliers: >1 = shorter intervals = more orders per session.
MULTS=(1.0 1.25 1.5 1.75 2.0 2.5 3.0)

WEB_CID="$(docker compose -f "${COMPOSE}" --profile build ps -q web)"
if [[ -z "${WEB_CID}" ]]; then
  echo "STS web container is not running." >&2
  exit 1
fi

deploy_runtime() {
  docker cp "${ROOT}/sts-docker-helpers/diagnostics/track_scale_10x10.php" \
    "${WEB_CID}:/var/www/html/sts/track_scale_10x10.php"
  # Deploy the whole track_scale plugin as a unit (baked into the image, not mounted).
  docker cp "${ROOT}/sts-docker/sts/plugins/track_scale/." \
    "${WEB_CID}:/var/www/html/sts/plugins/track_scale/"
  docker cp "${ROOT}/sts-docker/sts/warm_start_helpers.php" \
    "${WEB_CID}:/var/www/html/sts/warm_start_helpers.php"
  docker cp "${ROOT}/sts-docker/sts/operational_steps_catalog.php" \
    "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.php"
  docker cp "${WORKFLOW}" \
    "${WEB_CID}:/var/www/html/sts/backups/session_editor/start_session.workflow.json"
}

echo "==> Traffic extremes benchmark" | tee "${LOG}"
echo "    Rounds: ${ROUNDS} x ${SESSIONS} sessions per traffic_mult" | tee -a "${LOG}"
echo "    Levels: ${MULTS[*]}" | tee -a "${LOG}"
echo | tee -a "${LOG}"

deploy_runtime

printf "%-8s | %-5s %-5s %-5s %-5s | %-5s %-5s | %-5s %-5s | %-6s %-6s %-6s | %s\n" \
  "Traffic" "Dem" "Scul" "Sth" "Nv" "Unfl" "Open" "Wgh" "Rld" "CK1pu" "D749pu" "NVLpu" "ok" \
  | tee -a "${LOG}"
printf "%s\n" "$(printf '%.0s-' {1..95})" | tee -a "${LOG}"

for mult in "${MULTS[@]}"; do
  echo "==> traffic_mult=${mult}" | tee -a "${LOG}"
  python3 "${SEED_DIR}/generate_hart_seed.py" \
    --traffic-mult "${mult}" \
    --output "${BACKUP}" >> "${LOG}" 2>&1

  "${ROOT}/sts-docker-helpers/bin/apply_hart_seed.sh" >> "${LOG}" 2>&1

  OUT="$(docker exec "${WEB_CID}" php /var/www/html/sts/track_scale_10x10.php \
    /var/www/html/sts/backups/session_editor/start_session.workflow.json \
    "${ROUNDS}" "${SESSIONS}" 2>&1)"
  echo "${OUT}" >> "${LOG}"

  # Parse AVG line from benchmark output.
  AVG_LINE="$(echo "${OUT}" | grep '^AVG' || true)"
  if [[ -z "${AVG_LINE}" ]]; then
    echo "WARN: no AVG line for traffic_mult=${mult}" | tee -a "${LOG}"
    continue
  fi

  # Extract key fields from fixed-width AVG row (matches track_scale_10x10.php).
  dem="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' | awk '{print $1}')"
  scul="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' | awk '{print $2}')"
  sth="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' | awk '{print $3}')"
  nv="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' | awk '{print $4}')"
  unfl="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}' | awk '{print $1}')"
  open="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}' | awk '{print $2}')"
  ck1="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$6); print $6}' | awk '{print $1}')"
  d749="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$6); print $6}' | awk '{print $2}')"
  nvl="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$6); print $6}' | awk '{print $3}')"
  wgh="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$5); print $5}' | awk '{print $1}')"
  rld="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$5); print $5}' | awk '{print $2}')"
  ok="$(echo "${AVG_LINE}" | grep -oE '[0-9]+/[0-9]+ ok' || echo '?')"

  RELOAD_BLOCK="$(echo "${OUT}" | sed -n '/== Track scale reload routing ==/,/^$/p' | grep 'Overall reload rate' || true)"
  echo "${RELOAD_BLOCK}" >> "${LOG}"

  printf "%-8s | %-5s %-5s %-5s %-5s | %-5s %-5s | %-5s %-5s | %-6s %-6s %-6s | %s\n" \
    "${mult}x" "${dem}" "${scul}" "${sth}" "${nv}" "${unfl}" "${open}" \
    "${wgh}" "${rld}" "${ck1}" "${d749}" "${nvl}" "${ok}" | tee -a "${LOG}"
  echo | tee -a "${LOG}"
done

echo "==> Restoring baseline seed (traffic_mult=1.0, moderate home split)" | tee -a "${LOG}"
python3 "${SEED_DIR}/generate_hart_seed.py" --traffic-mult 1.0 --output "${BACKUP}" >> "${LOG}" 2>&1
"${ROOT}/sts-docker-helpers/bin/apply_hart_seed.sh" >> "${LOG}" 2>&1

echo "==> Done. Full log: ${LOG}" | tee -a "${LOG}"
