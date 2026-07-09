#!/usr/bin/env bash
# Apply job crew descriptions from hart_seed_config.json to the live STS database.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"


usage() {
  cat <<'EOF'
Usage: apply_hart_job_descriptions.sh [options]

Push job description text from hart_seed_config.json into the running STS database.
Does not restore the full seed or change job steps.

Options are passed to apply_hart_job_descriptions.py:
  --config=PATH         Seed JSON (default: seed/hart_seed_config.json)
  --jobs=D749,NVL,...   Jobs to update (default: D749,NVL,CK1,STG-SCULLY,STG-DEMMLER)
  -h, --help            Show help
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

python3 "${TOOLS_DIR}/apply_hart_job_descriptions.py" "$@"
