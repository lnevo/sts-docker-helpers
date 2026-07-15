<?php
/**
 * integrate_d749_demmler_pool.php [--session N] [--dry-run] [--no-ops]
 *
 * Promote the Demmler yard-pool D749 cars into the live session as a real
 * D749 switch-list leg (not a supplemental sheet):
 *
 *   1. Auto-assign Ordered cars at Demmler Yard that are D749-eligible
 *      (same criteria as Assign Cars / auto_assign_locals).
 *   2. Generate a stock STS switch list into phase_08 (master cache + all
 *      styles), titled D749 / Demmler — without including South Yard cars
 *      that may already be assigned to D749.
 *   3. Register the phase in the session manifest and capture waybills into
 *      the session store.
 *   4. Drop stale print-all bundles so so.php rebuilds them.
 *   5. Unless --no-ops: pick up at Demmler Yard and set out to each car's
 *      final destination (load spot), completing that recipe leg.
 *
 * Defaults to the current DB session_nbr.
 *
 *   docker cp integrate_d749_demmler_pool.php sts-docker-web-1:/tmp/
 *   docker exec sts-docker-web-1 php /tmp/integrate_d749_demmler_pool.php
 *   docker exec sts-docker-web-1 php /tmp/integrate_d749_demmler_pool.php --dry-run
 */
error_reporting(E_ERROR | E_PARSE);

$bootstrap = __DIR__ . '/bootstrap.php';
if (is_file($bootstrap)) {
    require $bootstrap;
    diagnostics_resolve_runtime();
} else {
    $runtime = is_file(__DIR__ . '/open_db.php') ? __DIR__ : '/var/www/html/sts';
    chdir($runtime);
}
require 'open_db.php';
require_once 'session_helpers.php';
require_once 'master_switchlist_helpers.php';
require_once 'warm_start_helpers.php';
require_once 'drop_down_list_functions.php';
require_once 'operational_steps_catalog.php';

$DRY = in_array('--dry-run', $argv, true);
$NO_OPS = in_array('--no-ops', $argv, true);
$N = 0;
foreach ($argv as $i => $a) {
    if ($a === '--session' && isset($argv[$i + 1]) && ctype_digit((string) $argv[$i + 1])) {
        $N = (int) $argv[$i + 1];
    }
}

$dbc = open_db();
$root = session_web_root();
if ($N < 1) {
    $N = (int) session_get_db_session($dbc);
}
if ($N < 1) {
    fwrite(STDERR, "No session number\n");
    exit(1);
}

$JOB = 'D749';
$TITLE = 'D749';
$INFO = 'Demmler';
$PHASE = 8;
$DEMLER_STATION = 10;

echo "session=$N dry_run=" . ($DRY ? 'yes' : 'no') . " ops=" . ($NO_OPS ? 'skip' : 'pickup+setout') . "\n";

// --- 1. Eligible Demmler cars -----------------------------------------------
$eligible = array_keys(auto_assign_eligible_car_ids_for_job($dbc, $JOB, true));
$eligible = operational_steps_filter_car_ids_at_station($dbc, $eligible, $DEMLER_STATION);
if ($eligible === []) {
    // Fallback: the known six waybills (Ordered @ Demmler with filled orders).
    $rs = mysqli_query(
        $dbc,
        'SELECT c.id FROM cars c
         INNER JOIN car_orders co ON co.car = c.id
         INNER JOIN locations loc ON loc.id = c.current_location_id
         WHERE loc.station = ' . (int) $DEMLER_STATION . '
           AND c.handled_by_job_id = 0
           AND co.waybill_number IN ("001-001","001-004","001-010","001-015","002-003","002-004")'
    );
    while ($rs && ($row = mysqli_fetch_assoc($rs))) {
        $eligible[] = (int) $row['id'];
    }
}
sort($eligible);
echo "demmler candidates: " . count($eligible) . " [" . implode(',', $eligible) . "]\n";
if ($eligible === []) {
    fwrite(STDERR, "No Demmler pool cars to integrate\n");
    exit(1);
}

// Cars already on D749 that are NOT at Demmler (e.g. South Yard outbound).
$job_id = warm_start_job_id($dbc, $JOB);
$other_assigned = [];
$rs = mysqli_query(
    $dbc,
    'SELECT c.id, c.reporting_marks, c.current_location_id, loc.station AS sta
     FROM cars c
     LEFT JOIN locations loc ON loc.id = c.current_location_id
     WHERE c.handled_by_job_id = ' . (int) $job_id
);
while ($rs && ($row = mysqli_fetch_assoc($rs))) {
    if ((int) ($row['sta'] ?? 0) !== $DEMLER_STATION && !in_array((int) $row['id'], $eligible, true)) {
        $other_assigned[] = (int) $row['id'];
    }
}
echo "other D749 assignments left untouched: " . count($other_assigned) . "\n";

if ($DRY) {
    foreach ($eligible as $cid) {
        $r = mysqli_fetch_assoc(mysqli_query(
            $dbc,
            'SELECT c.reporting_marks, co.waybill_number, c.status
             FROM cars c LEFT JOIN car_orders co ON co.car = c.id
             WHERE c.id = ' . (int) $cid . ' LIMIT 1'
        ));
        echo "  would assign " . ($r['reporting_marks'] ?? '?') . ' ' . ($r['waybill_number'] ?? '') . ' ' . ($r['status'] ?? '') . "\n";
    }
    echo "dry-run complete — no writes\n";
    exit(0);
}

$assigned = warm_start_assign_cars_to_job($dbc, $JOB, $eligible);
echo "assigned=$assigned\n";

// --- 2. Generate phase_08 without pulling non-Demmler D749 cars --------------
$phase_dir = session_phase_output_dir($N, $PHASE, $root);
session_ensure_writable_dir($phase_dir);

// Park other D749 assignments so stock capture is Demmler-only, then restore.
foreach ($other_assigned as $cid) {
    mysqli_query($dbc, 'UPDATE cars SET handled_by_job_id = 0 WHERE id = ' . (int) $cid);
}

$config = session_merge_runtime_config([]);
$written = master_sw_generate_for_jobs($dbc, [$JOB], $phase_dir, $config, [
    'format' => 'all',
    'session_override' => (string) $N,
    'title' => $TITLE,
    'info' => $INFO,
]);

foreach ($other_assigned as $cid) {
    mysqli_query(
        $dbc,
        'UPDATE cars SET handled_by_job_id = ' . (int) $job_id . '
         WHERE id = ' . (int) $cid . ' AND handled_by_job_id = 0'
    );
}

$cache = master_sw_load_sections_payload($phase_dir, $JOB, $N);
$car_count = 0;
foreach (($cache['sections'] ?? []) as $sec) {
    $car_count += count($sec['cars'] ?? []);
}
echo "generated phase_$PHASE cars=$car_count written_jobs=" . count($written) . "\n";
if ($car_count < 1) {
    fwrite(STDERR, "Generate produced no cars — aborting before manifest change\n");
    exit(1);
}

// Ensure title/info are frozen on the master cache (not "Supplemental").
master_sw_save_sections_cache($phase_dir, $JOB, $N, $cache['sections'], [
    'title' => $TITLE,
    'info' => $INFO,
]);
// Re-render headers from corrected cache.
master_sw_generate_for_jobs($dbc, [$JOB], $phase_dir, $config, [
    'format' => 'all',
    'render_only' => true,
    'session_override' => (string) $N,
    'title' => $TITLE,
    'info' => $INFO,
]);

// Strip any leftover phase_08/D749-SUPP or phase_08/waybills side debris.
foreach (['D749-SUPP'] as $junk) {
    $junk_path = rtrim($phase_dir, '/') . '/' . $junk;
    if (is_dir($junk_path)) {
        session_rrmdir($junk_path);
        echo "removed $junk\n";
    }
}

// --- 3. Manifest register ---------------------------------------------------
$manifest = session_load_manifest($N, $root);
$phases = [];
foreach ($manifest['phases'] ?? [] as $p) {
    if ((int) ($p['phase'] ?? 0) === $PHASE) {
        continue; // replace existing phase 8
    }
    $phases[] = $p;
}
$manifest['phases'] = $phases;
session_register_phase($manifest, $PHASE, [
    'step' => 0,
    'jobs' => [$JOB],
    'format' => 'all',
    'styles' => master_sw_all_styles(),
    'label' => 'Generate Switch Lists D749 (all)— D749 · Demmler',
    'title' => $TITLE,
    'info' => $INFO,
    'output' => $phase_dir,
]);
session_save_manifest($N, $manifest, $root);
echo "manifest: registered phase $PHASE (D749 / Demmler)\n";

// --- 4. Waybills into session store -----------------------------------------
$wb = session_generate_waybills_for_phase($dbc, $N, $PHASE, $root);
echo "waybills captured for phase: " . (int) ($wb['count'] ?? 0)
    . " session_total=" . (int) ($wb['session_count'] ?? 0) . "\n";

// Drop stale print-all bundles so overview rebuilds them from the new manifest.
$session_dir = session_dir_for($N, $root);
foreach (glob($session_dir . '/print_all*.html') ?: [] as $f) {
    @unlink($f);
}
foreach (glob($session_dir . '/train_' . $JOB . '.print_all*.html') ?: [] as $f) {
    @unlink($f);
}
echo "cleared stale print-all bundles\n";

// --- 5. Complete the leg (pickup + final-dest setout) -----------------------
$picked = 0;
$set_out = 0;
if (!$NO_OPS) {
    $picked = warm_start_pickup_job_at_station($dbc, $JOB, $DEMLER_STATION);
    $set_out = warm_start_setout_all_job_train($dbc, $JOB);
    echo "ops: picked_up=$picked set_out=$set_out\n";
}

// --- Verify -----------------------------------------------------------------
echo "--- result ---\n";
$in = implode(',', array_map('intval', $eligible));
$rs = mysqli_query(
    $dbc,
    "SELECT c.reporting_marks, c.status, c.handled_by_job_id, c.current_location_id,
            loc.code AS loc, co.waybill_number
     FROM cars c
     LEFT JOIN locations loc ON loc.id = c.current_location_id
     LEFT JOIN car_orders co ON co.car = c.id
     WHERE c.id IN ($in)
     ORDER BY co.waybill_number"
);
while ($rs && ($r = mysqli_fetch_assoc($rs))) {
    echo sprintf(
        "  %-12s wb=%-8s status=%-8s job=%s loc=%s\n",
        $r['reporting_marks'],
        $r['waybill_number'] ?? '',
        $r['status'],
        $r['handled_by_job_id'],
        ((int) $r['current_location_id'] === 0 ? 'IN-TRAIN' : ($r['loc'] ?? '?'))
    );
}
echo "switchlist: so.php?f=session_{$N}/phase_08/{$JOB}/phase_01_full.html\n";
echo "print_all:  so.php?f=session_{$N}/phase_08/{$JOB}/print_all.html\n";
echo "overview:   session_overview.php?session={$N}\n";
echo "OK\n";
