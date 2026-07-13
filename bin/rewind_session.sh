#!/usr/bin/env bash
# Rewind the STS database: delete an operating session and return the DB to the
# END of the previous session.
#
# STS keeps no automatic per-session DB snapshot, so a reliable rewind requires a
# snapshot captured at the end of the target-1 session (see snapshot_session_db.sh):
#   sts-backups/db_session_<PREV>
#
# What this does (default = remove the current session_nbr):
#   1. Safety-dump the current DB to sts-backups/rewind_undo_<timestamp>
#   2. Restore sts-backups/db_session_<PREV> (full # -delimited replay; photos
#      and calibration are left untouched)
#   3. Archive + remove the session_state output tree(s) for the removed
#      session(s) into sts-backups/rewind_archive/
#   4. Verify settings.session_nbr == PREV
#
# Usage:
#   rewind_session.sh                 # remove current session, restore PREV snapshot
#   rewind_session.sh --to 11         # remove session 11 (restore db_session_10)
#   rewind_session.sh --snapshot NAME # restore an explicitly named dump
#   rewind_session.sh --dry-run       # show the plan, change nothing
#   rewind_session.sh --allow-reverse # best-effort reverse-apply if no snapshot
#                                     #   (WARNING: cannot fully restore car
#                                     #    positions/status without a snapshot)
#   rewind_session.sh --yes           # skip the confirmation prompt
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

TARGET=""
SNAPSHOT_NAME=""
DRY_RUN=0
ALLOW_REVERSE=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) TARGET="$2"; shift 2 ;;
    --snapshot) SNAPSHOT_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-reverse) ALLOW_REVERSE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
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

db_session_nbr() {
  docker exec "${WEB_CID}" php -r '
    chdir("/var/www/html/sts");
    require "credentials.php";
    $d = mysqli_connect($server_name, $user_name, $password, $db_name);
    if (!$d) { fwrite(STDERR, mysqli_connect_error()); exit(1); }
    $r = mysqli_query($d, "select setting_value from settings where setting_name = \"session_nbr\"");
    $x = $r ? mysqli_fetch_row($r) : null;
    echo (int) ($x[0] ?? 0);
  '
}

CURRENT_SESSION="$(db_session_nbr)"
TARGET="${TARGET:-${CURRENT_SESSION}}"
PREV=$(( TARGET - 1 ))

if [[ "${TARGET}" -lt 1 ]]; then
  echo "Target session must be >= 1 (got ${TARGET})." >&2
  exit 1
fi
if [[ "${PREV}" -lt 0 ]]; then
  echo "Cannot rewind below session 0." >&2
  exit 1
fi

SNAPSHOT_NAME="${SNAPSHOT_NAME:-db_session_${PREV}}"
SNAPSHOT_PATH="${BACKUPS_DIR}/${SNAPSHOT_NAME}"
TS="$(date +%Y%m%d_%H%M%S)"
UNDO_NAME="rewind_undo_${TS}"
ARCHIVE_DIR="${BACKUPS_DIR}/rewind_archive"
SESSIONS_DIR="${BACKUPS_DIR}/session_state/sessions"

echo "STS session rewind"
echo "  current session_nbr : ${CURRENT_SESSION}"
echo "  remove session      : ${TARGET}"
echo "  restore to end of   : ${PREV}"
echo "  snapshot            : ${SNAPSHOT_PATH}"
echo "  safety undo dump    : ${BACKUPS_DIR}/${UNDO_NAME}"
echo ""

HAVE_SNAPSHOT=0
[[ -f "${SNAPSHOT_PATH}" ]] && HAVE_SNAPSHOT=1

if [[ "${HAVE_SNAPSHOT}" -eq 0 ]]; then
  echo "No snapshot found at ${SNAPSHOT_PATH}."
  if [[ "${ALLOW_REVERSE}" -eq 0 ]]; then
    cat >&2 <<EOF

A reliable rewind needs a DB snapshot from the end of session ${PREV}.
None exists. Options:
  * If you have another dump, pass it:  --snapshot <name>
  * To attempt a best-effort reverse-apply (deletes this session's car_orders,
    history, reverts shipments.last_ship_date, decrements session_nbr) run again
    with --allow-reverse. NOTE: car positions/status CANNOT be fully restored
    this way -- only a snapshot can do that.

Going forward, run snapshot_session_db.sh at the end of each session so this
rewind can restore cleanly.
EOF
    exit 1
  fi
  echo "Proceeding with --allow-reverse (best-effort, positions not restorable)."
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[dry-run] Would safety-dump current DB -> ${BACKUPS_DIR}/${UNDO_NAME}"
  if [[ "${HAVE_SNAPSHOT}" -eq 1 ]]; then
    echo "[dry-run] Would restore snapshot ${SNAPSHOT_PATH}"
  else
    echo "[dry-run] Would reverse-apply session ${TARGET} row changes"
  fi
  for (( s = TARGET; s <= CURRENT_SESSION; s++ )); do
    [[ -d "${SESSIONS_DIR}/session_${s}" ]] && echo "[dry-run] Would archive+remove ${SESSIONS_DIR}/session_${s}"
  done
  echo "[dry-run] Would verify session_nbr == ${PREV}"
  exit 0
fi

if [[ "${ASSUME_YES}" -eq 0 ]]; then
  read -r -p "Proceed with rewind? [y/N] " ans
  [[ "${ans}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# 1. Safety dump ------------------------------------------------------------
echo "==> Safety-dumping current DB to backups/${UNDO_NAME}"
docker exec -e SNAP_NAME="${UNDO_NAME}" "${WEB_CID}" php -r '
  chdir("/var/www/html/sts");
  require "open_db.php";
  require "backup_tables.php";
  backup_tables(open_db(), getenv("SNAP_NAME"));
'

# 2. Restore or reverse-apply ----------------------------------------------
if [[ "${HAVE_SNAPSHOT}" -eq 1 ]]; then
  echo "==> Restoring snapshot ${SNAPSHOT_NAME} (SQL replay; photos untouched)"
  docker exec -e RESTORE_NAME="${SNAPSHOT_NAME}" "${WEB_CID}" php -r '
    chdir("/var/www/html/sts");
    require "credentials.php";
    $dbc = mysqli_connect($server_name, $user_name, $password, $db_name);
    if (!$dbc) { fwrite(STDERR, mysqli_connect_error() . "\n"); exit(1); }
    $file = "./backups/" . getenv("RESTORE_NAME");
    if (!is_file($file)) { fwrite(STDERR, "Snapshot missing in container: $file\n"); exit(1); }
    foreach (explode("#", file_get_contents($file)) as $cmd) {
      $cmd = trim($cmd);
      if ($cmd === "") { continue; }
      if (!mysqli_query($dbc, $cmd) && stripos($cmd, "drop") === false) {
        fwrite(STDERR, "SQL error: " . mysqli_error($dbc) . "\n" . substr($cmd, 0, 160) . "\n");
        exit(1);
      }
    }
    $ts = "/var/www/html/sts/plugins/track_scale/track_scale_helpers.php";
    if (is_readable($ts)) {
      require_once $ts;
      if (function_exists("track_scale_reset_cached_weights")) {
        track_scale_reset_cached_weights($dbc, true);
      }
    }
    print "Snapshot restored.\n";
  '
else
  echo "==> Reverse-applying session ${TARGET} (best-effort)"
  docker exec -e RW_TARGET="${TARGET}" -e RW_PREV="${PREV}" "${WEB_CID}" php -r '
    chdir("/var/www/html/sts");
    require "credentials.php";
    $dbc = mysqli_connect($server_name, $user_name, $password, $db_name);
    if (!$dbc) { fwrite(STDERR, mysqli_connect_error() . "\n"); exit(1); }
    $t = (int) getenv("RW_TARGET");
    $p = (int) getenv("RW_PREV");
    $pad = str_pad((string) $t, 3, "0", STR_PAD_LEFT);
    // Orders created this session (waybill prefix NNN-).
    mysqli_query($dbc, "delete from car_orders where waybill_number like \"" . $pad . "-%\"");
    $orders = mysqli_affected_rows($dbc);
    // Shipments last shipped this session -> roll interval back one session.
    mysqli_query($dbc, "update shipments set last_ship_date = " . $p . " where last_ship_date = " . $t);
    $ship = mysqli_affected_rows($dbc);
    // History rows for this session.
    mysqli_query($dbc, "delete from history where session_nbr = " . $t);
    $hist = mysqli_affected_rows($dbc);
    // Session counter.
    mysqli_query($dbc, "update settings set setting_value = " . $p . " where setting_name = \"session_nbr\"");
    fwrite(STDERR, "    car_orders deleted={$orders} shipments reverted={$ship} history deleted={$hist}\n");
    print "Reverse-apply complete (car positions NOT restored).\n";
  '
fi

# 3. Archive + remove session_state output trees ---------------------------
mkdir -p "${ARCHIVE_DIR}"
for (( s = TARGET; s <= CURRENT_SESSION; s++ )); do
  tree="${SESSIONS_DIR}/session_${s}"
  if [[ -d "${tree}" ]]; then
    tarball="${ARCHIVE_DIR}/session_${s}_${TS}.tar.gz"
    echo "==> Archiving ${tree} -> ${tarball}"
    tar -czf "${tarball}" -C "${SESSIONS_DIR}" "session_${s}"
    rm -rf "${tree}"
  fi
done

# 4. Verify -----------------------------------------------------------------
NEW_SESSION="$(db_session_nbr)"
echo ""
echo "==> session_nbr is now ${NEW_SESSION} (expected ${PREV})"
if [[ "${NEW_SESSION}" -ne "${PREV}" ]]; then
  echo "WARNING: session_nbr mismatch. Review the safety dump backups/${UNDO_NAME}." >&2
  exit 1
fi
echo ""
echo "Rewind complete. Undo with:"
echo "  bin/rewind_session.sh --snapshot ${UNDO_NAME} --to $(( PREV + 1 )) --yes"
echo "  (or restore backups/${UNDO_NAME} directly)"
