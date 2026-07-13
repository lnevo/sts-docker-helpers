<?php
/**
 * Build start-of-session station + wheel reports into
 * session_N/station_report.html and session_N/wheel_report.html.
 * Prefer the dynamic path (so.php builds on first request); use this to warm
 * the cache for every session after a bulk import or migration, or to re-bake
 * every cached report after a report template change (staleness only tracks the
 * session's switch-list archives, not this code).
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
    foreach (['station' => 'session_build_station_report', 'wheel' => 'session_build_wheel_report'] as $kind => $fn) {
        $rel = $fn($dbc, $sn, $root);
        if ($rel === null) {
            $failed[] = "{$sn}/{$kind}";
            echo "FAIL session {$sn} ({$kind})\n";
            continue;
        }
        $built++;
        echo "Wrote {$rel}\n";
    }
}

mysqli_close($dbc);
echo "built: {$built}, failed: " . count($failed) . "\n";
exit($failed === [] ? 0 : 1);
