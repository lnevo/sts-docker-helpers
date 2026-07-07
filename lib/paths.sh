# Shared path resolution for sts-docker-helpers shell scripts.
# Source from bin/: source "${BIN_DIR}/../lib/paths.sh"

sts_helpers_resolve_paths() {
  local caller="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
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
    local candidate
    for candidate in \
      "${HELPERS_ROOT}/sts-docker" \
      "${HELPERS_ROOT}/../sts-docker"; do
      if [[ -d "${candidate}" ]]; then
        STS_DOCKER="$(cd "${candidate}" && pwd)"
        break
      fi
    done
  fi
  if [[ -z "${STS_DOCKER:-}" || ! -d "${STS_DOCKER}" ]]; then
    echo "sts-docker not found. Symlink or clone github.com/lnevo/sts-docker to ./sts-docker or set STS_DOCKER." >&2
    return 1
  fi

  COMPOSE=(docker compose -f "${STS_DOCKER}/docker-compose.yml" --profile build)

  APPLY_HART_SEED="${BIN_DIR}/apply_hart_seed.sh"
  SEED_DIR="${HELPERS_ROOT}/seed"
  TOOLS_DIR="${HELPERS_ROOT}/tools"
  MIGRATIONS_DIR="${HELPERS_ROOT}/migrations"

  for candidate in \
    "${HELPERS_ROOT}/backups" \
    "${HELPERS_ROOT}/sts-backups" \
    "${HELPERS_ROOT}/../sts-backups"; do
    if [[ -d "${candidate}" ]]; then
      BACKUPS_DIR="$(cd "${candidate}" && pwd)"
      break
    fi
  done
  if [[ -z "${BACKUPS_DIR:-}" ]]; then
    BACKUPS_DIR="${HELPERS_ROOT}/backups"
    mkdir -p "${BACKUPS_DIR}"
  fi
}
