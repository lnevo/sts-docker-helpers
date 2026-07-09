#!/usr/bin/env bash
# Build and apply a warm-start STS database (simulated prior operating sessions).
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"


BACKUP_NAME="hart_warm_start"
SEED=42
COMPLETED_SESSIONS=3
MAX_SESSIONS=12
CK1_TEST=0
TRACKED=0
RESTORE_BASE=1
CONTINUE=0

usage() {
  cat <<'EOF'
Usage: apply_warm_start.sh [options]

Restore hart_seed, simulate operating sessions until staging jobs are ready to run,
save hart_warm_start, and leave that state loaded in Docker.

Options:
  --sessions N       Minimum sessions before checking staging stop (default: 3)
  --max-sessions N   Maximum sessions to simulate (default: 12)
  --seed N           Random seed for order generation (default: 42)
  --no-restore       Skip hart_seed restore (simulate from current DB state)
  --continue         Advance from current session (implies --no-restore, no re-seed)
  --ck1-test         Run fixed sessions then CK1 weigh test instead of staging stop
  --tracked          Tracked sessions: CK1 each session, stop when STG-SCULLY ready at Scully
  --backup-name NAME Backup file name (default: hart_warm_start)
  -h, --help         Show this help

Requires the build-profile web + db containers to be running.
Uses backups/hart_seed unless --no-restore.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sessions) COMPLETED_SESSIONS="$2"; shift 2 ;;
    --max-sessions) MAX_SESSIONS="$2"; shift 2 ;;
    --ck1-test) CK1_TEST=1; shift ;;
    --tracked) TRACKED=1; shift ;;
    --seed) SEED="$2"; shift 2 ;;
    --no-restore) RESTORE_BASE=0; shift ;;
    --continue) CONTINUE=1; RESTORE_BASE=0; shift ;;
    --backup-name) BACKUP_NAME="$2"; shift 2 ;;
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

echo "==> Syncing warm-start scripts into web container"
for php in warm_start_helpers.php warm_start_session_stats.php simulate_warm_start.php simulate_ck1_weigh.php track_scale_helpers.php; do
  docker cp "${HELPERS_ROOT}/sts/${php}" "${WEB_CID}:/var/www/html/sts/${php}"
done

if [[ "${RESTORE_BASE}" -eq 1 ]]; then
  if [[ ! -f "${APPLY_HART_SEED}" ]]; then
    echo "apply_hart_seed.sh not found at ${APPLY_HART_SEED}." >&2
    exit 1
  fi
  seed_file="${BACKUPS_DIR}/hart_seed"
  echo "==> Restoring base hart_seed"
  "${APPLY_HART_SEED}" --sql-file "${seed_file}"
fi

SIM_ARGS=(--sessions="${COMPLETED_SESSIONS}" --max-sessions="${MAX_SESSIONS}" --backup="${BACKUP_NAME}")
[[ "${TRACKED}" -eq 1 ]] && SIM_ARGS+=(--tracked)
[[ "${CK1_TEST}" -eq 1 ]] && SIM_ARGS+=(--ck1-test)
if [[ "${CONTINUE}" -eq 1 ]]; then
  echo "==> Advancing warm start from current session (min=${COMPLETED_SESSIONS}, max=${MAX_SESSIONS}, no re-seed)"
  SIM_ARGS+=(--continue)
else
  echo "==> Simulating warm start (min_sessions=${COMPLETED_SESSIONS}, max=${MAX_SESSIONS}, seed=${SEED})"
  SIM_ARGS+=(--seed="${SEED}")
fi
docker exec "${WEB_CID}" php /var/www/html/sts/simulate_warm_start.php "${SIM_ARGS[@]}"

PHOTOS_SRC="${BACKUPS_DIR}/hart_seed_photos"
PHOTOS_DST="${BACKUPS_DIR}/${BACKUP_NAME}_photos"
if [[ -d "${PHOTOS_SRC}" && ! -e "${PHOTOS_DST}" ]]; then
  echo "==> Linking car photos to ${BACKUP_NAME}_photos"
  ln -sfn "$(basename "${PHOTOS_SRC}")" "${PHOTOS_DST}"
fi

echo ""
echo "Done. Warm-start backup: ${BACKUPS_DIR}/${BACKUP_NAME}"
echo "STS: http://localhost:8980/sts/"
