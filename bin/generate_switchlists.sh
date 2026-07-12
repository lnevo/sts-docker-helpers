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

# DEPRECATED: generate_master_switchlists.php only snapshots current job
# assignment once per job, so it cannot produce the workflow's per-phase D749/NVL
# switch lists (e.g. D749 at Demmler AND at South Yard). Phased switch lists must
# be produced by the session_run_recipe engine that runs the saved workflow's
# assign → generate → pick-up → set-out steps.
cat >&2 <<EOF
generate_switchlists.sh is deprecated and no longer calls
generate_master_switchlists.php (it produced incorrect single-phase output).

To generate correct phased switch lists, run the active saved workflow:
  ${BIN_DIR}/run_catalog_workflow.sh            # advances + generates one session
  ${BIN_DIR}/run_session_simulations.sh --sessions N   # multi-session sweep

Output lands in the container at temp/sessions/session_N and is viewable at
  http://localhost:8980/sts/session.php
EOF
exit 2
