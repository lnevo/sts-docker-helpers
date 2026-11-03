#!/usr/bin/env bash
# Validate hart_seed integrity and PHP/runtime location-code aliases.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

# shellcheck source=../lib/sts_api.sh
source "${_script_home}/../lib/sts_api.sh"
sts_api_guard || exit 1

SEED_NAME="hart_seed0"
[[ -f "${BACKUPS_DIR}/${SEED_NAME}" ]] || SEED_NAME="hart_seed"
STS_TASK_QUIET=1 sts_task_run POST /admin/restore "{\"backup\":\"${SEED_NAME}\",\"photos\":false,\"full\":true}"

# Legacy location-code aliases (SCL, DEM, ...) are resolved by the PHP runtime
# (warm_start_location_id_by_code); no API route exposes them, so this one check
# stays on docker exec.
ALIAS_ERRORS=""
WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -n "${WEB_CID}" ]]; then
  ALIAS_ERRORS="$(docker exec "${WEB_CID}" php -r '
chdir("/var/www/html/sts");
require "open_db.php";
require "operational_steps_catalog.php";
$dbc = open_db();
foreach (["SCL", "DEM", "SOUTH", "NIL-SHEN-COKE"] as $code) {
    if (warm_start_location_id_by_code($dbc, $code) <= 0) {
        echo "Legacy alias does not resolve: {$code}\n";
    }
}
')"
else
  echo "WARNING: web container not found; legacy alias check skipped" >&2
fi

LOCATIONS_JSON="$(sts_api_raw GET '/locations?limit=1000')"
SHIPMENTS_JSON="$(sts_api_raw GET '/shipments?limit=1000')"
CARS_JSON="$(sts_api_raw GET '/cars?limit=1000')"
STATIONS_JSON="$(sts_api_raw GET '/stations?limit=1000')"

ALIAS_ERRORS="${ALIAS_ERRORS}" python3 -c '
import json, os, sys
locs, ships, cars, stations = (json.loads(a)["data"] for a in sys.argv[1:5])
codes = {l["code"] for l in locs}
ids = {l["id"] for l in locs}
errors = [e for e in os.environ.get("ALIAS_ERRORS", "").splitlines() if e]
warnings = []
required = ["SCULLY-YARD", "DEMMLER-YARD", "SOUTH-YARD", "SOUTH-SCALE",
            "SHEN-COKE-SHIPPING", "NORTH-YARD", "WEST-YARD", "EAST-YARD"]
errors = ["Missing required location code: %s" % c for c in required if c not in codes] + errors
for s in ships:
    if s["loading_location_id"] not in ids or s["unloading_location_id"] not in ids:
        errors.append("Shipment with broken location FK: %s" % s["code"])
if any(c["location_id"] and c["location_id"] > 0 and c["location_id"] not in ids for c in cars):
    errors.append("Cars reference missing location ids")
if any(st["station_nbr"] and st["station_nbr"] > 0 and st["station_nbr"] not in ids for st in stations):
    errors.append("Routing.station_nbr references missing locations")
for c in sorted(codes):
    if c.startswith("SCL-") or c.startswith("DEM-"):
        warnings.append("Legacy party-track code still in seed: %s" % c)
if not cars:
    errors.append("hart_seed has 0 cars")
print("hart_seed reference validation")
print("  cars: %d" % len(cars))
print("  locations: %d" % len(locs))
if warnings:
    print("\nWarnings (%d):" % len(warnings))
    for w in warnings:
        print("  - " + w)
if errors:
    print("\nErrors (%d):" % len(errors))
    for e in errors:
        print("  - " + e)
    sys.exit(1)
print("\nOK \u2014 required codes, legacy aliases, and FK checks passed.")
' "${LOCATIONS_JSON}" "${SHIPMENTS_JSON}" "${CARS_JSON}" "${STATIONS_JSON}"
