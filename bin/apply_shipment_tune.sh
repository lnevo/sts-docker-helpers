#!/usr/bin/env bash
# Apply tune_shipment_orders.sql to the running STS MariaDB container.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${BIN_DIR}/../lib/paths.sh"
sts_helpers_resolve_paths

SQL_FILE="${MIGRATIONS_DIR}/tune_shipment_orders.sql"
YARD_BALANCE_PY="${SEED_DIR}/balance_shipment_yards.py"

MYSQL_USER="${MYSQL_USER:-sts_user}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-sts_password}"
MYSQL_DATABASE="${MYSQL_DATABASE:-sts_db3}"
RESET_LAST_SHIP=0

usage() {
  cat <<'EOF'
Usage: apply_shipment_tune.sh [options]

Update shipment min/max interval and amount fields in the running STS database
to reduce car-order volume during Generate Car Orders (Automatic).

Load/unload times are NOT changed — they do not affect order generation.

Options:
  --sql-file PATH       SQL file to apply (default: tune_shipment_orders.sql)
  --reset-last-ship     Set last_ship_date = 0 on all shipments after tuning
  -h, --help            Show this help

Requires the build-profile db container to be running:
  cd sts-docker && docker compose --profile build up -d
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sql-file)
      SQL_FILE="$2"
      shift 2
      ;;
    --reset-last-ship)
      RESET_LAST_SHIP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "${SQL_FILE}" ]]; then
  echo "SQL file not found: ${SQL_FILE}" >&2
  exit 1
fi

DB_CID="$("${COMPOSE[@]}" ps -q db 2>/dev/null || true)"
if [[ -z "${DB_CID}" ]]; then
  echo "Database container is not running. Start with:" >&2
  echo "  cd ${STS_DOCKER} && docker compose --profile build up -d" >&2
  exit 1
fi

mysql_exec() {
  docker exec -i "${DB_CID}" \
    mariadb -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "${MYSQL_DATABASE}" "$@"
}

echo "==> Shipment intervals before tune"
mysql_exec -e "
SELECT
  CASE
    WHEN cc.code IN ('GA', 'GD') AND s.code LIKE 'IX-%' THEN 'ix_gondola'
    WHEN cc.code IN ('GA', 'GD') THEN 'local_gondola'
    WHEN cc.code = 'FM' AND s.code LIKE 'IX-%' THEN 'ix_fm'
    WHEN cc.code = 'FM' THEN 'local_fm'
    WHEN cc.code = 'HP' AND s.code LIKE 'IX-%' THEN 'ix_hp'
    WHEN cc.code = 'HP' THEN 'local_hp'
    WHEN cc.code IN ('TA', 'TL') AND s.code LIKE 'IX-%' THEN 'ix_tank'
    WHEN cc.code IN ('TA', 'TL') THEN 'local_tank'
    WHEN s.code LIKE 'IX-%' THEN 'ix_other'
    ELSE 'local'
  END AS kind,
  COUNT(*) AS shipments,
  MIN(s.min_interval) AS min_int,
  MAX(s.max_interval) AS max_int,
  MIN(s.min_amount) AS min_amt,
  MAX(s.max_amount) AS max_amt
FROM shipments s
LEFT JOIN car_codes cc ON cc.id = s.car_code
GROUP BY kind
ORDER BY kind;
"

echo "==> Applying ${SQL_FILE}"
mysql_exec < "${SQL_FILE}"

if [[ -f "${YARD_BALANCE_PY}" ]]; then
  echo "==> Balancing interchange yards (available fleet)"
  python3 "${YARD_BALANCE_PY}" --apply --config "${SEED_DIR}/hart_seed_config.json"
fi

if [[ "${RESET_LAST_SHIP}" -eq 1 ]]; then
  echo "==> Resetting last_ship_date to 0 on all shipments"
  mysql_exec -e "UPDATE shipments SET last_ship_date = 0;"
fi

echo "==> Shipment intervals after tune"
mysql_exec -e "
SELECT
  CASE
    WHEN cc.code IN ('GA', 'GD') AND s.code LIKE 'IX-%' THEN 'ix_gondola'
    WHEN cc.code IN ('GA', 'GD') THEN 'local_gondola'
    WHEN cc.code = 'FM' AND s.code LIKE 'IX-%' THEN 'ix_fm'
    WHEN cc.code = 'FM' THEN 'local_fm'
    WHEN cc.code = 'HP' AND s.code LIKE 'IX-%' THEN 'ix_hp'
    WHEN cc.code = 'HP' THEN 'local_hp'
    WHEN cc.code IN ('TA', 'TL') AND s.code LIKE 'IX-%' THEN 'ix_tank'
    WHEN cc.code IN ('TA', 'TL') THEN 'local_tank'
    WHEN s.code LIKE 'IX-%' THEN 'ix_other'
    ELSE 'local'
  END AS kind,
  COUNT(*) AS shipments,
  MIN(s.min_interval) AS min_int,
  MAX(s.max_interval) AS max_int,
  MIN(s.min_amount) AS min_amt,
  MAX(s.max_amount) AS max_amt
FROM shipments s
LEFT JOIN car_codes cc ON cc.id = s.car_code
GROUP BY kind
ORDER BY kind;
"

echo "==> Interchange yard forecast balance (10-session est.)"
mysql_exec -e "
SELECT r.station,
       COUNT(*) AS shipments,
       ROUND(SUM(10 * (s.min_amount + s.max_amount) / 2
            / NULLIF((s.min_interval + s.max_interval) / 2, 0)), 1) AS est_carloads_10sess
FROM shipments s
LEFT JOIN locations l ON l.id = s.loading_location
LEFT JOIN routing r ON r.id = l.station
WHERE r.station IN ('Demmler Yard', 'Scully Yard')
  AND s.code NOT LIKE 'COKE-%'
GROUP BY r.station
ORDER BY r.station;
"

echo "Done. Generate Car Orders will now fire shipments less often."
echo "Tip: wipe or restart car orders first if you want a clean slate for the next session."
