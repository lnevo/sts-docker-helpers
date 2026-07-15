#!/usr/bin/env python3
"""Rewrite STS backup SQL so job-route tables restore safely on Mac MariaDB.

Mac Docker MariaDB uses lower_case_table_names=2. Stock STS backups emit:

  drop table `CK1`;
  CREATE TABLE `CK1` (...);

After a wipe/drop that can leave a ghost name and the next restore fails with
"Table 'ck1' already exists" (usually on CREATE or rename).

HART-safe pattern (same as generate_hart_seed.py):

  drop table if exists `CK1__sts_restore`;
  CREATE TABLE `CK1__sts_restore` (...);
  drop table if exists `CK1`;
  rename table `CK1__sts_restore` to `CK1`;

Also normalizes bare `drop table` to `drop table if exists` for other tables.

Usage:
  python3 sanitize_sts_backup_sql.py sts-backups/hart_session2_locked
  python3 sanitize_sts_backup_sql.py --all   # hart_* dumps under sts-backups
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
HELPERS_ROOT = TOOLS_DIR.parent
CARDS_ROOT = HELPERS_ROOT.parent
DEFAULT_BACKUPS = CARDS_ROOT / "sts-backups"

JOB_NAMES = ("CK1", "D749", "NVL", "YM1", "STG-DEMMLER", "STG-SCULLY", "STG")
JOB_CANON = {n.lower(): n for n in JOB_NAMES}

CHUNK_DROP = re.compile(
    r"^\s*drop\s+table\s+(?:if\s+exists\s+)?`([^`]+)`\s*;\s*$", re.I | re.M
)
CHUNK_CREATE = re.compile(
    r"^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`([^`]+)`\s*\(", re.I | re.M
)
CHUNK_RENAME = re.compile(
    r"^\s*rename\s+table\s+`([^`]+)`\s+to\s+`([^`]+)`\s*;\s*$", re.I | re.M
)
CHUNK_DELETE = re.compile(
    r"^\s*delete\s+from\s+`([^`]+)`\s*;\s*$", re.I | re.M
)


def job_base(name: str) -> str | None:
    base = re.sub(r"__sts_restore$", "", name, flags=re.I)
    return JOB_CANON.get(base.lower())


def is_restore_name(name: str) -> bool:
    return name.lower().endswith("__sts_restore") and job_base(name) is not None


def split_chunks(text: str) -> list[str]:
    return [c.strip() for c in text.split("#") if c.strip()]


def join_chunks(chunks: list[str]) -> str:
    parts: list[str] = []
    for chunk in chunks:
        parts.append(chunk)
        parts.append("#")
        parts.append("")
    return "\n".join(parts).rstrip() + "\n"


def rewrite_create_name(create_sql: str, new_name: str) -> str:
    return re.sub(
        r"(CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?)`[^`]+`",
        rf"\1`{new_name}`",
        create_sql,
        count=1,
        flags=re.I,
    )


def extract_drop_table(chunk: str) -> str | None:
    """Return table name from a drop chunk, including header+drop combos."""
    m = CHUNK_DROP.search(chunk)
    return m.group(1) if m else None


def leading_comments(chunk: str) -> str:
    lines = []
    for line in chunk.splitlines():
        if line.startswith("--") or line.strip() == "":
            lines.append(line)
        else:
            break
    return "\n".join(lines).rstrip()


def sanitize(text: str) -> tuple[str, dict[str, int]]:
    chunks = split_chunks(text)
    out: list[str] = []
    stats = {"job_rewritten": 0, "job_kept": 0, "drops_normalized": 0, "deletes_removed": 0}
    i = 0
    while i < len(chunks):
        chunk = chunks[i]
        drop_name = extract_drop_table(chunk)
        create_m = CHUNK_CREATE.match(chunk)
        delete_m = CHUNK_DELETE.match(chunk)

        # Keep an already-correct restore dance (do not re-emit / duplicate).
        # First chunk may be "-- header ... drop table if exists `CK1__sts_restore`;"
        if drop_name and is_restore_name(drop_name):
            job = job_base(drop_name)
            if job and i + 3 < len(chunks):
                c1, c2, c3 = chunks[i + 1], chunks[i + 2], chunks[i + 3]
                c1m = CHUNK_CREATE.match(c1)
                c2_drop = extract_drop_table(c2)
                if (
                    c1m
                    and is_restore_name(c1m.group(1))
                    and job_base(c1m.group(1)) == job
                    and c2_drop
                    and job_base(c2_drop) == job
                    and not is_restore_name(c2_drop)
                    and CHUNK_RENAME.match(c3)
                ):
                    restore = f"{job}__sts_restore"
                    header = leading_comments(chunk)
                    if header:
                        out.append(header)
                    out.extend(
                        [
                            f"drop table if exists `{restore}`;",
                            rewrite_create_name(c1, restore),
                            f"drop table if exists `{job}`;",
                            f"rename table `{restore}` to `{job}`;",
                        ]
                    )
                    i += 4
                    stats["job_kept"] += 1
                    continue

        # Bare drop + create for a job table.
        if drop_name and job_base(drop_name) and not is_restore_name(drop_name):
            job = job_base(drop_name)
            assert job
            if i + 1 < len(chunks) and CHUNK_CREATE.match(chunks[i + 1]):
                create_name = CHUNK_CREATE.match(chunks[i + 1]).group(1)
                if job_base(create_name) == job and not is_restore_name(create_name):
                    restore = f"{job}__sts_restore"
                    out.extend(
                        [
                            f"drop table if exists `{restore}`;",
                            rewrite_create_name(chunks[i + 1], restore),
                            f"drop table if exists `{job}`;",
                            f"rename table `{restore}` to `{job}`;",
                        ]
                    )
                    i += 2
                    stats["job_rewritten"] += 1
                    continue

        # Old CREATE IF NOT EXISTS + DELETE pattern (never for *__sts_restore creates).
        if create_m and job_base(create_m.group(1)) and not is_restore_name(create_m.group(1)):
            job = job_base(create_m.group(1))
            assert job
            restore = f"{job}__sts_restore"
            out.extend(
                [
                    f"drop table if exists `{restore}`;",
                    rewrite_create_name(chunk, restore),
                    f"drop table if exists `{job}`;",
                    f"rename table `{restore}` to `{job}`;",
                ]
            )
            i += 1
            if i < len(chunks) and CHUNK_DELETE.match(chunks[i]):
                if job_base(CHUNK_DELETE.match(chunks[i]).group(1)) == job:
                    stats["deletes_removed"] += 1
                    i += 1
            stats["job_rewritten"] += 1
            continue

        if delete_m and job_base(delete_m.group(1)):
            stats["deletes_removed"] += 1
            i += 1
            continue

        if drop_name and CHUNK_DROP.match(chunk):
            fixed = f"drop table if exists `{drop_name}`;"
            if fixed != chunk.strip():
                stats["drops_normalized"] += 1
            out.append(fixed)
            i += 1
            continue

        if chunk.lstrip().startswith("--") and re.search(r"drop\s+table", chunk, re.I):
            # Header + drop already handled above when it's a restore starter.
            fixed = re.sub(
                r"drop\s+table\s+(?!if\s+exists)`([^`]+)`\s*;",
                r"drop table if exists `\1`;",
                chunk,
                flags=re.I,
            )
            if fixed != chunk:
                stats["drops_normalized"] += 1
            out.append(fixed)
            i += 1
            continue

        out.append(chunk)
        i += 1

    rewritten = join_chunks(out)
    if text.lstrip().startswith("--") and not rewritten.lstrip().startswith("--"):
        header_lines: list[str] = []
        for line in text.splitlines():
            if line.startswith("--") or line.strip() == "":
                header_lines.append(line)
            else:
                break
        rewritten = "\n".join(header_lines).rstrip() + "\n\n" + rewritten
    return rewritten, stats


def verify(text: str) -> list[str]:
    problems: list[str] = []
    for job in JOB_NAMES:
        if job == "STG":
            continue
        bare_drop = len(re.findall(rf"(?im)^drop table `{re.escape(job)}`;", text))
        bare_create = len(re.findall(rf"(?im)^CREATE TABLE `{re.escape(job)}` \(", text))
        restore = len(re.findall(rf"CREATE TABLE `{re.escape(job)}__sts_restore`", text))
        rename = len(
            re.findall(
                rf"rename table `{re.escape(job)}__sts_restore` to `{re.escape(job)}`;",
                text,
                flags=re.I,
            )
        )
        if bare_drop or bare_create:
            problems.append(f"{job}: still has bare drop/create")
        if restore != rename:
            problems.append(f"{job}: restore={restore} rename={rename} mismatch")
        if restore > 1 or rename > 1:
            problems.append(f"{job}: duplicated restore block")
    return problems


def process_file(path: Path, *, dry_run: bool) -> int:
    original = path.read_text(encoding="utf-8", errors="replace")
    rewritten, stats = sanitize(original)
    problems = verify(rewritten)
    changed = rewritten != original
    print(
        f"{path.name}: changed={changed} rewritten={stats['job_rewritten']} "
        f"kept={stats['job_kept']} drops={stats['drops_normalized']}"
    )
    if problems:
        for p in problems:
            print(f"  VERIFY FAIL: {p}")
        return 1
    if dry_run or not changed:
        return 0
    bak_dir = path.parent / f"_sql_cleanup_bak_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    bak_dir.mkdir(exist_ok=True)
    shutil.copy2(path, bak_dir / path.name)
    path.write_text(rewritten, encoding="utf-8")
    print(f"  wrote {path} (bak {bak_dir / path.name})")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path, help="SQL dump files")
    parser.add_argument(
        "--all",
        action="store_true",
        help="Sanitize hart_seed / hart_seed0 / hart_session* under sts-backups",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--backups-dir",
        type=Path,
        default=DEFAULT_BACKUPS,
        help="Backups directory for --all",
    )
    args = parser.parse_args()

    files: list[Path] = list(args.paths)
    if args.all:
        for name in (
            "hart_seed",
            "hart_seed0",
            "hart_session1",
            "hart_session2",
            "hart_session2_locked",
        ):
            p = args.backups_dir / name
            if p.is_file():
                files.append(p)
        for p in sorted(args.backups_dir.glob("rewind_undo_*")):
            if p.is_file():
                files.append(p)
    if not files:
        print("No files given. Pass paths or --all.", file=sys.stderr)
        return 2

    rc = 0
    for path in files:
        if not path.is_file():
            print(f"missing: {path}", file=sys.stderr)
            rc = 1
            continue
        rc = max(rc, process_file(path, dry_run=args.dry_run))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
