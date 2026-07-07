#!/usr/bin/env python3
"""Pull jobs, pickup criteria, locations, and shipments from live STS DB into hart_seed_config.json."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent
SEED_DIR = REPO_ROOT / "seed"
ALL_SECTIONS = ("jobs", "pickup_criteria", "locations", "shipments")


def resolve_sts_docker_dir() -> Path:
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


def resolve_default_config() -> Path:
    local = SEED_DIR / "hart_seed_config.json"
    if local.is_file():
        return local
    return local


DEFAULT_CONFIG = resolve_default_config()

def docker_mysql_query(sql: str) -> str:
    compose = resolve_sts_docker_dir() / "docker-compose.yml"
    db_cid = subprocess.check_output(
        ["docker", "compose", "-f", str(compose), "--profile", "build", "ps", "-q", "db"],
        text=True,
    ).strip()
    if not db_cid:
        raise SystemExit(
            "STS database container is not running.\n"
            "Start with: cd sts-docker && docker compose --profile build up -d"
        )
    return subprocess.check_output(
        [
            "docker",
            "exec",
            "-i",
            db_cid,
            "mariadb",
            "-usts_user",
            "-psts_password",
            "sts_db3",
            "-N",
            "-B",
            "-e",
            sql,
        ],
        text=True,
    )


def parse_rows(raw: str) -> list[list[str]]:
    raw = raw.strip()
    if not raw:
        return []
    return [line.split("\t") for line in raw.splitlines()]


def parse_optional_int(value: str) -> int | None:
    value = value.strip()
    if not value or value.upper() == "NULL":
        return None
    return int(value)


def parse_optional_float(value: str) -> float | None:
    value = value.strip()
    if not value or value.upper() == "NULL":
        return None
    return float(value)


def load_config(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def save_config(path: Path, config: dict) -> None:
    with path.open("w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def fetch_lookup_maps() -> tuple[dict[int, str], dict[int, str], dict[int, str]]:
    commodities: dict[int, str] = {}
    for row in parse_rows(docker_mysql_query("SELECT Id, Code FROM commodities")):
        commodities[int(row[0])] = row[1]

    car_codes: dict[int, str] = {}
    for row in parse_rows(docker_mysql_query("SELECT Id, code FROM car_codes")):
        car_codes[int(row[0])] = row[1]

    locations: dict[int, str] = {}
    for row in parse_rows(docker_mysql_query("SELECT Id, code FROM locations")):
        locations[int(row[0])] = row[1]

    return commodities, car_codes, locations


def fetch_jobs() -> list[dict]:
    jobs: list[dict] = []
    for job_id, name, description in parse_rows(
        docker_mysql_query("SELECT Id, name, description FROM jobs ORDER BY Id")
    ):
        safe_name = name.replace("`", "``")
        steps: list[dict] = []
        for step_number, station, pickup, setout, remarks in parse_rows(
            docker_mysql_query(
                f"SELECT step_number, station, pickup, setout, remarks "
                f"FROM `{safe_name}` ORDER BY step_number"
            )
        ):
            steps.append(
                {
                    "step_number": int(step_number),
                    "station": int(station),
                    "pickup": pickup.upper() == "T",
                    "setout": setout.upper() == "T",
                    "remarks": remarks or "",
                }
            )
        jobs.append(
            {
                "id": int(job_id),
                "name": name,
                "description": description or "",
                "steps": steps,
            }
        )
    return jobs


def fetch_pickup_criteria() -> list[dict]:
    rows: list[dict] = []
    for (
        job_name,
        step_nbr,
        car_status,
        commodity_id,
        car_code_id,
        dest_station_id,
    ) in parse_rows(
        docker_mysql_query(
            "SELECT job_id, step_nbr, car_status, commodity_id, car_code_id, "
            "dest_station_id FROM pu_criteria ORDER BY id"
        )
    ):
        entry: dict = {
            "job": job_name,
            "step_nbr": int(step_nbr),
            "car_status": car_status or "",
            "dest_station_id": int(dest_station_id),
        }
        commodity = parse_optional_int(commodity_id)
        car_code = parse_optional_int(car_code_id)
        if commodity is not None:
            entry["commodity_id"] = commodity
        if car_code is not None:
            entry["car_code_id"] = car_code
        rows.append(entry)
    return rows


def fetch_locations() -> list[dict]:
    rows: list[dict] = []
    for loc_id, code, station, track, spot, rpt_station, remarks, color in parse_rows(
        docker_mysql_query(
            "SELECT Id, code, station, track, spot, rpt_station, remarks, color "
            "FROM locations ORDER BY Id"
        )
    ):
        entry: dict = {
            "id": int(loc_id),
            "code": code,
            "station": int(station),
            "track": track or "",
            "spot": spot or "",
            "rpt_station": rpt_station or "",
            "remarks": remarks or "",
        }
        if color:
            entry["color"] = color
        rows.append(entry)
    return rows


def fetch_shipments(
    commodities: dict[int, str],
    car_codes: dict[int, str],
    locations: dict[int, str],
) -> list[dict]:
    rows: list[dict] = []
    for (
        ship_id,
        code,
        description,
        consignment,
        car_code_id,
        loading_id,
        unloading_id,
        min_interval,
        max_interval,
        min_amount,
        max_amount,
        special_instructions,
        remarks,
        min_load_time,
        max_load_time,
        min_unload_time,
        max_unload_time,
    ) in parse_rows(
        docker_mysql_query(
            "SELECT Id, code, description, consignment, car_code, loading_location, "
            "unloading_location, min_interval, max_interval, min_amount, max_amount, "
            "special_instructions, remarks, min_load_time, max_load_time, "
            "min_unload_time, max_unload_time FROM shipments ORDER BY Id"
        )
    ):
        loading_code = locations.get(int(loading_id), "")
        unloading_code = locations.get(int(unloading_id), "")
        commodity_code = commodities.get(int(consignment), "")
        car_code = car_codes.get(int(car_code_id), "XM")
        entry: dict = {
            "id": int(ship_id),
            "code": code,
            "description": description or "",
            "commodity": commodity_code,
            "consignment_id": int(consignment),
            "car_code": car_code,
            "loading_location": loading_code,
            "unloading_location": unloading_code,
            "min_interval": float(min_interval),
            "max_interval": float(max_interval),
            "min_amount": int(float(min_amount)),
            "max_amount": int(float(max_amount)),
            "special_instructions": special_instructions or "",
            "remarks": remarks or "",
        }
        for key, raw in (
            ("min_load_time", min_load_time),
            ("max_load_time", max_load_time),
            ("min_unload_time", min_unload_time),
            ("max_unload_time", max_unload_time),
        ):
            parsed = parse_optional_int(raw)
            if parsed is not None:
                entry[key] = parsed
        rows.append(entry)
    return rows


def sync_coke_shipments(config: dict, shipments: list[dict]) -> int:
    coke_specs = config.get("coke_shipments", [])
    if not coke_specs:
        return 0
    by_code = {row["code"]: row for row in shipments}
    updated = 0
    for spec in coke_specs:
        code = spec.get("code")
        if not code or code not in by_code:
            continue
        source = by_code[code]
        for field in (
            "description",
            "commodity",
            "car_code",
            "loading_location",
            "unloading_location",
            "special_instructions",
            "min_interval",
            "max_interval",
            "min_amount",
            "max_amount",
        ):
            if field in source:
                spec[field] = source[field]
        updated += 1
    return updated


def sync_shenango_coke(config: dict, locations: list[dict]) -> bool:
    shenango = config.get("shenango_coke", {})
    code = shenango.get("location_code", "NIL-SHEN-COKE")
    match = next((row for row in locations if row["code"] == code), None)
    if not match:
        return False
    shenango["station_id"] = match["station"]
    shenango["track"] = match.get("track", "")
    shenango["spot"] = match.get("spot", "")
    shenango["rpt_station"] = match.get("rpt_station", "")
    shenango["remarks"] = match.get("remarks", "")
    config["shenango_coke"] = shenango
    return True


def apply_sections(
    config: dict,
    sections: set[str],
    *,
    dry_run: bool,
) -> dict[str, int | bool]:
    summary: dict[str, int | bool] = {}
    commodities, car_codes, location_codes = fetch_lookup_maps()

    if "jobs" in sections:
        jobs = fetch_jobs()
        config["jobs"] = jobs
        summary["jobs"] = len(jobs)
        summary["job_steps"] = sum(len(job["steps"]) for job in jobs)

    if "pickup_criteria" in sections:
        criteria = fetch_pickup_criteria()
        config["pickup_criteria"] = criteria
        summary["pickup_criteria"] = len(criteria)

    if "locations" in sections:
        locations = fetch_locations()
        config["locations"] = locations
        summary["locations"] = len(locations)
        summary["shenango_coke_updated"] = sync_shenango_coke(config, locations)

    if "shipments" in sections:
        shipments = fetch_shipments(commodities, car_codes, location_codes)
        config["shipments"] = shipments
        summary["shipments"] = len(shipments)
        summary["coke_shipments_updated"] = sync_coke_shipments(config, shipments)

    if not dry_run:
        config["_db_sync"] = {
            "last_synced": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "sections": sorted(sections),
        }

    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG,
        help=f"hart_seed_config.json path (default: {DEFAULT_CONFIG.name})",
    )
    parser.add_argument(
        "--sections",
        default=",".join(ALL_SECTIONS),
        help=f"Comma-separated sections to sync (default: {','.join(ALL_SECTIONS)})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Fetch from DB and print summary without writing config",
    )
    parser.add_argument(
        "--backup",
        action="store_true",
        help="Write a timestamped backup of the config before updating",
    )
    args = parser.parse_args()

    sections = {part.strip() for part in args.sections.split(",") if part.strip()}
    unknown = sections - set(ALL_SECTIONS)
    if unknown:
        raise SystemExit(f"Unknown section(s): {', '.join(sorted(unknown))}")

    config_path = args.config.resolve()
    config = load_config(config_path)

    summary = apply_sections(config, sections, dry_run=args.dry_run)

    if args.dry_run:
        print("Dry run — no files written.")
    else:
        if args.backup:
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            backup_path = config_path.with_name(f"{config_path.stem}.backup-{stamp}.json")
            save_config(backup_path, load_config(config_path))
            print(f"Backup: {backup_path}")

        save_config(config_path, config)
        print(f"Updated: {config_path}")

    for key, value in summary.items():
        print(f"  {key}: {value}")

    print(
        "\nRegenerate SQL seed with:\n"
        "  python3 generate_hart_seed.py --output sts-backups/hart_seed"
    )


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        print(exc.stderr or str(exc), file=sys.stderr)
        raise SystemExit(exc.returncode) from exc
