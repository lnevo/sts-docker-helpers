#!/usr/bin/env python3
"""Apply HART location code v2 naming: yards -YARD, drop NIL-/I/O, coke merge, dedupe 2s."""

from __future__ import annotations

import csv
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent
SEED_DIR = REPO_ROOT / "seed"
INPUTS = SEED_DIR / "inputs"
BACKUP = REPO_ROOT / "backups" / "hart_seed"

ROOT = REPO_ROOT.parent

YARD_RENAMES = {
    "NORTH": "NORTH-YARD",
    "WEST": "WEST-YARD",
    "EAST": "EAST-YARD",
    "SOUTH": "SOUTH-YARD",
    "SCL": "SCL-YARD",
    "DEM": "DEM-YARD",
}

COKE_RENAMES = {
    "NS-O-COKE": "CLV-STEEL-COKE",
    "NS-O-COKE2": "CLV-STEEL-COKE",
    "USS-O-COKE": "USS-ET-COKE",
    "USS-O-COKE2": "USS-ET-COKE",
}

COKE_DROP = frozenset({"NS-O-COKE", "USS-O-COKE2"})  # merged into survivor at other station

COKE_SURVIVOR_STATION = {
    "CLV-STEEL-COKE": 15,
    "USS-ET-COKE": 14,
}

COKE_RPT = {
    "CLV-STEEL-COKE": "USS Cleveland Works, Cleveland, OH",
    "USS-ET-COKE": "U.S. Steel Edgar Thomson Works",
}

SHEN_RENAME = {"NIL-SHEN-COKE": "SHEN-COKE-SHIPPING"}

# Keep st15 / drop st14 base (only `-2` side used in shipments)
KEEP_ST15_DROP_BASE = frozenset(
    {
        "ALGH-I-SCRP",
        "ALGH-I-STEL",
        "GCHM-I-HCLA",
        "GE-O-PHOS",
        "KNOS-O-IGAS",
        "MCCO-O-BILL",
        "REPS-I-COIL",
        "REPS-I-STEL",
        "WEIR-I-SLAB",
    }
)

# Keep st14 base / drop st15 `2`
KEEP_BASE_DROP_ST15 = frozenset(
    {
        "ALGH-I-SLAB",
        "GE-O-ARGN",
        "KNOS-O-CEMT",
        "MCCO-O-SCRP",
        "REPS-I-BILL",
        "RYRS-O-COIL",
        "WEIR-I-COIL",
    }
)

# Both sides used — st14 = base name, st15 = -MR suffix after strip
BOTH_USED_BASES = frozenset(
    {
        "BASF-I-PLST",
        "GCHM-I-PHOS",
        "HOCH-O-ACAR",
        "MEDS-I-CEMT",
        "OHOT-O-PRES",
        "OHTL-O-PLST",
        "SFP-I-FORG",
        "USSB-I-SBAR",
    }
)

LOC_RE = re.compile(
    r'insert into `locations` values\("(\d+)","([^"]+)","(\d+)","([^"]*)","([^"]*)","([^"]*)","([^"]*)","([^"]*)"\);'
)
SHIP_RE = re.compile(
    r'insert into `shipments` values\("(\d+)","([^"]+)","([^"]*)","(\d+)","(\d+)","(\d+)","(\d+)"'
)

CODE_COLS = {
    "code",
    "current_load_loc",
    "current_unload_loc",
    "proposed_load_loc",
    "proposed_unload_loc",
    "loading_location",
    "unloading_location",
}


def parse_seed_locations(path: Path) -> list[dict]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        m = LOC_RE.match(line)
        if m:
            rows.append(
                {
                    "id": int(m.group(1)),
                    "code": m.group(2),
                    "station": int(m.group(3)),
                    "track": m.group(4),
                    "spot": m.group(5),
                    "rpt_station": m.group(6),
                    "remarks": m.group(7),
                    "color": m.group(8),
                }
            )
    return rows


def parse_seed_shipments(path: Path) -> list[dict]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        m = SHIP_RE.match(line)
        if m:
            rows.append(
                {
                    "id": int(m.group(1)),
                    "code": m.group(2),
                    "load": int(m.group(6)),
                    "unload": int(m.group(7)),
                }
            )
    return rows


def strip_io(code: str) -> str:
    return re.sub(r"-[IO]-", "-", code)


def strip_nil(code: str) -> str:
    if code.startswith("NIL-"):
        return code[4:]
    return code


def strip_trailing_2(code: str) -> str:
    if code.endswith("2") and not code.endswith("COKE2"):
        return code[:-1]
    return code


def is_interchange_dup_pair(base: str, locs: list[dict]) -> bool:
    """base without trailing 2; check if base and base2 exist at st14/15."""
    c2 = base if base.endswith("2") else base + "2"
    if base.endswith("2"):
        base = base[:-1]
        c2 = base + "2"
    stations = set()
    for loc in locs:
        if loc["code"] in (base, c2):
            stations.add(loc["station"])
    return stations == {14, 15}


def interchange_pair_key(code: str) -> str | None:
    m = re.match(r"^([A-Z0-9]+)-[IO]-(.+)$", code)
    if not m:
        return None
    party, rest = m.group(1), m.group(2)
    if rest.endswith("2"):
        rest = rest[:-1]
    return f"{party}-{rest}"


def pair_members(key: str, locs: list[dict]) -> tuple[str | None, str | None]:
    """Return (st14_code, st15_code) for an interchange duplicate pair key like ALGH-I-SCRP."""
    st14 = st15 = None
    for loc in locs:
        pk = interchange_pair_key(loc["code"])
        if pk != key:
            continue
        if loc["station"] == 14:
            st14 = loc["code"]
        elif loc["station"] == 15:
            st15 = loc["code"]
    return st14, st15


def build_mapping(locs: list[dict], ships: list[dict]) -> tuple[dict[str, str], frozenset[str]]:
    """old_code -> new_code; dropped codes removed from seed."""
    load_use: dict[int, list[str]] = defaultdict(list)
    unload_use: dict[int, list[str]] = defaultdict(list)
    for s in ships:
        load_use[s["load"]].append(s["code"])
        unload_use[s["unload"]].append(s["code"])

    def used_code(code: str) -> bool:
        for loc in locs:
            if loc["code"] != code:
                continue
            lid = loc["id"]
            return bool(load_use[lid] or unload_use[lid])
        return False

    mapping: dict[str, str] = {}
    dropped: set[str] = set()

    for old, new in YARD_RENAMES.items():
        mapping[old] = new
    mapping.update(SHEN_RENAME)
    for old, new in COKE_RENAMES.items():
        mapping[old] = new
    dropped.update(COKE_DROP)

    seen_pair_keys: set[str] = set()
    for loc in locs:
        key = interchange_pair_key(loc["code"])
        if not key or key in seen_pair_keys:
            continue
        st14_code, st15_code = pair_members(key, locs)
        if not st14_code or not st15_code:
            continue
        seen_pair_keys.add(key)

        # key is like ALGH-I-SCRP — recover IO form from st14_code
        base_io = st14_code
        new_plain = strip_io(base_io)
        new_mr = f"{new_plain}-MR"

        if base_io in KEEP_ST15_DROP_BASE:
            mapping[st14_code] = new_plain
            mapping[st15_code] = new_plain
            dropped.add(st14_code)
        elif base_io in KEEP_BASE_DROP_ST15:
            mapping[st14_code] = new_plain
            mapping[st15_code] = new_plain
            dropped.add(st15_code)
        elif base_io in BOTH_USED_BASES:
            mapping[st14_code] = new_plain
            mapping[st15_code] = new_mr
        else:
            u14 = used_code(st14_code)
            u15 = used_code(st15_code)
            if u15 and not u14:
                mapping[st14_code] = new_plain
                mapping[st15_code] = new_plain
                dropped.add(st14_code)
            elif u14 and not u15:
                mapping[st14_code] = new_plain
                mapping[st15_code] = new_plain
                dropped.add(st15_code)
            elif u14 and u15:
                mapping[st14_code] = new_plain
                mapping[st15_code] = new_mr
            else:
                mapping[st14_code] = new_plain
                mapping[st15_code] = new_mr

    for loc in locs:
        code = loc["code"]
        if code in mapping or code in dropped:
            continue
        if code == "SOUTH-SCALE":
            mapping[code] = code
            continue
        new = strip_nil(strip_io(code))
        mapping[code] = new

    return mapping, frozenset(dropped)


def remap(code: str, mapping: dict[str, str]) -> str:
    if not code:
        return code
    return mapping.get(code.strip(), code.strip())


def apply_csv(path: Path, mapping: dict[str, str], dropped: frozenset[str]) -> None:
    if not path.is_file():
        return
    rows = []
    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        fieldnames = reader.fieldnames or []
        for row in reader:
            if row.get("entity_type") == "location":
                code = row.get("code", "").strip()
                if code in dropped:
                    continue
            for col in fieldnames:
                if col in CODE_COLS and row.get(col):
                    row[col] = remap(row[col], mapping)
            # coke location row updates
            code = row.get("code", "").strip()
            if code == "CLV-STEEL-COKE":
                row["station_id"] = "15"
                row["station_name"] = "McKees Rocks-PA"
                row["rpt_station"] = COKE_RPT["CLV-STEEL-COKE"]
            elif code == "USS-ET-COKE":
                row["station_id"] = "14"
                row["station_name"] = "Mckeesport-PA"
                row["rpt_station"] = COKE_RPT["USS-ET-COKE"]
            rows.append({k: row.get(k, "") for k in fieldnames})
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def walk_json(obj, mapping: dict[str, str]):
    if isinstance(obj, dict):
        return {k: walk_json(v, mapping) for k, v in obj.items()}
    if isinstance(obj, list):
        return [walk_json(v, mapping) for v in obj]
    if isinstance(obj, str):
        return remap(obj, mapping)
    return obj


def apply_config(path: Path, mapping: dict[str, str]) -> None:
    data = json.loads(path.read_text(encoding="utf-8"))
    data = walk_json(data, mapping)
    if "shenango_coke" in data:
        data["shenango_coke"]["location_code"] = "SHEN-COKE-SHIPPING"
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def sync_copies(mapping: dict[str, str], dropped: frozenset[str]) -> None:
    csv_names = [
        "hart_scully_nville_shipping_map_proposed.csv",
        "hart_ix_shipping_map_proposed.csv",
        "hart_expanded_shipping_map_proposed.csv",
    ]
    targets = [INPUTS / n for n in csv_names]
    targets += [ROOT / n for n in csv_names]
    targets += [ROOT / "hart_seed_package" / n for n in csv_names if n != "hart_expanded_shipping_map_proposed.csv"]

    for path in targets:
        apply_csv(path, mapping, dropped)

    configs = [
        SEED_DIR / "hart_seed_config.json",
        ROOT / "hart_seed_config.json",
        ROOT / "hart_seed_package" / "hart_seed_config.json",
    ]
    for path in configs:
        if path.is_file():
            apply_config(path, mapping)


def print_summary(mapping: dict[str, str], dropped: frozenset[str]) -> None:
    changed = sorted((o, n) for o, n in mapping.items() if o != n and o not in dropped)
    print(f"Renamed: {len(changed)} codes")
    print(f"Dropped: {len(dropped)} codes")
    print("\n--- Coke ---")
    for o in ("NS-O-COKE", "NS-O-COKE2", "USS-O-COKE", "USS-O-COKE2"):
        print(f"  {o:16} -> {mapping.get(o, '(dropped)')}")
    print("\n--- Yards ---")
    for o, n in YARD_RENAMES.items():
        print(f"  {o:16} -> {n}")
    print(f"  NIL-SHEN-COKE    -> SHEN-COKE-SHIPPING")
    print(f"  SOUTH-SCALE      -> (unchanged)")
    print("\n--- Sample offline ---")
    for o, n in changed[:15]:
        if "-I-" in o or "-O-" in o:
            print(f"  {o:22} -> {n}")
    if len(changed) > 15:
        print(f"  ... and {len(changed) - 15} more")


def main() -> int:
    seed_path = BACKUP
    if not seed_path.is_file():
        print(f"Missing {seed_path}", file=sys.stderr)
        return 1
    locs = parse_seed_locations(seed_path)
    ships = parse_seed_shipments(seed_path)
    mapping, dropped = build_mapping(locs, ships)

    print_summary(mapping, dropped)
    sync_copies(mapping, dropped)

    out = TOOLS_DIR / "location_code_v2_mapping.json"
    out.write_text(
        json.dumps({"mapping": mapping, "dropped": sorted(dropped)}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"\nWrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
