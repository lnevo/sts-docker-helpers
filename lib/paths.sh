# Shared path resolution for sts-docker-helpers shell scripts.
# Source from helpers scripts: source "${SCRIPT_DIR}/lib/paths.sh"

sts_helpers_resolve_paths() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  HELPERS_ROOT="${SCRIPT_DIR}"

  if [[ -n "${STS_DOCKER:-}" && -d "${STS_DOCKER}" ]]; then
    STS_DOCKER="$(cd "${STS_DOCKER}" && pwd)"
  else
    local candidate
    for candidate in \
      "${HELPERS_ROOT}/../sts-docker" \
      "${HELPERS_ROOT}/sts-docker"; do
      if [[ -d "${candidate}" ]]; then
        STS_DOCKER="$(cd "${candidate}" && pwd)"
        break
      fi
    done
  fi
  if [[ -z "${STS_DOCKER:-}" || ! -d "${STS_DOCKER}" ]]; then
    echo "sts-docker not found. Clone github.com/lnevo/sts-docker nearby or set STS_DOCKER." >&2
    return 1
  fi

  COMPOSE=(docker compose -f "${STS_DOCKER}/docker-compose.yml" --profile build)

  if [[ -n "${HART_CARDS_ROOT:-}" && -f "${HART_CARDS_ROOT}/apply_hart_seed.sh" ]]; then
    HART_CARDS_ROOT="$(cd "${HART_CARDS_ROOT}" && pwd)"
  else
    HART_CARDS_ROOT=""
    for candidate in \
      "${HELPERS_ROOT}/.." \
      "${HELPERS_ROOT}/../Car Cards"; do
      if [[ -f "${candidate}/apply_hart_seed.sh" ]]; then
        HART_CARDS_ROOT="$(cd "${candidate}" && pwd)"
        break
      fi
    done
  fi

  if [[ -n "${HART_CARDS_ROOT}" ]]; then
    APPLY_HART_SEED="${HART_CARDS_ROOT}/apply_hart_seed.sh"
    BACKUPS_DIR="${HART_CARDS_ROOT}/sts-backups"
  else
    APPLY_HART_SEED=""
    BACKUPS_DIR="${HELPERS_ROOT}/../sts-backups"
  fi
}
