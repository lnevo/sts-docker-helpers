<?php
error_reporting(E_ERROR | E_PARSE);
chdir('/var/www/html/sts');
require 'credentials.php';
$d = mysqli_connect($server_name, $user_name, $password, $db_name);

echo "=== orphan car (no location, no job) ===\n";
$r = mysqli_query($d, 'SELECT Id, reporting_marks, current_location_id, handled_by_job_id, status, remarks
                       FROM cars WHERE current_location_id=0 AND handled_by_job_id=0');
while ($x = mysqli_fetch_assoc($r)) {
    print_r($x);
}

echo "\n=== cars missing from album entirely ===\n";
$r = mysqli_query($d, 'SELECT Id, reporting_marks, current_location_id, handled_by_job_id FROM cars
                       WHERE NOT (
                         (current_location_id>0 AND car_code_id IN (SELECT id FROM car_codes)
                          AND current_location_id IN (SELECT id FROM locations))
                         OR
                         (handled_by_job_id>0 AND handled_by_job_id IN (SELECT id FROM jobs)
                          AND car_code_id IN (SELECT id FROM car_codes))
                       )');
while ($x = mysqli_fetch_assoc($r)) {
    echo "  Id={$x['Id']} {$x['reporting_marks']} loc={$x['current_location_id']} job={$x['handled_by_job_id']}\n";
}

echo "\n=== cars with invalid FK (broken location/code) that might still list oddly ===\n";
$r = mysqli_query($d, 'SELECT c.Id, c.reporting_marks, c.car_code_id, c.current_location_id
                       FROM cars c
                       LEFT JOIN car_codes cc ON cc.id=c.car_code_id
                       LEFT JOIN locations l ON l.id=c.current_location_id
                       WHERE cc.id IS NULL OR (c.current_location_id>0 AND l.id IS NULL)');
$n = 0;
while ($x = mysqli_fetch_assoc($r)) {
    $n++;
    echo "  Id={$x['Id']} {$x['reporting_marks']} code={$x['car_code_id']} loc={$x['current_location_id']}\n";
}
if (!$n) {
    echo "  (none)\n";
}
