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

echo "==> Syncing legacy begin-session CLI into web container"
sts_helpers_docker_cp_legacy_cli "${WEB_CID}" begin_operating_session.php

echo "==> Beginning operating session"
sts_helpers_docker_exec_www "${WEB_CID}" php /var/www/html/sts/begin_operating_session.php "${PHP_ARGS[@]}"

if [[ "${GENERATE_SWITCHLISTS}" -eq 1 ]]; then
  # --switchlists previously called generate_master_switchlists.php, which only
  # snapshotted current assignment once per job and could not produce the
  # per-phase D749/NVL switch lists. Phased switch lists now come from running
  # the saved workflow through session_run_recipe.
  cat >&2 <<EOF
==> --switchlists is deprecated in begin_session.sh.
    begin_session only runs session prep; it does not run the workflow's
    operating/generate steps. Generate phased switch lists with the workflow:
      ${BIN_DIR}/run_catalog_workflow.sh
    (or run a full sweep: ${BIN_DIR}/run_session_simulations.sh --sessions N)
EOF
fi
