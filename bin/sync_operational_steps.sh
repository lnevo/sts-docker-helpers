#!/usr/bin/env bash
# Sync operational steps workflow builder into session/ (local + Docker container).
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

SOURCE_CSV="${HELPERS_ROOT}/docs/STS_OPERATIONAL_STEPS.csv"
SOURCE_RECIPE="${HELPERS_ROOT}/docs/STS_OPERATIONAL_RECIPE.json"
FROM_BACKUPS=0

usage() {
  cat <<'EOF'
Usage: sync_operational_steps.sh [--from-backups]

Sync workflow builder (editor + PHP API + catalog) and recipe/CSV into session/.
Default source: docs/STS_OPERATIONAL_STEPS.csv
  --from-backups  Pull saved recipe/CSV from sts-backups into docs/
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-backups) FROM_BACKUPS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "${FROM_BACKUPS}" -eq 1 ]]; then
  if [[ -f "${BACKUPS_DIR}/STS_OPERATIONAL_STEPS.csv" ]]; then
    cp -f "${BACKUPS_DIR}/STS_OPERATIONAL_STEPS.csv" "${SOURCE_CSV}"
  fi
  if [[ -f "${BACKUPS_DIR}/STS_OPERATIONAL_RECIPE.json" ]]; then
    cp -f "${BACKUPS_DIR}/STS_OPERATIONAL_RECIPE.json" "${SOURCE_RECIPE}"
  fi
fi

SESSION_SRC="${HELPERS_ROOT}/session"
EDITOR_HTML="${SESSION_SRC}/editor.html"
SIMULATOR_PHP="${SESSION_SRC}/simulator.php"
API_PHP="${SESSION_SRC}/operational_steps_api.php"
INDEX_PHP="${SESSION_SRC}/index.php"
JOB_PHP="${SESSION_SRC}/job.php"
WORKFLOW_JS="${SESSION_SRC}/workflow-shared.js"
WORKFLOW_CSS="${SESSION_SRC}/workflow-ui.css"
CATALOG_PHP="${HELPERS_ROOT}/sts/operational_steps_catalog.php"
SESSION_HELPERS="${HELPERS_ROOT}/sts/session_helpers.php"
SAVE_PHP="${HELPERS_ROOT}/sts/save_operational_steps.php"
OUTPUT_ROOT="${HELPERS_ROOT}/../session"

if [[ ! -f "${SOURCE_CSV}" ]]; then
  echo "Missing ${SOURCE_CSV}" >&2
  exit 1
fi

mkdir -p "${OUTPUT_ROOT}"
cp -f "${SOURCE_CSV}" "${OUTPUT_ROOT}/STS_OPERATIONAL_STEPS.csv"
cp -f "${EDITOR_HTML}" "${OUTPUT_ROOT}/editor.html"
cp -f "${SIMULATOR_PHP}" "${OUTPUT_ROOT}/simulator.php"
cp -f "${API_PHP}" "${OUTPUT_ROOT}/operational_steps_api.php"
cp -f "${INDEX_PHP}" "${OUTPUT_ROOT}/index.php"
cp -f "${JOB_PHP}" "${OUTPUT_ROOT}/job.php"
cp -f "${WORKFLOW_JS}" "${OUTPUT_ROOT}/workflow-shared.js"
cp -f "${WORKFLOW_CSS}" "${OUTPUT_ROOT}/workflow-ui.css"
cp -f "${SAVE_PHP}" "${OUTPUT_ROOT}/save_operational_steps.php"
cp -f "${SOURCE_CSV}" "${BACKUPS_DIR}/STS_OPERATIONAL_STEPS.csv"

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -n "${WEB_CID}" ]]; then
  docker exec "${WEB_CID}" mkdir -p /var/www/html/session
  docker cp "${CATALOG_PHP}" "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.php"
  docker cp "${SESSION_HELPERS}" "${WEB_CID}:/var/www/html/sts/session_helpers.php"
  docker cp "${HELPERS_ROOT}/sts/master_switchlist_helpers.php" "${WEB_CID}:/var/www/html/sts/master_switchlist_helpers.php"
  docker cp "${HELPERS_ROOT}/sts/warm_start_helpers.php" "${WEB_CID}:/var/www/html/sts/warm_start_helpers.php"
  docker cp "${HELPERS_ROOT}/sts/generate_master_switchlists.php" "${WEB_CID}:/var/www/html/sts/generate_master_switchlists.php"
  docker cp "${OUTPUT_ROOT}/STS_OPERATIONAL_STEPS.csv" "${WEB_CID}:/var/www/html/session/STS_OPERATIONAL_STEPS.csv"
  docker cp "${OUTPUT_ROOT}/editor.html" "${WEB_CID}:/var/www/html/session/editor.html"
  docker cp "${OUTPUT_ROOT}/simulator.php" "${WEB_CID}:/var/www/html/session/simulator.php"
  docker cp "${OUTPUT_ROOT}/operational_steps_api.php" "${WEB_CID}:/var/www/html/session/operational_steps_api.php"
  docker cp "${OUTPUT_ROOT}/index.php" "${WEB_CID}:/var/www/html/session/index.php"
  docker cp "${OUTPUT_ROOT}/job.php" "${WEB_CID}:/var/www/html/session/job.php"
  docker cp "${OUTPUT_ROOT}/workflow-shared.js" "${WEB_CID}:/var/www/html/session/workflow-shared.js"
  docker cp "${OUTPUT_ROOT}/workflow-ui.css" "${WEB_CID}:/var/www/html/session/workflow-ui.css"
  docker cp "${OUTPUT_ROOT}/save_operational_steps.php" "${WEB_CID}:/var/www/html/session/save_operational_steps.php"
  docker cp "${SESSION_SRC}/session_index_template.php" "${WEB_CID}:/var/www/html/session/session_index_template.php"
  if [[ -f "${SOURCE_RECIPE}" ]]; then
    cp -f "${SOURCE_RECIPE}" "${OUTPUT_ROOT}/STS_OPERATIONAL_RECIPE.json"
    docker cp "${OUTPUT_ROOT}/STS_OPERATIONAL_RECIPE.json" "${WEB_CID}:/var/www/html/session/STS_OPERATIONAL_RECIPE.json"
    cp -f "${SOURCE_RECIPE}" "${BACKUPS_DIR}/STS_OPERATIONAL_RECIPE.json"
  else
    docker exec "${WEB_CID}" php -r '
chdir("/var/www/html/sts");
require_once "operational_steps_catalog.php";
$csv = "/var/www/html/session/STS_OPERATIONAL_STEPS.csv";
$r = operational_steps_default_recipe_from_csv_file($csv);
file_put_contents("/var/www/html/session/STS_OPERATIONAL_RECIPE.json", json_encode($r, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES)."\n");
file_put_contents("/var/www/html/sts/backups/STS_OPERATIONAL_RECIPE.json", json_encode($r, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES)."\n");
echo count($r["steps"])." recipe steps\n";
'
    docker cp "${WEB_CID}:/var/www/html/session/STS_OPERATIONAL_RECIPE.json" "${OUTPUT_ROOT}/STS_OPERATIONAL_RECIPE.json" 2>/dev/null || true
    docker cp "${WEB_CID}:/var/www/html/session/STS_OPERATIONAL_RECIPE.json" "${HELPERS_ROOT}/docs/STS_OPERATIONAL_RECIPE.json" 2>/dev/null || true
  fi
  docker exec "${WEB_CID}" chown -R www-data:www-data /var/www/html/session 2>/dev/null || true
  docker exec "${WEB_CID}" chmod -R u+rwX /var/www/html/session 2>/dev/null || true
  echo "Workflow editor:  http://localhost:8980/session/editor.html"
  echo "Session simulator: http://localhost:8980/session/simulator.php"
  echo "Session index:    http://localhost:8980/session/index.php"
else
  echo "Web container not running — local files only under ${OUTPUT_ROOT}/"
fi

echo "CSV: ${BACKUPS_DIR}/STS_OPERATIONAL_STEPS.csv"
