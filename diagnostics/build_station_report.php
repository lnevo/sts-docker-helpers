<?php
/**
 * Build start-of-session station reports into session_N/station_report.html.
 * Prefer the dynamic path (so.php builds on first request); use this to warm
 * the cache for every session after a bulk import or migration.
 *
 *   docker exec -u www-data <web> php /tmp/build_station_report.php [N|all]
 *
 * Omit N or pass "all" to build every session directory on disk.
 */
error_reporting(E_ERROR | E_PARSE);

$sts = '/var/www/html/sts';
require_once $sts . '/open_db.php';
require_once $sts . '/session_helpers.php';

$arg = $argv[1] ?? 'all';
$root = session_web_root();
$dbc = open_db();

$sessions = [];
if ($arg === 'all' || $arg === '') {
    foreach (glob($root . '/session_*', GLOB_ONLYDIR) ?: [] as $d) {
        if (preg_match('#/session_(\d+)$#', $d, $m)) {
            $sessions[] = (int) $m[1];
        }
    }
    sort($sessions, SORT_NUMERIC);
} else {
    $sessions = [max(1, (int) $arg)];
}

if ($sessions === []) {
    fwrite(STDERR, "No session directories found under {$root}\n");
    exit(1);
}

$built = 0;
$failed = [];
foreach ($sessions as $sn) {
    $rel = session_build_station_report($dbc, $sn, $root);
    if ($rel === null) {
        $failed[] = $sn;
        echo "FAIL session {$sn}\n";
        continue;
    }
    $built++;
    echo "Wrote {$rel}\n";
}

mysqli_close($dbc);
echo "built: {$built}, failed: " . count($failed) . "\n";
exit($failed === [] ? 0 : 1);
