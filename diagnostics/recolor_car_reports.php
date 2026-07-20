<?php
/**
 * Patch cached station/wheel report HTML with destination location color swatches.
 * Preserves snapshot car rows; only updates Action / Destination cell styles.
 *
 *   php recolor_car_reports.php [N|all]
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

error_reporting(E_ERROR | E_PARSE);
chdir('/var/www/html/sts');
require_once 'open_db.php';
require_once 'session_helpers.php';

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

$station = 0;
$wheel = 0;
foreach ($sessions as $sn) {
    $c = session_car_report_recolor_session($dbc, $sn, $root);
    $station += (int) $c['station'];
    $wheel += (int) $c['wheel'];
    echo "session_{$sn}: station={$c['station']} wheel={$c['wheel']}\n";
}

mysqli_close($dbc);
echo "recolored files: station={$station} wheel={$wheel}\n";
exit(0);
