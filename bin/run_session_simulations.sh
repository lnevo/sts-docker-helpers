#!/usr/bin/env bash
# Advance tracked warm-start sessions and generate phased switch lists for each.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"


SESSIONS=10
TRACKED=1
RESTORE_SEED=1
APPLY_JOB_DESCRIPTIONS=1

usage() {
  cat <<'EOF'
Usage: run_session_simulations.sh [options]

Restore hart_seed (optional), run tracked warm-start one session at a time,
run begin_session (STG-SCULLY, fill orders, auto-assign), then generate switch lists
for the new operating session.

Options:
  --sessions N       Number of sessions to simulate (default: 10)
  --no-restore       Skip hart_seed restore (continue from current DB)
  --no-tracked       Use staging-stop warm start instead of tracked locals
  --no-job-descriptions  Skip apply_hart_job_descriptions.sh
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sessions) SESSIONS="$2"; shift 2 ;;
    --no-restore) RESTORE_SEED=0; shift ;;
    --no-tracked) TRACKED=0; shift ;;
    --no-job-descriptions) APPLY_JOB_DESCRIPTIONS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container is not running. Start with:" >&2
  echo "  cd ${STS_DOCKER} && docker compose --profile build up -d" >&2
  exit 1
fi

OUTPUT_ROOT="${HELPERS_ROOT}/../switchlists"
mkdir -p "${OUTPUT_ROOT}"

if [[ "${APPLY_JOB_DESCRIPTIONS}" -eq 1 ]]; then
  echo "==> Applying HART job descriptions"
  "${BIN_DIR}/apply_hart_job_descriptions.sh"
fi

if [[ "${RESTORE_SEED}" -eq 1 ]]; then
  echo "==> Restoring hart_seed (session 0)"
  "${BIN_DIR}/apply_hart_seed.sh"
  if [[ "${APPLY_JOB_DESCRIPTIONS}" -eq 1 ]]; then
    echo "==> Applying HART job descriptions (post-seed)"
    "${BIN_DIR}/apply_hart_job_descriptions.sh"
  fi
fi

WARM_ARGS=(--sessions 1 --max-sessions 1)
if [[ "${TRACKED}" -eq 1 ]]; then
  WARM_ARGS+=(--tracked)
fi

for ((n = 1; n <= SESSIONS; n++)); do
  echo ""
  echo "========================================"
  echo "==> Session ${n}/${SESSIONS}: warm start"
  echo "========================================"
  if [[ "${n}" -eq 1 && "${RESTORE_SEED}" -eq 1 ]]; then
    "${BIN_DIR}/apply_warm_start.sh" "${WARM_ARGS[@]}" --backup-name "sim_session_${n}"
  else
    "${BIN_DIR}/apply_warm_start.sh" --no-restore --continue "${WARM_ARGS[@]}" --backup-name "sim_session_${n}"
  fi

  DB_SESSION="$(
    docker exec "${WEB_CID}" php -r \
      'chdir("/var/www/html/sts"); require "open_db.php"; $d=open_db(); $r=mysqli_query($d,"SELECT setting_value FROM settings WHERE setting_name=\"session_nbr\""); echo mysqli_fetch_row($r)[0];'
  )"
  if [[ "${DB_SESSION}" != "${n}" ]]; then
    echo "WARNING: expected session ${n} after warm start, DB is session ${DB_SESSION}" >&2
  fi

  echo "==> Session ${n}: begin operating session (STG-SCULLY, fill, auto-assign)"
  "${BIN_DIR}/begin_session.sh" --run-stg-scully --switchlists

  DB_SESSION="$(
    docker exec "${WEB_CID}" php -r \
      'chdir("/var/www/html/sts"); require "open_db.php"; $d=open_db(); $r=mysqli_query($d,"SELECT setting_value FROM settings WHERE setting_name=\"session_nbr\""); echo mysqli_fetch_row($r)[0];'
  )"
  echo "==> Operating session ${DB_SESSION} ready (switch lists generated)"
done

echo ""
echo "==> Syncing switchlists into web container"
docker exec "${WEB_CID}" mkdir -p /var/www/html/switchlists
docker cp "${OUTPUT_ROOT}/." "${WEB_CID}:/var/www/html/switchlists/"

echo ""
echo "Done. ${SESSIONS} warm-start session(s) simulated; switch lists through operating session $((SESSIONS + 1))."
echo "All sessions:  http://localhost:8980/switchlists/index.html"
echo "Latest session: http://localhost:8980/switchlists/session_$((SESSIONS + 1))/index.html"
