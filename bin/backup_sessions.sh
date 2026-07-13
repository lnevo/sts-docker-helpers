#!/usr/bin/env bash
# Snapshot (and restore) the STS session state to a timestamped archive.
#
# Live session state now lives on the host-mounted sts-backups volume at
# sts/backups/session_state/sessions (see session_web_root() in
# session_helpers.php), so it already persists across container recreation. This
# helper keeps timestamped .tar.gz snapshots alongside it (in session_state/) so
# you can roll back to an earlier state.
#
# The archive is written into the mounted backups dir
# (~/sts/sts-backups -> /var/www/html/sts/backups) under session_state/, so it
# persists on the host and shows up in sts-backups/session_state/.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

# Live session state and the backups mount as seen from inside the web container.
CONTAINER_STATE_DIR="/var/www/html/sts/backups/session_state"
CONTAINER_SESSIONS_PARENT="${CONTAINER_STATE_DIR}"
CONTAINER_SESSIONS_DIR="${CONTAINER_SESSIONS_PARENT}/sessions"
HOST_STATE_DIR="${BACKUPS_DIR}/session_state"

usage() {
  cat <<EOF
Usage: backup_sessions.sh <command> [arg]

Session statistics/output live in the web container at
  ${CONTAINER_SESSIONS_DIR}
which is ephemeral (not a Docker volume). This helper snapshots them into
  ${HOST_STATE_DIR}/

Commands:
  backup            Snapshot current session state to a timestamped .tar.gz
                    (also refreshes sessions_latest.tar.gz). Default command.
  restore [NAME]    Restore session state from an archive (default: latest).
                    NAME may be a filename in session_state/ or a full path.
                    Existing backups/session_state/sessions is replaced.
  list              List available session-state archives.
  -h, --help        Show this help.
EOF
}

resolve_web_cid() {
  WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
  if [[ -z "${WEB_CID}" ]]; then
    echo "Web container is not running. Start with:" >&2
    echo "  cd ${STS_DOCKER} && docker compose --profile build up -d" >&2
    exit 1
  fi
}

cmd_backup() {
  resolve_web_cid
  if ! docker exec "${WEB_CID}" sh -c "[ -d '${CONTAINER_SESSIONS_DIR}' ]"; then
    echo "No session state found at ${CONTAINER_SESSIONS_DIR} — nothing to back up." >&2
    exit 1
  fi

  local stamp archive
  stamp="$(date +%Y%m%d_%H%M%S)"
  archive="sessions_${stamp}.tar.gz"

  echo "==> Archiving ${CONTAINER_SESSIONS_DIR} -> ${HOST_STATE_DIR}/${archive}"
  # Run tar inside the container so it writes through the mounted backups dir as
  # www-data (correct ownership) and no host-side docker cp is needed.
  docker exec -u www-data "${WEB_CID}" sh -c "
    set -e
    mkdir -p '${CONTAINER_STATE_DIR}'
    tar -czf '${CONTAINER_STATE_DIR}/${archive}' -C '${CONTAINER_SESSIONS_PARENT}' sessions
    cp -f '${CONTAINER_STATE_DIR}/${archive}' '${CONTAINER_STATE_DIR}/sessions_latest.tar.gz'
  "

  local count size
  count="$(docker exec "${WEB_CID}" sh -c "ls -1 '${CONTAINER_SESSIONS_DIR}' 2>/dev/null | wc -l" | tr -d '[:space:]')"
  size="$(du -h "${HOST_STATE_DIR}/${archive}" 2>/dev/null | cut -f1)"
  echo "==> Backed up ${count} session(s) (${size})"
  echo "    ${HOST_STATE_DIR}/${archive}"
  echo "    ${HOST_STATE_DIR}/sessions_latest.tar.gz (refreshed)"
}

cmd_restore() {
  resolve_web_cid
  local name="${1:-sessions_latest.tar.gz}"
  local container_archive

  if [[ "${name}" == /* ]]; then
    # Absolute host path — copy into the container's backups mount by basename.
    if [[ ! -f "${name}" ]]; then
      echo "Archive not found: ${name}" >&2
      exit 1
    fi
    container_archive="${CONTAINER_STATE_DIR}/$(basename "${name}")"
    if [[ "$(cd "$(dirname "${name}")" && pwd)" != "${HOST_STATE_DIR}" ]]; then
      docker cp "${name}" "${WEB_CID}:${container_archive}"
    fi
  else
    container_archive="${CONTAINER_STATE_DIR}/${name}"
  fi

  if ! docker exec "${WEB_CID}" sh -c "[ -f '${container_archive}' ]"; then
    echo "Archive not found in container: ${container_archive}" >&2
    echo "Run 'backup_sessions.sh list' to see available archives." >&2
    exit 1
  fi

  echo "==> Restoring session state from ${container_archive}"
  docker exec -u www-data "${WEB_CID}" sh -c "
    set -e
    mkdir -p '${CONTAINER_SESSIONS_PARENT}'
    rm -rf '${CONTAINER_SESSIONS_DIR}'
    tar -xzf '${container_archive}' -C '${CONTAINER_SESSIONS_PARENT}'
  "
  local count
  count="$(docker exec "${WEB_CID}" sh -c "ls -1 '${CONTAINER_SESSIONS_DIR}' 2>/dev/null | wc -l" | tr -d '[:space:]')"
  echo "==> Restored ${count} session(s) to ${CONTAINER_SESSIONS_DIR}"
}

cmd_list() {
  if [[ ! -d "${HOST_STATE_DIR}" ]]; then
    echo "No archives yet (${HOST_STATE_DIR} does not exist)."
    return 0
  fi
  echo "Archives in ${HOST_STATE_DIR}:"
  ls -lh "${HOST_STATE_DIR}"/*.tar.gz 2>/dev/null || echo "  (none)"
}

main() {
  local cmd="${1:-backup}"
  case "${cmd}" in
    backup) shift || true; cmd_backup "$@" ;;
    restore) shift || true; cmd_restore "$@" ;;
    list) cmd_list ;;
    -h|--help) usage ;;
    *) echo "Unknown command: ${cmd}" >&2; echo >&2; usage; exit 1 ;;
  esac
}

main "$@"
