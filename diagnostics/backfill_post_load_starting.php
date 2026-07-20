<?php
/**
 * Rebuild car-report bookends for one session without replaying the recipe:
 *   Pre (existing Starting renamed on disk) → load_unload → Starting → End.
 *
 * Host must already have renamed Starting→Pre and removed End phases for this
 * session. This script assumes the live DB is currently at the *start* of the
 * target session (end of N-1 restored, session_nbr = N).
 *
 * Usage (in container):
 *   php backfill_post_load_starting.php <session>
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

$session = (int) ($argv[1] ?? 0);
if ($session < 1) {
    fwrite(STDERR, "Usage: backfill_post_load_starting.php <session>\n");
    exit(1);
}

chdir('/var/www/html/sts');
require_once 'open_db.php';
require_once 'session_helpers.php';
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

$updated = (int) warm_start_load_unload($dbc, 1.0);
echo "load_unload updated={$updated}\n";

$st = session_generate_station_report_phase($dbc, $session, 'Starting', $root);
$wh = session_generate_wheel_report_phase($dbc, $session, 'Starting', $root);
if ($st === null || $wh === null) {
    fwrite(STDERR, "Failed to snap Starting for session {$session}\n");
    exit(2);
}
echo sprintf(
    "Starting station=%s wheel=%s\n",
    $st['total'] ?? '?',
    $wh['total'] ?? '?'
);

exit(0);
