<?php
chdir('/var/www/html/sts');
require_once 'open_db.php';
$dbc = open_db();
$s = mysqli_fetch_assoc(mysqli_query($dbc, "SELECT setting_value FROM settings WHERE setting_name='session_nbr'"));
echo 'session=' . ($s['setting_value'] ?? '?') . "\n";

$q = mysqli_query($dbc, 'SELECT Id, reporting_marks, status, current_location_id, handled_by_job_id FROM cars WHERE current_location_id = 0 ORDER BY reporting_marks');
if (!$q) {
    fwrite(STDERR, 'query failed: ' . mysqli_error($dbc) . "\n");
    exit(1);
}
echo "in_train:\n";
$n = 0;
while ($row = mysqli_fetch_assoc($q)) {
    $n++;
    echo "  {$row['reporting_marks']} status={$row['status']} job_id={$row['handled_by_job_id']}\n";
}
echo "in_train_count={$n}\n";

$jobs = mysqli_query($dbc, "SELECT id, name FROM jobs WHERE name='CK1'");
while ($j = mysqli_fetch_assoc($jobs)) {
    echo "CK1 job_id={$j['id']}\n";
    $cq = mysqli_query(
        $dbc,
        'SELECT reporting_marks, status, current_location_id FROM cars WHERE handled_by_job_id='
        . (int) $j['id'] . ' ORDER BY reporting_marks'
    );
    while ($c = mysqli_fetch_assoc($cq)) {
        echo "  {$c['reporting_marks']} status={$c['status']} loc={$c['current_location_id']}\n";
    }
}
echo "track_scale=http://localhost:8980/sts/plugins/track_scale/track_scale.php\n";
