#!/usr/bin/env python3
"""Apply job descriptions from hart_seed_config.json to the live STS database."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent
SEED_DIR = REPO_ROOT / "seed"
DEFAULT_JOBS = ("D749", "NVL", "CK1", "STG-SCULLY", "STG-DEMMLER")


def resolve_sts_docker_dir() -> Path:
    import os

    if os.environ.get("STS_DOCKER"):
        return Path(os.environ["STS_DOCKER"]).resolve()
    for candidate in (
        REPO_ROOT / "sts-docker",
        REPO_ROOT.parent / "sts-docker",
    ):
        if (candidate / "docker-compose.yml").is_file():
            return candidate.resolve()
    raise SystemExit(
        "sts-docker not found. Clone github.com/lnevo/sts-docker to ./sts-docker or set STS_DOCKER."
    )


def docker_web_php(php_code: str) -> str:
    compose = resolve_sts_docker_dir() / "docker-compose.yml"
    web_cid = subprocess.check_output(
        ["docker", "compose", "-f", str(compose), "--profile", "build", "ps", "-q", "web"],
        text=True,
    ).strip()
    if not web_cid:
        raise SystemExit(
            "STS web container is not running.\n"
            "Start with: cd sts-docker && docker compose --profile build up -d"
        )
    return subprocess.check_output(
        ["docker", "exec", web_cid, "php", "-r", php_code],
        text=True,
    )


def load_config(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def apply_job_descriptions(config: dict, job_names: set[str]) -> list[str]:
  updated: list[str] = []
  jobs_payload = []
  for job in config.get("jobs", []):
      name = job.get("name", "")
      if name not in job_names:
          continue
      jobs_payload.append(
          {
              "name": name,
              "description": job.get("description", ""),
          }
      )

  if not jobs_payload:
      raise SystemExit("No matching jobs found in config.")

  payload_json = json.dumps(jobs_payload, ensure_ascii=False)
  raw = docker_web_php(
      r'''
chdir("/var/www/html/sts");
require "open_db.php";
$payload = json_decode(''' + json.dumps(payload_json) + r''', true);
if (!is_array($payload)) {
    fwrite(STDERR, "Invalid payload\n");
    exit(1);
}
$dbc = open_db();
$updated = [];
foreach ($payload as $job) {
    $name = (string) ($job["name"] ?? "");
    $description = (string) ($job["description"] ?? "");
    if ($name === "") {
        continue;
    }
    $name_esc = mysqli_real_escape_string($dbc, $name);
    $desc_esc = mysqli_real_escape_string($dbc, $description);
    $sql = 'UPDATE jobs SET description = "' . $desc_esc . '" WHERE name = "' . $name_esc . '"';
    if (!mysqli_query($dbc, $sql)) {
        fwrite(STDERR, "Failed to update {$name}: " . mysqli_error($dbc) . "\n");
        exit(1);
    }
    if (mysqli_affected_rows($dbc) > 0) {
        $updated[] = $name;
    } else {
        $rs = mysqli_query($dbc, 'SELECT 1 FROM jobs WHERE name = "' . $name_esc . '" LIMIT 1');
        if (!$rs || mysqli_num_rows($rs) === 0) {
            fwrite(STDERR, "Job not found: {$name}\n");
            exit(1);
        }
        $updated[] = $name . " (unchanged)";
    }
}
echo json_encode($updated, JSON_UNESCAPED_UNICODE);
'''
  )
  return json.loads(raw)


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
    sys.exit(main())
