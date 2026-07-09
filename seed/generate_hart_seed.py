#!/usr/bin/env python3
"""Generate STS restore SQL for the HART layout from Car Cards source files.

Reads roster, waybill, and spot data from this directory and writes a backup-format
SQL file compatible with STS Database Maintenance -> Restore (same format as files
in sts-backups/).
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

SEED_DIR = Path(__file__).resolve().parent
REPO_ROOT = SEED_DIR.parent
CARDS_ROOT = REPO_ROOT.parent
INPUTS_DIR = SEED_DIR / "inputs"
DEFAULT_CONFIG = SEED_DIR / "hart_seed_config.json"


def resolve_default_hart_dir() -> Path:
    """Prefer a directory that has CarImagesFinal (required for car roster)."""
    for candidate in (INPUTS_DIR, CARDS_ROOT, REPO_ROOT):
        if (candidate / "CarImagesFinal").is_dir() and (
            candidate / "HART_MergedCarRoster.xml"
        ).is_file():
            return candidate
    return INPUTS_DIR


def resolve_default_output() -> Path:
    for candidate in (
        CARDS_ROOT / "sts-backups" / "hart_seed",
        REPO_ROOT / "backups" / "hart_seed",
    ):
        candidate.parent.mkdir(parents=True, exist_ok=True)
        return candidate
    return CARDS_ROOT / "sts-backups" / "hart_seed"


DEFAULT_HART_DIR = resolve_default_hart_dir()
DEFAULT_OUTPUT = resolve_default_output()
DEFAULT_MRR_CSV = INPUTS_DIR / "MRR-AAR_Class_Codes.csv"
DEFAULT_SCULLY_MAP = INPUTS_DIR / "hart_scully_nville_shipping_map_proposed.csv"
DEFAULT_IX_MAP = INPUTS_DIR / "hart_ix_shipping_map_proposed.csv"
DEFAULT_SHIPMENT_RENAMES = INPUTS_DIR / "hart_shipment_code_renames_proposed.csv"

from balance_shipment_yards import (  # noqa: E402
    balance_shipment_rows,
    inventory_from_car_rows,
)

JOB_STEP_CREATE = """CREATE TABLE `{table}` (
  `step_number` int(11) NOT NULL,
  `station` int(11) DEFAULT NULL,
  `pickup` char(1) DEFAULT NULL,
  `setout` char(1) DEFAULT NULL,
  `remarks` varchar(256) DEFAULT NULL,
  PRIMARY KEY (`step_number`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;"""

# STS backup CREATE TABLE definitions (MariaDB / STS 2024 schema).
TABLE_SCHEMAS: dict[str, str] = {
    "blocks": """CREATE TABLE `blocks` (
  `id` int(11) DEFAULT NULL,
  `job_id` int(11) DEFAULT NULL,
  `seq_nbr` int(11) DEFAULT NULL,
  `code` varchar(256) DEFAULT NULL,
  `description` varchar(256) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;""",
    "car_codes": """CREATE TABLE `car_codes` (
  `Id` int(11) NOT NULL AUTO_INCREMENT,
  `code` tinytext NOT NULL,
  `description` tinytext DEFAULT NULL,
  `remarks` text DEFAULT NULL,
  PRIMARY KEY (`Id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "car_orders": """CREATE TABLE `car_orders` (
  `waybill_number` varchar(16) NOT NULL,
  `shipment` int(11) NOT NULL,
  `car` int(11) NOT NULL,
  PRIMARY KEY (`waybill_number`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "cars": """CREATE TABLE `cars` (
  `Id` int(11) NOT NULL AUTO_INCREMENT,
  `reporting_marks` varchar(16) NOT NULL,
  `car_code_id` int(11) NOT NULL,
  `current_location_id` int(11) NOT NULL,
  `position` int(11) DEFAULT NULL,
  `status` varchar(256) NOT NULL,
  `handled_by_job_id` int(11) DEFAULT NULL,
  `remarks` text DEFAULT NULL,
  `load_count` int(11) NOT NULL,
  `home_location` int(11) DEFAULT NULL,
  `RFID_code` char(255) DEFAULT NULL,
  `block_id` int(11) DEFAULT NULL,
  `last_spotted` int(11) DEFAULT NULL,
  PRIMARY KEY (`Id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "commodities": """CREATE TABLE `commodities` (
  `Id` int(11) NOT NULL AUTO_INCREMENT,
  `Code` tinytext NOT NULL,
  `Description` tinytext DEFAULT NULL,
  `Remarks` text DEFAULT NULL,
  PRIMARY KEY (`Id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "empty_locations": """CREATE TABLE `empty_locations` (
  `shipment` int(11) NOT NULL,
  `priority` int(11) NOT NULL,
  `location` int(11) NOT NULL,
  PRIMARY KEY (`shipment`,`priority`,`location`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "history": """CREATE TABLE `history` (
  `car_id` int(11) DEFAULT NULL,
  `session_nbr` int(11) DEFAULT NULL,
  `event_date` datetime DEFAULT NULL,
  `event` varchar(256) DEFAULT NULL,
  `location` int(11) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;""",
    "jobs": """CREATE TABLE `jobs` (
  `Id` int(11) NOT NULL AUTO_INCREMENT,
  `name` tinytext NOT NULL,
  `description` text DEFAULT NULL,
  PRIMARY KEY (`Id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "locations": """CREATE TABLE `locations` (
  `Id` int(11) NOT NULL AUTO_INCREMENT,
  `code` tinytext NOT NULL,
  `station` int(11) NOT NULL,
  `track` tinytext DEFAULT NULL,
  `spot` tinytext DEFAULT NULL,
  `rpt_station` tinytext DEFAULT NULL,
  `remarks` text DEFAULT NULL,
  `color` tinytext DEFAULT NULL,
  PRIMARY KEY (`Id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "owners": """CREATE TABLE `owners` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(256) DEFAULT NULL,
  `remarks` varchar(256) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "ownership": """CREATE TABLE `ownership` (
  `car_id` int(11) NOT NULL,
  `owner_id` int(11) NOT NULL,
  `on_off_rr` varchar(256) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "pool": """CREATE TABLE `pool` (
  `car_id` int(11) NOT NULL,
  `shipment_id` int(11) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "pu_criteria": """CREATE TABLE `pu_criteria` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `job_id` varchar(64) DEFAULT NULL,
  `step_nbr` int(11) DEFAULT NULL,
  `car_status` varchar(256) DEFAULT NULL,
  `commodity_id` int(11) DEFAULT NULL,
  `car_code_id` int(11) DEFAULT NULL,
  `dest_station_id` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "routing": """CREATE TABLE `routing` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `station` tinytext NOT NULL,
  `station_nbr` int(11) DEFAULT NULL,
  `instructions` text DEFAULT NULL,
  `sort_seq` int(11) DEFAULT NULL,
  `color1` int(11) DEFAULT NULL,
  `color2` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "settings": """CREATE TABLE `settings` (
  `setting_name` varchar(256) NOT NULL,
  `setting_desc` varchar(256) NOT NULL,
  `setting_value` varchar(256) NOT NULL,
  PRIMARY KEY (`setting_name`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
    "shipments": """CREATE TABLE `shipments` (
  `Id` int(11) NOT NULL AUTO_INCREMENT,
  `code` tinytext NOT NULL,
  `description` tinytext NOT NULL,
  `consignment` int(11) NOT NULL,
  `car_code` int(11) NOT NULL,
  `loading_location` int(11) NOT NULL,
  `unloading_location` int(11) NOT NULL,
  `last_ship_date` int(11) NOT NULL,
  `min_interval` int(11) NOT NULL,
  `max_interval` int(11) NOT NULL,
  `min_amount` int(11) NOT NULL,
  `max_amount` int(11) NOT NULL,
  `special_instructions` tinytext DEFAULT NULL,
  `remarks` text DEFAULT NULL,
  `min_load_time` int(11) DEFAULT NULL,
  `max_load_time` int(11) DEFAULT NULL,
  `min_unload_time` int(11) DEFAULT NULL,
  `max_unload_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`Id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;""",
}

STATIC_BACKUP_TABLES = [
    "blocks",
    "car_codes",
    "car_orders",
    "cars",
    "commodities",
    "empty_locations",
    "history",
    "jobs",
    "locations",
    "owners",
    "ownership",
    "pool",
    "pu_criteria",
    "routing",
    "settings",
    "shipments",
]

# Shipment order limits for HART — used by STS generate.php (not load/unload times).
# Tiered profile targeting ~20-24 orders on first Generate Session from fresh seed.
# General/FM use interval 0-2 + amount 1-1 for session-1 eligibility; HC/HP/GA stay throttled.
SHIPMENT_INTERVALS_LOCAL = {
    "min_interval": 0,
    "max_interval": 2,
    "min_amount": 1,
    "max_amount": 1,
}
SHIPMENT_INTERVALS_LOCAL_GONDOLA = {
    "min_interval": 3,
    "max_interval": 5,
    "min_amount": 0,
    "max_amount": 1,
}
SHIPMENT_INTERVALS_IX = {
    "min_interval": 0,
    "max_interval": 2,
    "min_amount": 1,
    "max_amount": 1,
}
SHIPMENT_INTERVALS_LOCAL_HC = {
    "min_interval": 2,
    "max_interval": 5,
    "min_amount": 0,
    "max_amount": 1,
}
SHIPMENT_INTERVALS_IX_HC = {
    "min_interval": 3,
    "max_interval": 6,
    "min_amount": 0,
    "max_amount": 1,
}
SHIPMENT_INTERVALS_LOCAL_HP = {
    "min_interval": 2,
    "max_interval": 4,
    "min_amount": 0,
    "max_amount": 1,
}
SHIPMENT_INTERVALS_IX_HP = {
    "min_interval": 4,
    "max_interval": 7,
    "min_amount": 0,
    "max_amount": 1,
}
SHIPMENT_INTERVALS_LOCAL_TANK = {
    "min_interval": 1,
    "max_interval": 2,
    "min_amount": 0,
    "max_amount": 1,
}
SHIPMENT_INTERVALS_IX_TANK = {
    "min_interval": 2,
    "max_interval": 4,
    "min_amount": 0,
    "max_amount": 1,
}
SHIPMENT_INTERVALS_IX_GONDOLA = {
    "min_interval": 5,
    "max_interval": 8,
    "min_amount": 0,
    "max_amount": 1,
}
SHIPMENT_INTERVALS_LOCAL_FM = {
    "min_interval": 0,
    "max_interval": 2,
    "min_amount": 1,
    "max_amount": 1,
}
SHIPMENT_INTERVALS_IX_FM = {
    "min_interval": 0,
    "max_interval": 2,
    "min_amount": 0,
    "max_amount": 1,
}
GONDOLA_CODES = frozenset({"GA", "GD"})
TANK_CODES = frozenset({"TA", "TL"})
FLATCAR_FM_CODES = frozenset({"FM"})
COVERED_HOPPER_HP_CODES = frozenset({"HP"})
COVERED_HOPPER_HC_CODES = frozenset({"HC"})

PASSENGER_TYPES = frozenset(
    {
        "Baggage",
        "Coach",
        "Combine",
        "Dining",
        "Observation",
        "Caboose",
        "MOW",
    }
)


def load_covered_hopper_prefixes(
    metadata_csv: Path,
    roster_xml: Path,
    config: dict,
) -> dict[str, str]:
    """Map roster IDs to covered-hopper AAR prefix: HC (gravity) or HP (pneumatic)."""
    _, marks_to_id = load_roster_lookup(roster_xml)
    prefixes: dict[str, str] = {}

    for roster_id in config.get("pneumatic_covered_hopper_roster_ids", []):
        prefixes[roster_id] = "HP"
    for roster_id in config.get("covered_hopper_roster_ids", []):
        prefixes.setdefault(roster_id, "HC")

    gravity_keywords = [
        k.lower()
        for k in config.get(
            "covered_hopper_note_keywords",
            ["covered hopper", "cement hopper", "portland cement"],
        )
    ]
    pneumatic_keywords = [
        k.lower()
        for k in config.get(
            "pneumatic_hopper_note_keywords",
            ["pneumatic", "plastic pellet"],
        )
    ]

    with metadata_csv.open(encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            if "CarImagesFinal" not in (row.get("notes") or ""):
                continue
            roster_id = resolve_roster_id(row, marks_to_id)
            if not roster_id:
                continue
            if roster_id in prefixes:
                continue
            car_class = infer_car_class(row)
            if car_class == "LO" and normalize_car_type(row.get("car_type") or "") == "Hopper":
                prefixes[roster_id] = (
                    "HP"
                    if roster_id in config.get("pneumatic_covered_hopper_roster_ids", [])
                    else "HC"
                )
                continue
            notes = (row.get("notes") or "").lower()
            if any(keyword in notes for keyword in pneumatic_keywords):
                prefixes[roster_id] = "HP"
            elif any(keyword in notes for keyword in gravity_keywords):
                prefixes[roster_id] = "HC"
    return prefixes


def load_roster_lookup(roster_xml: Path) -> tuple[dict[str, str], dict[str, str]]:
    root = ET.parse(roster_xml).getroot()
    id_to_marks: dict[str, str] = {}
    marks_to_id: dict[str, str] = {}
    for car in root.findall("cars/car"):
        if car.get("type") in PASSENGER_TYPES:
            continue
        roster_id = car.get("id", "")
        marks = f"{car.get('roadName', '')}{car.get('roadNumber', '')}"
        if roster_id:
            id_to_marks[roster_id] = marks
            marks_to_id[marks] = roster_id
    return id_to_marks, marks_to_id


def resolve_roster_id(row: dict, marks_to_id: dict[str, str]) -> str | None:
    roster_id = (row.get("roster_id") or "").strip()
    if roster_id:
        return roster_id

    road = (row.get("road_name") or "").replace("&", "").replace(" ", "").strip()
    number = (row.get("road_number") or "").strip()
    if road and number:
        return marks_to_id.get(f"{road}{number}")
    return None


def roster_ids_with_final_images(
    metadata_csv: Path,
    final_dir: Path,
    roster_xml: Path,
) -> set[str]:
    """Roster IDs that have a CarImagesFinal source file (same rules as sync_hart_car_images.py)."""
    _, marks_to_id = load_roster_lookup(roster_xml)
    roster_ids: set[str] = set()
    with metadata_csv.open(encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            if "CarImagesFinal" not in (row.get("notes") or ""):
                continue
            roster_id = resolve_roster_id(row, marks_to_id)
            if not roster_id:
                continue
            src = final_dir / row["source_image"].strip()
            if src.exists():
                roster_ids.add(roster_id)
    return roster_ids


def sql_str(value: str | None) -> str:
    if value is None:
        return "NULL"
    escaped = (
        str(value)
        .replace("\\", "\\\\")
        .replace("'", "''")
        .replace("\r\n", "\n")
        .replace("\r", "\n")
        .replace("\n", "\\n")
    )
    return f"'{escaped}'"


def sql_int(value: int | None) -> str:
    if value is None:
        return "NULL"
    return str(int(value))


def backup_val(value: object) -> str:
    """Format a value for STS backup insert statements (all values quoted)."""
    if value is None:
        return '""'
    if isinstance(value, bool):
        return '"T"' if value else '"F"'
    if isinstance(value, int):
        return f'"{value}"'
    escaped = (
        str(value)
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\r\n", "\n")
        .replace("\r", "\n")
    )
    return f'"{escaped}"'


def patch_auto_increment(ddl: str, next_id: int) -> str:
    if "AUTO_INCREMENT=" in ddl:
        return re.sub(r"AUTO_INCREMENT=\d+", f"AUTO_INCREMENT={next_id}", ddl)
    return ddl


def table_ddl(table: str, next_id: int | None = None) -> str:
    if table in TABLE_SCHEMAS:
        ddl = TABLE_SCHEMAS[table]
        if next_id is not None:
            return patch_auto_increment(ddl, next_id)
        return ddl
    return JOB_STEP_CREATE.format(table=table)


def emit_backup_table(
    lines: list[str],
    table: str,
    create_ddl: str,
    rows: list[list[object]],
    *,
    job_route: bool = False,
) -> None:
    if job_route:
        restore_table = f"{table}__sts_restore"
        temp_ddl = create_ddl.replace(f"CREATE TABLE `{table}`", f"CREATE TABLE `{restore_table}`", 1)
        lines.append(f"drop table if exists `{restore_table}`;")
        lines.append("#")
        lines.append(temp_ddl)
        lines.append("#")
        lines.append(f"drop table if exists `{table}`;")
        lines.append("#")
        lines.append(f"rename table `{restore_table}` to `{table}`;")
    else:
        lines.append(f"drop table if exists `{table}`;")
        lines.append("#")
        lines.append(create_ddl)
    lines.append("#")
    for row in rows:
        values = ",".join(backup_val(value) for value in row)
        lines.append(f"insert into `{table}` values({values});")
        lines.append("#")
    lines.append("")
    lines.append("#")
    lines.append("")


def load_config(path: Path) -> dict:
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def commodity_code(name: str) -> str:
    if not name or name == "EMPTY":
        return ""
    if name == "Process Chemicals":
        return "PROCCHEM"
    if name == "General Freight":
        return "GENFREIGHT"
    return re.sub(r"[^A-Za-z0-9]", "", name.upper())[:24]


def commodity_hazmat_remarks(commodity_name: str, config: dict) -> str:
    """Hazmat UN/class/placard and handling notes for process-chemical commodities."""
    hazmat = config.get("process_chemical_hazmat", {})
    return hazmat.get(commodity_name.strip(), "").strip()


def usage_location_code(industry: str, usage: str) -> str:
    prefix = {
        "Aristech Plastics": "ARIS",
        "A Stucki Co": "STUK",
        "Calgon Carbon": "CALG",
        "Ferrel Gas": "FERR",
        "Kosmos Cement": "KOSM",
    }.get(industry, re.sub(r"[^A-Za-z0-9]", "", industry.upper())[:4])
    suffix = {
        "Pellet Unload": "PELLETS",
        "Chemical Unload": "CHEMICAL",
        "Shipping Door": "SHIPPING",
        "Coal Unload": "COAL",
        "Carbon Load": "CARBON",
        "Cement Unload": "CEMENT",
        "Aggregate Unload": "AGGREGATE",
        "LPG Unload": "LPG",
        "Crane Track": "CRANE",
        "Team Track": "TEAM",
    }.get(usage.strip())
    if not suffix:
        suffix = re.sub(r"[^A-Za-z0-9]", "", usage.upper())[:24]
    return f"{prefix}-{suffix}"


ISLAND_UNLOAD_USAGES = frozenset(
    {
        "Pellet Unload",
        "Chemical Unload",
        "Coal Unload",
        "Cement Unload",
        "Aggregate Unload",
        "LPG Unload",
    }
)
ISLAND_LOAD_USAGES = frozenset({"Carbon Load", "Shipping Door"})
ISLAND_BIDIRECTIONAL_TRACK = "IN/OUT"
POHC_YARD_CODE = "SCULLY-YARD"
CSX_YARD_CODE = "DEMMLER-YARD"
STAGING_TRACK = "Staging"

# Legacy proposal CSV codes mapped to home interchange yards.
PHYSICAL_BLOCK_MAP = {
    "SCL": "SCULLY-YARD",
    "DEM": "DEMMLER-YARD",
    "SCL-YARD": "SCULLY-YARD",
    "DEM-YARD": "DEMMLER-YARD",
    "SCULLY-YARD": "SCULLY-YARD",
    "DEMMLER-YARD": "DEMMLER-YARD",
    "SCL-IN": "SCULLY-YARD",
    "DEM-IN": "DEMMLER-YARD",
    "SCL-RCV": "SCULLY-YARD",
    "DEM-RCV": "DEMMLER-YARD",
}

# Physical yard blocks are not modeled; home yards SCL/DEM handle setout and pickup.
SKIP_INTERCHANGE_LOCATION_CODES = frozenset(
    {
        "SCL",
        "DEM",
        "SCL-IN",
        "DEM-IN",
        "SCL-RCV",
        "DEM-RCV",
        "SCL-OUT",
        "SCL-FWD",
        "DEM-OUT",
        "DEM-FWD",
    }
)

NIL_INDUSTRY_PREFIX = {
    "ARIS": "Aristech Plastics",
    "STUK": "A Stucki Co",
    "CALG": "Calgon Carbon",
    "FERR": "Ferrel Gas",
    "KOSM": "Kosmos Cement",
}

SPUR_COLOR_TO_STS = {
    "yellow": "yellow",
    "red": "red",
    "green": "green",
    "orange": "orange",
    "blue": "mediumblue",
}

# Home interchange yard highlight colors (formerly on SCL-OUT / DEM-OUT blocks).
YARD_LOCATION_COLORS = {
    "SCULLY-YARD": "pink",
    "DEMMLER-YARD": "purple",
    "SCL-YARD": "pink",
    "DEM-YARD": "purple",
    "SCL": "pink",
    "DEM": "purple",
}


def fixed_location_color(code: str) -> str:
    return YARD_LOCATION_COLORS.get(code, "")


def offline_station_color(station_id: int, config: dict) -> str:
    """POHC offline (McKees Rocks) = pink; CSX offline (Mckeesport) = purple."""
    offline = config.get("offline_stations", {})
    pohc_offline = int(offline.get("pohc_offline_station_id", 15))
    csx_offline = int(offline.get("csx_offline_station_id", 14))
    if station_id == pohc_offline:
        return "pink"
    if station_id == csx_offline:
        return "purple"
    return ""


def normalize_interchange_location_code(code: str) -> str:
    """Map legacy yard block codes to home interchange yards (SCL / DEM)."""
    text = (code or "").strip()
    return PHYSICAL_BLOCK_MAP.get(text, text)


def load_industry_location_colors(hart_dir: Path) -> dict[str, str]:
    """Industry highlight colors from layout spurs file (matches operator sheet palette)."""
    colors: dict[str, str] = {}
    spurs = hart_dir / "spurs"
    if not spurs.is_file():
        return colors
    with spurs.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or "-" not in line:
                continue
            industry, _, color_name = [part.strip() for part in line.split("-", 2)]
            sts_color = SPUR_COLOR_TO_STS.get(color_name.lower())
            if sts_color:
                colors[industry] = sts_color
    return colors


def industry_for_location_code(code: str) -> str | None:
    if not code:
        return None
    text = code.strip()
    if text.startswith("NIL-"):
        parts = text.split("-", 2)
        if len(parts) >= 2:
            return NIL_INDUSTRY_PREFIX.get(parts[1])
    prefix = text.split("-", 1)[0]
    return NIL_INDUSTRY_PREFIX.get(prefix)


def format_spot_range(numbers: list[int]) -> str:
    nums = sorted({int(n) for n in numbers})
    if not nums:
        return ""
    if len(nums) == 1:
        return str(nums[0])
    return f"{nums[0]}-{nums[-1]}"


def normalize_rpt_station(label: str) -> str:
    """STS reporting station: company (city, state) without IN/OUT prefixes or em-dashes."""
    text = (label or "").strip()
    if not text:
        return ""
    text = re.sub(r"^(IN|OUT)\s*[—–-]\s*", "", text, flags=re.IGNORECASE).strip()
    text = text.replace(" — ", ", ").replace("—", ", ").replace("–", ", ")
    text = re.sub(r",\s*,", ",", text)
    return text.strip(" ,")


GENERIC_OFFLINE_REMARKS = frozenset(
    {
        "POHC",
        "CSX",
        "POHC Offline load",
        "POHC Offline unload",
        "CSX Offline load",
        "CSX Offline unload",
        "POHC coke lane",
        "CSX coke lane",
    }
)


def customer_name_without_location(label: str) -> str:
    """Party/customer name only — drop (city, state) or trailing ', City, ST'."""
    text = normalize_rpt_station(label)
    if not text:
        return ""
    text = re.sub(r"\s*\([^)]*\)\s*", "", text).strip()
    text = re.sub(r",\s*[^,]+,\s*[A-Z]{2}\s*$", "", text).strip()
    return text.strip(" ,")


def offline_location_remarks(rpt_station: str, remarks: str) -> str:
    if remarks.strip() in GENERIC_OFFLINE_REMARKS:
        name = customer_name_without_location(rpt_station)
        if name:
            return name
    return remarks


def island_location_fields(
    industry: str, usage: str, spot_numbers: list[int]
) -> tuple[str, str, str, str]:
    """Track, spot, rpt_station, remarks for Neville Island industry locations."""
    usage = usage.strip()
    rpt_station = f"{industry}, {usage}" if usage else industry
    spot = format_spot_range(spot_numbers)
    if usage in ISLAND_UNLOAD_USAGES:
        return "INBOUND", spot, rpt_station, industry
    if usage in ISLAND_LOAD_USAGES:
        return "OUTBOUND", spot, rpt_station, industry
    return ISLAND_BIDIRECTIONAL_TRACK, spot, rpt_station, industry


def is_layout_party(name: str, layout_parties: set[str]) -> bool:
    n = name.strip()
    if not n:
        return False
    if n in layout_parties:
        return True
    return n.lower().startswith("ferrellgas")


# STS mechanical designators (letter pair + length digits) align with the opsig /
# MRR-AAR reference. Classic AAR stencil classes from car cards (LO, HT, HM, …)
# are mapped to these STS prefixes.
AAR_PREFIX_DESCRIPTIONS: dict[str, str] = {
    "HM": "hopper, open top, twin hopper, gravity discharge inside rails",
    "HT": "hopper, open top, crosswise dump between rails",
    "HK": "hopper, open top, triple hopper, gravity discharge outside rails",
    "HC": "hopper, covered, gravity discharge",
    "HP": "hopper, covered, pneumatic discharge",
    "XM": "boxcar, general service",
    "FM": "flatcar, general service",
    "TA": "tankcar, general service",
    "TL": "tankcar, lined for corrosive or specialty liquids",
    "GA": "gondola, open top",
    "GD": "gondola, open top with side doors for dumping",
    "FC": "flatcar, center beam",
    "RM": "refrigerator, mechanical",
    "WF": "work flatcar, MOW service",
    "WC": "work crane car, MOW service",
}

# Classic AAR class (opsig 1987) -> STS prefix when length suffix is appended.
CLASSIC_AAR_TO_STS_PREFIX: dict[str, str] = {
    "LO": "HC",  # covered hopper; pneumatic roster overrides to HP
    "HT": "HT",
    "HM": "HM",
    "HK": "HK",
    "HD": "HK",
    "HA": "HM",  # legacy stencil -> twin hopper
    "HB": "HK",  # legacy stencil -> outside triple hopper
    "XM": "XM",
    "XI": "XM",
    "GB": "GA",
    "GA": "GA",
    "GD": "GD",
    "GT": "GA",
    "FM": "FM",
    "FC": "FC",
    "F3": "FM",
    "TA": "TA",
    "TM": "TA",
    "TL": "TL",
    "TP": "TA",  # pressurized/LPG — STS MRR list uses TA for general tanks
    "RM": "RM",
    "RP": "RM",
}

ROSTER_TYPE_AAR_PREFIX: dict[str, str] = {
    "Boxcar": "XM",
    "Flatcar": "FM",
    "Gondola": "GA",
    "Tank": "TA",
    "Coil": "FC",
    "Reefer": "RM",
}

WAYBILL_TYPE_AAR_PREFIX: dict[str, str] = {
    "Boxcar": "XM",
    "Flat Car": "FM",
    "Gondola": "GA",
    "Tank Car": "TA",
    "Coil Car": "FC",
    "Reefer": "RM",
}

HOPPER_AAR_PREFIXES = frozenset({"HM", "HT", "HK", "HC", "HP"})
OPEN_TOP_HOPPER_CODES = frozenset({"HM", "HT", "HK"})
OPEN_TOP_HOPPER_AAR = frozenset({"HM", "HT", "HK"})
OPEN_TOP_HOPPER_PREFIXES = frozenset({"HM", "HT", "HK"})
TANK_AAR_PREFIXES = frozenset({"TA", "TL"})
TANK_CODE_FALLBACKS: dict[str, list[str]] = {"TL": ["TA"]}
PNEUMATIC_COVERED_COMMODITIES = frozenset({"Plastic Pellets"})
MRR_DESCRIPTIONS: dict[str, str] = {}


def load_mrr_aar_descriptions(path: Path) -> dict[str, str]:
    """Load official STS AAR code descriptions from MRR-AAR_Class_Codes.csv."""
    descriptions: dict[str, str] = {}
    if not path.exists():
        return descriptions
    with path.open(newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            code = (row.get("Code") or "").strip()
            desc = (row.get("Description") or "").strip()
            if code and desc:
                descriptions[code] = desc
    return descriptions


OPEN_HOPPER_NOTE_KEYWORDS = (
    "coke hopper",
    "coke",
    "coal hopper",
    "coal",
    "gla",
    "open-top",
    "open top",
)
OPEN_HOPPER_CAR_CLASSES = frozenset({"HT", "HM", "HK", "HD", "HA", "HB"})
LO_OCR_PATTERNS = (
    re.compile(r"\bLO\s+LMT\b"),
    re.compile(r"\bLOLMT\b"),
    re.compile(r"\bGAPY\b[^A-Z]{0,32}\bLO\b"),
)


def normalize_car_type(car_type: str) -> str:
    car_type = car_type.strip()
    return "Hopper" if car_type == "Coal" else car_type


def infer_car_class(row: dict[str, str]) -> str:
    """Use reviewed car_class, else LO stencil from OCR on covered-hopper cards."""
    car_class = (row.get("car_class") or "").strip().upper()
    if car_class:
        return car_class
    if normalize_car_type(row.get("car_type") or "") != "Hopper":
        return ""
    ocr = (row.get("ocr_text") or "").upper()
    for pattern in LO_OCR_PATTERNS:
        if pattern.search(ocr):
            return "LO"
    return ""


def load_roster_metadata(
    metadata_csv: Path,
    roster_xml: Path,
) -> dict[str, dict[str, str]]:
    """Map roster ID -> car_class and notes from image_metadata.csv."""
    _, marks_to_id = load_roster_lookup(roster_xml)
    meta: dict[str, dict[str, str]] = {}
    with metadata_csv.open(encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            roster_id = resolve_roster_id(row, marks_to_id)
            if not roster_id:
                continue
            meta[roster_id] = {
                "car_class": infer_car_class(row),
                "notes": (row.get("notes") or "").strip(),
                "car_type": normalize_car_type(row.get("car_type") or ""),
            }
    return meta


def is_covered_hopper_meta(meta: dict[str, str] | None, config: dict) -> bool:
    if not meta:
        return False
    if normalize_car_type(meta.get("car_type", "")) != "Hopper":
        return False
    car_class = meta.get("car_class", "").upper()
    if car_class in OPEN_HOPPER_CAR_CLASSES:
        return False
    if car_class == "LO":
        return True
    notes = meta.get("notes", "").lower()
    if any(keyword in notes for keyword in OPEN_HOPPER_NOTE_KEYWORDS):
        return False
    keywords = config.get(
        "covered_hopper_note_keywords",
        ["covered hopper", "cement hopper", "portland cement", "kosmos"],
    )
    return any(keyword in notes for keyword in keywords)


def covered_hopper_prefix_for(
    roster_id: str,
    covered_prefixes: dict[str, str],
    meta: dict[str, str] | None,
    config: dict,
) -> str | None:
    if roster_id in covered_prefixes:
        return covered_prefixes[roster_id]
    if is_covered_hopper_meta(meta, config):
        return "HP" if roster_id in config.get("pneumatic_covered_hopper_roster_ids", []) else "HC"
    return None


def open_hopper_sts_prefix(
    roster_id: str,
    meta: dict[str, str] | None,
    config: dict,
) -> str:
    hk_marks = config.get("open_hopper_hk_marks") or config.get(
        "coke_fleet_hk_marks", []
    )
    if roster_id in hk_marks:
        return "HK"
    if roster_id in config.get("coke_fleet_marks", []):
        return "HM"
    if meta:
        classic = meta.get("car_class", "").upper()
        mapped = CLASSIC_AAR_TO_STS_PREFIX.get(classic)
        if mapped in OPEN_TOP_HOPPER_PREFIXES:
            return mapped
    return "HM"


def tank_prefix_for_commodity(commodity: str, config: dict) -> str:
    commodity = commodity.strip()
    lined = frozenset(config.get("tank_lined_commodities", []))
    if commodity in lined:
        return "TL"
    return "TA"


def aar_code_prefix(prefix: str) -> str:
    """Mechanical designator only (e.g. HA40 -> HA)."""
    prefix = prefix.strip().upper()
    if len(prefix) > 2 and prefix[2:].isdigit():
        return prefix[:2]
    return prefix


def aar_description(code: str) -> str:
    code = aar_code_prefix(code)
    if code in MRR_DESCRIPTIONS:
        return MRR_DESCRIPTIONS[code]
    return AAR_PREFIX_DESCRIPTIONS.get(code, "freight car")


def aar_code_for_roster_car(
    car_type: str,
    length: str | None,
    *,
    covered_hopper_prefix: str | None = None,
    roster_meta: dict[str, str] | None = None,
    roster_id: str = "",
    config: dict | None = None,
) -> str | None:
    config = config or {}

    if car_type == "Hopper":
        if covered_hopper_prefix in {"HC", "HP"}:
            return aar_code_prefix(covered_hopper_prefix)
        if is_covered_hopper_meta(roster_meta, config):
            return "HC"
        return aar_code_prefix(
            open_hopper_sts_prefix(roster_id or "", roster_meta, config)
        )

    if car_type == "Gondola" and roster_meta:
        classic = roster_meta.get("car_class", "")
        if classic == "GD":
            return "GD"
        if classic in {"GB", "GT", "GA"}:
            return "GA"

    if car_type == "Boxcar" and roster_meta:
        classic = roster_meta.get("car_class", "")
        if classic in {"XM", "XI"}:
            return "XM"

    if car_type == "Flatcar" and roster_meta:
        classic = roster_meta.get("car_class", "")
        if classic in {"FM", "F3"}:
            return "FM"

    prefix = ROSTER_TYPE_AAR_PREFIX.get(car_type)
    if roster_meta and not prefix:
        classic = roster_meta.get("car_class", "")
        prefix = CLASSIC_AAR_TO_STS_PREFIX.get(classic)
    if not prefix:
        return None
    return aar_code_prefix(prefix)


def aar_prefix_for_waybill(car_type: str, commodity: str, config: dict) -> str | None:
    if car_type == "Hopper":
        commodity_lower = commodity.strip().lower()
        if commodity_lower == "coke":
            return "HM"
        if commodity_lower == "coal":
            return "H*"
        if commodity_lower == "aggregate":
            return "HT"
        return "HT"
    if car_type == "Covered Hopper":
        commodity = commodity.strip()
        if commodity in PNEUMATIC_COVERED_COMMODITIES:
            return "HP"
        return "HC"
    if car_type == "Tank Car":
        forced = (config.get("shipment_tank_code") or "").strip().upper()
        if forced:
            return aar_code_prefix(forced)
        return tank_prefix_for_commodity(commodity, config)
    return WAYBILL_TYPE_AAR_PREFIX.get(car_type)


class SeedBuilder:
    def __init__(self, config: dict, industry_colors: dict[str, str] | None = None):
        self.config = config
        self.industry_colors = industry_colors or {}
        self.routing_rows: list[dict] = []
        self.location_rows: list[dict] = []
        self.commodity_rows: list[dict] = []
        self.car_code_rows: list[dict] = []
        self.shipment_rows: list[dict] = []
        self.car_rows: list[dict] = []
        self.job_rows: list[dict] = []
        self.pu_criteria_rows: list[dict] = []
        self.empty_location_rows: list[dict] = []
        self.pool_rows: list[dict] = []
        self.owner_rows: list[dict] = []
        self.ownership_rows: list[dict] = []
        self.inbound_empty_shipments: list[dict] = []
        self._shipment_route_keys: set[tuple] = set()
        self.shipment_code_renames: dict[str, str] = {}
        self.party_offline_locations: dict[tuple[str, str, str], str] = {}
        self.location_industry_by_code: dict[str, str] = {}
        self.ix_shipment_offline: dict[str, tuple[str, str, str]] = {}
        self._interchange_yard_for_location: dict[int, int] = {}
        self._staging_location_specs: list[dict] = []

        self.location_code_to_id: dict[str, int] = {}
        self.commodity_code_to_id: dict[str, int] = {}
        self.car_code_to_id: dict[str, int] = {}
        self.fleet_code_counts: dict[str, int] = {}
        self.freight_car_ids: set[int] = set()
        self.industry_first_location: dict[str, str] = {}
        self.usage_lookup: dict[tuple[str, str], str] = {}

        self._next_location_id = 1
        self._next_commodity_id = 1
        self._next_shipment_id = 1
        self._next_car_id = 1
        self._next_car_code_id = 1

        self.layout_parties = set(config.get("layout_party_names", []))
        self.coke_fleet_marks = frozenset(config.get("coke_fleet_marks", []))
        self.unavailable_marks = frozenset(
            config.get("unavailable_reporting_marks", [])
        )

    def location_color(self, *, code: str = "", industry: str = "") -> str:
        """Industry highlight colors apply only to Neville Island industry spots."""
        resolved = industry or industry_for_location_code(code)
        if not resolved:
            return ""
        return self.industry_colors.get(resolved, "")

    def ensure_car_code(self, code: str) -> int:
        code = aar_code_prefix(code)
        if code in self.car_code_to_id:
            return self.car_code_to_id[code]
        car_code_id = self._next_car_code_id
        self._next_car_code_id += 1
        self.car_code_to_id[code] = car_code_id
        description = aar_description(code)
        if code == "H*":
            description = "hopper, open top (HM, HT, or HK)"
        self.car_code_rows.append(
            {
                "id": car_code_id,
                "code": code,
                "description": description,
                "remarks": "",
            }
        )
        return car_code_id

    def resolve_fleet_car_code(self, prefix: str) -> str:
        """Prefer an AAR code the roster actually has."""
        prefix = aar_code_prefix(prefix)
        if prefix.endswith("*"):
            return prefix
        if self.fleet_code_counts.get(prefix, 0) > 0:
            return prefix
        for alt in TANK_CODE_FALLBACKS.get(prefix, []):
            alt = aar_code_prefix(alt)
            if self.fleet_code_counts.get(alt, 0) > 0:
                return alt
        matching = [
            code
            for code, count in self.fleet_code_counts.items()
            if code.startswith(prefix) and count > 0
        ]
        if matching:
            return max(matching, key=lambda code: self.fleet_code_counts[code])
        if prefix in TANK_AAR_PREFIXES:
            for tank_code in ("TA", "TL"):
                if self.fleet_code_counts.get(tank_code, 0) > 0:
                    return tank_code
        return prefix

    def pick_shipment_aar_code(self, car_type: str, commodity: str) -> str:
        prefix = aar_prefix_for_waybill(car_type, commodity, self.config)
        if not prefix:
            prefix = "XM"
        return self.resolve_fleet_car_code(prefix)

    def is_hopper_car_code(self, car_code_id: int) -> bool:
        for row in self.car_code_rows:
            if row["id"] == car_code_id:
                return row["code"][:2] in HOPPER_AAR_PREFIXES
        return False

    def station_name_for_location(self, location_id: int) -> str:
        for loc in self.location_rows:
            if loc["id"] != location_id:
                continue
            station_id = loc.get("station")
            for route in self.routing_rows:
                if route["id"] == station_id:
                    return route.get("station", "")
            break
        return ""

    def balance_interchange_shipment_intervals(self) -> dict:
        """Re-tune interchange shipment intervals using available home-yard fleet."""
        inventory = inventory_from_car_rows(
            self.car_rows,
            self.station_name_for_location,
            self.car_code_for_id,
            self.freight_car_ids,
        )
        return balance_shipment_rows(
            self.shipment_rows,
            inventory,
            self.station_name_for_location,
            self.car_code_for_id,
            self.config,
        )

    def add_routing(self) -> None:
        instructions = self.config.get("routing_instructions", {})
        default_setout = self.config.get("default_setout_locations", {})
        for station in self.config["stations"]:
            station_id = station["id"]
            self.routing_rows.append(
                {
                    "id": station_id,
                    "station": station["name"],
                    "station_nbr": None,
                    "instructions": station.get("instructions")
                    or instructions.get(str(station_id))
                    or instructions.get(station["name"], ""),
                    "sort_seq": station["sort_seq"],
                    "color1": 0,
                    "color2": 0,
                    "_default_setout_code": default_setout.get(str(station_id))
                    or default_setout.get(station["name"]),
                }
            )

    def apply_default_setout_locations(self) -> None:
        for row in self.routing_rows:
            code = row.pop("_default_setout_code", None)
            if code and code in self.location_code_to_id:
                row["station_nbr"] = self.location_code_to_id[code]

    def add_location(
        self,
        code: str,
        station_id: int,
        track: str = "",
        spot: str = "",
        rpt_station: str = "",
        remarks: str = "",
        color: str = "",
    ) -> int:
        if code in self.location_code_to_id:
            return self.location_code_to_id[code]
        if not color:
            color = fixed_location_color(code)
        if not color:
            color = offline_station_color(station_id, self.config)
        loc_id = self._next_location_id
        self._next_location_id += 1
        self.location_code_to_id[code] = loc_id
        station = station_id
        pohc_yard = self.config["car_home_yard"]["pohc_yard_code"]
        csx_yard = self.config["car_home_yard"]["csx_yard_code"]
        offline = self.config.get("offline_stations", {})
        pohc_offline = int(offline.get("pohc_offline_station_id", 15))
        csx_offline = int(offline.get("csx_offline_station_id", 14))
        if station == pohc_offline and pohc_yard in self.location_code_to_id:
            self._interchange_yard_for_location[loc_id] = self.location_code_to_id[
                pohc_yard
            ]
        elif station == csx_offline and csx_yard in self.location_code_to_id:
            self._interchange_yard_for_location[loc_id] = self.location_code_to_id[
                csx_yard
            ]
        elif station == 9 and pohc_yard in self.location_code_to_id:
            self._interchange_yard_for_location[loc_id] = self.location_code_to_id[
                pohc_yard
            ]
        elif station == 10 and csx_yard in self.location_code_to_id:
            self._interchange_yard_for_location[loc_id] = self.location_code_to_id[
                csx_yard
            ]
        self.location_rows.append(
            {
                "id": loc_id,
                "code": code,
                "station": station_id,
                "track": track,
                "spot": spot,
                "rpt_station": normalize_rpt_station(rpt_station),
                "remarks": remarks,
                "color": color,
            }
        )
        return loc_id

    def add_yard_locations(self) -> None:
        # Staging yards (car home / fleet storage)
        self.add_location("NORTH-YARD", 11)
        self.add_location("WEST-YARD", 2)
        self.add_location("EAST-YARD", 13)
        self.add_location("SOUTH-YARD", 8)
        self.add_location("SOUTH-SCALE", 8, track="West Lead", spot="Scale")
        shenango = self.config.get("shenango_coke", {})
        if shenango:
            self.add_location(
                shenango["location_code"],
                int(shenango["station_id"]),
                track=shenango.get("track", ""),
                spot=shenango.get("spot", ""),
                rpt_station=shenango.get("rpt_station", "Neville Island"),
                remarks=shenango.get("remarks", "Shenango Coke Works"),
                color=shenango.get("color", "black"),
            )
        # Empty-return yards (separate routing stations; see outbound_empty_return in config)
        pohc_yard = self.config["car_home_yard"]["pohc_yard_code"]
        csx_yard = self.config["car_home_yard"]["csx_yard_code"]
        scl_id = self.add_location(pohc_yard, 9, remarks="POHC")
        dem_id = self.add_location(csx_yard, 10, remarks="CSX")
        self._interchange_yard_for_location[scl_id] = scl_id
        self._interchange_yard_for_location[dem_id] = dem_id

    def add_interchange_staging_locations(self) -> None:
        """Inbound yard blocks, coke Offline lanes, and island-local Offline party spots."""
        for spec in self._staging_location_specs:
            self.add_location(
                spec["code"],
                int(spec["station_id"]),
                track=spec.get("track", ""),
                spot=spec.get("spot", ""),
                rpt_station=spec.get("rpt_station", ""),
                remarks=spec.get("remarks", ""),
            )
        # Coke outbound Offline lanes (if not already loaded from proposal CSV)
        if "CLEVWORK-COKE" not in self.location_code_to_id:
            rpt = "USS Cleveland Works, Cleveland, OH"
            self.add_location(
                "CLEVWORK-COKE",
                15,
                track=STAGING_TRACK,
                spot="OUT",
                rpt_station=rpt,
                remarks=customer_name_without_location(rpt),
            )
        if "USSTEELE-COKE" not in self.location_code_to_id:
            rpt = "U.S. Steel Edgar Thomson Works"
            self.add_location(
                "USSTEELE-COKE",
                14,
                track=STAGING_TRACK,
                spot="OUT",
                rpt_station=rpt,
                remarks=customer_name_without_location(rpt),
            )

    def add_coke_outbound_locations(self) -> None:
        """Backward-compatible alias."""
        self.add_interchange_staging_locations()

    def ingest_spots(self, spot_csv: Path) -> None:
        skip = {u.lower() for u in self.config["skip_usages"]}
        island_station = int(self.config["island_local_station"])
        spots_by_usage: dict[tuple[str, str], list[int]] = {}
        with spot_csv.open(newline="", encoding="utf-8") as fh:
            for row in csv.DictReader(fh):
                industry = row["Industry"].strip()
                usage = row["Usage"].strip()
                if usage.lower() in skip:
                    continue
                spot_nbr = int(str(row["Spot #"]).strip())
                key = (industry, usage)
                spots_by_usage.setdefault(key, []).append(spot_nbr)

        for industry, usage in sorted(spots_by_usage):
            key = (industry, usage)
            code = usage_location_code(industry, usage)
            track, spot, rpt_station, remarks = island_location_fields(
                industry, usage, spots_by_usage[key]
            )
            self.add_location(
                code,
                island_station,
                track=track,
                spot=spot,
                rpt_station=rpt_station,
                remarks=remarks,
                color=self.location_color(code=code, industry=industry),
            )
            self.usage_lookup[key] = code
            if industry not in self.industry_first_location:
                self.industry_first_location[industry] = code

    def external_yard_for_via(self, via: str) -> tuple[str, int, str]:
        via = (via or "CSX").strip().upper()
        if via == "POHC":
            code = self.config["car_home_yard"]["pohc_yard_code"]
            return code, 9, "POHC"
        code = self.config["car_home_yard"]["csx_yard_code"]
        return code, 10, "CSX"

    def interchange_yard_location_id(self, via: str) -> int:
        code, _, _ = self.external_yard_for_via(via)
        return self.location_code_to_id[code]

    def interchange_yard_for_location_id(self, location_id: int) -> int:
        return self._interchange_yard_for_location.get(location_id, location_id)

    def offline_location_id(self, flow: str, via: str, party: str) -> int | None:
        key = (flow.strip().upper(), (via or "CSX").strip().upper(), party.strip())
        code = self.party_offline_locations.get(key)
        if code and code in self.location_code_to_id:
            return self.location_code_to_id[code]
        return None

    def load_shipping_proposals(
        self,
        scully_map: Path,
        shipment_renames: Path,
        ix_map: Path | None = None,
    ) -> None:
        if shipment_renames.is_file():
            with shipment_renames.open(newline="", encoding="utf-8") as fh:
                for row in csv.DictReader(fh):
                    if row.get("section") != "shipment_rename":
                        continue
                    legacy = row.get("legacy_code", "").strip()
                    proposed = row.get("proposed_code", "").strip()
                    if legacy and proposed:
                        self.shipment_code_renames[legacy] = proposed

        self._ingest_staging_map(scully_map, island_local_flows=True)
        if ix_map is not None:
            self._ingest_staging_map(ix_map, island_local_flows=False)

    def _ingest_staging_map(
        self, map_path: Path, *, island_local_flows: bool
    ) -> None:
        if not map_path.is_file():
            return

        with map_path.open(newline="", encoding="utf-8") as fh:
            rows = list(csv.DictReader(fh))

        for row in rows:
            entity = row.get("entity_type", "").strip()
            status = row.get("status", "").strip()
            if entity != "shipment" or status not in {"proposed", "active"}:
                continue
            flow = row.get("flow", "").strip().upper()
            if island_local_flows and flow in {"IN", "OUT"}:
                industry = row.get("layout_industry", "").strip()
                via = row.get("via", "").strip().upper()
                party = row.get("party_name", "").strip()
                if flow == "IN":
                    offline = normalize_interchange_location_code(
                        row.get("proposed_load_loc", "").strip()
                    )
                else:
                    offline = normalize_interchange_location_code(
                        row.get("proposed_unload_loc", "").strip()
                    )
                for loc in (
                    normalize_interchange_location_code(
                        row.get("proposed_load_loc", "").strip()
                    ),
                    normalize_interchange_location_code(
                        row.get("proposed_unload_loc", "").strip()
                    ),
                ):
                    if loc and industry:
                        self.location_industry_by_code.setdefault(loc, industry)
                if party and offline:
                    self.party_offline_locations[(flow, via, party)] = offline
            elif not island_local_flows and flow == "IX":
                code = (
                    row.get("proposed_shipment_code", "").strip()
                    or row.get("shipment_code", "").strip()
                )
                load_loc = normalize_interchange_location_code(
                    row.get("proposed_load_loc", "").strip()
                )
                unload_loc = normalize_interchange_location_code(
                    row.get("proposed_unload_loc", "").strip()
                )
                special = row.get("special_instructions", "").strip()
                if code and load_loc and unload_loc:
                    self.ix_shipment_offline[code] = (
                        load_loc,
                        unload_loc,
                        special,
                    )

        for row in rows:
            entity = row.get("entity_type", "").strip()
            status = row.get("status", "").strip()
            if entity != "location" or status not in {"proposed", "active"}:
                continue
            code = normalize_interchange_location_code(row.get("code", "").strip())
            track = row.get("track", "").strip()
            if not code or code in {POHC_YARD_CODE, CSX_YARD_CODE}:
                continue
            if code.startswith("NIL-"):
                continue
            if code in SKIP_INTERCHANGE_LOCATION_CODES:
                continue
            if track not in {"INBOUND", "OUTBOUND", STAGING_TRACK, "OFFLINE"}:
                continue
            if track == "OFFLINE":
                track = STAGING_TRACK
            self._staging_location_specs.append(
                {
                    "code": code,
                    "station_id": row.get("station_id", "").strip(),
                    "track": track,
                    "spot": row.get("spot", "").strip(),
                    "rpt_station": normalize_rpt_station(
                        row.get("rpt_station", "").strip()
                    ),
                    "remarks": offline_location_remarks(
                        row.get("rpt_station", "").strip(),
                        row.get("remarks", "").strip(),
                    ),
                }
            )

    def interchange_crossing_yards(self, via: str) -> tuple[int, int, str, str]:
        """Interchange loads at one yard and unloads at the other (POHC↔CSX bridge)."""
        pohc_yard = self.config["car_home_yard"]["pohc_yard_code"]
        csx_yard = self.config["car_home_yard"]["csx_yard_code"]
        scully_id = self.location_code_to_id[pohc_yard]
        demmler_id = self.location_code_to_id[csx_yard]
        via = (via or "CSX").strip().upper()
        if via == "POHC":
            return scully_id, demmler_id, "POHC", "CSX"
        return demmler_id, scully_id, "CSX", "POHC"

    def interchange_yard_label(self, via: str) -> str:
        code, station_id, _ = self.external_yard_for_via(via)
        for station in self.config.get("stations", []):
            if station.get("id") == station_id:
                return station["name"]
        return code

    def off_line_party_label(self, via: str, party: str) -> str:
        party = party.strip()
        yard = self.interchange_yard_label(via)
        if party:
            return f"{yard} ({party})"
        return yard

    def industry_spot_label(
        self, industry: str, usage: str, spots: str, spot_code: str | None
    ) -> str:
        if industry and usage:
            return f"{industry} — {usage}"
        return industry or usage or (spot_code or "")

    def add_commodities_from_waybills(self, waybill_rows: list[dict]) -> None:
        codes: dict[str, str] = {}
        hazmat_names: dict[str, str] = {}
        for extra in self.config.get("extra_commodities", []):
            code = extra["code"]
            codes[code] = extra["description"]
            hazmat_names[code] = extra.get("hazmat_name", extra["description"])
        for row in waybill_rows:
            commodity = row.get("commodity", "").strip()
            if not commodity or commodity == "EMPTY":
                continue
            code = commodity_code(commodity)
            if code:
                summary = row.get("load_summary", "").strip()
                desc = summary if summary else commodity
                codes[code] = desc
                hazmat_names[code] = commodity
        for code in sorted(codes):
            cid = self._next_commodity_id
            self._next_commodity_id += 1
            self.commodity_code_to_id[code] = cid
            remarks = commodity_hazmat_remarks(hazmat_names.get(code, ""), self.config)
            self.commodity_rows.append(
                {
                    "id": cid,
                    "code": code,
                    "description": codes[code],
                    "remarks": remarks,
                }
            )

    def resolve_industry_spot(
        self, industry: str, usage: str, spots: str
    ) -> str | None:
        usage = usage.strip()
        if usage:
            key = (industry, usage)
            if key in self.usage_lookup:
                return self.usage_lookup[key]
            return usage_location_code(industry, usage)
        return self.industry_first_location.get(industry)

    def shipment_code(self, row: dict) -> str:
        card_id = row.get("card_id", "").strip()
        industry = row.get("industry", "").strip()
        kind = row.get("card_kind", "").strip()
        flow = row.get("flow", "").strip()
        prefix = {
            "Aristech Plastics": "ARIS",
            "A Stucki Co": "STUK",
            "Calgon Carbon": "CALG",
            "Ferrel Gas": "FERR",
            "Kosmos Cement": "KOSM",
            "INTERCHANGE": "IX",
        }.get(industry, "SHP")
        legacy = f"{prefix}-{kind[:3].upper()}-{flow or 'XX'}-{card_id.zfill(3)}"
        return self.shipment_code_renames.get(legacy, legacy)

    def shipment_description(
        self,
        row: dict,
        *,
        loading_label: str,
        unloading_label: str,
        via_label: str | None = None,
    ) -> str:
        industry = row.get("industry", "").strip()
        commodity = row.get("commodity", "").strip()
        kind = row.get("card_kind", "").strip()
        flow = row.get("flow", "").strip()
        route_from = row.get("route_from", "").strip()
        route_to = row.get("route_to", "").strip()

        if kind == "interchange":
            if route_from and route_to:
                return f"{route_from} to {route_to}"
            via = via_label if via_label is not None else row.get("via", "").strip()
            return f"{commodity} ({via})" if via else commodity
        if kind == "loaded" and flow == "IN":
            if route_from and industry:
                return f"{route_from} to {industry}"
        if kind == "loaded" and flow == "OUT":
            if industry and route_to:
                return f"{industry} to {route_to}"
        if industry:
            return f"{industry} — {commodity}"
        return commodity

    def shipment_route_key(self, row: dict) -> tuple | None:
        """Business key for deduplicating identical local/interchange moves."""
        industry = row.get("industry", "").strip()
        kind = row.get("card_kind", "").strip()
        flow = row.get("flow", "").strip()
        usage = row.get("usage", "").strip()
        commodity_name = row.get("commodity", "").strip()
        route_from = row.get("route_from", "").strip()
        route_to = row.get("route_to", "").strip()
        via = row.get("via", "").strip()

        if kind == "interchange":
            return ("IX", route_from, route_to, via)
        if kind == "loaded" and flow == "IN":
            return ("IN", industry, usage, via, route_from, commodity_name)
        if kind == "loaded" and flow == "OUT":
            return ("OUT", industry, usage, via, route_to, commodity_name)
        return None

    def add_shipments(self, waybill_rows: list[dict]) -> None:
        for row in waybill_rows:
            industry = row.get("industry", "").strip()
            kind = row.get("card_kind", "").strip()
            flow = row.get("flow", "").strip()
            usage = row.get("usage", "").strip()
            spots = row.get("spots", "").strip()
            commodity_name = row.get("commodity", "").strip()
            route_from = row.get("route_from", "").strip()
            route_to = row.get("route_to", "").strip()
            via = row.get("via", "").strip()
            car_type = row.get("car_type", "").strip()

            # STS tracks empty/loaded on cars; skip dedicated empty-move orders.
            if kind in {"inbound_empty", "outbound_empty"}:
                continue
            if commodity_name == "EMPTY":
                continue

            route_key = self.shipment_route_key(row)
            if route_key is not None:
                if route_key in self._shipment_route_keys:
                    continue
                self._shipment_route_keys.add(route_key)

            car_code = self.pick_shipment_aar_code(car_type, commodity_name)
            car_code_id = self.ensure_car_code(car_code)
            commodity_key = commodity_code(commodity_name)
            consignment_id = self.commodity_code_to_id.get(commodity_key)

            if kind == "interchange":
                if is_layout_party(route_from, self.layout_parties):
                    continue
                if is_layout_party(route_to, self.layout_parties):
                    continue
                ship_code = self.shipment_code(row)
                ix_route = self.ix_shipment_offline.get(ship_code)
                if ix_route:
                    load_code, unload_code, special = ix_route
                    loading_id = self.location_code_to_id[load_code]
                    unloading_id = self.location_code_to_id[unload_code]
                    loading_label = route_from
                    unloading_label = route_to
                else:
                    loading_id, unloading_id, load_via, unload_via = (
                        self.interchange_crossing_yards(via)
                    )
                    loading_label = self.off_line_party_label(load_via, route_from)
                    unloading_label = self.off_line_party_label(
                        unload_via, route_to
                    )
                    special = f"{load_via}->{unload_via}"
            elif kind == "loaded" and flow == "IN":
                if not route_from:
                    continue
                spot_code = self.resolve_industry_spot(industry, usage, spots)
                if not spot_code:
                    continue
                loading_id = self.offline_location_id(flow, via, route_from)
                if loading_id is None:
                    loading_id = self.interchange_yard_location_id(via)
                unloading_id = self.location_code_to_id[spot_code]
                loading_label = self.off_line_party_label(via, route_from)
                unloading_label = self.industry_spot_label(
                    industry, usage, spots, spot_code
                )
                special = via or ""
            elif kind == "loaded" and flow == "OUT":
                if not route_to:
                    continue
                spot_code = self.resolve_industry_spot(industry, usage, spots)
                if not spot_code:
                    continue
                loading_id = self.location_code_to_id[spot_code]
                unloading_id = self.offline_location_id(flow, via, route_to)
                if unloading_id is None:
                    unloading_id = self.interchange_yard_location_id(via)
                loading_label = self.industry_spot_label(
                    industry, usage, spots, spot_code
                )
                unloading_label = self.off_line_party_label(via, route_to)
                special = via or ""
            else:
                continue

            if consignment_id is None:
                continue

            if car_code in GONDOLA_CODES:
                if kind == "interchange":
                    intervals = SHIPMENT_INTERVALS_IX_GONDOLA
                else:
                    intervals = SHIPMENT_INTERVALS_LOCAL_GONDOLA
            elif car_code in FLATCAR_FM_CODES:
                if kind == "interchange":
                    intervals = SHIPMENT_INTERVALS_IX_FM
                else:
                    intervals = SHIPMENT_INTERVALS_LOCAL_FM
            elif car_code in COVERED_HOPPER_HP_CODES:
                if kind == "interchange":
                    intervals = SHIPMENT_INTERVALS_IX_HP
                else:
                    intervals = SHIPMENT_INTERVALS_LOCAL_HP
            elif car_code in COVERED_HOPPER_HC_CODES:
                if kind == "interchange":
                    intervals = SHIPMENT_INTERVALS_IX_HC
                else:
                    intervals = SHIPMENT_INTERVALS_LOCAL_HC
            elif car_code in TANK_CODES:
                if kind == "interchange":
                    intervals = SHIPMENT_INTERVALS_IX_TANK
                else:
                    intervals = SHIPMENT_INTERVALS_LOCAL_TANK
            elif kind == "interchange":
                intervals = SHIPMENT_INTERVALS_IX
            else:
                intervals = SHIPMENT_INTERVALS_LOCAL

            self.shipment_rows.append(
                {
                    "id": self._next_shipment_id,
                    "code": self.shipment_code(row),
                    "description": self.shipment_description(
                        row,
                        loading_label=loading_label,
                        unloading_label=unloading_label,
                        via_label=special if kind == "interchange" else None,
                    ),
                    "consignment": consignment_id,
                    "car_code": car_code_id,
                    "loading_location": loading_id,
                    "unloading_location": unloading_id,
                    "last_ship_date": 0,
                    "min_interval": intervals["min_interval"],
                    "max_interval": intervals["max_interval"],
                    "min_amount": intervals["min_amount"],
                    "max_amount": intervals["max_amount"],
                    "special_instructions": "",
                    "remarks": "",
                }
            )
            self._next_shipment_id += 1

    def add_coke_shipments(self) -> None:
        coke_weigh_note = "All loads to be weighed in South Yard."
        for spec in self.config.get("coke_shipments", []):
            commodity_key = spec["commodity"]
            consignment_id = self.commodity_code_to_id.get(commodity_key)
            if consignment_id is None:
                continue
            loading_code = normalize_interchange_location_code(spec["loading_location"])
            unloading_code = normalize_interchange_location_code(
                spec["unloading_location"]
            )
            if loading_code not in self.location_code_to_id:
                continue
            if unloading_code not in self.location_code_to_id:
                continue
            car_code = spec.get("car_code", "HM")
            car_code_id = self.ensure_car_code(car_code)
            code = spec["code"]
            if code.startswith("COKE-USS") or code.startswith("COKE-CLEV"):
                special = coke_weigh_note
            else:
                special = spec.get("special_instructions", "")
            self.shipment_rows.append(
                {
                    "id": self._next_shipment_id,
                    "code": code,
                    "description": spec["description"],
                    "consignment": consignment_id,
                    "car_code": car_code_id,
                    "loading_location": self.location_code_to_id[loading_code],
                    "unloading_location": self.location_code_to_id[unloading_code],
                    "last_ship_date": 0,
                    "min_interval": float(spec.get("min_interval", 0)),
                    "max_interval": float(spec.get("max_interval", 0)),
                    "min_amount": int(spec.get("min_amount", 1)),
                    "max_amount": int(spec.get("max_amount", 1)),
                    "special_instructions": special,
                    "remarks": "",
                }
            )
            self._next_shipment_id += 1

    def apply_config_location_overrides(self) -> None:
        """Apply locations exported from the live DB via sync_hart_seed_config.py."""
        overrides = self.config.get("locations")
        if not overrides:
            return
        by_code = {row["code"]: row for row in self.location_rows}
        for spec in overrides:
            code = spec["code"]
            station = int(spec.get("station", spec.get("station_id", 0)))
            track = spec.get("track", "")
            spot = spec.get("spot", "")
            rpt_station = spec.get("rpt_station", "")
            remarks = spec.get("remarks", "")
            color = spec.get("color", "")
            if code in by_code:
                row = by_code[code]
                row["station"] = station
                row["track"] = track
                row["spot"] = spot
                row["rpt_station"] = normalize_rpt_station(rpt_station)
                row["remarks"] = remarks
                if color:
                    row["color"] = color
                continue
            loc_id = int(spec["id"]) if spec.get("id") is not None else self._next_location_id
            if loc_id >= self._next_location_id:
                self._next_location_id = loc_id + 1
            if not color:
                color = fixed_location_color(code)
            if not color:
                color = offline_station_color(station, self.config)
            self.location_code_to_id[code] = loc_id
            self.location_rows.append(
                {
                    "id": loc_id,
                    "code": code,
                    "station": station,
                    "track": track,
                    "spot": spot,
                    "rpt_station": normalize_rpt_station(rpt_station),
                    "remarks": remarks,
                    "color": color,
                }
            )
            by_code[code] = self.location_rows[-1]

    def apply_config_shipment_overrides(self) -> None:
        """Apply shipments exported from the live DB via sync_hart_seed_config.py."""
        overrides = self.config.get("shipments")
        if not overrides:
            return
        by_code = {row["code"]: row for row in self.shipment_rows}

        def shipment_from_spec(spec: dict) -> dict:
            commodity_key = spec.get("commodity", "")
            consignment_id = spec.get("consignment_id")
            if consignment_id is not None:
                consignment_id = int(consignment_id)
            else:
                consignment_id = self.commodity_code_to_id.get(commodity_key)
            if consignment_id is None:
                raise ValueError(
                    f"Shipment {spec['code']!r}: unknown commodity {commodity_key!r}"
                )
            loading_code = normalize_interchange_location_code(spec["loading_location"])
            unloading_code = normalize_interchange_location_code(
                spec["unloading_location"]
            )
            car_code = spec.get("car_code", "XM")
            car_code_id = self.ensure_car_code(car_code)
            row = {
                "code": spec["code"],
                "description": spec.get("description", ""),
                "consignment": consignment_id,
                "car_code": car_code_id,
                "loading_location": self.location_code_to_id[loading_code],
                "unloading_location": self.location_code_to_id[unloading_code],
                "last_ship_date": 0,
                "min_interval": float(spec.get("min_interval", 0)),
                "max_interval": float(spec.get("max_interval", 0)),
                "min_amount": int(spec.get("min_amount", 1)),
                "max_amount": int(spec.get("max_amount", 1)),
                "special_instructions": spec.get("special_instructions", ""),
                "remarks": spec.get("remarks", ""),
            }
            if spec.get("id") is not None:
                row["id"] = int(spec["id"])
            return row

        for spec in overrides:
            code = spec["code"]
            if code in by_code:
                updated = shipment_from_spec(spec)
                existing = by_code[code]
                existing.update(updated)
                if "id" in updated:
                    existing["id"] = updated["id"]
                continue
            row = shipment_from_spec(spec)
            row["id"] = row.get("id", self._next_shipment_id)
            self._next_shipment_id = max(self._next_shipment_id, row["id"] + 1)
            self.shipment_rows.append(row)
            by_code[code] = row

    def car_code_for_id(self, car_code_id: int) -> str:
        for row in self.car_code_rows:
            if row["id"] == car_code_id:
                return row["code"]
        return "XM"

    def car_length_ft(self, car: dict) -> int | None:
        match = re.search(r"(\d+)ft", car.get("remarks", ""))
        return int(match.group(1)) if match else None

    def is_coke_fleet_car(self, car: dict) -> bool:
        return car.get("reporting_marks", "") in self.coke_fleet_marks

    def is_unit_train_hopper(self, code: str, car: dict) -> bool:
        """Designated coke-fleet open hoppers home at Shenango Coke Works."""
        if car and self.is_coke_fleet_car(car):
            return True
        return False

    def _location_row(self, location_id: int) -> dict | None:
        for row in self.location_rows:
            if row["id"] == location_id:
                return row
        return None

    def shipment_endpoint_demand_role(self, location_id: int) -> str | None:
        """Classify a shipment endpoint for home-yard fleet demand."""
        loc = self._location_row(location_id)
        if not loc:
            return None
        island_station = int(self.config.get("island_local_station", 3))
        if loc.get("station") == island_station:
            return "island"
        if loc.get("code") == "SOUTH-SCALE":
            return "weigh"
        pohc_yard = self.config["car_home_yard"]["pohc_yard_code"]
        csx_yard = self.config["car_home_yard"]["csx_yard_code"]
        scully_id = self.location_code_to_id[pohc_yard]
        demmler_id = self.location_code_to_id[csx_yard]
        yard_id = self.interchange_yard_for_location_id(location_id)
        if yard_id == scully_id:
            return "scully"
        if yard_id == demmler_id:
            return "demmler"
        return None

    def build_home_yard_demand_from_shipments(
        self,
    ) -> dict[str, dict[str, float]]:
        """Per car-code demand for South Yard (island + scale), Scully, and Demmler."""
        weigh_weight = float(
            self.config.get("car_home_yard", {}).get("scale_weigh_demand_weight", 0.5)
        )
        demand: dict[str, dict[str, float]] = {}

        for shipment in self.shipment_rows:
            code = self.car_code_for_id(shipment["car_code"])
            bucket = demand.setdefault(
                code,
                {"island": 0.0, "weigh": 0.0, "scully": 0.0, "demmler": 0.0},
            )
            for loc_id in (
                shipment["loading_location"],
                shipment["unloading_location"],
            ):
                role = self.shipment_endpoint_demand_role(loc_id)
                if role == "island":
                    bucket["island"] += 1
                elif role == "weigh":
                    bucket["weigh"] += weigh_weight
                elif role == "scully":
                    bucket["scully"] += 1
                elif role == "demmler":
                    bucket["demmler"] += 1
        return demand

    def home_yard_targets(
        self,
        demand: dict[str, dict[str, float]],
        interchange_counts: dict[str, int],
    ) -> dict[str, dict[int, int]]:
        home = self.config["car_home_yard"]
        scully_id = self.location_code_to_id[home["pohc_yard_code"]]
        demmler_id = self.location_code_to_id[home["csx_yard_code"]]
        south_id = self.location_code_to_id[
            home.get("south_yard_code", "SOUTH-YARD")
        ]
        targets: dict[str, dict[int, int]] = {}

        for code, count in interchange_counts.items():
            if count <= 0:
                continue
            code_demand = demand.get(code, {})
            south_need = code_demand.get("island", 0) + code_demand.get("weigh", 0)
            scully_need = code_demand.get("scully", 0)
            demmler_need = code_demand.get("demmler", 0)
            total_need = south_need + scully_need + demmler_need
            if total_need == 0:
                south_target = count // 3
                remainder = count - south_target
                scully_target = remainder // 2
                demmler_target = remainder - scully_target
            else:
                south_target = round(count * south_need / total_need)
                south_target = min(max(south_target, 0), count)
                remainder = count - south_target
                interchange_need = scully_need + demmler_need
                if interchange_need == 0:
                    scully_target = remainder // 2
                else:
                    scully_target = round(remainder * scully_need / interchange_need)
                scully_target = min(max(scully_target, 0), remainder)
                demmler_target = remainder - scully_target
            targets[code] = {
                south_id: south_target,
                scully_id: scully_target,
                demmler_id: demmler_target,
            }
        return targets

    def pick_home_yard_for_car_code(
        self,
        code: str,
        targets: dict[str, dict[int, int]],
        assigned: dict[str, dict[int, int]],
    ) -> int:
        code_targets = targets.get(code, {})
        code_assigned = assigned.setdefault(code, {})
        ranked: list[tuple[int, int, int]] = []
        for yard_id, target in code_targets.items():
            have = code_assigned.get(yard_id, 0)
            ranked.append((target - have, -have, yard_id))
        if not ranked:
            pohc_yard = self.config["car_home_yard"]["pohc_yard_code"]
            return self.location_code_to_id[pohc_yard]
        ranked.sort(reverse=True)
        yard_id = ranked[0][2]
        code_assigned[yard_id] = code_assigned.get(yard_id, 0) + 1
        return yard_id

    def assign_car_home_yards(self) -> None:
        pohc_yard = self.config["car_home_yard"]["pohc_yard_code"]
        csx_yard = self.config["car_home_yard"]["csx_yard_code"]
        scully_id = self.location_code_to_id[pohc_yard]
        demmler_id = self.location_code_to_id[csx_yard]
        coke_plant_code = self.config["car_home_yard"].get(
            "coke_plant_yard_code", "SHEN-COKE-SHIPPING"
        )
        coke_plant_id = self.location_code_to_id[coke_plant_code]
        demand = self.build_home_yard_demand_from_shipments()

        interchange_cars: dict[str, list[dict]] = {}
        for car in self.car_rows:
            if car["id"] not in self.freight_car_ids:
                continue
            code = self.car_code_for_id(car["car_code_id"])
            if self.is_unit_train_hopper(code, car):
                car["current_location_id"] = coke_plant_id
                car["home_location"] = coke_plant_id
                continue
            interchange_cars.setdefault(code, []).append(car)

        targets = self.home_yard_targets(
            demand, {code: len(cars) for code, cars in interchange_cars.items()}
        )
        assigned: dict[str, dict[int, int]] = {}

        for code, cars in interchange_cars.items():
            for car in cars:
                yard_id = self.pick_home_yard_for_car_code(code, targets, assigned)
                car["current_location_id"] = yard_id
                car["home_location"] = yard_id

    def assign_coke_fleet_pools(self) -> None:
        """Link Shenango coke hoppers to all coke shipment orders."""
        coke_codes = {spec["code"] for spec in self.config.get("coke_shipments", [])}
        shipment_ids = [
            row["id"] for row in self.shipment_rows if row["code"] in coke_codes
        ]
        hk_marks = frozenset(
            self.config.get("open_hopper_hk_marks")
            or self.config.get("coke_fleet_hk_marks", [])
        )
        for car in self.car_rows:
            marks = car.get("reporting_marks", "")
            if marks not in self.coke_fleet_marks:
                continue
            if marks in hk_marks:
                continue
            if marks in self.unavailable_marks:
                continue
            for shipment_id in shipment_ids:
                self.pool_rows.append(
                    {"car_id": car["id"], "shipment_id": shipment_id}
                )

    def place_track_scale_demo_cars(self) -> None:
        """Stage the scale test car (COST1) at South Yard Scale for calibrate demos.

        Sets both current_location_id and home_location so STS Reset Simulation
        (reset.php) leaves the test car at the scale instead of sending it home.
        """
        demo = self.config.get("track_scale_demo", {})
        marks = demo.get("cars_at_scale", [])
        if not marks:
            return
        scale_id = self.location_code_to_id.get("SOUTH-SCALE")
        if scale_id is None:
            return
        marks_set = frozenset(marks)
        for car in self.car_rows:
            if car.get("reporting_marks", "") in marks_set:
                car["current_location_id"] = scale_id
                car["home_location"] = scale_id

    def apply_unavailable_car_status(self) -> None:
        """Keep roster cars in the fleet but exclude them from fill orders / pool."""
        for car in self.car_rows:
            if car.get("reporting_marks", "") in self.unavailable_marks:
                car["status"] = "Unavailable"

    def add_cars(
        self,
        roster_xml: Path,
        metadata_csv: Path,
        final_images_dir: Path,
    ) -> None:
        home_yard = self.config["car_home_yard"]
        scully_id = self.location_code_to_id[home_yard["pohc_yard_code"]]
        demmler_id = self.location_code_to_id[home_yard["csx_yard_code"]]

        image_roster_ids = roster_ids_with_final_images(
            metadata_csv, final_images_dir, roster_xml
        )

        covered_hopper_prefixes = load_covered_hopper_prefixes(
            metadata_csv, roster_xml, self.config
        )
        roster_metadata = load_roster_metadata(metadata_csv, roster_xml)

        root = ET.parse(roster_xml).getroot()
        for car in root.findall("cars/car"):
            car_type = car.get("type", "")
            if car_type in PASSENGER_TYPES:
                continue
            roster_id = car.get("id", "")
            if roster_id not in image_roster_ids:
                # Preserve STS car IDs for synced RollingStock/{id}.jpg files.
                self._next_car_id += 1
                continue
            road = car.get("roadName", "")
            number = car.get("roadNumber", "")
            marks = f"{road}{number}"
            length = car.get("length", "")
            meta = roster_metadata.get(roster_id, {})
            covered_prefix = covered_hopper_prefix_for(
                roster_id, covered_hopper_prefixes, meta, self.config
            )
            code = aar_code_for_roster_car(
                car_type,
                length,
                covered_hopper_prefix=covered_prefix,
                roster_meta=meta,
                roster_id=roster_id,
                config=self.config,
            )
            if not code:
                self._next_car_id += 1
                continue
            car_code_id = self.ensure_car_code(code)
            self.fleet_code_counts[code] = self.fleet_code_counts.get(code, 0) + 1
            self.freight_car_ids.add(self._next_car_id)
            self.car_rows.append(
                {
                    "id": self._next_car_id,
                    "reporting_marks": marks,
                    "car_code_id": car_code_id,
                    "current_location_id": scully_id,
                    "position": None,
                    "status": "Empty",
                    "handled_by_job_id": None,
                    "remarks": f"{car_type} {length}ft" if length else car_type,
                    "load_count": 0,
                    "home_location": scully_id,
                    "RFID_code": None,
                }
            )
            self._next_car_id += 1

    def add_mow_equipment(
        self,
        roster_xml: Path,
        metadata_csv: Path,
        final_images_dir: Path,
    ) -> None:
        """Append MOW cars that have photos, using fixed car IDs (do not renumber freight fleet)."""
        entries = self.config.get("mow_equipment", [])
        if not entries:
            return

        csx_yard = self.config["car_home_yard"]["csx_yard_code"]
        demmler_id = self.location_code_to_id[csx_yard]
        image_roster_ids = roster_ids_with_final_images(
            metadata_csv, final_images_dir, roster_xml
        )

        root = ET.parse(roster_xml).getroot()
        roster_cars = {
            car.get("id", ""): car
            for car in root.findall("cars/car")
            if car.get("type") == "MOW"
        }

        for entry in entries:
            roster_id = entry["roster_id"]
            if roster_id not in image_roster_ids:
                continue
            car = roster_cars.get(roster_id)
            if car is None:
                continue

            car_id = int(entry["car_id"])
            length = car.get("length", "")
            aar_code = entry.get("aar_code")
            if not aar_code:
                if "crane" in entry.get("description", "").lower():
                    aar_code = "WC"
                else:
                    aar_code = "WF"
            aar_code = aar_code_prefix(aar_code)

            marks = f"{car.get('roadName', '')}{car.get('roadNumber', '')}"
            label = entry.get("description") or f"MOW {length}ft".strip()
            car_code_id = self.ensure_car_code(aar_code)
            self.fleet_code_counts[aar_code] = self.fleet_code_counts.get(aar_code, 0) + 1
            self.car_rows.append(
                {
                    "id": car_id,
                    "reporting_marks": marks,
                    "car_code_id": car_code_id,
                    "current_location_id": demmler_id,
                    "position": None,
                    "status": "Empty",
                    "handled_by_job_id": None,
                    "remarks": label,
                    "load_count": 0,
                    "home_location": demmler_id,
                    "RFID_code": None,
                }
            )
            self._next_car_id = max(self._next_car_id, car_id + 1)

        self.car_rows.sort(key=lambda row: row["id"])

    def add_jobs(self) -> None:
        for job in self.config.get("jobs", []):
            self.job_rows.append(
                {
                    "id": job["id"],
                    "name": job["name"],
                    "description": job.get("description", ""),
                    "steps": job.get("steps", []),
                }
            )

    def build_default_pickup_criteria(self) -> list[dict]:
        """Pickup criteria for Auto-Assign: one dest_station per row (STS demo pattern)."""
        south_yard = 8
        scully = 9
        demmler = 10
        north_yard = 11
        east_yard = 13
        offline = self.config.get("offline_stations", {})
        demmler_offline = int(offline.get("csx_offline_station_id", 14))
        scully_offline = int(offline.get("pohc_offline_station_id", 15))
        shenango = int(self.config.get("shenango_coke", {}).get("station_id", 12))
        island = int(self.config["island_local_station"])
        rows: list[dict] = []

        def add(job: str, step: int, dest: int, car_status: str = "") -> None:
            rows.append(
                {
                    "job": job,
                    "step_nbr": step,
                    "car_status": car_status,
                    "commodity_id": None,
                    "car_code_id": None,
                    "dest_station_id": dest,
                }
            )

        # D749 — Demmler pick-ups by destination
        add("D749", 10, scully)
        add("D749", 20, island)
        add("D749", 30, demmler)
        add("D749", 40, demmler)

        # NVL — Scully pick-ups by destination
        add("NVL", 10, island)
        add("NVL", 20, demmler)
        add("NVL", 30, scully)
        add("NVL", 40, island)
        for dest in (island, scully, demmler):
            add("NVL", 50, dest)
        add("NVL", 60, scully)

        # CK1 — coke moves (dest only; Shenango setout is step 60, no pickup criteria)
        add("CK1", 10, south_yard)
        add("CK1", 20, demmler)
        add("CK1", 30, scully)
        add("CK1", 40, north_yard)

        # STG-SCULLY — Scully yard shuffle to Scully Offline, then block staging
        add("STG-SCULLY", 10, scully_offline)
        add("STG-SCULLY", 12, scully_offline)
        add("STG-SCULLY", 20, scully)
        add("STG-SCULLY", 30, shenango)
        add("STG-SCULLY", 40, island)
        add("STG-SCULLY", 45, demmler_offline)
        add("STG-SCULLY", 50, demmler)
        add("STG-SCULLY", 60, scully)

        # STG-DEMMLER — Demmler yard shuffle to Demmler Offline, then block staging
        add("STG-DEMMLER", 10, demmler_offline)
        add("STG-DEMMLER", 12, demmler_offline)
        add("STG-DEMMLER", 20, scully)
        add("STG-DEMMLER", 30, shenango)
        add("STG-DEMMLER", 40, island)
        add("STG-DEMMLER", 45, scully_offline)
        add("STG-DEMMLER", 50, demmler)
        add("STG-DEMMLER", 60, demmler)

        return rows

    def add_pickup_criteria(self) -> None:
        configured = self.config.get("pickup_criteria")
        if configured:
            self.pu_criteria_rows = configured
            return
        self.pu_criteria_rows = self.build_default_pickup_criteria()

    def add_club_ops(self) -> None:
        """Populate owners and per-car ownership for STS Club Ops."""
        club_ops = self.config.get("club_ops", {})
        owners = club_ops.get("owners", [])
        if not owners:
            return

        self.owner_rows = [
            {
                "id": int(owner["id"]),
                "name": owner.get("name", ""),
                "remarks": owner.get("remarks", ""),
            }
            for owner in owners
        ]
        default_owner_id = int(
            club_ops.get("default_owner_id", self.owner_rows[0]["id"])
        )
        default_on_off_rr = club_ops.get("default_on_off_rr", "on")

        self.ownership_rows = []
        for car in self.car_rows:
            on_off_rr = default_on_off_rr
            if car.get("status") == "Unavailable":
                on_off_rr = "Unavailable"
            self.ownership_rows.append(
                {
                    "car_id": car["id"],
                    "owner_id": default_owner_id,
                    "on_off_rr": on_off_rr,
                }
            )

    def render_backup(self) -> str:
        lines: list[str] = [
            "-- HART layout STS backup",
            "-- Generated by generate_hart_seed.py — restore via STS Database Maintenance",
            "",
        ]
        cfg = self.config

        job_names = sorted(row["name"] for row in self.job_rows)
        table_order = job_names + STATIC_BACKUP_TABLES

        for table in table_order:
            if table in job_names:
                job = next(row for row in self.job_rows if row["name"] == table)
                create_ddl = table_ddl(table)
                rows = []
                for step in job.get("steps", []):
                    rows.append(
                        [
                            step["step_number"],
                            step["station"],
                            "T" if step.get("pickup") else "F",
                            "T" if step.get("setout") else "F",
                            step.get("remarks", ""),
                        ]
                    )
                emit_backup_table(lines, table, create_ddl, rows, job_route=True)
                continue

            if table == "blocks":
                emit_backup_table(lines, table, table_ddl("blocks"), [])
            elif table == "car_codes":
                rows = [
                    [row["id"], row["code"], row["description"], ""]
                    for row in sorted(self.car_code_rows, key=lambda row: row["code"])
                ]
                next_id = max((row["id"] for row in self.car_code_rows), default=0) + 1
                emit_backup_table(
                    lines,
                    table,
                    table_ddl("car_codes", next_id),
                    rows,
                )
            elif table == "car_orders":
                emit_backup_table(lines, table, table_ddl("car_orders"), [])
            elif table == "cars":
                rows = []
                for row in self.car_rows:
                    rows.append(
                        [
                            row["id"],
                            row["reporting_marks"],
                            row["car_code_id"],
                            row["current_location_id"],
                            row["position"] if row["position"] is not None else "",
                            row["status"],
                            row["handled_by_job_id"] if row["handled_by_job_id"] is not None else 0,
                            row["remarks"],
                            row["load_count"],
                            row["home_location"] if row["home_location"] is not None else "",
                            row["RFID_code"] if row["RFID_code"] is not None else "",
                            "",
                            0,
                        ]
                    )
                next_id = max((row["id"] for row in self.car_rows), default=0) + 1
                emit_backup_table(
                    lines,
                    table,
                    table_ddl("cars", next_id),
                    rows,
                )
            elif table == "commodities":
                rows = [
                    [row["id"], row["code"], row["description"], row["remarks"]]
                    for row in self.commodity_rows
                ]
                next_id = self._next_commodity_id
                emit_backup_table(
                    lines,
                    table,
                    table_ddl("commodities", next_id),
                    rows,
                )
            elif table == "empty_locations":
                rows = [
                    [row["shipment"], row["priority"], row["location"]]
                    for row in self.empty_location_rows
                ]
                emit_backup_table(lines, table, table_ddl("empty_locations"), rows)
            elif table == "history":
                emit_backup_table(lines, table, table_ddl("history"), [])
            elif table == "jobs":
                rows = [
                    [row["id"], row["name"], row["description"]]
                    for row in self.job_rows
                ]
                next_id = max((row["id"] for row in self.job_rows), default=0) + 1
                emit_backup_table(
                    lines,
                    table,
                    table_ddl("jobs", next_id),
                    rows,
                )
            elif table == "locations":
                rows = [
                    [
                        row["id"],
                        row["code"],
                        row["station"],
                        row["track"],
                        row["spot"],
                        row["rpt_station"],
                        row["remarks"],
                        row["color"],
                    ]
                    for row in self.location_rows
                ]
                emit_backup_table(
                    lines,
                    table,
                    table_ddl("locations", self._next_location_id),
                    rows,
                )
            elif table == "owners":
                rows = [
                    [row["id"], row["name"], row.get("remarks", "")]
                    for row in self.owner_rows
                ]
                next_id = max((row["id"] for row in self.owner_rows), default=0) + 1
                emit_backup_table(
                    lines,
                    table,
                    table_ddl("owners", next_id),
                    rows,
                )
            elif table == "ownership":
                rows = [
                    [row["car_id"], row["owner_id"], row["on_off_rr"]]
                    for row in self.ownership_rows
                ]
                emit_backup_table(lines, table, table_ddl("ownership"), rows)
            elif table == "pool":
                rows = [
                    [row["car_id"], row["shipment_id"]] for row in self.pool_rows
                ]
                emit_backup_table(lines, table, table_ddl("pool"), rows)
            elif table == "pu_criteria":
                rows = []
                for index, row in enumerate(self.pu_criteria_rows, start=1):
                    rows.append(
                        [
                            index,
                            row["job"],
                            row["step_nbr"],
                            row.get("car_status", ""),
                            row.get("commodity_id") if row.get("commodity_id") is not None else "",
                            row.get("car_code_id") if row.get("car_code_id") is not None else "",
                            row["dest_station_id"],
                        ]
                    )
                next_id = len(self.pu_criteria_rows) + 1
                emit_backup_table(
                    lines,
                    table,
                    table_ddl("pu_criteria", next_id),
                    rows,
                )
            elif table == "routing":
                rows = [
                    [
                        row["id"],
                        row["station"],
                        row["station_nbr"] if row["station_nbr"] is not None else "",
                        row["instructions"],
                        row["sort_seq"],
                        row["color1"],
                        row["color2"],
                    ]
                    for row in self.routing_rows
                ]
                next_id = max((row["id"] for row in self.routing_rows), default=0) + 1
                emit_backup_table(
                    lines,
                    table,
                    table_ddl("routing", next_id),
                    rows,
                )
            elif table == "settings":
                rows = [
                    ["max_history", "Max History Entries Per Car", "24"],
                    ["print_width", "Print Width", "7.5in"],
                    ["railroad_initials", "Initials of the railroad", cfg["railroad_initials"]],
                    ["railroad_name", "Name of the railroad", cfg["railroad_name"]],
                    ["session_nbr", "Session Number", "0"],
                ]
                emit_backup_table(lines, table, table_ddl("settings"), rows)
            elif table == "shipments":
                rows = []
                for row in self.shipment_rows:
                    rows.append(
                        [
                            row["id"],
                            row["code"],
                            row["description"],
                            row["consignment"] if row["consignment"] is not None else "",
                            row["car_code"],
                            row["loading_location"],
                            row["unloading_location"],
                            row["last_ship_date"],
                            row["min_interval"],
                            row["max_interval"],
                            row["min_amount"],
                            row["max_amount"],
                            row["special_instructions"],
                            row["remarks"],
                            "",
                            "",
                            "",
                            "",
                        ]
                    )
                emit_backup_table(
                    lines,
                    table,
                    table_ddl("shipments", self._next_shipment_id),
                    rows,
                )

        lines.append(f"-- routing: {len(self.routing_rows)}")
        lines.append(f"-- locations: {len(self.location_rows)}")
        lines.append(f"-- commodities: {len(self.commodity_rows)}")
        lines.append(f"-- car_codes: {len(self.car_code_rows)}")
        lines.append(f"-- shipments: {len(self.shipment_rows)}")
        lines.append(f"-- cars: {len(self.car_rows)}")
        lines.append(f"-- jobs: {len(self.job_rows)}")
        lines.append(f"-- pu_criteria: {len(self.pu_criteria_rows)}")
        lines.append(f"-- empty_locations: {len(self.empty_location_rows)}")
        lines.append(f"-- pool: {len(self.pool_rows)}")
        lines.append(f"-- owners: {len(self.owner_rows)}")
        lines.append(f"-- ownership: {len(self.ownership_rows)}")
        lines.append("")
        return "\n".join(lines)


def read_waybills(path: Path) -> list[dict]:
    with path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def main() -> None:
    global MRR_DESCRIPTIONS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hart-dir", type=Path, default=DEFAULT_HART_DIR)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--mrr-csv", type=Path, default=DEFAULT_MRR_CSV)
    args = parser.parse_args()

    MRR_DESCRIPTIONS = load_mrr_aar_descriptions(args.mrr_csv)

    hart_dir = args.hart_dir
    config = load_config(args.config)
    industry_colors = load_industry_location_colors(hart_dir)
    builder = SeedBuilder(config, industry_colors=industry_colors)
    builder.load_shipping_proposals(
        DEFAULT_SCULLY_MAP, DEFAULT_SHIPMENT_RENAMES, DEFAULT_IX_MAP
    )

    builder.add_routing()
    builder.add_yard_locations()
    builder.add_interchange_staging_locations()
    builder.ingest_spots(hart_dir / "spot_assignments.csv")
    builder.apply_default_setout_locations()
    builder.apply_config_location_overrides()

    waybills = read_waybills(hart_dir / "HART_Spot_Waybills.csv")
    builder.add_commodities_from_waybills(waybills)
    builder.add_cars(
        hart_dir / "HART_MergedCarRoster.xml",
        hart_dir / "image_metadata.csv",
        hart_dir / "CarImagesFinal",
    )
    builder.add_mow_equipment(
        hart_dir / "HART_MergedCarRoster.xml",
        hart_dir / "image_metadata.csv",
        hart_dir / "CarImagesFinal",
    )
    builder.add_shipments(waybills)
    builder.add_coke_shipments()
    builder.apply_config_shipment_overrides()
    builder.assign_car_home_yards()
    builder.apply_unavailable_car_status()
    yard_summary = builder.balance_interchange_shipment_intervals()
    builder.assign_coke_fleet_pools()
    builder.place_track_scale_demo_cars()
    builder.add_jobs()
    builder.add_pickup_criteria()
    builder.add_club_ops()

    sql = builder.render_backup()
    if len(builder.car_rows) == 0:
        print(
            "ERROR: generate_hart_seed produced 0 cars. "
            "Ensure CarImagesFinal exists (project root or --hart-dir) "
            "or run tools/merge_car_fleet_from_backup.py after generation.",
            file=sys.stderr,
        )
        sys.exit(1)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(sql, encoding="utf-8")
    print(f"Wrote {args.output}")
    print(
        f"  routing={len(builder.routing_rows)} locations={len(builder.location_rows)} "
        f"commodities={len(builder.commodity_rows)} car_codes={len(builder.car_code_rows)} "
        f"shipments={len(builder.shipment_rows)} "
        f"cars={len(builder.car_rows)} "
        f"jobs={len(builder.job_rows)} "
        f"pu_criteria={len(builder.pu_criteria_rows)} "
        f"empty_locations={len(builder.empty_location_rows)} "
        f"pool={len(builder.pool_rows)}"
    )
    if yard_summary.get("enabled"):
        print(
            f"  yard_balance: target={yard_summary.get('target_loads_per_car_10sess')} "
            f"adjustments={yard_summary.get('adjustments')}"
        )


if __name__ == "__main__":
    main()
