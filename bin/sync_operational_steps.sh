#!/usr/bin/env bash
# Hot-deploy sts/ to container. Session editor CSVs live only in sts-backups/session_editor/.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

SOURCE_CSV="${HELPERS_ROOT}/docs/STS_OPERATIONAL_STEPS.csv"
SOURCE_RECIPE="${HELPERS_ROOT}/docs/STS_OPERATIONAL_RECIPE.json"
STS_WEB="${STS_DOCKER}/sts"
EDITOR_DIR="${BACKUPS_DIR}/session_editor"
FROM_BACKUPS=0
SEED_RECIPE=0

usage() {
  cat <<'EOF'
Usage: sync_operational_steps.sh [--from-backups] [--seed-recipe]

Hot-deploy sts/ to the web container. Session editor reads/writes CSVs only under
sts-backups/session_editor/ (not seeded unless --seed-recipe).

  --from-backups  Pull saved recipe/CSV from session_editor into docs/
  --seed-recipe   Copy docs recipe into session_editor (optional first-time seed)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-backups) FROM_BACKUPS=1; shift ;;
    --seed-recipe) SEED_RECIPE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "${FROM_BACKUPS}" -eq 1 ]]; then
  if [[ -f "${EDITOR_DIR}/STS_OPERATIONAL_STEPS.csv" ]]; then
    cp -f "${EDITOR_DIR}/STS_OPERATIONAL_STEPS.csv" "${SOURCE_CSV}"
  elif [[ -f "${BACKUPS_DIR}/STS_OPERATIONAL_STEPS.csv" ]]; then
    cp -f "${BACKUPS_DIR}/STS_OPERATIONAL_STEPS.csv" "${SOURCE_CSV}"
  fi
  if [[ -f "${EDITOR_DIR}/STS_OPERATIONAL_RECIPE.json" ]]; then
    cp -f "${EDITOR_DIR}/STS_OPERATIONAL_RECIPE.json" "${SOURCE_RECIPE}"
  elif [[ -f "${BACKUPS_DIR}/STS_OPERATIONAL_RECIPE.json" ]]; then
    cp -f "${BACKUPS_DIR}/STS_OPERATIONAL_RECIPE.json" "${SOURCE_RECIPE}"
  fi
fi

if [[ ! -d "${STS_WEB}" ]]; then
  echo "Missing ${STS_WEB} — sts-docker/sts not found" >&2
  exit 1
fi

mkdir -p "${EDITOR_DIR}"
if [[ "${SEED_RECIPE}" -eq 1 ]]; then
  if [[ ! -f "${SOURCE_CSV}" ]]; then
    echo "Missing ${SOURCE_CSV}" >&2
    exit 1
  fi
  cp -f "${SOURCE_CSV}" "${EDITOR_DIR}/STS_OPERATIONAL_STEPS.csv"
  if [[ -f "${SOURCE_RECIPE}" ]]; then
    cp -f "${SOURCE_RECIPE}" "${EDITOR_DIR}/STS_OPERATIONAL_RECIPE.json"
  fi
fi

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
  echo "Session index:   http://localhost:8980/sts/session.php"
else
  echo "Web container not running — deploy sts/ manually"
fi

echo "Session editor dir: ${EDITOR_DIR}"
