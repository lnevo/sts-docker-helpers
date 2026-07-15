<?php
error_reporting(E_ERROR | E_PARSE);
chdir('/var/www/html/sts');
require 'credentials.php';
$d = mysqli_connect($server_name, $user_name, $password, $db_name);

echo "=== handled_by distribution ===\n";
$r = mysqli_query($d, 'SELECT COALESCE(j.name,"(none)") job, COUNT(*) c,
                              SUM(c.current_location_id>0) with_loc,
                              SUM(c.current_location_id=0) no_loc
                       FROM cars c LEFT JOIN jobs j ON j.id=c.handled_by_job_id
                       GROUP BY c.handled_by_job_id ORDER BY c DESC');
while ($x = mysqli_fetch_assoc($r)) {
    echo "  {$x['job']}: {$x['c']} cars (with_loc={$x['with_loc']} no_loc={$x['no_loc']})\n";
}

echo "\n=== cars handled by NVL (what the list shows for each) ===\n";
$r = mysqli_query($d, 'SELECT c.Id id, c.reporting_marks marks, c.current_location_id loc,
                              c.handled_by_job_id job, j.name jname, l.code lcode, r.station st
                       FROM cars c
                       LEFT JOIN jobs j ON j.id=c.handled_by_job_id
                       LEFT JOIN locations l ON l.id=c.current_location_id
                       LEFT JOIN routing r ON r.id=l.station
                       WHERE j.name="NVL" OR c.handled_by_job_id<>0
                       ORDER BY j.name, marks');
$n = 0;
while ($x = mysqli_fetch_assoc($r)) {
    $n++;
    $loc_disp = ((int) $x['loc'] > 0) ? "{$x['st']} / {$x['lcode']}" : 'In Train (loc=0)';
    echo "  {$x['marks']}: handled_by={$x['jname']}  location={$loc_disp}\n";
}
echo "total with any handled_by: {$n}\n";
