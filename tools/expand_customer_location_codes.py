#!/usr/bin/env python3
"""Expand offline location customer tokens to use the 13-char switchlist limit."""

from __future__ import annotations

import csv
import json
import re
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent
SEED_DIR = REPO_ROOT / "seed"
INPUTS = SEED_DIR / "inputs"
ROOT = REPO_ROOT.parent

MAX_CODE_LEN = 13
MR_SUFFIX = "-MR"

CSV_FILES = [
    INPUTS / "hart_scully_nville_shipping_map_proposed.csv",
    INPUTS / "hart_ix_shipping_map_proposed.csv",
]

CONFIG_PATHS = [
    SEED_DIR / "hart_seed_config.json",
    ROOT / "hart_seed_config.json",
    ROOT / "hart_seed_package" / "hart_seed_config.json",
]

CODE_COLS = frozenset(
    {
        "code",
        "current_load_loc",
        "current_unload_loc",
        "proposed_load_loc",
        "proposed_unload_loc",
        "loading_location",
        "unloading_location",
    }
)

# Manual overrides keyed by normalized party name (no parenthetical).
PARTY_OVERRIDES: dict[str, str] = {
    "BASF": "BASF",
    "GE": "GE",
    "Heinz": "HEINZ",
    "Penelec": "PENELEC",
    "Holcim": "HOLCIM",
    "DuPont": "DUPONT",
    "Ryerson Steel Service": "RYERSON",
    "Ryerson Steel": "RYERSON",
    "Pittsburgh Forge": "PITTSFORGE",
    "Standard Forged Products": "STDFORGED",
    "Ferrellgas pipeline terminal": "FERRELLPIP",
    "Ferrellgas Co": "FERRELLGAS",
    "U.S. Steel Edgar Thomson Works": "USSTEELET",
    "USS Cleveland Works, Cleveland, OH": "CLEVWORKS",
    "Novacor": "NOVACOR",
    "Univar": "UNIVAR",
    "Kosmos Cement": "KOSMOSCEM",
    "Lehigh Cement": "LEHIGHCEM",
    "Medusa Cement": "MEDUSACEM",
    "Consol Energy": "CONSOLEN",
    "Republic Steel": "REPUBLIC",
    "Allegheny Ludlum": "ALLEGHENY",
    "Metal Service Co.": "METALSVC",
    "General Chemical": "GENLCHEM",
    "Universal Stainless & Alloy": "UNIVSS",
    "Owens-Illinois": "OWENSIL",
    "Owens-Illinois (Toledo, OH)": "OWENSTOL",
    "Owens-Illinois (Ottawa, IL)": "OWENSOTT",
    "McConway & Torley": "MCCONWAY",
    "Wheeling-Pittsburgh Steel": "WHEELING",
    "Weirton Steel": "WEIRTON",
    "Washington Steel": "WASHSTL",
    "Bethlehem Steel": "BETHLEHM",
    "Calgon Corp": "CALGON",
    "Houghton Chemical": "HOUGHTON",
    "Exxon Chemical": "EXXONCH",
    "Dow Chemical": "DOWCHEM",
    "John Deere": "JOHNDEER",
    "Giant Eagle": "GIANTEAG",
    "Graybar Electric": "GRAYBAR",
    "Carpenter Steel": "CARPENTR",
    "Caterpillar": "CATERPIL",
    "Sharon Steel": "SHARON",
    "Armco Steel": "ARMCO",
    "Air Products": "AIRPROD",
    "Mapco LP": "MAPCO",
    "Knouse Foods": "KNOUSE",
    "Sysco Foods": "SYSCO",
    "Suburban Propane": "SUBURBAN",
    "Dubuque Packing Co": "DUBUQUE",
    "Martin Marietta": "MARTINMR",
    "Michigan Limestone": "MICHIGAN",
    "US Aggregates": "USAGG",
    "R&P Coal": "RPCOAL",
    "Hillman Coal": "HILLMAN",
}

COMMODITY_ALIASES = {
    "STEEL": "STEL",
    "SPRINGS": "SPRG",
    "RESINS": "PRES",
}


def normalize_party(name: str) -> str:
    text = re.sub(r"\s*\([^)]*\)\s*", "", (name or "").strip())
    text = re.sub(r"\s+", " ", text)
    return text.strip(" ,")


def strip_company_suffixes(name: str) -> str:
    for suffix in (
        " Works",
        " Company",
        " Corp.",
        " Corp",
        " Co.",
        " Co",
        " LP",
        " Inc.",
        " Inc",
        " Steel",
    ):
        if name.endswith(suffix):
            name = name[: -len(suffix)].strip()
    return name


def expand_company(name: str, max_len: int) -> str:
    if max_len < 2:
        return "X"[:max_len]

    raw = (name or "").strip()
    if raw in PARTY_OVERRIDES:
        return PARTY_OVERRIDES[raw][:max_len]

    party = normalize_party(name)
    if party in PARTY_OVERRIDES:
        return PARTY_OVERRIDES[party][:max_len]

    cleaned = strip_company_suffixes(party)
    words = re.findall(r"[A-Za-z0-9]+", cleaned.upper())
    if not words:
        return "UNK"[:max_len]

    if len(words) == 1:
        return words[0][:max_len]

    joined = "".join(words)
    if len(joined) <= max_len:
        return joined

    first = words[0]
    if len(first) >= max_len:
        return first[:max_len]

    tail_budget = max_len - len(first)
    tail_words = words[1:]
    if len(tail_words) == 1:
        return (first + tail_words[0][:tail_budget])[:max_len]

    per_word = max(2, tail_budget // len(tail_words))
    tail = "".join(word[:per_word] for word in tail_words)
    return (first + tail)[:max_len]


def split_location_code(code: str) -> tuple[str, str, bool]:
    is_mr = code.endswith(MR_SUFFIX)
    base = code[: -len(MR_SUFFIX)] if is_mr else code
    if base in {"CLV-STEEL-COKE", "USS-ET-COKE", "SHEN-COKE-SHIPPING"}:
        return base, "COKE" if "COKE" in base else "", is_mr
    if "-" not in base:
        return base, "", is_mr
    company, commodity = base.rsplit("-", 1)
    commodity = COMMODITY_ALIASES.get(commodity, commodity)
    return company, commodity, is_mr


def build_location_code(rpt_station: str, commodity: str, *, is_mr: bool) -> str:
    commodity = COMMODITY_ALIASES.get(commodity, commodity)
    suffix_len = len(commodity) + 1
    if is_mr:
        suffix_len += len(MR_SUFFIX)
    company_max = MAX_CODE_LEN - suffix_len
    company = expand_company(rpt_station, company_max)
    code = f"{company}-{commodity}"
    if is_mr:
        code += MR_SUFFIX
    if len(code) > MAX_CODE_LEN:
        raise ValueError(f"code too long ({len(code)}): {code} from {rpt_station!r}")
    return code


def load_offline_locations() -> dict[str, dict]:
    locations: dict[str, dict] = {}
    for csv_path in CSV_FILES:
        if not csv_path.is_file():
            continue
        with csv_path.open(newline="", encoding="utf-8") as fh:
            for row in csv.DictReader(fh):
                if row.get("entity_type", "").strip() != "location":
                    continue
                if row.get("track", "").strip() != "OFFLINE":
                    continue
                code = row.get("code", "").strip()
                rpt = row.get("rpt_station", "").strip()
                if not code or not rpt:
                    continue
                locations[code] = {
                    "rpt_station": rpt,
                    "station_id": row.get("station_id", "").strip(),
                    "station_name": row.get("station_name", "").strip(),
                    "track": row.get("track", "").strip(),
                    "spot": row.get("spot", "").strip(),
                    "remarks": row.get("remarks", "").strip(),
                }
    return locations


def build_mapping(locations: dict[str, dict]) -> dict[str, str]:
    mapping: dict[str, str] = {}
    used: dict[str, str] = {}

    for old_code, meta in sorted(locations.items()):
        _company, commodity, is_mr = split_location_code(old_code)
        if not commodity:
            mapping[old_code] = old_code
            continue
        new_code = build_location_code(meta["rpt_station"], commodity, is_mr=is_mr)
        if new_code in used and used[new_code] != old_code:
            raise ValueError(
                f"collision: {old_code} and {used[new_code]} -> {new_code}"
            )
        used[new_code] = old_code
        mapping[old_code] = new_code

    return mapping


def remap(code: str, mapping: dict[str, str]) -> str:
    text = (code or "").strip()
    return mapping.get(text, text)


def apply_csv(path: Path, mapping: dict[str, str]) -> None:
    if not path.is_file():
        return
    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        fieldnames = reader.fieldnames or []
        rows = []
        for row in reader:
            for col in fieldnames:
                if col in CODE_COLS and row.get(col):
                    row[col] = remap(row[col], mapping)
            rows.append(row)

    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames, lineterminator="\n")
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
    if not path.is_file():
        return
    data = json.loads(path.read_text(encoding="utf-8"))
    data = walk_json(data, mapping)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def sync_copies(mapping: dict[str, str]) -> None:
    targets = list(CSV_FILES)
    targets += [
        ROOT / "hart_scully_nville_shipping_map_proposed.csv",
        ROOT / "hart_ix_shipping_map_proposed.csv",
        ROOT / "hart_seed_package" / "hart_scully_nville_shipping_map_proposed.csv",
        ROOT / "hart_seed_package" / "hart_ix_shipping_map_proposed.csv",
    ]
    for path in targets:
        apply_csv(path, mapping)

    for path in CONFIG_PATHS:
        apply_config(path, mapping)


def print_summary(mapping: dict[str, str]) -> None:
    changed = sorted((o, n) for o, n in mapping.items() if o != n)
    print(f"Expanded {len(changed)} offline customer codes")
    longest = max(mapping.values(), key=len)
    print(f"Longest code: {longest} ({len(longest)} chars)")
    too_long = [c for c in mapping.values() if len(c) > MAX_CODE_LEN]
    if too_long:
        print("ERROR: codes over limit:", too_long, file=sys.stderr)
        sys.exit(1)
    print("\n--- Samples ---")
    for old, new in changed[:20]:
        print(f"  {old:18} -> {new}")
    if len(changed) > 20:
        print(f"  ... and {len(changed) - 20} more")


def main() -> int:
    locations = load_offline_locations()
    mapping = build_mapping(locations)
    print_summary(mapping)
    sync_copies(mapping)
    out = TOOLS_DIR / "customer_code_expansion_mapping.json"
    out.write_text(json.dumps({"mapping": mapping}, indent=2) + "\n", encoding="utf-8")
    print(f"\nWrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
