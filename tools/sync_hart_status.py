#!/usr/bin/env python3
"""Make STS Unavailable match out_of_service in the car repository.

    sync_hart_status.py [--check] [--no-live]

Updates the seed, and the running STS database if it is up. --check only reports.
Reads seed/inputs/image_metadata.csv, which `bin/cars publish` copies in.

Follows STS add_remove.php: a car taken off keeps its status in ownership.on_off_rr,
and a car put back gets that status again. Seeded cars hold "Unavailable" there
instead of a status, so they come back Empty.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

HELPERS = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(HELPERS / "seed"), str(HELPERS / "tools")]

import add_hart_cars as sts  # noqa: E402
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
    query = (
        "select c.id, c.reporting_marks, c.status, coalesce(o.on_off_rr, 'on') "
        "from cars c left join ownership o on o.car_id = c.id;"
    )
    result = subprocess.run(
        ["docker", "compose", "-f", str(sts.COMPOSE), "--profile", "build", "exec", "-T", "db",
         "mariadb", "-usts_user", "-psts_password", "-N", "-B", "sts_db3", "-e", query],
        capture_output=True, text=True, check=True,
    )
    return [tuple(line.split("\t")) for line in result.stdout.splitlines() if line]


def live_statements(changes: list[tuple[str, str, str, str]]) -> list[str]:
    out = []
    for car_id, _, status, on_off in changes:
        out.append(f"update cars set status = '{status}' where id = {car_id};")
        out.append(f"update ownership set on_off_rr = '{on_off}' where car_id = {car_id};")
    return out


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
        sts.apply_live(live_statements(live_changes))
    if seed_changes:
        seed_path.write_text(apply_to_seed(sql, seed_changes), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
