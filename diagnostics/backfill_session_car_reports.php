<?php
/**
 * Backfill catalog station/wheel report phases for one session snapshot.
 *
 * Usage (container, after restoring the matching DB dump):
 *   php backfill_session_car_reports.php clear 1 2
 *   php backfill_session_car_reports.php snap 1 "Starting"
 *   php backfill_session_car_reports.php snap 1 "End of session"
 *   php backfill_session_car_reports.php snap 2 "Starting"
 *   php backfill_session_car_reports.php snap 2 "End of session"
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

chdir('/var/www/html/sts');
require_once 'open_db.php';
require_once 'session_helpers.php';

$cmd = $argv[1] ?? '';
if ($cmd === 'clear') {
    $sessions = array_slice($argv, 2);
    if ($sessions === []) {
        fwrite(STDERR, "Usage: clear <session> [session...]\n");
        exit(1);
    }
    $root = session_web_root();
    foreach ($sessions as $session) {
        $session = (int) $session;
        $dir = session_dir_for($session, $root);
        if (!is_dir($dir)) {
            echo "skip session_{$session} (missing)\n";
            continue;
        }
        $manifest = session_load_manifest($session, $root);
        $manifest['station_reports'] = [];
        $manifest['wheel_reports'] = [];
        session_save_manifest($session, $manifest, $root);
        foreach (glob($dir . '/station_report*.html') ?: [] as $f) {
            @unlink($f);
        }
        foreach (glob($dir . '/wheel_report*.html') ?: [] as $f) {
            @unlink($f);
        }
        echo "cleared session_{$session}\n";
    }
    exit(0);
}

if ($cmd === 'snap') {
    $session = (int) ($argv[2] ?? 0);
    $info = (string) ($argv[3] ?? '');
    if ($session < 1) {
        fwrite(STDERR, "Usage: snap <session> <info>\n");
        exit(1);
    }
    $dbc = open_db();
    $root = session_web_root();
    $cur = (int) (mysqli_fetch_row(mysqli_query(
        $dbc,
        "SELECT setting_value FROM settings WHERE setting_name='session_nbr'"
    ))[0] ?? 0);
    $st = session_generate_station_report_phase($dbc, $session, $info, $root);
    $wh = session_generate_wheel_report_phase($dbc, $session, $info, $root);
    echo sprintf(
        "session_%d [%s] (db session=%d) station=%s wheel=%s\n",
        $session,
        $info !== '' ? $info : 'Phase',
        $cur,
        $st['total'] ?? 'fail',
        $wh['total'] ?? 'fail'
    );
    if ($st === null || $wh === null) {
        exit(2);
    }
    exit(0);
}

fwrite(STDERR, "Usage: clear|snap ...\n");
exit(1);
