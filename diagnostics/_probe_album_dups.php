<?php
error_reporting(E_ERROR | E_PARSE);
chdir('/var/www/html/sts');
require 'credentials.php';
$d = mysqli_connect($server_name, $user_name, $password, $db_name);

echo "=== cars that would appear TWICE in Rolling Stock Album (location AND job set) ===\n";
$r = mysqli_query($d, 'SELECT c.Id id, c.reporting_marks marks, c.current_location_id loc,
                              c.handled_by_job_id job, j.name jname, l.code lcode
                       FROM cars c
                       LEFT JOIN jobs j ON j.id=c.handled_by_job_id
                       LEFT JOIN locations l ON l.id=c.current_location_id
                       WHERE c.current_location_id > 0 AND c.handled_by_job_id > 0
                       ORDER BY c.reporting_marks');
$n = 0;
while ($x = mysqli_fetch_assoc($r)) {
    $n++;
    echo "  Id={$x['id']} {$x['marks']}  loc={$x['loc']}({$x['lcode']})  job={$x['job']}({$x['jname']})\n";
}
echo "count of dual-assignment cars: {$n}\n";

echo "\n=== album query row count vs cars table count ===\n";
$sql = 'select cars.id as car_id, cars.reporting_marks as reporting_marks
        from cars, car_codes, locations, routing
        where cars.car_code_id = car_codes.id
          and locations.id = cars.current_location_id
          and routing.id = locations.station
        UNION
        select cars.id, cars.reporting_marks
        from cars, car_codes, jobs
        where cars.car_code_id = car_codes.id
          and cars.handled_by_job_id = jobs.id
        order by reporting_marks';
$rs = mysqli_query($d, $sql);
$album = [];
$seen = [];
$dup_in_album = [];
while ($row = mysqli_fetch_assoc($rs)) {
    $album[] = $row['reporting_marks'];
    $m = $row['reporting_marks'];
    if (isset($seen[$m])) {
        $dup_in_album[] = $m;
    }
    $seen[$m] = ($seen[$m] ?? 0) + 1;
}
echo 'album rows=' . count($album) . ' cars table=' . mysqli_fetch_row(mysqli_query($d, 'select count(*) from cars'))[0] . "\n";
echo 'marks appearing >1x in album: ' . (count($dup_in_album) ? implode(', ', $dup_in_album) : '(none)') . "\n";

echo "\n=== in-train only (loc=0, job>0) / nowhere (loc=0, job=0) ===\n";
echo 'in train: ' . mysqli_fetch_row(mysqli_query($d, 'select count(*) from cars where current_location_id=0 and handled_by_job_id>0'))[0] . "\n";
echo 'orphans (no loc, no job): ' . mysqli_fetch_row(mysqli_query($d, 'select count(*) from cars where current_location_id=0 and handled_by_job_id=0'))[0] . "\n";
echo 'on location only: ' . mysqli_fetch_row(mysqli_query($d, 'select count(*) from cars where current_location_id>0 and handled_by_job_id=0'))[0] . "\n";
