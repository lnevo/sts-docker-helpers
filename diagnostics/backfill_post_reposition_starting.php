<?php
/**
 * Rebuild "Starting" station/wheel reports for one session at the new workflow
 * point (after fill + reposition), without replaying trains/switchlists.
 *
 * Assumes live DB is currently at end of session N-1. Sets session_nbr=N, runs
 * hart_session workflow steps from load_unload through reposition_empties
 * (honoring coke if_then gates), then snaps Starting into session_N.
 *
 * Usage (in container):
 *   php backfill_post_reposition_starting.php <session> [workflow_file]
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

$session = (int) ($argv[1] ?? 0);
$workflow = trim((string) ($argv[2] ?? 'hart_session.workflow.json'));
if ($session < 1) {
    fwrite(STDERR, "Usage: backfill_post_reposition_starting.php <session> [workflow_file]\n");
    exit(1);
}

chdir('/var/www/html/sts');
require_once 'open_db.php';
require_once 'session_helpers.php';
require_once 'operational_steps_catalog.php';
require_once 'warm_start_helpers.php';

$dbc = open_db();
$root = session_web_root();

mysqli_query(
    $dbc,
    "UPDATE settings SET setting_value='" . (int) $session
        . "' WHERE setting_name='session_nbr'"
);

$cur = (int) (mysqli_fetch_row(mysqli_query(
    $dbc,
    "SELECT setting_value FROM settings WHERE setting_name='session_nbr'"
))[0] ?? 0);
echo "session={$session} db_session_nbr={$cur}\n";

$editor = operational_steps_editor_dir();
$path = operational_steps_workflow_path($editor, $workflow);
if (!is_file($path)) {
    fwrite(STDERR, "Missing workflow {$path}\n");
    exit(2);
}
$recipe = operational_steps_load_recipe_from_json_file($path);
$steps = $recipe['steps'] ?? [];
if ($steps === []) {
    fwrite(STDERR, "Workflow has no steps\n");
    exit(2);
}

$from = null;
$to = null;
foreach ($steps as $i => $step) {
    $fid = $step['function'] ?? '';
    $n = $i + 1;
    if ($fid === 'load_unload' && $from === null) {
        $from = $n;
    }
    if ($fid === 'reposition_empties') {
        $to = $n;
    }
}
if ($from === null || $to === null || $to < $from) {
    fwrite(STDERR, "Could not locate load_unload..reposition_empties in workflow\n");
    exit(2);
}

echo "run recipe steps {$from}–{$to} (load_unload → reposition)\n";
$run = session_run_recipe($dbc, $recipe, [
    'from_step' => $from,
    'to_step' => $to,
    'reset_output' => false,
]);
$summary = [
    'filled' => 0,
    'generated' => 0,
    'repositioned' => 0,
    'load_unload' => 0,
];
foreach (($run['log'] ?? []) as $row) {
    foreach (array_keys($summary) as $k) {
        if (isset($row[$k])) {
            $summary[$k] += (int) $row[$k];
        }
    }
}
echo sprintf(
    "ops generated=%d filled=%d repo=%d load_unload=%d\n",
    $summary['generated'],
    $summary['filled'],
    $summary['repositioned'],
    $summary['load_unload']
);

$st = session_generate_station_report_phase($dbc, $session, 'Starting', $root);
$wh = session_generate_wheel_report_phase($dbc, $session, 'Starting', $root);
if ($st === null || $wh === null) {
    fwrite(STDERR, "Failed to snap Starting for session {$session}\n");
    exit(2);
}

// Collapse duplicate Info labels (old Starting + new Starting → keep latest),
// then force bookend order: Pre → Starting → End of session.
$manifest = session_load_manifest($session, $root);
session_compact_car_reports($manifest, $session, $root);
$bookend_order = ['Pre' => 0, 'Starting' => 1, 'End of session' => 2];
foreach (['station_reports', 'wheel_reports'] as $key) {
    $rows = is_array($manifest[$key] ?? null) ? $manifest[$key] : [];
    usort($rows, static function ($a, $b) use ($bookend_order) {
        $ia = $bookend_order[trim((string) ($a['info'] ?? ''))] ?? 50;
        $ib = $bookend_order[trim((string) ($b['info'] ?? ''))] ?? 50;
        if ($ia !== $ib) {
            return $ia <=> $ib;
        }
        return ((int) ($a['phase'] ?? 0)) <=> ((int) ($b['phase'] ?? 0));
    });
    $manifest[$key] = array_values($rows);
}
session_save_manifest($session, $manifest, $root);
session_car_report_refresh_phase_navs($session, 'station', $root);
session_car_report_refresh_phase_navs($session, 'wheel', $root);

echo sprintf(
    "Starting station=%s wheel=%s\n",
    $st['total'] ?? '?',
    $wh['total'] ?? '?'
);

$phases = [];
foreach (['station_reports', 'wheel_reports'] as $key) {
    $phases[$key] = array_map(
        static fn($r) => ($r['info'] ?? '') . ':' . ($r['file'] ?? ''),
        $manifest[$key] ?? []
    );
}
echo 'manifest station=' . implode(', ', $phases['station_reports']) . "\n";
echo 'manifest wheel=' . implode(', ', $phases['wheel_reports']) . "\n";

exit(0);
