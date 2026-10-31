"""Where STS data lives, for the Python tools. lib/paths.sh does the same for bash.

Backups belong in sts-docker-data/backups beside this repo (STS_BACKUPS_DIR overrides).
Nothing here creates a folder, so a wrong path fails instead of leaving a stray directory.
"""

from __future__ import annotations

import os
from pathlib import Path

HELPERS_ROOT = Path(__file__).resolve().parents[1]


def backups_dir() -> Path:
    env = os.environ.get("STS_BACKUPS_DIR", "").strip()
    if env:
        return Path(env).expanduser()
    return HELPERS_ROOT.parent / "sts-docker-data" / "backups"
