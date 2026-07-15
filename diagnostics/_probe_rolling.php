<?php
error_reporting(E_ERROR | E_PARSE);
chdir('/var/www/html/sts');
require 'credentials.php';
$d = mysqli_connect($server_name, $user_name, $password, $db_name);

echo "=== cars count / empty marks / RFID collisions ===\n";
echo 'total=' . mysqli_fetch_row(mysqli_query($d, 'SELECT COUNT(*) FROM cars'))[0] . "\n";
echo 'empty marks=' . mysqli_fetch_row(mysqli_query($d, 'SELECT COUNT(*) FROM cars WHERE reporting_marks IS NULL OR reporting_marks=""'))[0] . "\n";
echo 'distinct marks=' . mysqli_fetch_row(mysqli_query($d, 'SELECT COUNT(DISTINCT reporting_marks) FROM cars'))[0] . "\n";

echo "\n=== near-duplicates: same digits, different road prefix ===\n";
$by_digits = [];
$r = mysqli_query($d, 'SELECT Id, reporting_marks, car_code_id, status, remarks FROM cars ORDER BY Id');
$all = [];
while ($x = mysqli_fetch_assoc($r)) {
    $all[] = $x;
    if (preg_match('/^(.*?)(\d+)$/', $x['reporting_marks'], $m)) {
        $by_digits[$m[2]][] = $x;
    }
}
foreach ($by_digits as $num => $cars) {
    if (count($cars) > 1) {
        foreach ($cars as $c) {
            echo "  num={$num} Id={$c['Id']} marks={$c['reporting_marks']} code={$c['car_code_id']} remarks={$c['remarks']}\n";
        }
    }
}

echo "\n=== RFID_code duplicates (non-empty) ===\n";
$r = mysqli_query($d, 'SELECT RFID_code, GROUP_CONCAT(Id) ids, GROUP_CONCAT(reporting_marks) marks, COUNT(*) c
                       FROM cars WHERE RFID_code IS NOT NULL AND RFID_code<>""
                       GROUP BY RFID_code HAVING c>1');
$n = 0;
while ($x = mysqli_fetch_assoc($r)) {
    $n++;
    echo "  RFID={$x['RFID_code']} ids={$x['ids']} marks={$x['marks']}\n";
}
if (!$n) {
    echo "  (none)\n";
}

echo "\n=== cars that look similar: same car_code + similar marks length / Levenshtein-ish pairs ===\n";
for ($i = 0; $i < count($all); $i++) {
    for ($j = $i + 1; $j < count($all); $j++) {
        $a = $all[$i];
        $b = $all[$j];
        if ($a['car_code_id'] !== $b['car_code_id']) {
            continue;
        }
        // identical after stripping road letters?
        $da = preg_replace('/\D/', '', $a['reporting_marks']);
        $db = preg_replace('/\D/', '', $b['reporting_marks']);
        if ($da !== '' && $da === $db) {
            echo "  SAME DIGITS Id={$a['Id']} {$a['reporting_marks']} vs Id={$b['Id']} {$b['reporting_marks']} code={$a['car_code_id']}\n";
        }
    }
}

echo "\n=== full fleet list (Id marks code remarks) ===\n";
foreach ($all as $c) {
    echo sprintf("  %3d  %-14s  code=%-3s  %s\n", $c['Id'], $c['reporting_marks'], $c['car_code_id'], $c['remarks']);
}

echo "\n=== car_codes table ===\n";
$r = mysqli_query($d, 'SELECT id, code, description FROM car_codes ORDER BY id');
while ($x = mysqli_fetch_assoc($r)) {
    echo "  {$x['id']} {$x['code']} {$x['description']}\n";
}
