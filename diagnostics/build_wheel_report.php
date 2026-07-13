<?php
/**
 * Build end-of-session wheel reports into session_N/wheel_report.html.
 *
 * Historical sessions (session number < current DB session) are reconstructed
 * from switch-list archives (in-train cars + STG-DEMMLER D749 inbound staging).
 * The current DB session uses a live query matching wheel_report.php.
 *
 * Use this after a bulk import, a report-template change, or when re-baking
 * sessions 1–N after archive reconstruction logic changes. Staleness checks
 * only watch switch-list archives, not this code.
 *
 *   docker exec -u www-data <web> php /tmp/build_wheel_report.php [N|all|historical]
 *
 *   historical — all sessions strictly before the current DB session (typical
 *                workaround pass for archived sessions 1–10 when current is 11)
 *   all        — every session directory on disk (includes live current session)
 *   N          — one session
 */
error_reporting(E_ERROR | E_PARSE);

$sts = '/var/www/html/sts';
require_once $sts . '/open_db.php';
require_once $sts . '/session_helpers.php';

$arg = $argv[1] ?? 'all';
$root = session_web_root();
$dbc = open_db();
$current = (int) session_get_db_session($dbc);

$sessions = [];
if ($arg === 'all' || $arg === '') {
    foreach (glob($root . '/session_*', GLOB_ONLYDIR) ?: [] as $d) {
        if (preg_match('#/session_(\d+)$#', $d, $m)) {
            $sessions[] = (int) $m[1];
        }
    }
    sort($sessions, SORT_NUMERIC);
} elseif ($arg === 'historical') {
    foreach (glob($root . '/session_*', GLOB_ONLYDIR) ?: [] as $d) {
        if (preg_match('#/session_(\d+)$#', $d, $m)) {
            $sn = (int) $m[1];
            if ($sn < $current) {
                $sessions[] = $sn;
            }
        }
    }
    sort($sessions, SORT_NUMERIC);
} else {
    $sessions = [max(1, (int) $arg)];
}

if ($sessions === []) {
    fwrite(STDERR, "No session directories matched (arg={$arg}, current DB session={$current})\n");
    exit(1);
}

$built = 0;
$failed = [];
foreach ($sessions as $sn) {
    $rel = session_build_wheel_report($dbc, $sn, $root);
    if ($rel === null) {
        $failed[] = $sn;
        echo "FAIL session {$sn}\n";
        continue;
    }
    $built++;
    $mode = ($sn === $current) ? 'live' : 'archived';
    echo "Wrote {$rel} ({$mode})\n";
}

mysqli_close($dbc);
echo "built: {$built}, failed: " . count($failed) . " (current DB session={$current})\n";
exit($failed === [] ? 0 : 1);
