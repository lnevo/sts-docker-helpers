#!/usr/bin/env python3
"""Balance Demmler vs Scully shipment intervals from forecast pressure vs available fleet.

Pressure = estimated 10-session car-loads / available home-yard cars (unavailable excluded).
Throttles yards/car-types over target pressure; boosts those under target.

Used by generate_hart_seed.py (seed build) and apply_shipment_tune.sh (live DB patch).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

SEED_DIR = Path(__file__).resolve().parent
REPO_ROOT = SEED_DIR.parent
DEFAULT_CONFIG = SEED_DIR / "hart_seed_config.json"

INTERCHANGE_STATIONS = ("Demmler Yard", "Scully Yard")


def load_config(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def yard_balance_settings(config: dict) -> dict:
    raw = config.get("shipment_yard_balance", {})
    return {
        "enabled": raw.get("enabled", True),
        "stations": tuple(raw.get("interchange_stations", INTERCHANGE_STATIONS)),
        "min_supply": float(raw.get("min_supply_per_code", 0.5)),
        "throttle_ratio": float(raw.get("throttle_ratio", 1.15)),
        "boost_ratio": float(raw.get("boost_ratio", 0.85)),
        "heavy_throttle_ratio": float(raw.get("heavy_throttle_ratio", 1.35)),
        "heavy_boost_ratio": float(raw.get("heavy_boost_ratio", 0.7)),
    }


def estimate_loads_10_sessions(
    min_interval: float,
    max_interval: float,
    min_amount: float,
    max_amount: float,
) -> float:
    avg_interval = max((min_interval + max_interval) / 2.0, 0.1)
    avg_amount = (min_amount + max_amount) / 2.0
    return 10.0 * avg_amount / avg_interval


def deltas_for_pressure(pressure: float, target: float, settings: dict) -> tuple[int, int]:
    """Return (min_interval_delta, max_interval_delta) for a yard/car-code bucket."""
    if target <= 0:
        return 0, 0
    ratio = pressure / target
    if ratio >= settings["heavy_throttle_ratio"]:
        return 1, 2
    if ratio >= settings["throttle_ratio"]:
        return 1, 1
    if ratio >= 1.05:
        return 0, 1
    if ratio <= settings["heavy_boost_ratio"]:
        return -1, -1
    if ratio <= settings["boost_ratio"]:
        return -1, 0
    if ratio <= 0.95:
        return 0, -1
    return 0, 0


def apply_interval_deltas(intervals: dict, min_delta: int, max_delta: int) -> dict:
    min_i = max(0, intervals["min_interval"] + min_delta)
    max_i = max(min_i, intervals["max_interval"] + max_delta)
    return {**intervals, "min_interval": min_i, "max_interval": max_i}


def shipment_routed_stations(row: dict, stations: tuple[str, ...]) -> list[str]:
    """Interchange yards this shipment touches (load/unload), not only loading spot."""
    routed = row.get("routed_stations")
    if routed is not None:
        return [s for s in routed if s in stations]
    station = row.get("station", "")
    return [station] if station in stations else []


def combine_interval_deltas(
    left: tuple[int, int], right: tuple[int, int]
) -> tuple[int, int]:
    """Prefer the stronger throttle when a lane routes through multiple yards."""
    return (max(left[0], right[0]), max(left[1], right[1]))


def compute_yard_balance(
    shipments: list[dict],
    inventory: dict[str, dict[str, int]],
    settings: dict,
) -> tuple[dict[tuple[str, str], tuple[int, int]], dict]:
    """Return ((station, car_code) -> (min_d, max_d)), summary dict."""
    stations = settings["stations"]
    demand: dict[str, dict[str, float]] = {s: {} for s in stations}
    for row in shipments:
        if str(row.get("code", "")).startswith("COKE-"):
            continue
        routed = shipment_routed_stations(row, stations)
        if not routed:
            continue
        car_code = row["car_code"]
        load = estimate_loads_10_sessions(
            float(row["min_interval"]),
            float(row["max_interval"]),
            float(row["min_amount"]),
            float(row["max_amount"]),
        )
        share = load / len(routed)
        for station in routed:
            demand[station][car_code] = demand.get(station, {}).get(car_code, 0.0) + share

    total_demand = sum(sum(by.values()) for by in demand.values())
    total_supply = 0.0
    for station in stations:
        for count in inventory.get(station, {}).values():
            total_supply += count
    target = total_demand / max(total_supply, 1.0)

    deltas: dict[tuple[str, str], tuple[int, int]] = {}
    summary = {
        "target_loads_per_car_10sess": round(target, 2),
        "total_demand_10sess": round(total_demand, 1),
        "total_supply": int(total_supply),
        "stations": {},
    }

    for station in stations:
        st_demand = sum(demand.get(station, {}).values())
        st_supply = sum(inventory.get(station, {}).values())
        st_summary = {
            "demand_10sess": round(st_demand, 1),
            "supply": st_supply,
            "loads_per_car": round(st_demand / max(st_supply, 1), 2),
            "car_codes": {},
        }
        all_codes = set(demand.get(station, {})) | set(inventory.get(station, {}))
        for car_code in sorted(all_codes):
            code_demand = demand.get(station, {}).get(car_code, 0.0)
            code_supply = inventory.get(station, {}).get(car_code, 0)
            effective_supply = max(code_supply, settings["min_supply"])
            pressure = code_demand / effective_supply if code_demand else 0.0
            min_d, max_d = deltas_for_pressure(pressure, target, settings)
            if min_d or max_d:
                deltas[(station, car_code)] = (min_d, max_d)
            st_summary["car_codes"][car_code] = {
                "demand": round(code_demand, 1),
                "supply": code_supply,
                "pressure": round(pressure, 2),
                "delta": [min_d, max_d],
            }
        summary["stations"][station] = st_summary

    return deltas, summary


def balance_shipment_rows(
    shipments: list[dict],
    inventory: dict[str, dict[str, int]],
    station_for_location_id,
    car_code_for_id,
    config: dict,
    routed_station_names_for_shipment=None,
) -> dict:
    """Apply yard-balance deltas in place to shipment dicts. Returns summary."""
    settings = yard_balance_settings(config)
    if not settings["enabled"]:
        return {"enabled": False}

    stations = settings["stations"]
    work: list[dict] = []
    for row in shipments:
        routed = []
        if routed_station_names_for_shipment is not None:
            routed = [
                s
                for s in routed_station_names_for_shipment(row)
                if s in stations
            ]
        if not routed:
            station = station_for_location_id(row["loading_location"])
            if station in stations:
                routed = [station]
        work.append(
            {
                "code": row["code"],
                "station": routed[0] if routed else "",
                "routed_stations": routed,
                "car_code": car_code_for_id(row["car_code"]),
                "min_interval": row["min_interval"],
                "max_interval": row["max_interval"],
                "min_amount": row["min_amount"],
                "max_amount": row["max_amount"],
            }
        )

    deltas, summary = compute_yard_balance(work, inventory, settings)
    summary["enabled"] = True
    summary["adjustments"] = len(deltas)

    for row in shipments:
        if str(row.get("code", "")).startswith("COKE-"):
            continue
        car_code = car_code_for_id(row["car_code"])
        if routed_station_names_for_shipment is not None:
            routed = [
                s
                for s in routed_station_names_for_shipment(row)
                if s in stations
            ]
        else:
            station = station_for_location_id(row["loading_location"])
            routed = [station] if station in stations else []
        min_d = max_d = 0
        matched = False
        for station in routed:
            key = (station, car_code)
            if key not in deltas:
                continue
            matched = True
            d_min, d_max = deltas[key]
            min_d, max_d = combine_interval_deltas((min_d, max_d), (d_min, d_max))
        if not matched:
            continue
        adjusted = apply_interval_deltas(row, min_d, max_d)
        row["min_interval"] = adjusted["min_interval"]
        row["max_interval"] = adjusted["max_interval"]

    return summary


def inventory_from_car_rows(
    car_rows: list[dict],
    station_for_location_id,
    car_code_for_id,
    freight_car_ids: set[int] | None = None,
) -> dict[str, dict[str, int]]:
    """Count available home-yard cars by interchange station and AAR car code."""
    inventory: dict[str, dict[str, int]] = {s: {} for s in INTERCHANGE_STATIONS}
    for car in car_rows:
        if car.get("status") == "Unavailable":
            continue
        if freight_car_ids is not None and car["id"] not in freight_car_ids:
            continue
        home_id = car.get("home_location")
        if home_id is None:
            continue
        station = station_for_location_id(home_id)
        if station not in inventory:
            continue
        code = car_code_for_id(car["car_code_id"])
        inventory[station][code] = inventory.get(station, {}).get(code, 0) + 1
    return inventory


def _resolve_sts_docker_compose() -> Path:
    if os.environ.get("STS_DOCKER"):
        return Path(os.environ["STS_DOCKER"]).resolve() / "docker-compose.yml"
    for candidate in (
        REPO_ROOT / "sts-docker" / "docker-compose.yml",
        REPO_ROOT.parent / "sts-docker" / "docker-compose.yml",
    ):
        if candidate.is_file():
            return candidate
    raise SystemExit(
        "sts-docker not found. Clone github.com/lnevo/sts-docker nearby or set STS_DOCKER."
    )


def _docker_mysql_query(sql: str) -> str:
    compose = _resolve_sts_docker_compose()
    db_cid = subprocess.check_output(
        ["docker", "compose", "-f", str(compose), "--profile", "build", "ps", "-q", "db"],
        text=True,
    ).strip()
    if not db_cid:
        raise SystemExit("STS database container is not running.")
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
            "-e",
            sql,
        ],
        text=True,
    )


def inventory_from_database() -> dict[str, dict[str, int]]:
    sql = """
SELECT r.station, cc.code, COUNT(*) AS n
FROM cars c
JOIN car_codes cc ON cc.id = c.car_code_id
JOIN locations l ON l.id = c.home_location
JOIN routing r ON r.id = l.station
WHERE c.status != 'Unavailable'
  AND r.station IN ('Demmler Yard', 'Scully Yard')
GROUP BY r.station, cc.code;
"""
    inventory: dict[str, dict[str, int]] = {s: {} for s in INTERCHANGE_STATIONS}
    out = _docker_mysql_query(sql).strip()
    if not out:
        return inventory
    for line in out.splitlines():
        station, code, count = line.split("\t")
        inventory.setdefault(station, {})[code] = int(count)
    return inventory


def shipments_from_database() -> list[dict]:
    sql = """
SELECT s.code, cc.code,
       s.min_interval, s.max_interval, s.min_amount, s.max_amount, s.id,
       rl.station AS load_station, ru.station AS unload_station
FROM shipments s
JOIN car_codes cc ON cc.id = s.car_code
LEFT JOIN locations ll ON ll.id = s.loading_location
LEFT JOIN routing rl ON rl.id = ll.station
LEFT JOIN locations lu ON lu.id = s.unloading_location
LEFT JOIN routing ru ON ru.id = lu.station
WHERE s.code NOT LIKE 'COKE-%';
"""
    rows = []
    out = _docker_mysql_query(sql).strip()
    if not out:
        return rows
    stations = set(INTERCHANGE_STATIONS)
    for line in out.splitlines():
        (
            code,
            car_code,
            min_i,
            max_i,
            min_a,
            max_a,
            sid,
            load_station,
            unload_station,
        ) = line.split("\t")
        routed = [
            s
            for s in (load_station, unload_station)
            if s in stations and s
        ]
        routed = list(dict.fromkeys(routed))
        rows.append(
            {
                "id": int(sid),
                "code": code,
                "station": routed[0] if routed else (load_station or ""),
                "routed_stations": routed,
                "car_code": car_code,
                "min_interval": float(min_i),
                "max_interval": float(max_i),
                "min_amount": float(min_a),
                "max_amount": float(max_a),
            }
        )
    return rows


def apply_balance_to_database(config: dict) -> dict:
    settings = yard_balance_settings(config)
    if not settings["enabled"]:
        return {"enabled": False}

    shipments = shipments_from_database()
    inventory = inventory_from_database()
    deltas, summary = compute_yard_balance(shipments, inventory, settings)
    summary["enabled"] = True
    summary["adjustments"] = len(deltas)

    if not deltas:
        return summary

    cases_min = []
    cases_max = []
    for row in shipments:
        min_d = max_d = 0
        matched = False
        for station in row.get("routed_stations") or [row.get("station", "")]:
            key = (station, row["car_code"])
            if key not in deltas:
                continue
            matched = True
            d_min, d_max = deltas[key]
            min_d, max_d = combine_interval_deltas((min_d, max_d), (d_min, d_max))
        if not matched:
            continue
        adjusted = apply_interval_deltas(row, min_d, max_d)
        sid = row["id"]
        cases_min.append(
            f"WHEN {sid} THEN {adjusted['min_interval']}"
        )
        cases_max.append(
            f"WHEN {sid} THEN {adjusted['max_interval']}"
        )

    ids = sorted({row["id"] for row in shipments if any(
        (station, row["car_code"]) in deltas
        for station in (row.get("routed_stations") or [row.get("station", "")])
    )})
    sql = f"""
UPDATE shipments
SET min_interval = CASE id {' '.join(cases_min)} ELSE min_interval END,
    max_interval = CASE id {' '.join(cases_max)} ELSE max_interval END
WHERE id IN ({','.join(str(i) for i in ids)});
"""
    _docker_mysql_query(sql)
    return summary


def print_summary(summary: dict) -> None:
    if not summary.get("enabled"):
        print("Yard balance disabled.")
        return
    print(
        f"Target ~{summary['target_loads_per_car_10sess']} loads/car/10 sessions "
        f"({summary['total_demand_10sess']} demand / {summary['total_supply']} available cars)"
    )
    for station, st in summary.get("stations", {}).items():
        print(
            f"  {station}: {st['demand_10sess']} loads, {st['supply']} cars "
            f"({st['loads_per_car']}/car)"
        )
        for code, row in st.get("car_codes", {}).items():
            if row["delta"] != [0, 0]:
                print(
                    f"    {code}: demand={row['demand']} supply={row['supply']} "
                    f"pressure={row['pressure']} delta={row['delta']}"
                )
    print(f"Adjusted {summary.get('adjustments', 0)} station/car-code buckets.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply balance to running STS database (after tune_shipment_orders.sql)",
    )
    args = parser.parse_args()
    config = load_config(args.config)

    if args.apply:
        summary = apply_balance_to_database(config)
        print("==> Shipment yard balance (available fleet)")
        print_summary(summary)
        return

    parser.error("Nothing to do without --apply (seed build uses this module from generate_hart_seed.py).")


if __name__ == "__main__":
    main()
