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

Drives STS through the REST API (--ck1-test still uses docker exec). The stack must be up.
Uses backups/hart_seed unless --no-restore.
EOF
}

_args=()
for _a in "$@"; do
  if [[ "${_a}" == --*=* ]]; then _args+=("${_a%%=*}" "${_a#*=}"); else _args+=("${_a}"); fi
done
set -- ${_args[@]+"${_args[@]}"}

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

# shellcheck source=../lib/sts_api.sh
source "${_script_home}/../lib/sts_api.sh"

if [[ "${CK1_TEST}" -eq 1 ]]; then
  # --ck1-test has no API equivalent: keep the docker CLI path for this flag only.
  WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
  if [[ -z "${WEB_CID}" ]]; then
    echo "Web container is not running. Start with:" >&2
    echo "  cd ${STS_DOCKER} && docker compose --profile build up -d" >&2
    exit 1
  fi
  echo "==> Syncing legacy CLI scripts into web container (runtime PHP is in the image)"
  sts_helpers_docker_cp_legacy_cli "${WEB_CID}" \
    simulate_warm_start.php play_operating_session.php simulate_ck1_weigh.php
else
  sts_api_guard || exit 1
fi

if [[ "${RESTORE_BASE}" -eq 1 ]]; then
  if [[ ! -f "${APPLY_HART_SEED}" ]]; then
    echo "apply_hart_seed.sh not found at ${APPLY_HART_SEED}." >&2
    exit 1
  fi
  seed_file="${BACKUPS_DIR}/hart_seed0"
  if [[ ! -f "${seed_file}" && -f "${BACKUPS_DIR}/hart_seed" ]]; then
    seed_file="${BACKUPS_DIR}/hart_seed"
  fi
  echo "==> Restoring base $(basename "${seed_file}")"
  "${APPLY_HART_SEED}" --sql-file "${seed_file}"
fi

if [[ "${CK1_TEST}" -eq 1 ]]; then
  SIM_ARGS=(--sessions="${COMPLETED_SESSIONS}" --max-sessions="${MAX_SESSIONS}" --backup="${BACKUP_NAME}" --ck1-test)
  [[ "${TRACKED}" -eq 1 ]] && SIM_ARGS+=(--tracked)
  if [[ "${CONTINUE}" -eq 1 ]]; then
    echo "==> Advancing warm start from current session (min=${COMPLETED_SESSIONS}, max=${MAX_SESSIONS}, no re-seed)"
    SIM_ARGS+=(--continue)
  else
    echo "==> Simulating warm start (min_sessions=${COMPLETED_SESSIONS}, max=${MAX_SESSIONS}, seed=${SEED})"
    SIM_ARGS+=(--seed="${SEED}")
  fi
  sts_helpers_docker_exec_www "${WEB_CID}" php /var/www/html/sts/simulate_warm_start.php "${SIM_ARGS[@]}"
else
  BODY="{\"sessions\":${COMPLETED_SESSIONS},\"max_sessions\":${MAX_SESSIONS},\"backup\":\"${BACKUP_NAME}\""
  [[ "${TRACKED}" -eq 1 ]] && BODY+=',"tracked":true'
  if [[ "${CONTINUE}" -eq 1 ]]; then
    echo "==> Advancing warm start from current session (min=${COMPLETED_SESSIONS}, max=${MAX_SESSIONS}, no re-seed)"
    BODY+=',"continue":true'
  else
    echo "==> Simulating warm start (min_sessions=${COMPLETED_SESSIONS}, max=${MAX_SESSIONS}, seed=${SEED})"
    BODY+=",\"seed\":${SEED}"
  fi
  BODY+='}'
  # The task log repeats the engine output; the wrapper lines and the summary are re-rendered
  # below in the CLI's format so the console output matches simulate_warm_start.php.
  STS_TASK_DROP='^(task [^ ]+ \(.*\) started|task finished|seed [0-9]+|warm start finished at session .*|backup written: .*)$' \
    sts_task_run POST /admin/warm-start "${BODY}"
  printf '%s' "${STS_TASK_RESULT}" | python3 -c '
import json, sys
t = json.load(sys.stdin)["result"]["output"]
s = t["summary"]
def log(m=""):
    print(m)
log(); log("=== Warm start summary ===")
log("Session: %s" % s["session"])
log("Orders: %s (%s unfilled)" % (s["orders_total"], s["orders_unfilled"]))
log("Awaiting job assignment: %s" % s["awaiting_assignment"])
log("Assigned, pending pickup: %s" % s["pending_pickup"])
b = s.get("staging_backlog") or {}
log("Staging eligible (ready to run): %s" % b.get("eligible", 0))
log("Staging on jobs: %s" % b.get("on_jobs", 0))
if s.get("stopped_at_stg_scully"):
    g = s.get("stg_scully_backlog") or {}
    log("STG-SCULLY backlog: %s eligible at Scully, %s on job" % (g.get("eligible", 0), g.get("on_jobs", 0)))
for label, key in (
    ("Non-staging cars still on jobs", "non_staging_on_jobs"), ("Cars on Neville Island", "island_cars"),
    ("Cars at South Yard", "south_yard_cars"), ("Offline cars ready for load/unload", "offline_ready"),
    ("Open reposition (E) orders", "reposition_orders"), ("Coke customer deliveries (total)", "coke_complete_deliveries"),
    ("Coke scale reloads (total)", "coke_reloads"), ("Coke weighed", "coke_weighed"),
    ("Coke outbound (in-tolerance at scale)", "coke_outbound_assignments"),
    ("CK1 outbound coke on train", "ck1_outbound_on_train"), ("In train (assigned)", "in_train_assigned"),
    ("Empties off-home (no order)", "empties_off_home")):
    log("%s: %s" % (label, s.get(key, 0)))
for status, count in (s.get("cars_by_status") or {}).items():
    log("  %s: %s" % (status, count))
if t.get("backup"):
    log(); log("Backup written: %s" % t["backup"])
'
fi

PHOTOS_SRC="${BACKUPS_DIR}/hart_seed0_photos"
if [[ ! -d "${PHOTOS_SRC}" ]]; then
  PHOTOS_SRC="${BACKUPS_DIR}/hart_seed_photos"
fi
PHOTOS_DST="${BACKUPS_DIR}/${BACKUP_NAME}_photos"
if [[ -d "${PHOTOS_SRC}" && ! -e "${PHOTOS_DST}" ]]; then
  echo "==> Linking car photos to ${BACKUP_NAME}_photos"
  ln -sfn "$(basename "${PHOTOS_SRC}")" "${PHOTOS_DST}"
fi

echo ""
echo "Done. Warm-start backup: ${BACKUPS_DIR}/${BACKUP_NAME}"
echo "STS: http://localhost:8980/sts/"
