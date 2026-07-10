#!/usr/bin/env bash
# Run WORKFLOW_TEST_ALL_TYPES.recipe.json through session_run_recipe in Docker.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container not running — start sts-docker before catalog workflow run" >&2
  exit 1
fi

EDITOR_DIR="${BACKUPS_DIR}/session_editor"
RECIPE="${EDITOR_DIR}/WORKFLOW_TEST_ALL_TYPES.recipe.json"
if [[ ! -f "${RECIPE}" ]]; then
  echo "Missing ${RECIPE} — run bin/run_catalog_tests.sh first" >&2
  exit 1
fi

docker cp "${HELPERS_ROOT}/sts/run_catalog_workflow.php" "${WEB_CID}:/var/www/html/sts/run_catalog_workflow.php"
docker cp "${RECIPE}" "${WEB_CID}:/var/www/html/sts/backups/session_editor/WORKFLOW_TEST_ALL_TYPES.recipe.json"
docker cp "${EDITOR_DIR}/WORKFLOW_TEST_ALL_TYPES.csv" "${WEB_CID}:/var/www/html/sts/backups/session_editor/WORKFLOW_TEST_ALL_TYPES.csv"

docker exec "${WEB_CID}" php /var/www/html/sts/run_catalog_workflow.php
