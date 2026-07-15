<?php
/**
 * validate_session_snapshot.php <session_N>
 *
 * Cross-check the live DB (expected: just restored db_session_N) against the
 * session_N switch-list / waybill archives. Reports car position+status,
 * handled_by/position, work-order fill state, and switch-list file presence.
 *
 *   End-of-session N layout  ~  start-of-session N+1 in the station report
 *   (reconstructed from archives sessions 1..N).
 *
 * Run inside the web container:
 *   docker exec sts-docker-web-1 php /tmp/validate_session_snapshot.php 2
 */
error_reporting(E_ERROR | E_PARSE);
chdir('/var/www/html/sts');
require 'open_db.php';
require 'session_helpers.php';

$N = (int) ($argv[1] ?? 0);
if ($N < 1) {
    fwrite(STDERR, "Usage: validate_session_snapshot.php <session_N>\n");
    exit(1);
}

$dbc = open_db();
$root = session_web_root();
$session_dir = session_dir_for($N, $root);

if (!is_dir($session_dir)) {
    fwrite(STDERR, "No session_state archive for session {$N}.\n");
    exit(1);
}

$db_session = (int) mysqli_fetch_row(mysqli_query(
    $dbc,
    'SELECT setting_value FROM settings WHERE setting_name = "session_nbr"'
))[0];

echo "=== Session {$N} snapshot validation ===\n";
echo "DB session_nbr: {$db_session}" . ($db_session === $N ? " (ok)\n" : " (MISMATCH, expected {$N})\n");

// --- Lookup maps -----------------------------------------------------------
$loc_by_id = [];
$loc_by_code = [];
$rs = mysqli_query($dbc, 'SELECT id, code FROM locations');
while ($row = mysqli_fetch_assoc($rs)) {
    $loc_by_id[(int) $row['id']] = (string) $row['code'];
    $loc_by_code[(string) $row['code']] = (int) $row['id'];
}
$car_by_marks = [];
$car_by_id = [];
$rs = mysqli_query($dbc, 'SELECT id, reporting_marks, current_location_id, status, handled_by_job_id, position FROM cars');
while ($row = mysqli_fetch_assoc($rs)) {
    $marks = (string) $row['reporting_marks'];
    $car_by_marks[$marks] = $row;
    $car_by_id[(int) $row['id']] = $marks;
}
$job_by_id = [];
$job_by_name = [];
$rs = mysqli_query($dbc, 'SELECT id, name FROM jobs');
while ($row = mysqli_fetch_assoc($rs)) {
    $job_by_id[(int) $row['id']] = (string) $row['name'];
    $job_by_name[(string) $row['name']] = (int) $row['id'];
}

// --- 1. Car positions / status (end of N ~ start of N+1) -----------------
$next = $N + 1;
$report = session_station_report_data($dbc, $next, $root);
$pos_mismatches = [];
$pos_checked = 0;
if ($report === null) {
    echo "\n[CAR POSITIONS] station report for start-of-session {$next} unavailable\n";
} else {
    $expected = [];
    foreach ($report['by_station'] as $rows) {
        foreach ($rows as $r) {
            $expected[(string) $r['marks']] = [
                'loc' => (string) $r['loc'],
                'status' => (string) $r['status'],
            ];
        }
    }
    foreach ($expected as $marks => $exp) {
        if (!isset($car_by_marks[$marks])) {
            continue;
        }
        $pos_checked++;
        $db = $car_by_marks[$marks];
        $db_loc = (int) $db['current_location_id'];
        $db_loc_code = $db_loc > 0 ? ($loc_by_id[$db_loc] ?? '') : '';
        $exp_loc = $exp['loc'];
        $exp_status = $exp['status'];
        $db_status = (string) $db['status'];
        if ($db_loc_code !== $exp_loc || $db_status !== $exp_status) {
            $pos_mismatches[] = [
                'marks' => $marks,
                'db_loc' => $db_loc_code !== '' ? $db_loc_code : '(in train)',
                'exp_loc' => $exp_loc !== '' ? $exp_loc : '(in train)',
                'db_status' => $db_status,
                'exp_status' => $exp_status,
            ];
        }
    }
    echo "\n[CAR POSITIONS] vs start-of-session {$next} archive reconstruction\n";
    echo "  checked: {$pos_checked}  mismatches: " . count($pos_mismatches) . "\n";
    foreach (array_slice($pos_mismatches, 0, 15) as $m) {
        echo "    {$m['marks']}: loc {$m['db_loc']} vs {$m['exp_loc']}, status {$m['db_status']} vs {$m['exp_status']}\n";
    }
    if (count($pos_mismatches) > 15) {
        echo "    ... and " . (count($pos_mismatches) - 15) . " more\n";
    }
}

// --- 2. handled_by / position from session N+1 switch-list archives --------
$worked = [];
foreach (glob(session_dir_for($next, $root) . '/phase_*/*_master.json') ?: [] as $f) {
    // session N+1 archive may be absent after rewind; fall back to last phase of N.
}
// Use session N archives for cars still on trains at end of session N.
$worked_end = [];
foreach (glob($session_dir . '/phase_*/*_master.json') ?: [] as $f) {
    $d = json_decode((string) file_get_contents($f), true);
    if (!is_array($d) || empty($d['sections'])) {
        continue;
    }
    $job = trim((string) ($d['job'] ?? ''));
    $job_id = ($job !== '' && strpos($job, 'STG-') !== 0) ? ($job_by_name[$job] ?? 0) : 0;
    foreach ($d['sections'] as $sec) {
        foreach (($sec['cars'] ?? []) as $car) {
            $marks = (string) ($car['reporting_marks'] ?? ($car[0] ?? ''));
            if ($marks === '') {
                continue;
            }
            $worked_end[$marks] = [
                'job' => $job_id,
                'job_name' => $job,
                'position' => (int) ($car['position'] ?? ($car[15] ?? 0)),
            ];
        }
    }
}
$hb_mismatches = [];
foreach ($worked_end as $marks => $exp) {
    if (!isset($car_by_marks[$marks])) {
        continue;
    }
    $db = $car_by_marks[$marks];
    $db_job = (int) $db['handled_by_job_id'];
    $db_pos = (int) $db['position'];
    if ($db_job !== (int) $exp['job'] || $db_pos !== (int) $exp['position']) {
        $hb_mismatches[] = [
            'marks' => $marks,
            'db' => ($db_job ? ($job_by_id[$db_job] ?? "?#{$db_job}") : '-') . '@' . $db_pos,
            'exp' => ($exp['job'] ? $exp['job_name'] : '-') . '@' . $exp['position'],
        ];
    }
}
echo "\n[HANDLED_BY] vs session {$N} switch-list archives (cars on lists)\n";
echo "  archive cars: " . count($worked_end) . "  mismatches: " . count($hb_mismatches) . "\n";
foreach (array_slice($hb_mismatches, 0, 10) as $m) {
    echo "    {$m['marks']}: DB {$m['db']} vs archive {$m['exp']}\n";
}

// --- 3. Work orders / waybills ---------------------------------------------
$wb_car = [];
$wb_first = [];
for ($s = 1; $s <= $N; $s++) {
    if (!is_dir(session_dir_for($s, $root))) {
        continue;
    }
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
                $wb_car[$wb] = (int) $car_by_marks[$marks]['id'];
                if (!isset($wb_first[$wb]) || $s < $wb_first[$wb]) {
                    $wb_first[$wb] = $s;
                }
            }
        }
    }
}
$pad = str_pad((string) $N, 3, '0', STR_PAD_LEFT);
$order_mismatches = [];
$orders_total = 0;
$orders_filled = 0;
$rs = mysqli_query($dbc, 'SELECT waybill_number, car FROM car_orders');
while ($row = mysqli_fetch_assoc($rs)) {
    $wb = (string) $row['waybill_number'];
    if (!preg_match('/^(\d{3})-/', $wb, $m)) {
        continue;
    }
    if ((int) $m[1] > $N) {
        $order_mismatches[] = ['wb' => $wb, 'issue' => 'order prefix > session ' . $N];
        continue;
    }
    $orders_total++;
    $db_car = (int) $row['car'];
    if ($db_car > 0) {
        $orders_filled++;
    }
    $first = $wb_first[$wb] ?? null;
    if ($first !== null && $first > $N) {
        if ($db_car !== 0) {
            $order_mismatches[] = ['wb' => $wb, 'issue' => "filled in DB but first archive appearance session {$first}"];
        }
    } elseif (isset($wb_car[$wb])) {
        if ($db_car !== $wb_car[$wb]) {
            $order_mismatches[] = [
                'wb' => $wb,
                'issue' => "car id {$db_car} vs archive car id {$wb_car[$wb]}",
            ];
        }
    }
}
$store = session_waybill_store_load($N, $root);
$store_count = count($store['order'] ?? []);
echo "\n[WORK ORDERS] car_orders through session {$N}\n";
echo "  DB orders (prefix<={$N}): {$orders_total} filled={$orders_filled}\n";
echo "  Archive waybills seen (sessions 1..{$N}): " . count($wb_car) . "\n";
echo "  Waybill store session_{$N}/waybills.json: {$store_count} bodies\n";
echo "  mismatches: " . count($order_mismatches) . "\n";
foreach (array_slice($order_mismatches, 0, 12) as $m) {
    echo "    {$m['wb']}: {$m['issue']}\n";
}

// --- 4. Switch-list archive integrity --------------------------------------
$manifest = session_load_manifest($N, $root);
$phases = $manifest['phases'] ?? [];
$sw_issues = [];
foreach ($phases as $phase) {
    $pnum = (int) ($phase['phase'] ?? 0);
    foreach ($phase['jobs'] ?? [] as $job) {
        $job = trim((string) $job);
        $master = $session_dir . '/phase_' . session_phase_pad($pnum) . '/' . $job . '_session_' . $N . '_master.json';
        if (!is_file($master)) {
            $sw_issues[] = "missing master: phase_{$pnum}/{$job}";
            continue;
        }
        $d = json_decode((string) file_get_contents($master), true);
        if (!is_array($d) || empty($d['sections'])) {
            $sw_issues[] = "empty master: phase_{$pnum}/{$job}";
        }
    }
}
echo "\n[SWITCH LISTS] session_{$N} manifest phases: " . count($phases) . "\n";
echo "  issues: " . count($sw_issues) . "\n";
foreach ($sw_issues as $issue) {
    echo "    {$issue}\n";
}

// --- Summary ---------------------------------------------------------------
$total_issues = count($pos_mismatches) + count($hb_mismatches) + count($order_mismatches) + count($sw_issues);
echo "\n=== SUMMARY ===\n";
if ($db_session !== $N) {
    echo "FAIL: session_nbr mismatch\n";
    exit(1);
}
if ($total_issues === 0) {
    echo "PASS: no discrepancies found for end-of-session {$N}\n";
    exit(0);
}
echo "REVIEW: {$total_issues} discrepancy(ies) — see sections above\n";
echo "Note: car_orders fill state is best-effort for orders completed before the base session;\n";
echo "      positions/status from archives are the authoritative check.\n";
exit(0);
