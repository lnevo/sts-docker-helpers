#!/usr/bin/env python3
"""Rename offline locations to company-I/O-commodity codes (max 13 chars for switchlists)."""

from __future__ import annotations

import csv
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEED_INPUTS = ROOT / "sts-docker-helpers/seed/inputs"
CSV_FILES = [
    SEED_INPUTS / "hart_scully_nville_shipping_map_proposed.csv",
    SEED_INPUTS / "hart_ix_shipping_map_proposed.csv",
]
CONFIG = ROOT / "sts-docker-helpers/seed/hart_seed_config.json"
GENERATOR = ROOT / "sts-docker-helpers/seed/generate_hart_seed.py"
HART_SEED_SQL = ROOT / "sts-docker-helpers/backups/hart_seed"
MAX_CODE_LEN = 13

LEGACY_OFFLINE_RE = re.compile(r"^(SCL|DEM)-(IN|OUT)-.+$")
LOC_COLS = (
    "proposed_load_loc",
    "proposed_unload_loc",
    "current_load_loc",
    "current_unload_loc",
)
COKE_OLD_CODES = {"SCL-OUT-NS", "SCL-OUT-CLEV", "DEM-OUT-URR", "DEM-OUT-USS"}
STATION_NAMES = {
    "9": "Scully Yard",
    "10": "Demmler Yard",
    "14": "Mckeesport, PA",
    "15": "McKees Rock, PA",
}

# Island-local + coke offline locations (phase 1–2 CSV).
SCULLY_LEGACY = frozenset(
    {
        "SCL-IN-NOVACOR",
        "SCL-IN-EXXON-BAY",
        "SCL-IN-ALLEGHENY",
        "SCL-IN-REP-STEEL",
        "SCL-IN-MCCONWAY",
        "SCL-IN-HILLMAN",
        "SCL-IN-HOUGHTON",
        "SCL-IN-GEN-CHEM",
        "SCL-IN-FERRELLGAS",
        "SCL-IN-KOSMOS",
        "SCL-IN-LEHIGH",
        "SCL-IN-MI-LIME",
        "SCL-OUT-NS",
        "SCL-OUT-BEMIS",
        "SCL-OUT-OI-TOLEDO",
        "SCL-OUT-PITTS-FORGE",
        "SCL-OUT-UNIVAR",
        "DEM-IN-DOW",
        "DEM-IN-BASF",
        "DEM-IN-METAL-SVC",
        "DEM-IN-RYERSON",
        "DEM-IN-WASH-STL",
        "DEM-IN-CONSOL",
        "DEM-IN-RP-COAL",
        "DEM-IN-FERRELLGAS-PIPE",
        "DEM-IN-MEDUSA",
        "DEM-IN-US-AGG",
        "DEM-IN-MARTIN-MARIETTA",
        "DEM-OUT-URR",
        "DEM-OUT-OI-OTTAWA",
        "DEM-OUT-METAL-SVC",
        "DEM-OUT-RYERSON",
        "DEM-OUT-CALGON-CORP",
        "DEM-OUT-HOUGHTON",
    }
)

# IX through-traffic offline locations (phase 3 CSV).
IX_LEGACY = frozenset(
    {
        "SCL-IN-GE",
        "SCL-IN-BASF",
        "SCL-IN-MEDUSA",
        "SCL-IN-SFP",
        "SCL-IN-USA-STAINLESS",
        "SCL-IN-WEIRTON",
        "SCL-IN-WHEELING-PGH",
        "SCL-IN-HEINZ",
        "SCL-IN-AIR-PRODUCTS",
        "SCL-IN-MAPCO",
        "SCL-OUT-OI-OTTAWA",
        "SCL-OUT-RYERSON",
        "SCL-OUT-HOUGHTON",
        "SCL-OUT-GE",
        "SCL-OUT-SHARON",
        "SCL-OUT-USA-STAINLESS",
        "SCL-OUT-SFP",
        "SCL-OUT-MCCONWAY",
        "SCL-OUT-CARPENTER",
        "SCL-OUT-AEP",
        "SCL-OUT-GIANT-EAGLE",
        "SCL-OUT-KNOUSE",
        "DEM-IN-WEIRTON",
        "DEM-IN-GEN-CHEM",
        "DEM-IN-CALGON-CORP",
        "DEM-IN-REP-STEEL",
        "DEM-IN-SFP",
        "DEM-IN-USA-STAINLESS",
        "DEM-IN-ALLEGHENY",
        "DEM-IN-BETHLEHEM",
        "DEM-IN-DUBUQUE",
        "DEM-OUT-PENELEC",
        "DEM-OUT-GRAYBAR",
        "DEM-OUT-DEERE",
        "DEM-OUT-HEINZ",
        "DEM-OUT-HOLCIM",
        "DEM-OUT-KNOUSE",
        "DEM-OUT-OI-TOLEDO",
        "DEM-OUT-CATERPILLAR",
        "DEM-OUT-RYERSON-CHI",
        "DEM-OUT-ARMCO",
        "DEM-OUT-MCCONWAY",
        "DEM-OUT-SYSCO",
        "DEM-OUT-GE",
        "DEM-OUT-DUPONT",
        "DEM-OUT-SUBURBAN-PROPANE",
    }
)

COMPANY_ABBREV = {
    "NOVACOR": "NVCR",
    "EXXON-BAY": "EXBY",
    "ALLEGHENY": "ALGH",
    "REP-STEEL": "REPS",
    "MCCONWAY": "MCCO",
    "HILLMAN": "HILM",
    "HOUGHTON": "HOCH",
    "GEN-CHEM": "GCHM",
    "FERRELLGAS": "FGRG",
    "FERRELLGAS-PIPE": "FGRP",
    "KOSMOS": "KOSM",
    "LEHIGH": "LEHI",
    "MI-LIME": "MILM",
    "NS": "NS",
    "CLEV": "NS",
    "BEMIS": "BEMI",
    "OI-TOLEDO": "OHTL",
    "OI-OTTAWA": "OHOT",
    "PITTS-FORGE": "PTFG",
    "UNIVAR": "UNVR",
    "DOW": "DOW",
    "BASF": "BASF",
    "METAL-SVC": "MTLS",
    "RYERSON": "RYRS",
    "WASH-STL": "WASH",
    "CONSOL": "CNSL",
    "RP-COAL": "RPCO",
    "MEDUSA": "MEDS",
    "US-AGG": "USAG",
    "MARTIN-MARIETTA": "MRTN",
    "URR": "USS",
    "USS": "USS",
    "GE": "GE",
    "SFP": "SFP",
    "USA-STAINLESS": "USSB",
    "WEIRTON": "WEIR",
    "WHEELING-PGH": "WHLP",
    "HEINZ": "HEIN",
    "AIR-PRODUCTS": "AIRP",
    "MAPCO": "MAPC",
    "SHARON": "SHAR",
    "CARPENTER": "CARP",
    "AEP": "AEP",
    "GIANT-EAGLE": "GNTL",
    "KNOUSE": "KNOS",
    "CALGON-CORP": "CLGC",
    "BETHLEHEM": "BETH",
    "DUBUQUE": "DUBQ",
    "PENELEC": "PENE",
    "GRAYBAR": "GRAY",
    "DEERE": "DEER",
    "HOLCIM": "HOLC",
    "CATERPILLAR": "CATP",
    "RYERSON-CHI": "RYCH",
    "ARMCO": "ARMC",
    "SYSCO": "SYSC",
    "DUPONT": "DUPT",
    "SUBURBAN-PROPANE": "SUBP",
}

COMMODITY_ABBREV = {
    "Plastic Pellets": "PLST",
    "Plastic Resins": "PRES",
    "Ethyl Acrylate": "ETAC",
    "Styrene Monomer": "STYR",
    "Methyl Methacrylate": "MMA",
    "Phosphoric Acid": "PHOA",
    "Phosphor Compounds": "PHOS",
    "Hydrochloric Acid": "HCLA",
    "Caustic Soda": "CAUS",
    "Industrial Gases": "IGAS",
    "Steel": "STEL",
    "Steel Coils": "COIL",
    "Steel Billets": "BILL",
    "Steel Plate": "PLAT",
    "Scrap Steel": "SCRP",
    "Stainless Slab": "SLAB",
    "Stainless Bar": "SBAR",
    "Forged Components": "FORG",
    "Railway Springs": "SPRG",
    "Fluorescent Lamps": "LAMP",
    "Fluorescent Tubes": "TUBE",
    "Tin Plate": "TINP",
    "Activated Carbon": "ACAR",
    "Coal": "COAL",
    "Cement": "CEMT",
    "Aggregate": "AGGR",
    "LPG": "LPG",
    "Coke": "COKE",
    "COKE": "COKE",
    "Argon": "ARGN",
    "Frozen Foods": "FRZN",
    "Packaged Meats": "MEAT",
    "Machined Parts": "MACH",
    "FREIGHT": "FRGT",
}


def company_from_legacy_code(code: str) -> str:
    if code in {"SCL-OUT-NS", "SCL-OUT-CLEV"}:
        return "NS"
    if code in {"DEM-OUT-URR", "DEM-OUT-USS"}:
        return "USS"
    parts = code.split("-", 2)
    return parts[2]


def abbrev_company(legacy_suffix: str) -> str:
    if legacy_suffix in COMPANY_ABBREV:
        return COMPANY_ABBREV[legacy_suffix]
    letters = re.sub(r"[^A-Za-z0-9]", "", legacy_suffix.upper())
    return letters[:5]


def abbrev_commodity(name: str) -> str:
    name = (name or "").strip()
    if name in COMMODITY_ABBREV:
        return COMMODITY_ABBREV[name]
    letters = re.sub(r"[^A-Za-z0-9]", "", name.upper())
    if len(letters) <= 5:
        return letters
    parts = re.findall(r"[A-Z0-9]+", name.upper())
    if len(parts) >= 2:
        return "".join(p[0] for p in parts[:5])[:5]
    return letters[:5]


def dir_letter(direction: str) -> str:
    return "I" if direction.strip().upper().startswith("I") else "O"


def fit_code(company: str, direction: str, commodity: str) -> str:
    """Build CO-I-CMD code, trimming parts to fit MAX_CODE_LEN."""
    d = dir_letter(direction)
    cmd = abbrev_commodity(commodity)
    co = abbrev_company(company)

    code = f"{co}-{d}-{cmd}"
    if len(code) <= MAX_CODE_LEN:
        return code

    # Trim commodity first, then company.
    budget = MAX_CODE_LEN - len(d) - 2  # hyphens
    co_max = min(len(co), 5)
    cmd_max = budget - co_max
    if cmd_max < 2:
        co_max = max(2, budget - 3)
        cmd_max = budget - co_max
    return f"{co[:co_max]}-{d}-{cmd[:cmd_max]}"


def parse_sql_offline_locations(sql_path: Path) -> dict[str, dict]:
    loc_meta: dict[str, dict] = {}
    pattern = re.compile(
        r'insert into `locations` values\("\d+","([^"]+)","(\d+)","OFFLINE","([^"]+)","([^"]*)","([^"]*)","[^"]*"\);'
    )
    for code, station_id, spot, rpt_station, remarks in pattern.findall(
        sql_path.read_text(encoding="utf-8", errors="replace")
    ):
        loc_meta[code] = {
            "rpt_station": rpt_station,
            "spot": spot,
            "station_id": station_id,
            "station_name": STATION_NAMES.get(station_id, ""),
            "remarks": remarks,
            "track": "OFFLINE",
        }
    for code, rpt, remarks, station_id, station_name in [
        (
            "SCL-OUT-CLEV",
            "NS / POHC interchange",
            "POHC Offline unload",
            "9",
            "Scully Yard",
        ),
        (
            "DEM-OUT-USS",
            "U.S. Steel Edgar Thomson Works",
            "CSX Offline unload",
            "10",
            "Demmler Yard",
        ),
    ]:
        if code not in loc_meta:
            loc_meta[code] = {
                "rpt_station": rpt,
                "spot": "OUT",
                "station_id": station_id,
                "station_name": station_name,
                "remarks": remarks,
                "track": "OFFLINE",
            }
    return loc_meta


STATION_BY_VIA = {"POHC": "15", "CSX": "14"}
IX_LOAD_STATION = {"POHC": "15", "CSX": "14"}
IX_UNLOAD_STATION = {"POHC": "15", "CSX": "14"}


def load_shipment_usages(
    loc_meta: dict[str, dict],
) -> dict[str, set[str]]:
    shipment_usages: dict[str, set[str]] = defaultdict(set)
    rpt_dir_to_legacy: dict[tuple[str, str], list[str]] = defaultdict(list)
    for code, meta in loc_meta.items():
        rpt_dir_to_legacy[(meta["rpt_station"], meta["spot"].upper())].append(code)

    for csv_path in CSV_FILES:
        with csv_path.open(newline="", encoding="utf-8") as fh:
            for row in csv.DictReader(fh):
                if row.get("entity_type", "").strip() != "shipment":
                    continue
                commodity = row.get("commodity", "").strip()
                if not commodity:
                    continue
                flow = row.get("flow", "").strip().upper()
                if flow == "IX":
                    load_party = row.get("route_from", "").strip()
                    unload_party = row.get("route_to", "").strip()
                    if load_party:
                        for legacy in rpt_dir_to_legacy.get((load_party, "IN"), []):
                            shipment_usages[legacy].add(commodity)
                    if unload_party:
                        for legacy in rpt_dir_to_legacy.get((unload_party, "OUT"), []):
                            shipment_usages[legacy].add(commodity)
                    continue
                party = row.get("party_name", "").strip()
                if party and flow in {"IN", "OUT"}:
                    for legacy in rpt_dir_to_legacy.get((party, flow), []):
                        shipment_usages[legacy].add(commodity)

    for code in COKE_OLD_CODES:
        if code in loc_meta:
            shipment_usages[code].add("COKE")

    return shipment_usages


def build_mappings(
    loc_meta: dict[str, dict], shipment_usages: dict[str, set[str]]
) -> tuple[dict[tuple[str, str], str], dict[str, dict], dict[tuple[str, str, str, str], str]]:
    old_to_new: dict[tuple[str, str], str] = {}
    new_codes: dict[str, dict] = {}
    party_key_to_new: dict[tuple[str, str, str, str], str] = {}

    for old_code, meta in sorted(loc_meta.items()):
        if not LEGACY_OFFLINE_RE.match(old_code):
            continue
        company = company_from_legacy_code(old_code)
        direction = meta["spot"].upper()
        commodities = sorted(shipment_usages.get(old_code) or [])
        if not commodities:
            commodities = ["FREIGHT"]
        elif len(commodities) > 1 and "FREIGHT" in commodities:
            commodities = [c for c in commodities if c != "FREIGHT"]
        for commodity in commodities:
            base = fit_code(company, direction, commodity)
            new_code = base
            n = 2
            while new_code in new_codes and new_codes[new_code]["station_id"] != meta["station_id"]:
                suffix = str(n)
                trim = MAX_CODE_LEN - len(suffix)
                new_code = f"{base[:trim]}{suffix}"
                n += 1
            assert len(new_code) <= MAX_CODE_LEN, new_code
            old_to_new[(old_code, commodity)] = new_code
            new_codes[new_code] = {**meta, "commodity": commodity}
            party_key_to_new[(meta["rpt_station"], direction, commodity, meta["station_id"])] = new_code

    return old_to_new, new_codes, party_key_to_new


def direction_for_col(col: str) -> str:
    if "unload_loc" in col:
        return "OUT"
    if "load_loc" in col:
        return "IN"
    return "IN"


def party_for_shipment_col(row: dict, col: str) -> str:
    flow = row.get("flow", "").strip().upper()
    if flow == "IX":
        if "unload_loc" in col:
            return row.get("route_to", "").strip()
        if "load_loc" in col:
            return row.get("route_from", "").strip()
        return row.get("party_name", "").strip()
    return row.get("party_name", "").strip()


def offline_cols_for_flow(flow: str) -> frozenset[str]:
    flow = flow.strip().upper()
    if flow == "IN":
        return frozenset({"proposed_load_loc", "current_load_loc"})
    if flow == "OUT":
        return frozenset({"proposed_unload_loc", "current_unload_loc"})
    if flow == "IX":
        return frozenset(LOC_COLS)
    return frozenset()


def station_for_shipment_col(row: dict, col: str) -> str:
    flow = row.get("flow", "").strip().upper()
    via = row.get("via", "").strip().upper()
    if flow == "IX":
        if "unload_loc" in col:
            return "14" if via == "POHC" else "15"
        if "load_loc" in col:
            return "15" if via == "POHC" else "14"
    if flow == "IN":
        return STATION_BY_VIA.get(via, "")
    if flow == "OUT":
        # Outbound offline unload at McKees Rock (POHC) or Mckeesport (CSX).
        return "15" if via == "POHC" else "14"
    return ""


def resolve_shipment_loc(
    loc: str,
    commodity: str,
    row: dict,
    col: str,
    loc_meta: dict[str, dict],
    old_to_new: dict[tuple[str, str], str],
    party_key_to_new: dict[tuple[str, str, str, str], str],
    offline_codes: set[str],
) -> str:
    party = party_for_shipment_col(row, col)
    direction = direction_for_col(col)
    station_id = station_for_shipment_col(row, col)
    if party and station_id:
        hit = party_key_to_new.get((party, direction, commodity, station_id))
        if hit:
            return hit
    if party:
        matches = [
            code
            for (p, d, c, _sid), code in party_key_to_new.items()
            if p == party and d == direction and c == commodity
        ]
        if len(matches) == 1:
            return matches[0]
    if LEGACY_OFFLINE_RE.match(loc):
        return old_to_new.get((loc, commodity), old_to_new.get((loc, "FREIGHT"), loc))
    if loc in offline_codes:
        return loc
    return loc


def new_codes_for_old(old_code: str, old_to_new: dict[tuple[str, str], str]) -> list[str]:
    seen: list[str] = []
    for (old, _commodity), new_code in sorted(old_to_new.items()):
        if old == old_code and new_code not in seen:
            seen.append(new_code)
    return seen


def default_location_template(csv_path: Path) -> dict:
    phase = "1_scl_nvil" if "scully" in csv_path.name else "3_ix_through"
    status = "proposed"
    return {
        "section": "location",
        "phase": phase,
        "status": status,
        "entity_type": "location",
    }


def rebuild_csv_files(
    loc_meta: dict[str, dict],
    old_to_new: dict[tuple[str, str], str],
    party_key_to_new: dict[tuple[str, str, str], str],
    new_codes: dict[str, dict],
) -> None:
    offline_codes = set(new_codes)
    csv_legacy = {
        CSV_FILES[0]: SCULLY_LEGACY | {"SCL-OUT-CLEV", "DEM-OUT-USS"},
        CSV_FILES[1]: IX_LEGACY,
    }

    for csv_path in CSV_FILES:
        legacy_for_file = csv_legacy[csv_path]
        with csv_path.open(newline="", encoding="utf-8") as fh:
            reader = csv.DictReader(fh)
            fieldnames = [f for f in (reader.fieldnames or []) if f]
            rows = list(reader)

        out_rows: list[dict] = []
        for row in rows:
            entity = row.get("entity_type", "").strip()
            if entity == "location" and row.get("track", "").strip() == "OFFLINE":
                continue
            if entity == "shipment":
                commodity = row.get("commodity", "").strip()
                flow = row.get("flow", "").strip().upper()
                island = row.get("island_spot", "").strip()
                for col in offline_cols_for_flow(flow):
                    if flow == "IN" and col in {"proposed_unload_loc", "current_unload_loc"} and island:
                        row[col] = island
                        continue
                    if flow == "OUT" and col in {"proposed_load_loc", "current_load_loc"} and island:
                        row[col] = island
                        continue
                    row[col] = resolve_shipment_loc(
                        row.get(col, "").strip(),
                        commodity,
                        row,
                        col,
                        loc_meta,
                        old_to_new,
                        party_key_to_new,
                        offline_codes,
                    )
                if flow == "OUT":
                    if island:
                        row["proposed_load_loc"] = island
                        row["current_load_loc"] = island
                    row["current_unload_loc"] = row.get("via", "").strip() or row["current_unload_loc"]
                    if row.get("via", "").strip() == "POHC":
                        row["current_unload_loc"] = "SCL"
                    elif row.get("via", "").strip() == "CSX":
                        row["current_unload_loc"] = "DEM"
                if flow == "IN":
                    if island:
                        row["proposed_unload_loc"] = island
                        row["current_unload_loc"] = island
                    via = row.get("via", "").strip()
                    row["current_load_loc"] = "SCL" if via == "POHC" else "DEM" if via == "CSX" else row["current_load_loc"]
            out_rows.append(row)

        template = default_location_template(csv_path)
        insert_at = 0
        for i, row in enumerate(out_rows):
            if row.get("entity_type", "").strip() == "location_rename":
                insert_at = i + 1
        if insert_at == 0:
            for i, row in enumerate(out_rows):
                if row.get("entity_type", "").strip() == "shipment":
                    insert_at = i
                    break

        location_rows: list[dict] = []
        for old_code in sorted(legacy_for_file):
            if old_code not in loc_meta:
                continue
            meta = loc_meta[old_code]
            phase = "coke_done" if old_code in COKE_OLD_CODES else template["phase"]
            status = "active" if old_code in COKE_OLD_CODES else template["status"]
            codes = new_codes_for_old(old_code, old_to_new)
            if not codes:
                continue
            for new_code in codes:
                commodity = new_codes[new_code].get("commodity", "")
                if commodity == "FREIGHT" and len(codes) > 1:
                    continue
                location_rows.append(
                    {
                        **{key: "" for key in fieldnames},
                        **template,
                        "phase": phase,
                        "status": status,
                        "code": new_code,
                        "station_id": meta["station_id"],
                        "station_name": meta["station_name"],
                        "track": meta["track"],
                        "spot": meta["spot"],
                        "rpt_station": meta["rpt_station"],
                        "remarks": meta["remarks"],
                    }
                )

        out_rows[insert_at:insert_at] = location_rows

        with csv_path.open("w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(
                fh, fieldnames=fieldnames, lineterminator="\n", extrasaction="ignore"
            )
            writer.writeheader()
            writer.writerows(out_rows)


def update_config(old_to_new: dict[tuple[str, str], str]) -> None:
    with CONFIG.open(encoding="utf-8") as fh:
        config = json.load(fh)
    uss_code = old_to_new.get(("DEM-OUT-USS", "COKE"), "USS-O-COKE2")
    ns_code = old_to_new.get(("SCL-OUT-CLEV", "COKE"), "NS-O-COKE")
    for ship in config.get("coke_shipments", []):
        code = ship.get("code", "")
        if code.startswith("COKE-USS"):
            ship["unloading_location"] = uss_code
        elif code.startswith("COKE-CLEV"):
            ship["unloading_location"] = ns_code
    with CONFIG.open("w", encoding="utf-8") as fh:
        json.dump(config, fh, indent=2)
        fh.write("\n")


def update_generator(old_to_new: dict[tuple[str, str], str]) -> None:
    text = GENERATOR.read_text(encoding="utf-8")
    replacements = {
        "SCL-OUT-CLEV": old_to_new.get(("SCL-OUT-CLEV", "COKE"), "NS-O-COKE"),
        "DEM-OUT-USS": old_to_new.get(("DEM-OUT-USS", "COKE"), "USS-O-COKE"),
        "NS-OUT-COKE": old_to_new.get(("SCL-OUT-CLEV", "COKE"), "NS-O-COKE"),
        "USS-OUT-COKE-2": old_to_new.get(("DEM-OUT-USS", "COKE"), "USS-O-COKE"),
        "USS-OUT-COKE": old_to_new.get(("DEM-OUT-USS", "COKE"), "USS-O-COKE"),
    }
    for old, new in replacements.items():
        text = text.replace(f'"{old}"', f'"{new}"')
    GENERATOR.write_text(text, encoding="utf-8")


def sync_copies() -> None:
    import shutil

    for src, dst in [
        (CSV_FILES[0], ROOT / "hart_scully_nville_shipping_map_proposed.csv"),
        (CSV_FILES[1], ROOT / "hart_ix_shipping_map_proposed.csv"),
        (CONFIG, ROOT / "hart_seed_config.json"),
        (CSV_FILES[0], ROOT / "hart_seed_package/hart_scully_nville_shipping_map_proposed.csv"),
        (CSV_FILES[1], ROOT / "hart_seed_package/hart_ix_shipping_map_proposed.csv"),
        (CONFIG, ROOT / "hart_seed_package/hart_seed_config.json"),
        (GENERATOR, ROOT / "hart_seed_package/generate_hart_seed.py"),
    ]:
        shutil.copy2(src, dst)


def main() -> int:
    loc_meta = parse_sql_offline_locations(HART_SEED_SQL)
    shipment_usages = load_shipment_usages(loc_meta)
    old_to_new, new_codes, party_key_to_new = build_mappings(loc_meta, shipment_usages)

    too_long = [c for c in new_codes if len(c) > MAX_CODE_LEN]
    if too_long:
        print("ERROR: codes exceed limit:", too_long, file=sys.stderr)
        return 1

    rebuild_csv_files(loc_meta, old_to_new, party_key_to_new, new_codes)
    update_config(old_to_new)
    update_generator(old_to_new)
    sync_copies()

    longest = max(new_codes, key=len)
    print(f"Renamed -> {len(new_codes)} offline codes (longest: {longest}, {len(longest)} chars)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
