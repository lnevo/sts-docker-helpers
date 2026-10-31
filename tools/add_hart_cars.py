#!/usr/bin/env python3
"""Add new HART cars to the STS seed, and to the running STS database if it is up.

    add_hart_cars.py NW32800 [more roster ids]

Each car gets the next free STS id, recorded in seed/inputs/sts_added_cars.csv so
a regenerated seed keeps it. Roster order must not set these ids: inserting a car
would renumber every later car and break the RollingStock/{id}.jpg photos.

Cars join at South Yard, Empty, with the pools of another car of the same code.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HELPERS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HELPERS / "seed"))

import generate_hart_seed as seed  # noqa: E402

HART_ROOT = HELPERS.parents[1]
INPUTS = HELPERS / "seed/inputs"
ADDED = INPUTS / "sts_added_cars.csv"
BACKUPS = HART_ROOT / "external/sts-docker-data/backups"
COMPOSE = HART_ROOT / "external/sts-docker/docker-compose.yml"
FINAL = HART_ROOT / "ops/car-cards/CarImagesFinal"
SOUTH_YARD = "4"
OWNER = "1"
COLUMNS = ["roster_id", "sts_car_id", "aar_code", "reporting_marks", "remarks"]


def find_seed() -> Path:
    for name in ("hart_seed0", "hart_seed"):
        path = BACKUPS / name
        if path.is_file():
            return path
    raise SystemExit(f"No hart_seed in {BACKUPS}")


def read_added() -> list[dict]:
    if not ADDED.is_file():
        return []
    with ADDED.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def code_ids(sql: str) -> dict[str, str]:
    return {
        code: cid
        for cid, code in re.findall(r'insert into `car_codes` values\("(\d+)","([^"]*)"', sql)
    }


def car_rows(sql: str) -> dict[str, tuple[str, str]]:
    """Map STS car id -> (reporting marks, car_code_id)."""
    return {
        cid: (marks, code)
        for cid, marks, code in re.findall(
            r'insert into `cars` values\("(\d+)","([^"]*)","(\d+)"', sql
        )
    }


def statements(car_id: str, marks: str, code_id: str, remarks: str, sql: str) -> list[str]:
    """INSERTs for one car, in the seed's value order."""
    out = [
        f'insert into `cars` values("{car_id}","{marks}","{code_id}","{SOUTH_YARD}","",'
        f'"Empty","0","{remarks}","0","{SOUTH_YARD}","","","0");',
        f'insert into `ownership` values("{car_id}","{OWNER}","on");',
    ]
    peers = {cid for cid, (_, code) in car_rows(sql).items() if code == code_id}
    pools = sorted(
        {pool for pool, cid in re.findall(r'insert into `pool` values\("(\d+)","(\d+)"\)', sql)
         if cid in peers}
    )
    out.extend(f'insert into `pool` values("{pool}","{car_id}");' for pool in pools)
    return out


def live_db_running() -> bool:
    try:
        result = subprocess.run(
            ["docker", "compose", "-f", str(COMPOSE), "--profile", "build",
             "ps", "--status", "running", "-q", "db"],
            capture_output=True, text=True, timeout=20, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and bool(result.stdout.strip())


def apply_live(lines: list[str]) -> None:
    sql = "start transaction;\n" + "\n".join(lines) + "\ncommit;\n"
    subprocess.run(
        ["docker", "compose", "-f", str(COMPOSE), "--profile", "build", "exec", "-T", "db",
         "mariadb", "-usts_user", "-psts_password", "sts_db3"],
        input=sql, text=True, check=True,
    )


def save_photo(car_id: str, roster_id: str, seed_path: Path) -> None:
    with (INPUTS / "image_metadata.csv").open(newline="", encoding="utf-8") as fh:
        row = next((r for r in csv.DictReader(fh) if r.get("roster_id") == roster_id), None)
    name = (row or {}).get("source_image", "")
    if not name or not (FINAL / name).is_file():
        return
    from PIL import Image

    out = seed_path.with_name(f"{seed_path.name}_photos") / f"{car_id}.jpg"
    out.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(FINAL / name) as image:
        image.convert("RGB").save(out, "JPEG", quality=85, optimize=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("roster_ids", nargs="+")
    parser.add_argument("--no-live", action="store_true")
    args = parser.parse_args()

    config = json.loads((HELPERS / "seed/hart_seed_config.json").read_text(encoding="utf-8"))
    roster = {
        c.get("id"): c
        for c in ET.parse(INPUTS / "HART_MergedCarRoster.xml").getroot().findall("./cars/car")
    }
    meta = seed.load_roster_metadata(
        INPUTS / "image_metadata.csv", INPUTS / "HART_MergedCarRoster.xml"
    )
    seed_path = find_seed()
    sql = seed_path.read_text(encoding="utf-8")
    codes = code_ids(sql)
    cars = car_rows(sql)
    known = {marks for marks, _ in cars.values()}
    added = read_added()
    ids = [int(c) for c in cars] + [int(a["sts_car_id"]) for a in added]
    next_id = max(ids, default=0) + 1

    pending = []
    for roster_id in args.roster_ids:
        car = roster.get(roster_id)
        if car is None:
            raise SystemExit(f"{roster_id} is not in the roster.")
        marks = f"{car.get('roadName', '')}{car.get('roadNumber', '')}"
        if marks in known:
            print(f"{roster_id} is already in the seed.")
            continue
        car_type = car.get("type", "")
        length = car.get("length", "")
        code = seed.aar_code_for_roster_car(
            car_type, length, roster_meta=meta.get(roster_id, {}),
            roster_id=roster_id, config=config,
        )
        code_id = codes.get(code or "")
        if not code_id:
            raise SystemExit(
                f"{roster_id}: STS has no car code for {car_type} {length}ft ({code}). "
                "Add the car code in STS, then publish again."
            )
        remarks = f"{car_type} {length}ft" if length else car_type
        pending.append((roster_id, str(next_id), code, marks, code_id, remarks))
        next_id += 1

    lines: list[str] = []
    for roster_id, car_id, code, marks, code_id, remarks in pending:
        lines.extend(statements(car_id, marks, code_id, remarks, sql))
        added.append(
            dict(zip(COLUMNS, (roster_id, car_id, code, marks, remarks)))
        )
        save_photo(car_id, roster_id, seed_path)
        print(f"{roster_id}: STS car {car_id}, code {code}")
    if not lines:
        return 0

    use_live = not args.no_live and live_db_running()
    if use_live:
        apply_live(lines)
        print("Added to the running STS database.")
    else:
        print("STS is not running; the seed is updated and the running database was not.")
    with seed_path.open("a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    with ADDED.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerows(added)
    print(f"Updated {seed_path} and {ADDED.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
