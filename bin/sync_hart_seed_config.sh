#!/usr/bin/env bash
set -euo pipefail
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${BIN_DIR}/../tools/sync_hart_seed_config.py" "$@"
