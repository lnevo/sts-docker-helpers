#!/usr/bin/env python3
"""Add new HART cars to the STS seed, and to the running STS (POST /cars) if it is up.

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
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HELPERS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HELPERS / "seed"))
sys.path.insert(0, str(HELPERS / "lib"))

import generate_hart_seed as seed  # noqa: E402
import sts_api  # noqa: E402

HART_ROOT = HELPERS.parents[1]
INPUTS = HELPERS / "seed/inputs"
ADDED = INPUTS / "sts_added_cars.csv"
BACKUPS = HART_ROOT / "external/sts-docker-data/backups"
FINAL = HART_ROOT / "ops/car-cards/car-images/CarImagesFinal"
LIVE_PHOTOS = HART_ROOT / "external/sts-docker-data/Rolling Stock photos"  # what the running container serves
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


def pools_for(code_id: str, sql: str) -> list[str]:
    """Shipment pools of the cars that already have this car code."""
    peers = {cid for cid, (_, code) in car_rows(sql).items() if code == code_id}
    return sorted(
        {pool for pool, cid in re.findall(r'insert into `pool` values\("(\d+)","(\d+)"\)', sql)
         if cid in peers}
    )


def statements(car_id: str, marks: str, code_id: str, remarks: str, sql: str) -> list[str]:
    """INSERTs for one car, in the seed's value order."""
    out = [
        f'insert into `cars` values("{car_id}","{marks}","{code_id}","{SOUTH_YARD}","",'
        f'"Empty","0","{remarks}","0","{SOUTH_YARD}","","","0");',
        f'insert into `ownership` values("{car_id}","{OWNER}","on");',
    ]
    out.extend(f'insert into `pool` values("{pool}","{car_id}");' for pool in pools_for(code_id, sql))
    return out


def live_db_running() -> bool:
    """True when STS answers on the API (the web and db containers are up)."""
    try:
        data = sts_api.get("/health")
    except sts_api.ApiError:
        return False
    return bool(data) and data.get("db") == "ok"


def keep_live_pools(pools: list[str], live: set[str], marks: str) -> list[str]:
    """Drop pools whose shipment is gone from the running database, and say so.

    The seed can still list a shipment that was deleted from the live database; STS rejects
    the whole car if one pool is unknown.
    """
    gone = [p for p in pools if p not in live]
    if gone:
        print(f"  {marks}: shipments {' '.join(gone)} are not in the running database; left out of its pools")
    return [p for p in pools if p in live]


def apply_live(cars: list[tuple[str, str, str, str, list[str]]]) -> None:
    """POST /cars for (car_id, marks, code_id, remarks, pools); the new id must match car_id.

    The API assigns ids itself. Photos are named by car id, so an id that differs from the
    seed's is an error, not something to carry on with.
    """
    live_shipments = {str(s["id"]) for s in sts_api.get("/shipments")}
    for car_id, marks, code_id, remarks, pools in cars:
        pools = keep_live_pools(pools, live_shipments, marks)
        created = sts_api.post("/cars", {
            "reporting_marks": marks,
            "car_code_id": int(code_id),
            "location_id": int(SOUTH_YARD),
            "home_location_id": int(SOUTH_YARD),
            "status": "Empty",
            "remarks": remarks,
            "load_count": 0,
            "owner_id": int(OWNER),
            "on_off_rr": "on",
            "pools": [int(p) for p in pools],
        })
        if str(created.get("id")) != car_id:
            raise SystemExit(
                f"{marks}: STS gave it id {created.get('id')}, the seed expects {car_id}. "
                "The running database is out of step with the seed; fix or remove the car by hand."
            )


def final_image(name: str) -> Path | None:
    """The finished crop for a source photo. Crops are PNGs named after the photo's stem."""
    stem = Path(name).stem
    for candidate in (FINAL / name, FINAL / f"{stem}.png"):
        if candidate.is_file():
            return candidate
    return None


def save_photo(car_id: str, roster_id: str, seed_path: Path) -> bool:
    """Write {car_id}.jpg for the seed and for the running container. False when there is no photo."""
    with (INPUTS / "image_metadata.csv").open(newline="", encoding="utf-8") as fh:
        row = next((r for r in csv.DictReader(fh) if r.get("roster_id") == roster_id), None)
    name = (row or {}).get("source_image", "")
    source = final_image(name) if name else None
    if source is None:
        print(f"  {roster_id}: no photo found for STS car {car_id} (looked for {name or 'no source_image'})")
        return False
    from PIL import Image

    targets = [seed_path.with_name(f"{seed_path.name}_photos")]
    if LIVE_PHOTOS.is_dir():
        targets.append(LIVE_PHOTOS)
    with Image.open(source) as image:
        for folder in targets:
            folder.mkdir(parents=True, exist_ok=True)
            image.convert("RGB").save(folder / f"{car_id}.jpg", "JPEG", quality=85, optimize=True)
    return True


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
    live_cars: list[tuple[str, str, str, str, list[str]]] = []
    for roster_id, car_id, code, marks, code_id, remarks in pending:
        lines.extend(statements(car_id, marks, code_id, remarks, sql))
        live_cars.append((car_id, marks, code_id, remarks, pools_for(code_id, sql)))
        added.append(
            dict(zip(COLUMNS, (roster_id, car_id, code, marks, remarks)))
        )
        save_photo(car_id, roster_id, seed_path)
        print(f"{roster_id}: STS car {car_id}, code {code}")
    if not lines:
        return 0

    use_live = not args.no_live and live_db_running()
    if use_live:
        apply_live(live_cars)
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
