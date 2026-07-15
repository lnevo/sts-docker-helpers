<?php
/**
 * add_nvl_nextday_phase.php <session>
 *
 * Add or refresh an NVL "Next Day" phase for a session from cars currently
 * in-train on NVL (handled_by_job_id + current_location_id=0). Used to backfill
 * session 2 archives after overnight NVL Next Day was added to the recipe.
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

$session = max(1, (int) ($argv[1] ?? 2));

chdir('/var/www/html/sts');
require_once 'open_db.php';
require_once 'session_helpers.php';
require_once 'master_switchlist_helpers.php';

$dbc = open_db();
$root = session_web_root();
$dir = session_dir_for($session, $root);
if (!is_dir($dir)) {
    fwrite(STDERR, "No session_$session directory\n");
    exit(1);
}

$manifest = session_load_manifest($session, $root) ?: [
    'session' => (string) $session,
    'phases' => [],
    'jobs' => [],
];

// Drop any existing NVL Next Day phase entries (files kept until rewrite).
$phases = [];
foreach ($manifest['phases'] ?? [] as $ph) {
    $jobs = $ph['jobs'] ?? [];
    $info = (string) ($ph['info'] ?? '');
    if (in_array('NVL', $jobs, true) && $info === 'Next Day') {
        continue;
    }
    $phases[] = $ph;
}
$manifest['phases'] = $phases;

$phase_num = 1;
foreach ($manifest['phases'] as $ph) {
    $phase_num = max($phase_num, (int) ($ph['phase'] ?? 0) + 1);
}
// Prefer appending after highest existing phase folder.
foreach (glob($dir . '/phase_*') ?: [] as $p) {
    if (preg_match('#phase_(\d+)$#', $p, $m)) {
        $phase_num = max($phase_num, (int) $m[1] + 1);
    }
}

$phase_dir = session_phase_output_dir($session, $phase_num, $root);
session_ensure_writable_dir($phase_dir);

$written = master_sw_generate_for_jobs($dbc, ['NVL'], $phase_dir, [], [
    'format' => 'all',
    'title' => 'NVL',
    'info' => 'Next Day',
    'session_override' => $session,
]);

$cars = 0;
$master = $phase_dir . '/NVL_session_' . $session . '_master.json';
if (is_file($master)) {
    $data = json_decode(file_get_contents($master), true);
    foreach ($data['sections'] ?? [] as $sec) {
        $cars += count($sec['cars'] ?? []);
    }
}

if ($cars < 1) {
    fwrite(STDERR, "NVL Next Day generated 0 cars — aborting phase register\n");
    exit(1);
}

session_register_phase($manifest, $phase_num, [
    'step' => null,
    'jobs' => ['NVL'],
    'format' => 'all',
    'styles' => ['mobile', 'half', 'full', 'dmp', 'wo', 'x2010'],
    'label' => 'Generate Switch Lists NVL (all)— NVL · Next Day',
    'title' => 'NVL',
    'info' => 'Next Day',
    'car_count' => $cars,
]);
session_save_manifest($session, $manifest, $root);
session_build_switchlist_print_all($dbc, $session, $root);
session_build_switchlist_train_print_all($dbc, $session, 'NVL', $root);

echo "session_$session NVL Next Day phase_$phase_num cars=$cars\n";
echo "written=" . json_encode($written) . "\n";
