<?php
/**
 * recreate_session_orders.php <session_N> [--apply] [--snapshot NAME]
 *
 * Rebuild the START-OF-SESSION-N ("session open", post-fill, pre-switching)
 * order + car state from the session-N switch-list archives.
 *
 * WHY: rewind_session.sh restores db_session_<N-1> and reconstruct_session_db.php
 * only TRIMS car_orders from the base DB. Orders that were created, filled and then
 * COMPLETED-AND-PRUNED during session N are gone from the base and never come back.
 * The session-N switch-list master JSONs, however, are a faithful record of every
 * car that was worked at session open: reporting_marks, status, waybill_number,
 * consignment (commodity), loading/unloading locations, current location, position
 * and owning job. This tool replays that record to:
 *
 *   car_orders  : (re)create one row per worked waybill, filled to the archived car.
 *                 - revenue/'M' orders : shipment = reverse-matched shipments.Id
 *                     (commodity + loading_location + unloading_location + car_code)
 *                 - 'E' orders          : shipment = destination location id
 *                     (car_orders.shipment holds a locations.id for empties;
 *                      see get_location_cars.php)
 *   cars        : current_location_id / position / status / handled_by_job_id set
 *                 to the archived session-open values (STG-* -> handled_by 0, matching
 *                 reconstruct_session_db.php: staging rows are not a live train).
 *
 * This effectively "rewinds the pickups and setouts" for every worked car back to
 * the moment the switch lists were printed, while preserving any orders already
 * present in the loaded DB (e.g. still-pending orders that were never worked).
 *
 * Read-only by default (dry-run). --apply writes and first captures a safety dump
 * to ./backups/<snapshot> (default recreate_orders_undo_<ts>).
 *
 * Run inside the web container:
 *   docker cp .../recreate_session_orders.php sts-docker-web-1:/tmp/
 *   docker exec sts-docker-web-1 php /tmp/recreate_session_orders.php 2            # dry-run
 *   docker exec sts-docker-web-1 php /tmp/recreate_session_orders.php 2 --apply    # write
 */
error_reporting(E_ERROR | E_PARSE);

$args = array_slice($argv, 1);
$N = 0;
$APPLY = false;
$SNAPSHOT = '';
for ($i = 0; $i < count($args); $i++) {
    $a = $args[$i];
    if ($a === '--apply') {
        $APPLY = true;
    } elseif ($a === '--snapshot') {
        $SNAPSHOT = (string) ($args[++$i] ?? '');
    } elseif (ctype_digit((string) $a)) {
        $N = (int) $a;
    }
}
if ($N < 1) {
    fwrite(STDERR, "Usage: recreate_session_orders.php <session_N> [--apply] [--snapshot NAME]\n");
    exit(1);
}

// --- Locate + load the STS runtime ----------------------------------------
$bootstrap = __DIR__ . '/bootstrap.php';
if (is_file($bootstrap)) {
    require $bootstrap;
    diagnostics_resolve_runtime();
} else {
    // Hot-copied into the container next to the runtime, or run from /tmp.
    $runtime = is_file(__DIR__ . '/open_db.php') ? __DIR__ : '/var/www/html/sts';
    chdir($runtime);
}
require 'open_db.php';
require 'session_helpers.php';
$dbc = open_db();
$root = session_web_root();

$dir = session_dir_for($N, $root);
if (!is_dir($dir)) {
    fwrite(STDERR, "No switch-list archives for session {$N} at {$dir}.\n");
    exit(1);
}

// --- DB lookup maps --------------------------------------------------------
$car_by_marks = [];
$rs = mysqli_query($dbc, 'SELECT id, reporting_marks FROM cars');
while ($r = mysqli_fetch_assoc($rs)) {
    $car_by_marks[(string) $r['reporting_marks']] = (int) $r['id'];
}
$loc_by_code = [];
$rs = mysqli_query($dbc, 'SELECT id, code FROM locations');
while ($r = mysqli_fetch_assoc($rs)) {
    $loc_by_code[(string) $r['code']] = (int) $r['id'];
}
$carcode_by_code = [];
$rs = mysqli_query($dbc, 'SELECT id, code FROM car_codes');
while ($r = mysqli_fetch_assoc($rs)) {
    $carcode_by_code[(string) $r['code']] = (int) $r['id'];
}
$job_by_name = [];
$rs = mysqli_query($dbc, 'SELECT id, name FROM jobs');
while ($r = mysqli_fetch_assoc($rs)) {
    $job_by_name[(string) $r['name']] = (int) $r['id'];
}
// shipments index: commodity|carcode|loading|unloading -> [ids]; plus code -> id
$ship_index = [];
$ship_by_code = [];
$rs = mysqli_query($dbc, 'SELECT id, code, consignment, car_code, loading_location, unloading_location FROM shipments');
while ($r = mysqli_fetch_assoc($rs)) {
    $key = (int) $r['consignment'] . '|' . (int) $r['car_code'] . '|'
         . (int) $r['loading_location'] . '|' . (int) $r['unloading_location'];
    $ship_index[$key][] = (int) $r['id'];
    $ship_by_code[(string) $r['code']] = (int) $r['id'];
}

// Authoritative shipment code per waybill, parsed from the archived waybill store
// (the "SHIPMENT ... (CODE)" cell). Disambiguates near-duplicate shipment
// templates (e.g. COKE-USS vs COKE-USS-BULK) that share commodity + route.
$wb_shipcode = [];
$wb_store = $dir . '/waybills/waybills.json';
if (is_file($wb_store)) {
    $store = json_decode((string) file_get_contents($wb_store), true);
    foreach (($store['bodies'] ?? []) as $wb => $html) {
        if (preg_match('/SHIPMENT.*?\(([A-Z0-9-]+)\)/s', (string) $html, $m)) {
            $wb_shipcode[(string) $wb] = $m[1];
        }
    }
}

// --- Gather worked cars from the session-N master JSONs --------------------
$field = function (array $c, string $name, $numeric) {
    return $c[$name] ?? ($c[(string) $numeric] ?? null);
};

$plan = [];        // marks -> details
$warnings = [];
foreach (glob($dir . '/phase_*/*_master.json') ?: [] as $f) {
    $d = json_decode((string) file_get_contents($f), true);
    if (!is_array($d) || empty($d['sections'])) {
        continue;
    }
    $job = trim((string) ($d['job'] ?? ''));
    $is_stg = strpos($job, 'STG-') === 0;
    $job_id = (!$is_stg && $job !== '') ? ($job_by_name[$job] ?? 0) : 0;

    foreach ($d['sections'] as $sec) {
        foreach (($sec['cars'] ?? []) as $c) {
            $marks = (string) ($field($c, 'reporting_marks', 0) ?? '');
            if ($marks === '' || isset($plan[$marks])) {
                continue; // first (session-open) appearance wins
            }
            $waybill = trim((string) ($field($c, 'waybill_number', 6) ?? ''));
            $status = (string) ($field($c, 'status', 2) ?? '');
            $commodity_id = (int) ($field($c, 'consignment_id', 5) ?? 0);
            $load_code = (string) ($field($c, 'loading_location', 11) ?? '');
            $unload_code = (string) ($field($c, 'unloading_location', 13) ?? '');
            $cur_loc_id = (int) ($field($c, 'current_location_id', 14) ?? 0);
            $position = (int) ($field($c, 'position', 15) ?? 0);
            $car_code = (string) ($field($c, 'car_code', 1) ?? '');

            $car_id = $car_by_marks[$marks] ?? 0;
            if ($car_id === 0) {
                $warnings[] = "car not found in DB: {$marks} ({$job} {$waybill})";
                continue;
            }

            // Resolve car_orders.shipment for this waybill.
            $order_type = strtoupper(substr($waybill, 4, 1));
            $shipment = null;
            $ship_note = '';
            if ($waybill === '') {
                $ship_note = 'no waybill';
            } elseif ($order_type === 'E') {
                $dest = $loc_by_code[$unload_code] ?? 0;
                if ($dest > 0) {
                    $shipment = $dest;
                    $ship_note = "empty -> dest loc {$unload_code}({$dest})";
                } else {
                    $ship_note = "empty dest location not found: '{$unload_code}'";
                }
            } elseif (isset($wb_shipcode[$waybill]) && isset($ship_by_code[$wb_shipcode[$waybill]])) {
                // Authoritative: exact shipment code printed on the archived waybill.
                $shipment = $ship_by_code[$wb_shipcode[$waybill]];
                $ship_note = 'shipment ' . $shipment . ' (archive code ' . $wb_shipcode[$waybill] . ')';
            } else {
                $cc = $carcode_by_code[$car_code] ?? 0;
                $lid = $loc_by_code[$load_code] ?? 0;
                $uid = $loc_by_code[$unload_code] ?? 0;
                $key = $commodity_id . '|' . $cc . '|' . $lid . '|' . $uid;
                $cands = $ship_index[$key] ?? [];
                if (count($cands) === 1) {
                    $shipment = $cands[0];
                    $ship_note = "shipment {$shipment} (route match)";
                } elseif (count($cands) > 1) {
                    sort($cands);
                    $shipment = $cands[0];
                    $ship_note = 'AMBIGUOUS shipments [' . implode(',', $cands) . '] -> using ' . $shipment;
                    $warnings[] = "ambiguous shipment for {$waybill} ({$marks}): [" . implode(',', $cands) . '] (no archive code)';
                } else {
                    $ship_note = "NO shipment match (commodity={$commodity_id} cc={$car_code} {$load_code}->{$unload_code})";
                    $warnings[] = "no shipment match for {$waybill} ({$marks}): " . $ship_note;
                }
            }

            $plan[$marks] = [
                'car_id' => $car_id,
                'job' => $job,
                'job_id' => $job_id,
                'waybill' => $waybill,
                'status' => $status,
                'cur_loc_id' => $cur_loc_id,
                'position' => $position,
                'shipment' => $shipment,
                'ship_note' => $ship_note,
                'order_type' => $order_type,
            ];
        }
    }
}

// --- Current DB state for diff ---------------------------------------------
$existing_orders = [];
$rs = mysqli_query($dbc, 'SELECT waybill_number, shipment, car FROM car_orders');
while ($r = mysqli_fetch_assoc($rs)) {
    $existing_orders[(string) $r['waybill_number']] = ['shipment' => (int) $r['shipment'], 'car' => (int) $r['car']];
}
$cur_car = [];
$rs = mysqli_query($dbc, 'SELECT id, current_location_id, position, status, handled_by_job_id FROM cars');
while ($r = mysqli_fetch_assoc($rs)) {
    $cur_car[(int) $r['id']] = $r;
}

// --- Report ----------------------------------------------------------------
$mode = $APPLY ? 'APPLY' : 'DRY-RUN';
printf("recreate_session_orders session=%d mode=%s\n", $N, $mode);
printf("session_nbr(loaded)=%s worked_cars=%d existing_orders=%d\n\n",
    mysqli_fetch_row(mysqli_query($dbc, 'SELECT setting_value FROM settings WHERE setting_name="session_nbr"'))[0],
    count($plan), count($existing_orders));

printf("%-11s %-6s %-9s %-9s %-4s %-4s %-6s %s\n",
    'MARKS', 'JOB', 'WAYBILL', 'STATUS', 'LOC', 'POS', 'NEW?', 'SHIPMENT');
printf("%s\n", str_repeat('-', 90));
$new_orders = $changed_orders = 0;
foreach ($plan as $marks => $p) {
    $isnew = !isset($existing_orders[$p['waybill']]);
    if ($isnew) {
        $new_orders++;
    } elseif ($existing_orders[$p['waybill']]['car'] !== $p['car_id']
        || $existing_orders[$p['waybill']]['shipment'] !== (int) $p['shipment']) {
        $changed_orders++;
    }
    printf("%-11s %-6s %-9s %-9s %-4d %-4d %-6s %s\n",
        $marks, $p['job'], $p['waybill'], $p['status'], $p['cur_loc_id'], $p['position'],
        $isnew ? 'new' : 'exist', $p['ship_note']);
}

echo "\n";
if ($warnings) {
    echo "WARNINGS (" . count($warnings) . "):\n";
    foreach ($warnings as $w) {
        echo "  - {$w}\n";
    }
    echo "\n";
}
printf("orders: new=%d changed_fill=%d | worked cars to reposition=%d\n", $new_orders, $changed_orders, count($plan));

if (!$APPLY) {
    echo "\nDry-run only. Re-run with --apply to write (a safety snapshot is taken first).\n";
    exit(0);
}

// --- Apply -----------------------------------------------------------------
$snap = $SNAPSHOT !== '' ? $SNAPSHOT : ('recreate_orders_undo_' . date('Ymd_His'));
if (is_file('backup_tables.php')) {
    require_once 'backup_tables.php';
}
if (function_exists('backup_tables')) {
    backup_tables($dbc, $snap);
    echo "Safety snapshot written: ./backups/{$snap}\n";
} else {
    fwrite(STDERR, "WARNING: backup_tables() unavailable; proceeding without safety snapshot.\n");
}

mysqli_query($dbc, 'START TRANSACTION');
$ok = true;
foreach ($plan as $marks => $p) {
    $wb = mysqli_real_escape_string($dbc, $p['waybill']);
    $shipment = $p['shipment'] === null ? 0 : (int) $p['shipment'];
    if ($p['waybill'] !== '') {
        $sql = 'REPLACE INTO car_orders (waybill_number, shipment, car) VALUES ("'
             . $wb . '", ' . $shipment . ', ' . (int) $p['car_id'] . ')';
        if (!mysqli_query($dbc, $sql)) {
            fwrite(STDERR, 'car_orders error: ' . mysqli_error($dbc) . "\n");
            $ok = false;
            break;
        }
    }
    $status = mysqli_real_escape_string($dbc, $p['status']);
    $sql = 'UPDATE cars SET current_location_id = ' . (int) $p['cur_loc_id']
         . ', position = ' . (int) $p['position']
         . ', handled_by_job_id = ' . (int) $p['job_id']
         . ($status !== '' ? ', status = "' . $status . '"' : '')
         . ' WHERE id = ' . (int) $p['car_id'];
    if (!mysqli_query($dbc, $sql)) {
        fwrite(STDERR, 'cars error: ' . mysqli_error($dbc) . "\n");
        $ok = false;
        break;
    }
}

if ($ok) {
    mysqli_query($dbc, 'COMMIT');
    $tot = (int) mysqli_fetch_row(mysqli_query($dbc, 'SELECT COUNT(*) FROM car_orders'))[0];
    $fil = (int) mysqli_fetch_row(mysqli_query($dbc, 'SELECT COUNT(*) FROM car_orders WHERE car > 0'))[0];
    printf("APPLIED. car_orders now total=%d filled=%d. Undo: restore ./backups/%s\n", $tot, $fil, $snap);
} else {
    mysqli_query($dbc, 'ROLLBACK');
    fwrite(STDERR, "ROLLED BACK (no changes). Safety snapshot ./backups/{$snap} still available.\n");
    exit(1);
}
