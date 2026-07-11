#!/usr/bin/env python3
"""Copy car fleet tables from an STS backup into a generated hart_seed.

Preserves all non-fleet sections of the seed (routing, locations, shipments,
jobs, pu_criteria, settings, etc.) while replacing car_codes, cars, pool,
owners, and ownership from a known-good backup such as session10.

Cars are normalized to fresh-seed baseline: Empty at home yard (Unavailable
cars are kept as-is). Scully/Demmler home locations (ids 7/8) remap to South Yard (4).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
HELPERS_ROOT = TOOLS_DIR.parent
CARDS_ROOT = HELPERS_ROOT.parent

FLEET_TABLES = ("car_codes", "cars", "pool", "owners", "ownership")

DROP_RE = re.compile(
    r"drop\s+table\s+(?:if\s+exists\s+)?[`'\"]?(\w+)[`'\"]?",
    re.IGNORECASE,
)
INSERT_RE = re.compile(
    r"insert\s+into\s+[`'\"]?(\w+)[`'\"]?\s+values\s*\((.*)\)\s*;?",
    re.IGNORECASE | re.DOTALL,
)
SOUTH_YARD_LOC_ID = "4"
INTERCHANGE_HOME_LOC_IDS = frozenset({"7", "8"})  # SCULLY-YARD, DEMMLER-YARD

CAR_INSERT_RE = re.compile(
    r'insert\s+into\s+`cars`\s+values\("(\d+)","([^"]*)","(\d+)","([^"]*)","([^"]*)","([^"]*)","([^"]*)","([^"]*)","(\d+)","([^"]*)","([^"]*)","([^"]*)","(\d+)"\)\s*;?',
    re.IGNORECASE,
)


def default_fleet_backup() -> Path:
    for candidate in (
        CARDS_ROOT / "sts-backups" / "session10",
        Path.home() / "sts" / "sts-backups" / "session10",
        HELPERS_ROOT / "backups" / "session10",
    ):
        if candidate.is_file():
            return candidate
    return CARDS_ROOT / "sts-backups" / "session10"


def default_seed_sql() -> Path:
    for candidate in (
        CARDS_ROOT / "sts-backups" / "hart_seed",
        Path.home() / "sts" / "sts-backups" / "hart_seed",
        HELPERS_ROOT / "backups" / "hart_seed",
    ):
        if candidate.is_file():
            return candidate
    return CARDS_ROOT / "sts-backups" / "hart_seed"


def split_backup(text: str) -> list[str]:
    return [part.strip() for part in text.split("#") if part.strip()]


def table_for_chunk(chunk: str) -> str | None:
    match = DROP_RE.search(chunk)
    if match:
        return match.group(1)
    match = re.search(r"CREATE\s+TABLE\s+[`'\"]?(\w+)[`'\"]?", chunk, re.IGNORECASE)
    if match:
        return match.group(1)
    match = INSERT_RE.search(chunk)
    if match:
        return match.group(1)
    return None


def extract_table_blocks(text: str) -> dict[str, list[str]]:
    blocks: dict[str, list[str]] = {}
    current_table: str | None = None
    current_chunks: list[str] = []

    for chunk in split_backup(text):
        table = table_for_chunk(chunk)
        if table and DROP_RE.search(chunk):
            if current_table and current_chunks:
                blocks[current_table] = current_chunks
            current_table = table
            current_chunks = [chunk]
            continue
        if current_table:
            current_chunks.append(chunk)

    if current_table and current_chunks:
        blocks[current_table] = current_chunks

    return blocks


def render_table_block(table: str, chunks: list[str]) -> str:
    lines: list[str] = [f"drop table if exists `{table}`;", "#"]
    for chunk in chunks[1:]:
        lines.append(chunk)
        lines.append("#")
    lines.append("")
    lines.append("#")
    return "\n".join(lines)


def quote_sql(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def normalize_car_insert(chunk: str) -> str:
    match = CAR_INSERT_RE.search(chunk)
    if not match:
        return chunk

    (
        car_id,
        marks,
        car_code_id,
        _current_loc,
        _position,
        status,
        _handled_by,
        remarks,
        _load_count,
        home_loc,
        rfid,
        _block_id,
        _last_spotted,
    ) = match.groups()

    if status == "Unavailable":
        return chunk

    if home_loc in INTERCHANGE_HOME_LOC_IDS:
        home = SOUTH_YARD_LOC_ID
    elif home_loc:
        home = home_loc
    else:
        home = SOUTH_YARD_LOC_ID
    return (
        "insert into `cars` values("
        f"{quote_sql(car_id)},"
        f"{quote_sql(marks)},"
        f"{quote_sql(car_code_id)},"
        f"{quote_sql(home)},"
        '"" ,'
        '"Empty",'
        '"0",'
        f"{quote_sql(remarks)},"
        '"0",'
        f"{quote_sql(home)},"
        f"{quote_sql(rfid)},"
        '"",'
        '"0"'
        ");"
    )


def normalize_car_chunks(chunks: list[str]) -> list[str]:
    normalized: list[str] = []
    for chunk in chunks:
        if INSERT_RE.search(chunk) and "cars" in chunk.lower():
            normalized.append(normalize_car_insert(chunk))
        else:
            normalized.append(chunk)
    return normalized


def count_inserts(text: str, table: str) -> int:
    return len(
        re.findall(rf"insert\s+into\s+`{table}`", text, flags=re.IGNORECASE)
    )


def count_car_inserts(text: str) -> int:
    return count_inserts(text, "cars")


def update_summary_counts(text: str, counts: dict[str, int]) -> str:
    lines = text.splitlines()
    for key, value in counts.items():
        pattern = re.compile(rf"^-- {re.escape(key)}:\s+\d+")
        replacement = f"-- {key}: {value}"
        for index, line in enumerate(lines):
            if pattern.match(line):
                lines[index] = replacement
                break
        else:
            lines.append(replacement)
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def table_section_pattern(table: str) -> re.Pattern[str]:
    return re.compile(
        rf"drop\s+table(?:\s+if\s+exists)?\s+`{re.escape(table)}`\s*;\s*#.*?"
        rf"(?=\ndrop\s+table|\Z|-- routing:)",
        re.DOTALL | re.IGNORECASE,
    )


def replace_table_section(sql: str, table: str, replacement: str) -> str:
    pattern = table_section_pattern(table)
    if not pattern.search(sql):
        raise SystemExit(f"Seed SQL is missing table section: {table}")
    return pattern.sub(replacement.rstrip() + "\n", sql, count=1)


def merge_fleet_into_seed(seed_text: str, fleet_text: str) -> tuple[str, dict[str, int]]:
    fleet_blocks = extract_table_blocks(fleet_text)
    merged = seed_text
    merged_counts: dict[str, int] = {}

    for table in FLEET_TABLES:
        if table not in fleet_blocks:
            continue
        chunks = fleet_blocks[table]
        if table == "cars":
            chunks = normalize_car_chunks(chunks)
        replacement = render_table_block(table, chunks)
        merged = replace_table_section(merged, table, replacement)
        merged_counts[table] = count_inserts(replacement, table)

    if merged_counts.get("cars", 0) == 0:
        raise SystemExit("Fleet backup contains no car rows.")

    merged = update_summary_counts(merged, merged_counts)
    return merged, merged_counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--seed",
        type=Path,
        default=default_seed_sql(),
        help="Generated hart_seed SQL (layout tables preserved)",
    )
    parser.add_argument(
        "--fleet-backup",
        type=Path,
        default=default_fleet_backup(),
        help="STS backup with a known-good car fleet (default: sts-backups/session10)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output path (default: overwrite --seed)",
    )
    args = parser.parse_args()

    if not args.seed.is_file():
        raise SystemExit(f"Seed SQL not found: {args.seed}")
    if not args.fleet_backup.is_file():
        raise SystemExit(f"Fleet backup not found: {args.fleet_backup}")

    seed_text = args.seed.read_text(encoding="utf-8")
    fleet_text = args.fleet_backup.read_text(encoding="utf-8")

    merged, counts = merge_fleet_into_seed(seed_text, fleet_text)
    output = args.output or args.seed
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(merged, encoding="utf-8")

    print(f"Wrote {output}")
    print(
        "  fleet from "
        f"{args.fleet_backup.name}: "
        f"cars={counts.get('cars', 0)} "
        f"car_codes={counts.get('car_codes', 0)} "
        f"pool={counts.get('pool', 0)}"
    )
    if count_car_inserts(merged) == 0:
        print("ERROR: merged seed still has 0 cars", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
