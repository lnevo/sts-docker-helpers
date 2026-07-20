<?php
/**
 * regen_session_switchlists_from_masters.php
 *
 * Rebuild session switchlist HTML from on-disk *_master.json (locked car
 * consists) using current locations.color. Does not re-simulate traffic.
 *
 * Usage (in container):
 *   php regen_session_switchlists_from_masters.php [session|1-3]
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

chdir('/var/www/html/sts');
require_once 'open_db.php';
require_once 'session_helpers.php';
require_once 'master_switchlist_helpers.php';

$arg = trim((string) ($argv[1] ?? '1-3'));
if (preg_match('/^(\d+)\s*-\s*(\d+)$/', $arg, $m)) {
    $sessions = range((int) $m[1], (int) $m[2]);
} elseif (ctype_digit($arg)) {
    $sessions = [(int) $arg];
} else {
    fwrite(STDERR, "Usage: php regen_session_switchlists_from_masters.php [session|from-to]\n");
    exit(1);
}

$dbc = open_db();
$root = session_web_root();

foreach ($sessions as $session) {
    $manifest = session_load_manifest($session, $root);
    if (!$manifest) {
        fwrite(STDERR, "no manifest for session {$session}\n");
        exit(1);
    }

    echo "==> session {$session}\n";
    foreach ($manifest['phases'] as $ph) {
        $num = (int) ($ph['phase'] ?? 0);
        $jobs = $ph['jobs'] ?? [];
        $job = $jobs[0] ?? '';
        if ($num < 1 || $job === '') {
            continue;
        }
        $phase_dir = session_phase_output_dir($session, $num, $root);
        $masters = glob($phase_dir . '/*_master.json') ?: [];
        if (!$masters) {
            echo "  skip phase {$num} — no master\n";
            continue;
        }
        $master = $masters[0];
        $data = json_decode((string) file_get_contents($master), true);
        if (!is_array($data)) {
            echo "  skip phase {$num} — bad master JSON\n";
            continue;
        }
        $sections = $data['sections'] ?? [];
        $job_name = $data['job'] ?? $job;
        $opts = [
            'format' => $ph['format'] ?? 'all',
            'title' => $data['title'] ?? ($ph['title'] ?? $job_name),
            'info' => $data['info'] ?? ($ph['info'] ?? ''),
            'session_override' => $session,
        ];
        $car_count = 0;
        foreach ($sections as $s) {
            $car_count += count($s['cars'] ?? []);
        }
        $info = $opts['info'] !== '' ? $opts['info'] : '(none)';
        echo "  regen phase_{$num} {$job_name} info={$info} cars={$car_count}\n";
        master_sw_generate_phased($dbc, $job_name, $sections, $phase_dir, $session, $opts);
        $data['title'] = $opts['title'];
        $data['info'] = $opts['info'];
        file_put_contents(
            $master,
            json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n"
        );
    }

    session_save_manifest($session, $manifest, $root);
    session_build_switchlist_print_all($dbc, $session, $root);
    foreach (['D749', 'CK1', 'NVL', 'STG-DEMMLER', 'STG-SCULLY'] as $job) {
        session_build_switchlist_train_print_all($dbc, $session, $job, $root);
        echo "  train print_all {$job} ok\n";
    }
}

echo "done\n";
