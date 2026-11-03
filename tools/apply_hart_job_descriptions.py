#!/usr/bin/env python3
"""Apply job descriptions from hart_seed_config.json to the running STS (PATCH /jobs/{job})."""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent
SEED_DIR = REPO_ROOT / "seed"
sys.path.insert(0, str(REPO_ROOT / "lib"))

import sts_api  # noqa: E402

DEFAULT_JOBS = ("D749", "NVL", "CK1", "STG-SCULLY", "STG-DEMMLER")


def load_config(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def apply_job_descriptions(config: dict, job_names: set[str]) -> list[str]:
    updated: list[str] = []
    jobs = [j for j in config.get("jobs", []) if j.get("name", "") in job_names]
    if not jobs:
        raise SystemExit("No matching jobs found in config.")
    for job in jobs:
        name = job["name"]
        description = job.get("description", "") or ""
        try:
            current = sts_api.get(f"/jobs/{urllib.parse.quote(name, safe='')}")
        except sts_api.ApiError as exc:
            if exc.status == 404:
                raise SystemExit(f"Job not found: {name}") from None
            raise
        if (current.get("description") or "") == description:
            updated.append(f"{name} (unchanged)")
            continue
        sts_api.patch(f"/jobs/{urllib.parse.quote(name, safe='')}", {"description": description})
        updated.append(name)
    return updated


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=SEED_DIR / "hart_seed_config.json",
        help="hart_seed_config.json path (default: seed/hart_seed_config.json)",
    )
    parser.add_argument(
        "--jobs",
        default=",".join(DEFAULT_JOBS),
        help=f"Comma-separated job names (default: {','.join(DEFAULT_JOBS)})",
    )
    args = parser.parse_args(argv)

    if not args.config.is_file():
        raise SystemExit(f"Config not found: {args.config}")

    job_names = {name.strip() for name in args.jobs.split(",") if name.strip()}
    config = load_config(args.config)
    updated = apply_job_descriptions(config, job_names)

    for name in updated:
        print(f"Updated {name}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except sts_api.ApiError as exc:
        raise SystemExit(str(exc)) from exc
