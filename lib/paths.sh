# Shared path resolution for sts-docker-helpers shell scripts.
# Source from bin/ after resolving _script_home (see bin/*.sh bootstrap).

sts_helpers_resolve_paths() {
  local caller="${1:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}"
  while [[ -L "${caller}" ]]; do
    local linkdir
    linkdir="$(cd "$(dirname "${caller}")" && pwd)"
    caller="$(readlink "${caller}")"
    [[ "${caller}" != /* ]] && caller="${linkdir}/${caller}"
  done
  BIN_DIR="$(cd "$(dirname "${caller}")" && pwd)"
  if [[ "$(basename "${BIN_DIR}")" == "bin" ]]; then
    HELPERS_ROOT="$(cd "${BIN_DIR}/.." && pwd)"
  else
    HELPERS_ROOT="${BIN_DIR}"
    BIN_DIR="${HELPERS_ROOT}/bin"
  fi
  SCRIPT_DIR="${BIN_DIR}"

  if [[ -n "${STS_DOCKER:-}" && -d "${STS_DOCKER}" ]]; then
    STS_DOCKER="$(cd "${STS_DOCKER}" && pwd)"
  else
    if [[ -d "${HELPERS_ROOT}/../sts-docker" ]]; then
      STS_DOCKER="$(cd "${HELPERS_ROOT}/../sts-docker" && pwd)"
    fi
  fi
  if [[ -z "${STS_DOCKER:-}" || ! -d "${STS_DOCKER}" ]]; then
    echo "sts-docker not found. Expected it at ../sts-docker, or set STS_DOCKER." >&2
    return 1
  fi

  local compose_files=(-f "${STS_DOCKER}/docker-compose.yml")
  COMPOSE=(docker compose "${compose_files[@]}" --profile build)

  APPLY_HART_SEED="${BIN_DIR}/apply_hart_seed.sh"
  SEED_DIR="${HELPERS_ROOT}/seed"
  TOOLS_DIR="${HELPERS_ROOT}/tools"
  MIGRATIONS_DIR="${HELPERS_ROOT}/migrations"

  # Backups live beside the runtime in sts-docker-data/backups. Never create them here.
  local backups="${STS_BACKUPS_DIR:-${STS_DOCKER}/../sts-docker-data/backups}"
  if [[ ! -d "${backups}" ]]; then
    echo "STS backups not found at ${backups}. Set STS_BACKUPS_DIR." >&2
    return 1
  fi
  BACKUPS_DIR="$(cd "${backups}" && pwd)"

  STS_WEB="${STS_DOCKER}/sts"
  DIAGNOSTICS_DIR="${HELPERS_ROOT}/diagnostics"
}

# sts_require_sandbox: simulations, sweeps and docker-exec writers run only on the
# sandbox stack. Refuses unless the compose web container (project from
# COMPOSE_PROJECT_NAME) has STS_STACK_NAME=sandbox and the API target's /health
# reports stack sandbox. Pins STS_EXPECT_STACK=sandbox for the scripts it calls.
sts_require_sandbox() {
  local cid stack
  cid="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
  if [[ -z "${cid}" ]]; then
    echo "REFUSING: no running web container in compose project '${COMPOSE_PROJECT_NAME:-sts-docker}'." >&2
    echo "$(basename "${0}") runs only on the sandbox stack: set COMPOSE_PROJECT_NAME=sts-sandbox and start it." >&2
    return 1
  fi
  if [[ "${cid}" == *$'\n'* ]]; then
    echo "REFUSING: more than one web container in compose project '${COMPOSE_PROJECT_NAME:-sts-docker}'." >&2
    return 1
  fi
  stack="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" | sed -n 's/^STS_STACK_NAME=//p')"
  if [[ "${stack}" != "sandbox" ]]; then
    echo "REFUSING: $(basename "${0}") runs only on the sandbox stack, but web container ${cid:0:12} is stack '${stack:-unknown}'." >&2
    echo "Set COMPOSE_PROJECT_NAME=sts-sandbox." >&2
    return 1
  fi
  if ! declare -F sts_api_require_sandbox >/dev/null; then
    # shellcheck source=sts_api.sh
    source "${HELPERS_ROOT}/lib/sts_api.sh"
  fi
  # docker exec writes go to this container and API writes to sts_api_base: they must be the
  # same stack, so docker must be local and the API URL a loopback address at one of the
  # container's published ports.
  local base api_port endpoint bindings line matched=0
  base="$(sts_api_base)"
  if ! endpoint="$(docker context inspect -f '{{.Endpoints.docker.Host}}' 2>&1)"; then
    echo "REFUSING: cannot read the docker context: ${endpoint}" >&2
    return 1
  fi
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    endpoint="${DOCKER_HOST}"
  fi
  if [[ "${endpoint}" != unix://* && "${endpoint}" != npipe://* ]]; then
    echo "REFUSING: docker talks to ${endpoint}, not this machine, so its container cannot be checked against ${base}." >&2
    return 1
  fi
  if [[ ! "${base}" =~ ^(https?)://(localhost|127\.0\.0\.1|\[::1\])(:([0-9]+))?(/|$) ]]; then
    echo "REFUSING: the API target ${base} is not a loopback address, so it cannot be web container ${cid:0:12}." >&2
    return 1
  fi
  api_port="${BASH_REMATCH[4]:-}"
  if [[ -z "${api_port}" ]]; then
    [[ "${BASH_REMATCH[1]}" == "https" ]] && api_port=443 || api_port=80
  fi
  if ! bindings="$(docker port "${cid}" 80/tcp 2>&1)"; then
    echo "REFUSING: docker port ${cid:0:12} failed: ${bindings}" >&2
    return 1
  fi
  while IFS= read -r line; do
    # 0.0.0.0:8981, [::]:8981, 127.0.0.1:8981 reach loopback; a binding to another address does not.
    case "${line%:*}" in
      0.0.0.0|127.0.0.1|"[::]"|"::"|"[::1]") [[ "${line##*:}" == "${api_port}" ]] && matched=1 ;;
    esac
  done <<< "${bindings}"
  if [[ "${matched}" -ne 1 ]]; then
    echo "REFUSING: the API target ${base} (port ${api_port}) is not web container ${cid:0:12} (published: ${bindings:-nothing})." >&2
    if [[ -n "${STS_API_URL:-}" ]]; then
      echo "Unset STS_API_URL or point it at that container." >&2
    else
      echo "The default URL for COMPOSE_PROJECT_NAME='${COMPOSE_PROJECT_NAME:-}' does not match; set STS_API_URL to that container." >&2
    fi
    return 1
  fi
  sts_api_require_sandbox
}

# Run a command in the web container as www-data (matches Apache/PHP web UI ownership).
sts_helpers_docker_exec_www() {
  local web_cid="$1"
  shift
  docker exec -u www-data "${web_cid}" "$@"
}

# Resolve an end-of-session dump for session N under the pre/post scheme:
#   hart_session_post{N}_locked → hart_session_post{N} →
#   hart_session{N}_locked → hart_session{N}
# Prints absolute path; returns 1 when none exist.
sts_resolve_session_end_dump() {
  local n="${1:?session number}"
  local cand
  for cand in \
    "hart_session_post${n}_locked" \
    "hart_session_post${n}" \
    "hart_session${n}_locked" \
    "hart_session${n}"; do
    if [[ -f "${BACKUPS_DIR}/${cand}" ]]; then
      echo "${BACKUPS_DIR}/${cand}"
      return 0
    fi
  done
  return 1
}

# Resolve a start-of-ops (post-generate) dump for session N:
#   hart_session_pre{N}_locked → hart_session_pre{N} → db_session_{N}_starting
# Prints absolute path; returns 1 when none exist.
sts_resolve_session_pre_dump() {
  local n="${1:?session number}"
  local cand
  for cand in \
    "hart_session_pre${n}_locked" \
    "hart_session_pre${n}" \
    "db_session_${n}_starting"; do
    if [[ -f "${BACKUPS_DIR}/${cand}" ]]; then
      echo "${BACKUPS_DIR}/${cand}"
      return 0
    fi
  done
  return 1
}
