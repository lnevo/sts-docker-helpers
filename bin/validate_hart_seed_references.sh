#!/usr/bin/env bash
# Validate hart_seed integrity and PHP/runtime location-code aliases.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container is not running." >&2
  exit 1
fi

"${BIN_DIR}/sync_operational_steps.sh" >/dev/null

docker exec "${WEB_CID}" php -r '
chdir("/var/www/html/sts");
require "open_db.php";
require "operational_steps_catalog.php";

$dbc = open_db();
operational_steps_dispatch_step($dbc, ["function" => "restore_database", "params" => ["backup" => "hart_seed"]], []);

$errors = [];
$warnings = [];

$required_codes = [
    "SCULLY-YARD", "DEMMLER-YARD", "SOUTH-YARD", "SOUTH-SCALE",
    "SHEN-COKE-SHIPPING", "NORTH-YARD", "WEST-YARD", "EAST-YARD",
];
foreach ($required_codes as $code) {
    if (warm_start_location_id_by_code($dbc, $code) <= 0) {
        $errors[] = "Missing required location code: {$code}";
    }
}

$legacy_codes = ["SCL", "DEM", "SOUTH", "NIL-SHEN-COKE"];
foreach ($legacy_codes as $code) {
    $id = warm_start_location_id_by_code($dbc, $code);
    if ($id <= 0) {
        $errors[] = "Legacy alias does not resolve: {$code}";
    }
}

$rs = mysqli_query(
    $dbc,
    "SELECT s.code FROM shipments s
     LEFT JOIN locations ll ON ll.id = s.loading_location
     LEFT JOIN locations ul ON ul.id = s.unloading_location
     WHERE ll.id IS NULL OR ul.id IS NULL"
);
if ($rs && mysqli_num_rows($rs) > 0) {
    while ($row = mysqli_fetch_array($rs)) {
        $errors[] = "Shipment with broken location FK: " . $row["code"];
    }
}

$rs = mysqli_query(
    $dbc,
    "SELECT COUNT(*) AS c FROM cars c
     LEFT JOIN locations l ON l.id = c.current_location_id
     WHERE c.current_location_id > 0 AND l.id IS NULL"
);
if ($rs && (int) mysqli_fetch_array($rs)["c"] > 0) {
    $errors[] = "Cars reference missing location ids";
}

$rs = mysqli_query(
    $dbc,
    "SELECT COUNT(*) AS c FROM routing r
     LEFT JOIN locations l ON l.id = r.station_nbr
     WHERE r.station_nbr > 0 AND l.id IS NULL"
);
if ($rs && (int) mysqli_fetch_array($rs)["c"] > 0) {
    $errors[] = "Routing.station_nbr references missing locations";
}

$rs = mysqli_query(
    $dbc,
    "SELECT code FROM locations WHERE code LIKE \"SCL-%\" OR code LIKE \"DEM-%\" ORDER BY code"
);
if ($rs) {
    while ($row = mysqli_fetch_array($rs)) {
        $warnings[] = "Legacy party-track code still in seed: " . $row["code"];
    }
}

$rs = mysqli_query($dbc, "SELECT COUNT(*) AS c FROM cars");
$car_count = $rs ? (int) mysqli_fetch_array($rs)["c"] : 0;
if ($car_count <= 0) {
    $errors[] = "hart_seed has 0 cars";
}

echo "hart_seed reference validation\n";
echo "  cars: {$car_count}\n";
echo "  locations: ";
$rs = mysqli_query($dbc, "SELECT COUNT(*) AS c FROM locations");
echo ($rs ? (int) mysqli_fetch_array($rs)["c"] : 0) . "\n";

if ($warnings !== []) {
    echo "\nWarnings (" . count($warnings) . "):\n";
    foreach ($warnings as $w) {
        echo "  - {$w}\n";
    }
}

if ($errors !== []) {
    echo "\nErrors (" . count($errors) . "):\n";
    foreach ($errors as $e) {
        echo "  - {$e}\n";
    }
    exit(1);
}

echo "\nOK — required codes, legacy aliases, and FK checks passed.\n";
'
