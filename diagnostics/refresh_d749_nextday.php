<?php
/**
 * refresh_d749_nextday.php <session>
 *
 * Rebuild D749 "Next Day" switchlist paper for a session from cars currently
 * in-train on D749. Prefer overwriting an existing Next Day phase folder so
 * phase numbers stay stable (session 2 bookend → session N+1 Starting).
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

$manifest = session_load_manifest($session, $root);
if (!is_array($manifest)) {
    fwrite(STDERR, "No manifest for session_$session\n");
    exit(1);
}

$phase_num = null;
$phase_idx = null;
foreach ($manifest['phases'] ?? [] as $i => $ph) {
    $jobs = $ph['jobs'] ?? [];
    $info = (string) ($ph['info'] ?? '');
    if (in_array('D749', $jobs, true) && $info === 'Next Day') {
        $phase_num = (int) ($ph['phase'] ?? 0);
        $phase_idx = $i;
        break;
    }
}

if ($phase_num === null || $phase_num < 1) {
    fwrite(STDERR, "No existing D749 Next Day phase in session_$session manifest\n");
    exit(1);
}

$phase_dir = session_phase_output_dir($session, $phase_num, $root);
session_ensure_writable_dir($phase_dir);

// Clear prior D749 HTML/JSON in this phase so regenerate is clean.
foreach (glob($phase_dir . '/D749*') ?: [] as $path) {
    if (is_file($path)) {
        @unlink($path);
    }
}
$job_dir = $phase_dir . '/D749';
if (is_dir($job_dir)) {
    foreach (glob($job_dir . '/*') ?: [] as $path) {
        if (is_file($path)) {
            @unlink($path);
        }
    }
}

$written = master_sw_generate_for_jobs($dbc, ['D749'], $phase_dir, [], [
    'format' => 'all',
    'title' => 'D749',
    'info' => 'Next Day',
    'session_override' => $session,
]);

$cars = 0;
$marks = [];
$master = $phase_dir . '/D749_session_' . $session . '_master.json';
if (is_file($master)) {
    $data = json_decode(file_get_contents($master), true);
    foreach ($data['sections'] ?? [] as $sec) {
        foreach ($sec['cars'] ?? [] as $c) {
            $cars++;
            $m = trim((string) ($c['reporting_marks'] ?? $c['marks'] ?? ''));
            if ($m !== '') {
                $marks[] = $m;
            }
        }
    }
}

if ($cars < 1) {
    fwrite(STDERR, "D749 Next Day generated 0 cars — aborting\n");
    exit(1);
}

sort($marks);
$manifest['phases'][$phase_idx]['car_count'] = $cars;
$manifest['phases'][$phase_idx]['output'] = $phase_dir;
$manifest['phases'][$phase_idx]['label'] = 'Generate Switch Lists D749 (all)— D749 · Next Day';
session_save_manifest($session, $manifest, $root);
session_build_switchlist_print_all($dbc, $session, $root);
session_build_switchlist_train_print_all($dbc, $session, 'D749', $root);

echo "session_$session D749 Next Day phase_$phase_num cars=$cars\n";
echo "marks=" . implode(',', $marks) . "\n";
echo "written=" . json_encode($written) . "\n";
