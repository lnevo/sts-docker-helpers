#!/usr/bin/env bash
# Capture a full, restorable DB snapshot for the current (or a named) operating
# session. Writes a `#`-delimited SQL dump (same format as STS Database
# Maintenance -> Backup) to sts-backups/db_session_<N>.
#
# This is the enabling prerequisite for rewind_session.sh: to reliably roll a
# session back you must have captured the DB state at the END of the previous
# session. Run this right before you start generating/working the next session
# (i.e. while session_nbr still reflects the session you just finished).
#
#   snapshot_session_db.sh                 # snapshot current session_nbr
#   snapshot_session_db.sh --name my_dump  # snapshot under a custom name
#   snapshot_session_db.sh --to 10         # label the dump as session 10
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

CUSTOM_NAME=""
FORCE_SESSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) CUSTOM_NAME="$2"; shift 2 ;;
    --to)   FORCE_SESSION="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container is not running." >&2
  exit 1
fi

# Current operating session number from the settings table.
CURRENT_SESSION="$(docker exec "${WEB_CID}" php -r '
  chdir("/var/www/html/sts");
  require "credentials.php";
  $d = mysqli_connect($server_name, $user_name, $password, $db_name);
  if (!$d) { fwrite(STDERR, mysqli_connect_error()); exit(1); }
  $r = mysqli_query($d, "select setting_value from settings where setting_name = \"session_nbr\"");
  $x = $r ? mysqli_fetch_row($r) : null;
  echo (int) ($x[0] ?? 0);
')"

SESSION_LABEL="${FORCE_SESSION:-${CURRENT_SESSION}}"
BACKUP_NAME="${CUSTOM_NAME:-db_session_${SESSION_LABEL}}"

echo "==> Snapshotting DB (session_nbr=${CURRENT_SESSION}) -> backups/${BACKUP_NAME}"
docker exec -e SNAP_NAME="${BACKUP_NAME}" "${WEB_CID}" php -r '
  chdir("/var/www/html/sts");
  require "open_db.php";
  require "backup_tables.php";
  $dbc = open_db();
  $name = getenv("SNAP_NAME");
  backup_tables($dbc, $name);
  $cars = mysqli_fetch_row(mysqli_query($dbc, "select count(*) from cars"))[0];
  $orders = mysqli_fetch_row(mysqli_query($dbc, "select count(*) from car_orders"))[0];
  $sess = mysqli_fetch_row(mysqli_query($dbc, "select setting_value from settings where setting_name=\"session_nbr\""))[0];
  fwrite(STDERR, "    cars={$cars} car_orders={$orders} session_nbr={$sess}\n");
'

SNAP_PATH="${BACKUPS_DIR}/${BACKUP_NAME}"
if [[ -f "${SNAP_PATH}" ]]; then
  echo "==> Wrote ${SNAP_PATH} ($(wc -c < "${SNAP_PATH}" | tr -d ' ') bytes)"
else
  echo "WARNING: expected snapshot not visible at ${SNAP_PATH}" >&2
fi
echo "Done."
