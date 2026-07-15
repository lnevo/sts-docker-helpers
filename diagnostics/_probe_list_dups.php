<?php
error_reporting(E_ERROR | E_PARSE);
chdir('/var/www/html/sts');
require 'credentials.php';
$d = mysqli_connect($server_name, $user_name, $password, $db_name);

echo "=== cars with MULTIPLE open car_orders (appear as duplicates in Rolling Stock DB list) ===\n";
$r = mysqli_query($d, 'SELECT c.Id id, c.reporting_marks marks, COUNT(co.waybill_number) orders,
                              GROUP_CONCAT(co.waybill_number ORDER BY co.waybill_number) wbs
                       FROM cars c
                       JOIN car_orders co ON co.car = c.Id
                       GROUP BY c.Id
                       HAVING orders > 1
                       ORDER BY orders DESC, marks');
$n = 0;
while ($x = mysqli_fetch_assoc($r)) {
    $n++;
    echo "  {$x['marks']} (Id={$x['id']}): {$x['orders']} orders -> {$x['wbs']}\n";
}
if (!$n) {
    echo "  (none — no car has >1 open order)\n";
}

echo "\n=== Rolling Stock list row count vs unique cars ===\n";
$sql = 'select cars.id as id, cars.reporting_marks as reporting_marks, car_orders.waybill_number as waybill_number
        from cars
        left join car_orders on cars.id = car_orders.car
        order by cars.reporting_marks';
$rs = mysqli_query($d, $sql);
$rows = 0;
$seen = [];
$dups = [];
while ($row = mysqli_fetch_assoc($rs)) {
    $rows++;
    $m = $row['reporting_marks'];
    if (isset($seen[$m])) {
        $dups[$m][] = $row['waybill_number'];
    } else {
        $seen[$m] = [$row['waybill_number']];
    }
}
echo "list rows={$rows} unique cars=" . count($seen) . "\n";
foreach ($dups as $m => $wbs) {
    echo "  DUPLICATE ROW: {$m} also appears with wb=" . implode(',', $wbs) . " (first wb=" . ($seen[$m][0] ?? '') . ")\n";
}

echo "\n=== orphan (loc=0,job=0) ===\n";
$r = mysqli_query($d, 'SELECT Id, reporting_marks FROM cars WHERE current_location_id=0 AND handled_by_job_id=0');
while ($x = mysqli_fetch_assoc($r)) {
    echo "  Id={$x['Id']} {$x['reporting_marks']}\n";
}
