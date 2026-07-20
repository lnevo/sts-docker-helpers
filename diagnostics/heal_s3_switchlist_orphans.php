<?php
/**
 * heal_s3_switchlist_orphans.php [--apply]
 *
 * After restoring end-of-session-3 (hart_session3_locked), clear Ordered cars
 * that never appeared on any session_3 switch-list master JSON.
 *
 * Dry-run by default. --apply deletes those car_orders and sets status Empty.
 * Does not touch session_3 switchlist archives.
 */
error_reporting(E_ERROR | E_PARSE);
chdir('/var/www/html/sts');
require 'open_db.php';
require 'session_helpers.php';

$dbc = open_db();
$apply = in_array('--apply', $argv, true);

$session = (int) mysqli_fetch_row(mysqli_query(
    $dbc,
    'SELECT setting_value FROM settings WHERE setting_name = "session_nbr"'
))[0];
echo "session_nbr={$session}\n";

$root = session_web_root();
$dir = session_dir_for(3, $root);
if (!is_dir($dir)) {
    fwrite(STDERR, "No session_3 archive at {$dir}\n");
    exit(1);
}

$on_list = [];
foreach (glob($dir . '/phase_*/*_master.json') ?: [] as $file) {
    $json = json_decode((string) file_get_contents($file), true);
    if (!is_array($json)) {
        continue;
    }
    $blob = json_encode($json);
    if (preg_match_all('/"reporting_marks"\s*:\s*"([^"]+)"/', $blob, $m)) {
        foreach ($m[1] as $marks) {
            $on_list[$marks] = true;
        }
    }
}
echo 'switchlist cars: ' . count($on_list) . "\n";

$rs = mysqli_query(
    $dbc,
    'SELECT c.id, c.reporting_marks, c.status, c.handled_by_job_id, c.current_location_id,
            l.code AS loc, o.waybill_number, s.code AS ship
     FROM cars c
     LEFT JOIN locations l ON l.id = c.current_location_id
     LEFT JOIN car_orders o ON o.car = c.id
     LEFT JOIN shipments s ON s.id = o.shipment
     WHERE c.status = "Ordered"
     ORDER BY c.reporting_marks'
);

$orphans = [];
$kept = 0;
while ($row = mysqli_fetch_assoc($rs)) {
    if (!isset($on_list[$row['reporting_marks']])) {
        $orphans[] = $row;
    } else {
        $kept++;
    }
}

echo "Ordered on a s3 switchlist: {$kept}\n";
echo 'Ordered orphans (not on any s3 switchlist): ' . count($orphans) . "\n";
foreach ($orphans as $o) {
    echo sprintf(
        "  ORPHAN %s loc=%s job=%s wb=%s %s\n",
        $o['reporting_marks'],
        $o['loc'] ?: '(train)',
        $o['handled_by_job_id'],
        $o['waybill_number'] ?: '—',
        $o['ship'] ?: '—'
    );
}

if (!$apply) {
    echo "Dry-run only. Re-run with --apply to heal.\n";
    exit(0);
}

$south_id = 0;
$south = mysqli_fetch_row(mysqli_query($dbc, 'SELECT id FROM locations WHERE code = "SOUTH-YARD" LIMIT 1'));
if ($south) {
    $south_id = (int) $south[0];
}

$healed = 0;
foreach ($orphans as $o) {
    $id = (int) $o['id'];
    mysqli_query($dbc, 'DELETE FROM car_orders WHERE car = "' . $id . '"');
    $sql = 'UPDATE cars
            SET status = "Empty",
                handled_by_job_id = 0,
                position = 0
            WHERE id = "' . $id . '"';
    mysqli_query($dbc, $sql);
    if ((int) $o['current_location_id'] === 0 && $south_id > 0) {
        mysqli_query(
            $dbc,
            'UPDATE cars SET current_location_id = "' . $south_id . '" WHERE id = "' . $id . '"'
        );
    }
    $healed++;
    echo "  healed {$o['reporting_marks']}\n";
}

echo "Healed {$healed} orphan(s).\n";
$rs = mysqli_query($dbc, 'SELECT status, COUNT(*) c FROM cars GROUP BY status ORDER BY status');
while ($r = mysqli_fetch_assoc($rs)) {
    echo "status {$r['status']}={$r['c']}\n";
}
