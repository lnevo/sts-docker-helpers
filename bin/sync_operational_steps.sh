#!/usr/bin/env bash
# Hot-deploy sts/ to container. Session editor CSVs live only in sts-backups/session_editor/.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

STS_WEB="${STS_DOCKER}/sts"
EDITOR_DIR="${BACKUPS_DIR}/session_editor"
TEST_CATALOG=0

usage() {
  cat <<'EOF'
Usage: sync_operational_steps.sh [--test-catalog]

Hot-deploy sts/ to the web container. Session editor reads/writes CSVs only under
sts-backups/session_editor/.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-catalog) TEST_CATALOG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ ! -d "${STS_WEB}" ]]; then
  echo "Missing ${STS_WEB} — sts-docker/sts not found" >&2
  exit 1
fi

mkdir -p "${EDITOR_DIR}"

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -n "${WEB_CID}" ]]; then
  docker cp "${STS_WEB}/." "${WEB_CID}:/var/www/html/sts/"
  docker exec "${WEB_CID}" rm -f /var/www/html/sts/index.php 2>/dev/null || true
  docker exec "${WEB_CID}" rm -f /var/www/html/sts/STS_OPERATIONAL_STEPS.csv /var/www/html/sts/STS_OPERATIONAL_RECIPE.json 2>/dev/null || true
  docker exec "${WEB_CID}" mkdir -p /var/www/html/sts/backups/session_editor
  docker cp "${EDITOR_DIR}/." "${WEB_CID}:/var/www/html/sts/backups/session_editor/"
  docker exec "${WEB_CID}" chown -R www-data:www-data /var/www/html/sts/backups/session_editor 2>/dev/null || true
  docker exec "${WEB_CID}" chown -R www-data:www-data /var/www/html/sts 2>/dev/null || true
  echo "Session editor:  http://localhost:8980/sts/editor.html"
  echo "API docs:        http://localhost:8980/sts/operational_steps_api-docs.html"
  echo "Session index:   http://localhost:8980/sts/session.php"
else
  echo "Web container not running — deploy sts/ manually"
fi

echo "Session editor dir: ${EDITOR_DIR}"

if [[ "${TEST_CATALOG}" -eq 1 ]]; then
  "${BIN_DIR}/run_catalog_tests.sh"
fi
