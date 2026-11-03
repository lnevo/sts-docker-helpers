#!/usr/bin/env python3
"""Pull jobs, pickup criteria, locations, and shipments from live STS into hart_seed_config.json.

Reads through the REST API (GET /jobs, /locations, /shipments, /commodities, /car-codes);
see lib/sts_api.py for the base URL and token.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))

import sts_api  # noqa: E402

SEED_DIR = REPO_ROOT / "seed"
ALL_SECTIONS = ("jobs", "pickup_criteria", "locations", "shipments")


def resolve_default_config() -> Path:
    local = SEED_DIR / "hart_seed_config.json"
    if local.is_file():
        return local
    return local


DEFAULT_CONFIG = resolve_default_config()

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
    commodities = {int(r["id"]): r["code"] for r in sts_api.get_all("/commodities")}
    car_codes = {int(r["id"]): r["code"] for r in sts_api.get_all("/car-codes")}
    locations = {int(r["id"]): r["code"] for r in sts_api.get_all("/locations")}
    return commodities, car_codes, locations


def normalize_db_text(value: str) -> str:
    return (value or "").replace("\r\n", "\n").replace("\r", "\n")


def fetch_job_details() -> list[dict]:
    """GET /jobs/{id} for every job, ordered by id (steps and pickup criteria included)."""
    listing = sorted(sts_api.get_all("/jobs"), key=lambda j: int(j["id"]))
    return [sts_api.get(f"/jobs/{j['id']}") for j in listing]


def fetch_jobs(details: list[dict] | None = None) -> list[dict]:
    jobs = []
    for detail in details if details is not None else fetch_job_details():
        steps = [
            {
                "step_number": int(step["step_number"]),
                "station": int(step["station_id"]),
                "pickup": bool(step["pickup"]),
                "setout": bool(step["setout"]),
                "remarks": normalize_db_text(step.get("remarks") or ""),
            }
            # Same order as the old SQL export (ORDER BY on the text column), so the
            # committed seed config doesn't churn: "100" sorts before "95".
            for step in sorted(detail.get("steps", []), key=lambda st: str(st["step_number"]))
        ]
        jobs.append(
            {
                "id": int(detail["id"]),
                "name": detail["name"],
                "description": normalize_db_text(detail.get("description") or ""),
                "steps": steps,
            }
        )
    return jobs


def fetch_pickup_criteria(details: list[dict] | None = None) -> list[dict]:
    rows: list[tuple[int, dict]] = []
    for detail in details if details is not None else fetch_job_details():
        for crit in detail.get("pickup_criteria", []):
            entry: dict = {
                "job": detail["name"],
                "step_nbr": int(crit["step_number"]),
                "car_status": crit.get("car_status") or "",
                "dest_station_id": int(crit["dest_station_id"]),
            }
            if crit.get("commodity_id") is not None:
                entry["commodity_id"] = int(crit["commodity_id"])
            if crit.get("car_code_id") is not None:
                entry["car_code_id"] = int(crit["car_code_id"])
            rows.append((int(crit["id"]), entry))
    return [entry for _, entry in sorted(rows, key=lambda r: r[0])]


def fetch_locations() -> list[dict]:
    rows: list[dict] = []
    for loc in sorted(sts_api.get_all("/locations"), key=lambda r: int(r["id"])):
        entry: dict = {
            "id": int(loc["id"]),
            "code": loc["code"],
            "station": int(loc["station_id"]),
            "track": loc.get("track") or "",
            "spot": loc.get("spot") or "",
            "rpt_station": loc.get("rpt_station") or "",
            "remarks": loc.get("remarks") or "",
        }
        if loc.get("color"):
            entry["color"] = loc["color"]
        rows.append(entry)
    return rows


def fetch_shipments(
    commodities: dict[int, str],
    car_codes: dict[int, str],
    locations: dict[int, str],
) -> list[dict]:
    rows: list[dict] = []
    for ship in sorted(sts_api.get_all("/shipments"), key=lambda r: int(r["id"])):
        entry: dict = {
            "id": int(ship["id"]),
            "code": ship["code"],
            "description": ship.get("description") or "",
            "commodity": commodities.get(int(ship["commodity_id"]), ""),
            "consignment_id": int(ship["commodity_id"]),
            "car_code": car_codes.get(int(ship["car_code_id"]), "XM"),
            "loading_location": locations.get(int(ship["loading_location_id"]), ""),
            "unloading_location": locations.get(int(ship["unloading_location_id"]), ""),
            "min_interval": float(ship["min_interval"]),
            "max_interval": float(ship["max_interval"]),
            "min_amount": int(float(ship["min_amount"])),
            "max_amount": int(float(ship["max_amount"])),
            "special_instructions": ship.get("special_instructions") or "",
            "remarks": ship.get("remarks") or "",
        }
        for key in ("min_load_time", "max_load_time", "min_unload_time", "max_unload_time"):
            if ship.get(key) is not None:
                entry[key] = int(ship[key])
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

    details = fetch_job_details() if sections & {"jobs", "pickup_criteria"} else []

    if "jobs" in sections:
        jobs = fetch_jobs(details)
        config["jobs"] = jobs
        summary["jobs"] = len(jobs)
        summary["job_steps"] = sum(len(job["steps"]) for job in jobs)

    if "pickup_criteria" in sections:
        criteria = fetch_pickup_criteria(details)
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
        help="Fetch from STS and print summary without writing config",
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
        "  python3 generate_hart_seed.py --output sts-docker-data/backups/hart_seed"
    )


if __name__ == "__main__":
    try:
        main()
    except sts_api.ApiError as exc:
        raise SystemExit(str(exc)) from exc
