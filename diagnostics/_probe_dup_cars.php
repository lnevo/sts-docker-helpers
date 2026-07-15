<?php
error_reporting(E_ERROR | E_PARSE);
chdir('/var/www/html/sts');
require 'credentials.php';
$d = mysqli_connect($server_name, $user_name, $password, $db_name);

echo "=== cars summary ===\n";
echo 'total=' . mysqli_fetch_row(mysqli_query($d, 'select count(*) from cars'))[0] . "\n";
echo 'distinct marks=' . mysqli_fetch_row(mysqli_query($d, 'select count(distinct reporting_marks) from cars'))[0] . "\n";

echo "\n=== duplicate reporting_marks ===\n";
$r = mysqli_query($d, 'select reporting_marks, group_concat(Id order by Id) ids, count(*) c from cars group by reporting_marks having c>1');
$n = 0;
while ($x = mysqli_fetch_assoc($r)) {
    $n++;
    echo "  {$x['reporting_marks']} ids={$x['ids']} count={$x['c']}\n";
}
if (!$n) {
    echo "  (none)\n";
}

echo "\n=== same road_number suffix under different roads? (last 4+ digits) ===\n";
$by_num = [];
$r = mysqli_query($d, 'select Id, reporting_marks from cars');
while ($x = mysqli_fetch_assoc($r)) {
    if (preg_match('/(\d{4,})$/', $x['reporting_marks'], $m)) {
        $by_num[$m[1]][] = $x['Id'] . '=' . $x['reporting_marks'];
    }
}
foreach ($by_num as $num => $list) {
    if (count($list) > 1) {
        echo "  num $num: " . implode(', ', $list) . "\n";
    }
}

echo "\n=== cars whose photo is missing / duplicate photos (Id.jpg) ===\n";
$photo_dir = './ImageStore/DB_Images/RollingStock';
$photos = is_dir($photo_dir) ? glob($photo_dir . '/*.jpg') : [];
$photo_ids = [];
foreach ($photos as $p) {
    $photo_ids[(int) basename($p, '.jpg')] = basename($p);
}
$r = mysqli_query($d, 'select Id, reporting_marks from cars order by Id');
$missing = 0;
$have = 0;
while ($x = mysqli_fetch_assoc($r)) {
    $id = (int) $x['Id'];
    if (isset($photo_ids[$id])) {
        $have++;
        unset($photo_ids[$id]);
    } else {
        $missing++;
        echo "  NO PHOTO for Id={$id} marks={$x['reporting_marks']}\n";
    }
}
echo "  with photo=$have missing=$missing orphan_photos=" . count($photo_ids) . "\n";
foreach ($photo_ids as $id => $fn) {
    echo "  ORPHAN photo $fn (no car Id)\n";
}
