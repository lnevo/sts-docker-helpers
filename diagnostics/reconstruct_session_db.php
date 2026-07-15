<?php
/**
 * reconstruct_session_db.php <target_session_N>
 *
 * Transform the currently-loaded DB (a full-fleet base, e.g. hart_prod_10)
 * into the START-OF-SESSION-N ready state (session_nbr = N), reconstructed from
 * the switch-list archives (session_state/sessions). This mirrors the meaning of
 * the existing snapshots: db_session_11 == live session 11, hart_prod_10 ==
 * session 10. The session N archives are the primary source for car positions.
 *
 *   cars.current_location_id / status : from session_station_report_data(N)
 *       (per-car start-of-N reconstruction with nearest-observation fallback)
 *   cars.handled_by_job_id / position : from the session N switch-list archives
 *       directly (only cars actually worked at the start of N are assigned)
 *   car_orders                        : base orders trimmed to prefix <= N;
 *       fill state (car) corrected from the archive waybill->car history
 *       (waybills whose first archive appearance is > N are reset to unfilled)
 *   shipments.last_ship_date          : capped at N
 *   settings.session_nbr              : set to N
 *
 * This is a best-effort reconstruction. Positions/status/handled_by are accurate
 * where a car appears in the archives; car_orders fill state and load_count are
 * approximate for orders that were completed-and-pruned before the base session.
 *
 * Run inside the web container:
 *   docker exec sts-docker-web-1 php /tmp/reconstruct_session_db.php 9
 */
error_reporting(E_ERROR | E_PARSE);
chdir('/var/www/html/sts');
require 'open_db.php';
require 'session_helpers.php';

$N = (int) ($argv[1] ?? 0);
if ($N < 1) {
    fwrite(STDERR, "Usage: reconstruct_session_db.php <target_session_N>\n");
    exit(1);
}
$src = $N; // start-of-session-N is described by the session N archives
$dbc = open_db();
$root = session_web_root();

if (!is_dir(session_dir_for($src, $root))) {
    fwrite(STDERR, "No archives for session {$src}.\n");
    exit(1);
}

// --- Lookup maps -----------------------------------------------------------
$loc_by_code = [];
$rs = mysqli_query($dbc, 'SELECT id, code FROM locations');
while ($row = mysqli_fetch_assoc($rs)) {
    $loc_by_code[(string) $row['code']] = (int) $row['id'];
}
$car_by_marks = [];
$rs = mysqli_query($dbc, 'SELECT id, reporting_marks FROM cars');
while ($row = mysqli_fetch_assoc($rs)) {
    $car_by_marks[(string) $row['reporting_marks']] = (int) $row['id'];
}
$job_by_name = [];
$rs = mysqli_query($dbc, 'SELECT id, name FROM jobs');
while ($row = mysqli_fetch_assoc($rs)) {
    $job_by_name[(string) $row['name']] = (int) $row['id'];
}

// --- Positions / status from the reconstructed station data ----------------
$data = session_station_report_data($dbc, $src, $root);
if ($data === null) {
    fwrite(STDERR, "station report data unavailable for session {$src}\n");
    exit(1);
}
$pos_by_marks = [];    // marks -> [loc_id, status]
foreach ($data['by_station'] as $rows) {
    foreach ($rows as $r) {
        $marks = (string) $r['marks'];
        $loc_code = (string) $r['loc'];
        $loc_id = $loc_code !== '' ? ($loc_by_code[$loc_code] ?? 0) : 0;
        $pos_by_marks[$marks] = [
            'loc' => $loc_id,
            'status' => (string) $r['status'],
        ];
    }
}

// --- handled_by / position(int) from the session N switch-list archives ----
$worked = []; // marks -> [job_id, position]
foreach (glob(session_dir_for($src, $root) . '/phase_*/*_master.json') ?: [] as $f) {
    $d = json_decode((string) file_get_contents($f), true);
    if (!is_array($d) || empty($d['sections'])) {
        continue;
    }
    $job = trim((string) ($d['job'] ?? ''));
    // STG-* are staging outbound rows, not a live train assignment.
    $job_id = ($job !== '' && strpos($job, 'STG-') !== 0) ? ($job_by_name[$job] ?? 0) : 0;
    foreach ($d['sections'] as $sec) {
        foreach (($sec['cars'] ?? []) as $car) {
            $marks = (string) ($car['reporting_marks'] ?? ($car[0] ?? ''));
            if ($marks === '' || isset($worked[$marks])) {
                continue;
            }
            $worked[$marks] = [
                'job' => $job_id,
                'position' => (int) ($car['position'] ?? ($car[15] ?? 0)),
            ];
        }
    }
}

// --- Archive waybill -> car (id) history, and first-appearance session ------
$wb_car = [];        // waybill -> car_id (latest reference at S <= src)
$wb_first = [];      // waybill -> earliest session seen
for ($s = 1; $s <= $src; $s++) {
    foreach (glob(session_dir_for($s, $root) . '/phase_*/*_master.json') ?: [] as $f) {
        $d = json_decode((string) file_get_contents($f), true);
        if (!is_array($d) || empty($d['sections'])) {
            continue;
        }
        foreach ($d['sections'] as $sec) {
            foreach (($sec['cars'] ?? []) as $car) {
                $wb = trim((string) ($car['waybill_number'] ?? ($car[6] ?? '')));
                $marks = (string) ($car['reporting_marks'] ?? ($car[0] ?? ''));
                if ($wb === '' || !isset($car_by_marks[$marks])) {
                    continue;
                }
                $wb_car[$wb] = $car_by_marks[$marks];
                if (!isset($wb_first[$wb]) || $s < $wb_first[$wb]) {
                    $wb_first[$wb] = $s;
                }
            }
        }
    }
}

// --- Apply: cars -----------------------------------------------------------
$updated = 0;
foreach ($car_by_marks as $marks => $car_id) {
    $loc = null;
    $status = null;
    if (isset($pos_by_marks[$marks])) {
        $loc = (int) $pos_by_marks[$marks]['loc'];
        $status = (string) $pos_by_marks[$marks]['status'];
    }
    $job_id = isset($worked[$marks]) ? (int) $worked[$marks]['job'] : 0;
    $position = isset($worked[$marks]) ? (int) $worked[$marks]['position'] : 0;

    $sets = ['handled_by_job_id = ' . $job_id, 'position = ' . $position];
    if ($loc !== null) {
        $sets[] = 'current_location_id = ' . $loc;
    }
    if ($status !== null && $status !== '') {
        $sets[] = 'status = "' . mysqli_real_escape_string($dbc, $status) . '"';
    }
    // last_spotted cannot exceed the reconstructed session.
    $sets[] = 'last_spotted = LEAST(COALESCE(last_spotted,0), ' . $N . ')';
    mysqli_query($dbc, 'UPDATE cars SET ' . implode(', ', $sets) . ' WHERE id = ' . (int) $car_id);
    $updated++;
}

// --- Apply: car_orders -----------------------------------------------------
// Trim to prefix <= N.
mysqli_query($dbc, 'DELETE FROM car_orders WHERE CAST(SUBSTRING(waybill_number,1,3) AS UNSIGNED) > ' . $N);
$deleted_orders = mysqli_affected_rows($dbc);

// Correct fill state on remaining orders.
$fixed_fill = 0;
$reset_fill = 0;
$rs = mysqli_query($dbc, 'SELECT waybill_number, car FROM car_orders');
$order_rows = [];
while ($row = mysqli_fetch_assoc($rs)) {
    $order_rows[] = $row;
}
foreach ($order_rows as $row) {
    $wb = (string) $row['waybill_number'];
    $first = $wb_first[$wb] ?? null;
    if ($first !== null && $first > $N) {
        // Filled only after session N -> unfilled at end of N.
        if ((int) $row['car'] !== 0) {
            mysqli_query($dbc, 'UPDATE car_orders SET car = 0 WHERE waybill_number = "' . mysqli_real_escape_string($dbc, $wb) . '"');
            $reset_fill++;
        }
    } elseif (isset($wb_car[$wb])) {
        // Filled by end of N -> pin to the archived car.
        if ((int) $row['car'] !== (int) $wb_car[$wb]) {
            mysqli_query($dbc, 'UPDATE car_orders SET car = ' . (int) $wb_car[$wb] . ' WHERE waybill_number = "' . mysqli_real_escape_string($dbc, $wb) . '"');
            $fixed_fill++;
        }
    }
}

// --- Apply: shipments + settings ------------------------------------------
mysqli_query($dbc, 'UPDATE shipments SET last_ship_date = ' . $N . ' WHERE last_ship_date > ' . $N);
$ship_capped = mysqli_affected_rows($dbc);
mysqli_query($dbc, 'UPDATE settings SET setting_value = ' . $N . ' WHERE setting_name = "session_nbr"');

// --- Summary ---------------------------------------------------------------
$order_total = (int) mysqli_fetch_row(mysqli_query($dbc, 'SELECT COUNT(*) FROM car_orders'))[0];
$order_filled = (int) mysqli_fetch_row(mysqli_query($dbc, 'SELECT COUNT(*) FROM car_orders WHERE car > 0'))[0];
$in_train = (int) mysqli_fetch_row(mysqli_query($dbc, 'SELECT COUNT(*) FROM cars WHERE current_location_id = 0'))[0];
fwrite(STDERR, sprintf(
    "session %d reconstructed: cars_updated=%d orders(total=%d filled=%d deleted=%d fill_fixed=%d fill_reset=%d) shipments_capped=%d in_train=%d\n",
    $N, $updated, $order_total, $order_filled, $deleted_orders, $fixed_fill, $reset_fill, $ship_capped, $in_train
));
