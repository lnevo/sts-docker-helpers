#!/usr/bin/env bash
# Verify sts-docker/sts contains everything needed for workflow + simulator after rebuild.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

REQUIRED=(
  operational_steps_api.php
  operational_steps_catalog.php
  simulator_api.php
  session_simulator_helpers.php
  session_simulator_ops.php
  session_runtime.php
  session_helpers.php
  warm_start_helpers.php
  warm_start_session_stats.php
  generate_order_helpers.php
  fill_order_helpers.php
  plugins/plugins.php
  plugins/track_scale/track_scale_helpers.php
  master_switchlist_helpers.php
  generate_master_switchlists.php
  editor.html
  workflow-shared.js
  open_db.php
)

missing=0
for f in "${REQUIRED[@]}"; do
  if [[ ! -f "${STS_WEB}/${f}" ]]; then
    echo "MISSING ${STS_WEB}/${f}" >&2
    missing=1
  fi
done

if [[ "${missing}" -ne 0 ]]; then
  echo "sts runtime incomplete — simulator will not work after rebuild" >&2
  exit 1
fi

echo "OK — ${#REQUIRED[@]} runtime files present under ${STS_WEB}"
