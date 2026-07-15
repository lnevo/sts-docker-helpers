<?php
/**
 * From session-2 end: run hart_session steps 4–23 so CK1 is loaded
 * and the track scale is calibrated; stop before automated weigh (24).
 */
chdir('/var/www/html/sts');
require_once 'open_db.php';
require_once 'operational_steps_catalog.php';
require_once 'session_simulator_helpers.php';

$dbc = open_db();
$before = mysqli_fetch_assoc(mysqli_query(
    $dbc,
    "SELECT setting_value FROM settings WHERE setting_name='session_nbr'"
))['setting_value'] ?? '?';
echo "session_before={$before}\n";

$dir = operational_steps_editor_dir();
$recipe = operational_steps_load_recipe($dir, 'hart_session.workflow.json');
$result = session_simulator_run($dbc, $recipe, [
    'start_step' => 4,
    'stop_step' => 23,
    'skip_steps' => '',
    'session_count' => 1,
]);

$after = mysqli_fetch_assoc(mysqli_query(
    $dbc,
    "SELECT setting_value FROM settings WHERE setting_name='session_nbr'"
))['setting_value'] ?? '?';

echo 'ok=' . (!empty($result['ok']) ? '1' : '0') . "\n";
echo "session_after={$after}\n";
echo 'start=' . ($result['start_step'] ?? '?')
    . ' stop=' . ($result['stop_step'] ?? '?') . "\n";

if (!empty($result['warnings'])) {
    echo "warnings:\n  " . implode("\n  ", $result['warnings']) . "\n";
}
if (!empty($result['summary'])) {
    echo "summary:\n  " . implode("\n  ", array_slice($result['summary'], 0, 50)) . "\n";
}

$q = mysqli_query($dbc, "
    SELECT c.reporting_marks, c.status, c.car_code, c.current_location_id,
           COALESCE(l.station, 'IN-TRAIN') AS station,
           COALESCE(l.code, '') AS loc
    FROM cars c
    LEFT JOIN locations l ON l.id = c.current_location_id
    WHERE c.job = 'CK1'
    ORDER BY c.reporting_marks
");
echo "CK1 cars:\n";
$total = 0;
$in_train = 0;
while ($row = mysqli_fetch_assoc($q)) {
    $total++;
    $loc = (int) $row['current_location_id'];
    if ($loc === 0) {
        $in_train++;
    }
    echo "  {$row['reporting_marks']} status={$row['status']} loc_id={$loc}"
        . " {$row['station']} {$row['loc']}\n";
}
echo "CK1_total={$total} in_train={$in_train}\n";

$log = $result['cycles'][0]['log'] ?? [];
$interesting = [];
foreach ($log as $entry) {
    $fid = $entry['action'] ?? '';
    if (in_array($fid, [
        'increment_session', 'auto_assign_locals', 'pick_up_cars', 'set_out_cars',
        'calibrate_track_scale', 'track_scale', 'generate_switchlists', 'fill_orders',
        'generate_orders', 'error',
    ], true) || !empty($entry['error'])) {
        $interesting[] = ($entry['step'] ?? '?') . ':' . $fid
            . (!empty($entry['error']) ? (' ERR=' . $entry['error']) : '');
    }
}
echo "key_log:\n  " . implode("\n  ", $interesting) . "\n";

mysqli_close($dbc);
exit(!empty($result['ok']) ? 0 : 1);
