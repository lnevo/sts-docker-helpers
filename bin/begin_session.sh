#!/usr/bin/env bash
# Begin a live operating session from warm-start end state (Docker STS).
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"


usage() {
  cat <<'EOF'
Usage: begin_session.sh [options]

After STG-SCULLY is complete (manual or --run-stg-scully): load/unload, increment session,
fill unfilled car orders, reposition empties, auto-assign jobs.

Exits with an error if STG-SCULLY backlog remains and --run-stg-scully was not passed.

Session prep options (passed to begin_operating_session.php):
  --run-stg-scully     Run STG-SCULLY staging before session prep (required if backlog exists)
  --no-increment       Keep current session number
  --no-fill            Skip filling unfilled car orders (default: fill all eligible)
  --fill-fraction=N    Fraction of unfilled orders to fill (default 1.0)
  --no-reposition      Skip empty reposition orders
  --no-assign          Skip auto-assign
  --repo-fraction=N    Reposition fraction (default 0.65)
  --generate           Generate revenue orders for the new session
  --backup=NAME        Save backup after setup

Switch list options:
  --switchlists        After session prep, generate phased switch lists (mobile + half sheet, D749, NVL, CK1)

Other:
  -h, --help           Show help
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

GENERATE_SWITCHLISTS=0
PHP_ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --switchlists) GENERATE_SWITCHLISTS=1 ;;
    *) PHP_ARGS+=("${arg}") ;;
  esac
done

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container is not running. Start with:" >&2
  echo "  cd ${STS_DOCKER} && docker compose --profile build up -d" >&2
  exit 1
fi

echo "==> Syncing begin_operating_session.php into web container"
docker cp "${HELPERS_ROOT}/sts/begin_operating_session.php" "${WEB_CID}:/var/www/html/sts/begin_operating_session.php"
docker cp "${HELPERS_ROOT}/sts/warm_start_helpers.php" "${WEB_CID}:/var/www/html/sts/warm_start_helpers.php"

echo "==> Beginning operating session"
docker exec "${WEB_CID}" php /var/www/html/sts/begin_operating_session.php "${PHP_ARGS[@]}"

if [[ "${GENERATE_SWITCHLISTS}" -eq 1 ]]; then
  echo "==> Generating phased switch lists (mobile + half sheet)"
  "${BIN_DIR}/generate_switchlists.sh" --format=phased
  SESSION="$(
    docker exec "${WEB_CID}" php -r \
      'chdir("/var/www/html/sts"); require "open_db.php"; $d=open_db(); $r=mysqli_query($d,"SELECT setting_value FROM settings WHERE setting_name=\"session_nbr\""); echo mysqli_fetch_row($r)[0];'
  )"
  echo "Switch list index: http://localhost:8980/switchlists/index.html"
  echo "Session index: http://localhost:8980/switchlists/session_${SESSION}/index.html"
fi
