#!/usr/bin/env bash
# Merge car fleet tables from a known-good STS backup into hart_seed.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"


exec python3 "${TOOLS_DIR}/merge_car_fleet_from_backup.py" "$@"
