#!/usr/bin/env bash
# Generate master switch lists (halfsheet HTML) for phased local jobs.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"


usage() {
  cat <<'EOF'
Usage: generate_switchlists.sh [options]

Generate master (multi-phase) switch lists for D749, NVL, and CK1.
Runs a dry-run simulation inside a DB transaction unless --render-only is used.

Options are passed to generate_master_switchlists.php:
  --format=halfsheet|mobile|phased|phased-mobile
                        Output layout (default: halfsheet; phased = per-phase mobile + half sheet + indexes)
  --render-only               Re-render from saved JSON cache (no DB dry-run)
  --from-halfsheet            Build JSON cache from existing halfsheet HTML
  --save-cache-only           Dry-run and save JSON cache only
  --jobs=D749,NVL,CK1   Jobs to include (default: all three)
  --output=DIR          Output root (default: repo switchlists/)
  --session=N           Expected session number (warns on mismatch)
  -h, --help            Show help
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

OUTPUT_ROOT="${HELPERS_ROOT}/../switchlists"
ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --output=*) OUTPUT_ROOT="${arg#--output=}" ;;
    *) ARGS+=("${arg}") ;;
  esac
done

echo "==> Syncing switch list scripts into web container"
docker cp "${HELPERS_ROOT}/sts/master_switchlist_helpers.php" "${WEB_CID}:/var/www/html/sts/master_switchlist_helpers.php"
docker cp "${HELPERS_ROOT}/sts/generate_master_switchlists.php" "${WEB_CID}:/var/www/html/sts/generate_master_switchlists.php"
docker cp "${HELPERS_ROOT}/sts/warm_start_helpers.php" "${WEB_CID}:/var/www/html/sts/warm_start_helpers.php"

SESSION_GUESS="$(basename "$(ls -d "${OUTPUT_ROOT}"/session_* 2>/dev/null | sort -V | tail -1)" 2>/dev/null || true)"
SESSION_GUESS="${SESSION_GUESS#session_}"
if [[ -n "${SESSION_GUESS}" && -d "${OUTPUT_ROOT}/session_${SESSION_GUESS}" ]]; then
  echo "==> Syncing existing switchlists/session_${SESSION_GUESS} into container"
  docker exec "${WEB_CID}" mkdir -p "/var/www/html/switchlists/session_${SESSION_GUESS}"
  docker cp "${OUTPUT_ROOT}/session_${SESSION_GUESS}/." "${WEB_CID}:/var/www/html/switchlists/session_${SESSION_GUESS}/"
fi

echo "==> Generating master switch lists"
docker exec "${WEB_CID}" php /var/www/html/sts/generate_master_switchlists.php --output=/var/www/html/switchlists "${ARGS[@]}"

SESSION="$(docker exec "${WEB_CID}" php -r 'chdir("/var/www/html/sts"); require "open_db.php"; $d=open_db(); $r=mysqli_query($d,"SELECT setting_value FROM settings WHERE setting_name=\"session_nbr\""); echo mysqli_fetch_row($r)[0];')"
mkdir -p "${OUTPUT_ROOT}/session_${SESSION}"
echo "==> Copying HTML to ${OUTPUT_ROOT}/session_${SESSION}"
docker cp "${WEB_CID}:/var/www/html/switchlists/session_${SESSION}/." "${OUTPUT_ROOT}/session_${SESSION}/"
if docker exec "${WEB_CID}" test -f "/var/www/html/switchlists/index.html"; then
  echo "==> Copying all-sessions index to ${OUTPUT_ROOT}/index.html"
  docker cp "${WEB_CID}:/var/www/html/switchlists/index.html" "${OUTPUT_ROOT}/index.html"
fi
