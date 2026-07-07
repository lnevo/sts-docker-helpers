#!/usr/bin/env bash
# Begin a live operating session from warm-start end state (Docker STS).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "${SCRIPT_DIR}/lib/paths.sh"
sts_helpers_resolve_paths

usage() {
  cat <<'EOF'
Usage: begin_session.sh [options]

After STG-SCULLY is complete (manual or --run-stg-scully): load/unload, increment session, reposition
empties, auto-assign jobs. Does NOT fill orders.

Exits with an error if STG-SCULLY backlog remains and --run-stg-scully was not passed.

Options are passed to begin_operating_session.php:
  --run-stg-scully     Run STG-SCULLY staging before session prep (required if backlog exists)
  --no-increment       Keep current session number
  --no-reposition      Skip empty reposition orders
  --no-assign          Skip auto-assign
  --repo-fraction=N    Reposition fraction (default 0.65)
  --generate           Generate revenue orders for the new session
  --backup=NAME        Save backup after setup
  -h, --help           Show help

Prerequisites:
  - Web container running (docker compose --profile build up -d)
  - Warm-start end state loaded (e.g. hart_warm_start)
  - STG-SCULLY complete (manually in STS, or use --run-stg-scully)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container is not running. Start with:" >&2
  echo "  cd ${STS_DOCKER} && docker compose --profile build up -d" >&2
  exit 1
fi

echo "==> Syncing begin_operating_session.php into web container"
docker cp "${SCRIPT_DIR}/sts/begin_operating_session.php" "${WEB_CID}:/var/www/html/sts/begin_operating_session.php"
docker cp "${SCRIPT_DIR}/sts/warm_start_helpers.php" "${WEB_CID}:/var/www/html/sts/warm_start_helpers.php"

echo "==> Beginning operating session"
docker exec "${WEB_CID}" php /var/www/html/sts/begin_operating_session.php "$@"
