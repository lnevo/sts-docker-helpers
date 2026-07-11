#!/usr/bin/env bash
# Validate catalog API parity and regenerate WORKFLOW_TEST_ALL_TYPES.recipe.json.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container not running — start sts-docker before catalog tests" >&2
  exit 1
fi

docker cp "${STS_DOCKER}/sts/operational_steps_catalog.php" "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.php"
docker cp "${STS_DOCKER}/sts/session_runtime.php" "${WEB_CID}:/var/www/html/sts/session_runtime.php"
docker cp "${STS_DOCKER}/sts/session_simulator_ops.php" "${WEB_CID}:/var/www/html/sts/session_simulator_ops.php"
docker cp "${STS_DOCKER}/sts/session_helpers.php" "${WEB_CID}:/var/www/html/sts/session_helpers.php"
docker cp "${STS_DOCKER}/sts/catalog_test_matrix.php" "${WEB_CID}:/var/www/html/sts/catalog_test_matrix.php"
docker cp "${HELPERS_ROOT}/bin/validate_catalog_api.php" "${WEB_CID}:/tmp/validate_catalog_api.php"
docker cp "${HELPERS_ROOT}/bin/generate_test_workflow_csv.php" "${WEB_CID}:/tmp/generate_test_workflow_csv.php"

docker exec -e STS_HELPERS_ROOT=/var/www/html "${WEB_CID}" php /tmp/validate_catalog_api.php

echo "==> Regenerating OpenAPI catalog schemas"
docker cp "${STS_DOCKER}/sts/generate_operational_steps_openapi_catalog.php" "${WEB_CID}:/var/www/html/sts/generate_operational_steps_openapi_catalog.php"
docker cp "${STS_DOCKER}/sts/operational_steps_catalog.php" "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.php"
docker exec "${WEB_CID}" php /var/www/html/sts/generate_operational_steps_openapi_catalog.php /var/www/html/sts/operational_steps_catalog.openapi.generated.yaml
docker cp "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.openapi.generated.yaml" "${STS_DOCKER}/sts/operational_steps_catalog.openapi.generated.yaml"

EDITOR_DIR="${BACKUPS_DIR}/session_editor"
mkdir -p "${EDITOR_DIR}" "${HELPERS_ROOT}/docs"

docker exec -e STS_HELPERS_ROOT=/var/www/html "${WEB_CID}" php /tmp/generate_test_workflow_csv.php /tmp/WORKFLOW_TEST_ALL_TYPES.recipe.json

docker cp "${WEB_CID}:/tmp/WORKFLOW_TEST_ALL_TYPES.recipe.json" "${EDITOR_DIR}/WORKFLOW_TEST_ALL_TYPES.recipe.json"

cp -f "${EDITOR_DIR}/WORKFLOW_TEST_ALL_TYPES.recipe.json" "${HELPERS_ROOT}/docs/WORKFLOW_TEST_ALL_TYPES.recipe.json"

docker cp "${EDITOR_DIR}/WORKFLOW_TEST_ALL_TYPES.recipe.json" "${WEB_CID}:/var/www/html/sts/backups/session_editor/WORKFLOW_TEST_ALL_TYPES.recipe.json"

echo "Catalog tests OK — ${EDITOR_DIR}/WORKFLOW_TEST_ALL_TYPES.recipe.json"

if [[ "${RUN_WORKFLOW:-1}" -eq 1 ]]; then
  RUN_WORKFLOW=1 "${BIN_DIR}/run_catalog_workflow.sh"
fi
