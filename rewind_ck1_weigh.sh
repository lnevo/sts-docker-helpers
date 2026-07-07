#!/usr/bin/env bash
# Restore warm-start DB and clear weigh artifacts, then re-weigh CK1 coke cars.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "${SCRIPT_DIR}/lib/paths.sh"
sts_helpers_resolve_paths

SCALE_DIR="${BACKUPS_DIR}/track_scale"
SEED_JSON="${SCALE_DIR}/seed.json"
SESSION_LOG="${SCALE_DIR}/session.log"
MARKS="BO31000,WLE621"

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container is not running." >&2
  exit 1
fi

if [[ ! -x "${APPLY_HART_SEED}" ]]; then
  echo "apply_hart_seed.sh not found at ${APPLY_HART_SEED}. Set HART_CARDS_ROOT." >&2
  exit 1
fi

echo "==> Restoring hart_warm_start database"
"${APPLY_HART_SEED}" --sql-file "${BACKUPS_DIR}/hart_warm_start"

echo "==> Clearing weigh cache for ${MARKS}"
python3 - <<PY
import json
import csv
from pathlib import Path

marks = {m.strip().upper() for m in "${MARKS}".split(",") if m.strip()}
seed_path = Path("${SEED_JSON}")
if seed_path.exists():
    seed = json.loads(seed_path.read_text())
    weights = seed.get("car_weights") or {}
    logged = seed.get("logged_cars") or []
    for m in marks:
        weights.pop(m, None)
    seed["car_weights"] = weights
    seed["logged_cars"] = [x for x in logged if str(x).upper() not in marks]
    seed_path.write_text(json.dumps(seed, indent=2) + "\n")
    print(f"Cleared seed cache for: {', '.join(sorted(marks))}")

log_path = Path("${SESSION_LOG}")
if log_path.exists():
    rows = []
    with log_path.open(newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        rows.append(header)
        removed = 0
        for row in reader:
            if len(row) > 4 and row[0] == "weigh" and row[4].upper() in marks:
                removed += 1
                continue
            rows.append(row)
    with log_path.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerows(rows)
    print(f"Removed {removed} prior weigh log row(s) for those cars")
PY

echo "==> Syncing simulate_ck1_weigh.php into container"
docker cp "${SCRIPT_DIR}/sts/simulate_ck1_weigh.php" "${WEB_CID}:/var/www/html/sts/simulate_ck1_weigh.php"
docker cp "${SCRIPT_DIR}/sts/track_scale_helpers.php" "${WEB_CID}:/var/www/html/sts/track_scale_helpers.php"

echo "==> Re-weighing CK1 cars"
docker exec "${WEB_CID}" php /var/www/html/sts/simulate_ck1_weigh.php --marks="${MARKS}"

echo ""
echo "Done. Check track scale session log and STS weigh UI."
