#!/usr/bin/env python3
"""Make STS Unavailable match out_of_service in the car repository.

    sync_hart_status.py [--check] [--no-live]

Updates the seed, and the running STS (through the API) if it is up. --check only reports.
Reads seed/inputs/image_metadata.csv, which `bin/cars publish` copies in.

Follows STS add_remove.php: a car taken off keeps its status in ownership.on_off_rr,
and a car put back gets that status again. Seeded cars hold "Unavailable" there
instead of a status, so they come back Empty.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HELPERS = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(HELPERS / "seed"), str(HELPERS / "tools"), str(HELPERS / "lib")]

import add_hart_cars as sts  # noqa: E402
import sts_api  # noqa: E402
from generate_hart_seed import load_out_of_service  # noqa: E402

UNAVAILABLE = "Unavailable"
CAR_LINE = re.compile(
    r'^(insert into `cars` values\("(\d+)","([^"]*)","[^"]*","[^"]*","[^"]*",")([^"]*)(".*)$', re.M
)
OWNER_LINE = re.compile(r'^(insert into `ownership` values\("(\d+)","[^"]*",")([^"]*)("\);)$', re.M)


def plan(cars: list[tuple[str, str, str, str]], wanted: set[str]) -> list[tuple[str, str, str, str]]:
    """From (id, marks, status, on_off_rr) rows, return (id, marks, new status, new on_off_rr)."""
    changes = []
    for car_id, marks, status, on_off_rr in cars:
        if marks in wanted and status != UNAVAILABLE:
            changes.append((car_id, marks, UNAVAILABLE, status))
        elif marks not in wanted and status == UNAVAILABLE:
            restored = "Empty" if on_off_rr in ("", "on", UNAVAILABLE) else on_off_rr
            changes.append((car_id, marks, restored, "on"))
    return changes


def seed_cars(sql: str) -> list[tuple[str, str, str, str]]:
    owners = {m[2]: m[3] for m in OWNER_LINE.finditer(sql)}
    return [(m[2], m[3], m[4], owners.get(m[2], "on")) for m in CAR_LINE.finditer(sql)]


def apply_to_seed(sql: str, changes: list[tuple[str, str, str, str]]) -> str:
    by_id = {car_id: (status, on_off) for car_id, _, status, on_off in changes}
    sql = CAR_LINE.sub(
        lambda m: f"{m[1]}{by_id[m[2]][0]}{m[5]}" if m[2] in by_id else m[0], sql
    )
    return OWNER_LINE.sub(
        lambda m: f"{m[1]}{by_id[m[2]][1]}{m[4]}" if m[2] in by_id else m[0], sql
    )


def live_cars() -> list[tuple[str, str, str, str]]:
    """(id, marks, status, on_off_rr) for every car, from GET /cars and GET /ownership."""
    on_off = {str(o["car_id"]): o["on_off_rr"] for o in sts_api.get_all("/ownership")}
    return [
        (str(c["id"]), c["reporting_marks"], c["status"], on_off.get(str(c["id"]), "on") or "on")
        for c in sts_api.get_all("/cars")
    ]


def apply_live_changes(changes: list[tuple[str, str, str, str]]) -> None:
    for car_id, _, status, on_off in changes:
        sts_api.patch(f"/cars/{car_id}", {"status": status})
        sts_api.put(f"/ownership/{car_id}", {"on_off_rr": on_off})


def describe(name: str, changes: list[tuple[str, str, str, str]]) -> None:
    text = " ".join(f"{marks}>{status}" for _, marks, status, _ in changes)
    print(f"  STS {name}: {text or 'matches'}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--no-live", action="store_true")
    args = parser.parse_args()

    wanted = set(load_out_of_service(sts.INPUTS / "image_metadata.csv"))
    seed_path = sts.find_seed()
    sql = seed_path.read_text(encoding="utf-8")
    seed_changes = plan(seed_cars(sql), wanted)
    describe("seed", seed_changes)

    live_changes = []
    if not args.no_live and sts.live_db_running():
        rows = live_cars()
        live_changes = plan(rows, wanted)
        describe("running database", live_changes)
        busy = {c[1]: c[2] for c in rows if c[1] in wanted and c[2] not in ("Empty", UNAVAILABLE)}
        if busy:
            print(f"  Check these by hand, they are in use: {busy}")
    else:
        print("  STS is not running; the running database was not checked.")

    if args.check:
        return 0
    if live_changes:
        apply_live_changes(live_changes)
    if seed_changes:
        seed_path.write_text(apply_to_seed(sql, seed_changes), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
