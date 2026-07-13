#!/usr/bin/env bash
# Drive a saved workflow through session_run_recipe in Docker (correct phased
# switch-list engine). Defaults to the editor's ACTIVE workflow so it runs the
# same recipe as the app UI. Pass a workflow file/name to override.
#
# Usage:
#   run_catalog_workflow.sh                         # active saved workflow
#   run_catalog_workflow.sh start_session.workflow.json
#   run_catalog_workflow.sh /abs/path/to/workflow.json
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container not running — start sts-docker before catalog workflow run" >&2
  exit 1
fi

WORKFLOW_ARG="${1:-}"
CONTAINER_ARG=""
if [[ -n "${WORKFLOW_ARG}" ]]; then
  if [[ -f "${WORKFLOW_ARG}" ]]; then
    # Absolute/relative host path — copy into the container's editor dir.
    docker cp "${WORKFLOW_ARG}" \
      "${WEB_CID}:/var/www/html/sts/backups/session_editor/$(basename "${WORKFLOW_ARG}")"
    CONTAINER_ARG="$(basename "${WORKFLOW_ARG}")"
  else
    # Treat as a workflow name resolved inside the container's editor dir.
    CONTAINER_ARG="${WORKFLOW_ARG}"
  fi
fi

# Keep the runner in sync with the source tree (no image rebuild needed).
docker cp "${STS_DOCKER}/sts/run_catalog_workflow.php" \
  "${WEB_CID}:/var/www/html/sts/run_catalog_workflow.php"

# Run as www-data so session output stays writable by Apache/PHP.
sts_helpers_docker_exec_www "${WEB_CID}" \
  php /var/www/html/sts/run_catalog_workflow.php ${CONTAINER_ARG:+"${CONTAINER_ARG}"}
