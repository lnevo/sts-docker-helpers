#!/usr/bin/env bash
# Simulate N operating sessions: warm start once, then begin + play + switchlists.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"


SESSIONS=10
WARM_MIN=3
WARM_MAX=12
TRACKED=1
RESTORE_SEED=1
RUN_WARM_START=1
APPLY_JOB_DESCRIPTIONS=1

usage() {
  cat <<'EOF'
Usage: run_session_simulations.sh [options]

Restore hart_seed (optional), run tracked warm start ONCE, then for each operating session:
  begin_session (STG-SCULLY, fill, assign) → phased switch lists → play session (except after last).

Each cycle advances the session counter once (at begin_session). Play leaves STG-SCULLY backlog
for the next begin_session.

Options:
  --sessions N           Operating sessions to open + generate switch lists for (default: 10)
  --warm-min N           Minimum prior sessions in initial warm start (default: 3)
  --warm-max N           Maximum prior sessions in initial warm start (default: 12)
  --no-restore           Skip hart_seed restore (continue from current DB)
  --no-warm-start        Skip initial warm start (continue mid-simulation)
  --no-tracked           Use staging-stop warm start instead of tracked locals
  --no-job-descriptions  Skip apply_hart_job_descriptions.sh
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sessions) SESSIONS="$2"; shift 2 ;;
    --warm-min) WARM_MIN="$2"; shift 2 ;;
    --warm-max) WARM_MAX="$2"; shift 2 ;;
    --no-restore) RESTORE_SEED=0; shift ;;
    --no-warm-start) RUN_WARM_START=0; shift ;;
    --no-tracked) TRACKED=0; shift ;;
    --no-job-descriptions) APPLY_JOB_DESCRIPTIONS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# shellcheck source=../lib/sts_api.sh
source "${_script_home}/../lib/sts_api.sh"
sts_api_guard || exit 1

OUTPUT_ROOT="${HELPERS_ROOT}/../switchlists"
mkdir -p "${OUTPUT_ROOT}"

clean_switchlists() {
  echo "==> Cleaning switchlists (local + container)"
  find "${OUTPUT_ROOT}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  # No API route clears the container's switchlists dir, so this one step stays on docker.
  local web_cid
  web_cid="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
  if [[ -n "${web_cid}" ]]; then
    docker exec "${web_cid}" sh -c 'rm -rf /var/www/html/switchlists/* 2>/dev/null || true'
    docker exec "${web_cid}" mkdir -p /var/www/html/switchlists
  else
    echo "WARNING: web container not found; container switchlists dir not cleaned" >&2
  fi
}

if [[ "${APPLY_JOB_DESCRIPTIONS}" -eq 1 ]]; then
  echo "==> Applying HART job descriptions"
  "${BIN_DIR}/apply_hart_job_descriptions.sh"
fi

if [[ "${RESTORE_SEED}" -eq 1 ]]; then
  clean_switchlists
  echo "==> Restoring hart_seed (session 0)"
  "${BIN_DIR}/apply_hart_seed.sh"
  if [[ "${APPLY_JOB_DESCRIPTIONS}" -eq 1 ]]; then
    echo "==> Applying HART job descriptions (post-seed)"
    "${BIN_DIR}/apply_hart_job_descriptions.sh"
  fi
fi

WARM_ARGS=(--sessions "${WARM_MIN}" --max-sessions "${WARM_MAX}")
if [[ "${TRACKED}" -eq 1 ]]; then
  WARM_ARGS+=(--tracked)
fi

WARM_SESSION="$(sts_session_nbr)"

if [[ "${RUN_WARM_START}" -eq 1 ]]; then
  echo ""
  echo "========================================"
  echo "==> Warm start (once)"
  echo "========================================"
  "${BIN_DIR}/apply_warm_start.sh" "${WARM_ARGS[@]}" --backup-name "sim_warm_start"

  WARM_SESSION="$(sts_session_nbr)"
  echo "==> Warm start complete at session ${WARM_SESSION} (STG-SCULLY backlog expected)"
else
  echo ""
  echo "==> Skipping warm start (continuing from session ${WARM_SESSION})"
fi

FIRST_OPEN=$((WARM_SESSION + 1))
LAST_OPEN=$((WARM_SESSION + SESSIONS))
PREV_SESSION="${WARM_SESSION}"

for ((n = 1; n <= SESSIONS; n++)); do
  echo ""
  echo "========================================"
  echo "==> Operating session cycle ${n}/${SESSIONS}: run active workflow"
  echo "========================================"
  # Drive the editor's ACTIVE saved workflow end-to-end (increment → prep →
  # D749/NVL/CK1 operating steps → phased switch lists → bookend staging) via
  # session_run_recipe. This is the correct phased-switch-list engine; the old
  # begin_session --switchlists + generate_master_switchlists.php path only
  # snapshotted current assignment once per job and could not produce the
  # per-phase D749/NVL lists.
  "${BIN_DIR}/run_catalog_workflow.sh"

  DB_SESSION="$(sts_session_nbr)"
  DELTA=$((DB_SESSION - PREV_SESSION))
  if [[ "${DELTA}" -ne 1 ]]; then
    echo "ERROR: session jumped ${PREV_SESSION} → ${DB_SESSION} (expected +1)" >&2
    exit 1
  fi
  PREV_SESSION="${DB_SESSION}"
  echo "==> Operating session ${DB_SESSION} complete (phased switch lists in backups/session_state/sessions/session_${DB_SESSION})"
done

echo ""
if [[ "${RUN_WARM_START}" -eq 1 ]]; then
  echo "Done. Warm start once at session ${WARM_SESSION}; ${SESSIONS} operating session(s) opened."
else
  echo "Done. Continued from session ${WARM_SESSION}; ${SESSIONS} operating session(s) opened."
fi
echo "Phased switch lists (workflow engine): sessions ${FIRST_OPEN}–${LAST_OPEN}"
echo "All sessions:   http://localhost:8980/sts/session.php"
echo "Latest session: http://localhost:8980/sts/session.php?session=${LAST_OPEN}"
