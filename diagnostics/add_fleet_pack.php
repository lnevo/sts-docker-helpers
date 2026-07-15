<?php
/**
 * Clone empty pool cars into the live DB for traffic experiments.
 *
 * Usage (in container):
 *   php add_fleet_pack.php light|target|ops|proto|proto_reclass|print
 *
 * Adds Empty cars with synthetic marks ADD*nn.
 * Revenue types: Scully / South / Demmler.
 * HM: mostly Shenango. HK: yards feeding coal (Scully/South/Demmler).
 * Does not touch car_orders. Safe to re-run after a lock restore.
 *
 * proto          — store shopping list counts (apply on lock as-is).
 * proto_reclass  — same end-state after moving 4 covered hoppers to HP
 *                  (BO600401/409/421 + NW12986).
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

chdir('/var/www/html/sts');
require_once 'open_db.php';

$pack = strtolower(trim((string) ($argv[1] ?? 'print')));

/** @var array<string,int> packs */
$packs = [
    // Toward 10-12 car trains + yard breathing room (~+27 → ~97 cars)
    'target' => [
        'HC' => 6,
        'FM' => 5,
        'TA' => 4,
        'XM' => 4,
        'GA' => 3,
        'HP' => 3,
        'FC' => 2,
    ],
    // Smaller trial (~+16 → ~86 cars)
    'light' => [
        'HC' => 4,
        'FM' => 3,
        'TA' => 3,
        'XM' => 2,
        'GA' => 2,
        'HP' => 2,
    ],
    // Target revenue + 14 HM for COKE bulk 5+5 breathing room (~70 → ~111)
    'ops' => [
        'HC' => 6,
        'FM' => 5,
        'TA' => 4,
        'XM' => 4,
        'GA' => 3,
        'HP' => 3,
        'FC' => 2,
        'HM' => 14,
    ],
    // Prototypical H*: coke HM, coal HK, cement/carbon HC, pellets HP, agg→GA
    // Buy list vs lock AAR (~70 → ~117). Prefer this when lock types are unchanged.
    'proto' => [
        'HM' => 14,
        'HC' => 4,
        'HP' => 5,
        'HK' => 4,
        'GA' => 5,
        'FM' => 5,
        'TA' => 4,
        'XM' => 4,
        'FC' => 2,
    ],
    // After reclass BO600401/409/421 + NW12986 HC→HP (same desired end counts)
    'proto_reclass' => [
        'HM' => 14,
        'HC' => 8,
        'HP' => 1,
        'HK' => 4,
        'GA' => 5,
        'FM' => 5,
        'TA' => 4,
        'XM' => 4,
        'FC' => 2,
    ],
];

$dbc = open_db();
$loc_id = static function (string $code) use ($dbc): int {
    $q = mysqli_query(
        $dbc,
        'SELECT id FROM locations WHERE code="' . mysqli_real_escape_string($dbc, $code) . '" LIMIT 1'
    );
    $row = $q ? mysqli_fetch_assoc($q) : null;
    return (int) ($row['id'] ?? 0);
};

$scully = $loc_id('SCULLY-YARD');
$south = $loc_id('SOUTH-YARD');
$demmler = $loc_id('DEMMLER-YARD');
$shen = $loc_id('SHEN-COKE-SHIPPING');
if ($demmler <= 0) {
    $demmler = $loc_id('DEMMLER');
}

// Prefer Scully (NVL source) then South (interchange) then Demmler.
$revenue_homes = array_values(array_filter([$scully, $scully, $south, $south, $demmler]));
if ($revenue_homes === []) {
    $revenue_homes = [7, 7, 4, 4, 8];
}
// HM: mostly Shenango, a few South/Scully for empties in transit.
$hm_homes = array_values(array_filter([
    $shen, $shen, $shen, $shen, $shen, $shen,
    $south, $scully,
]));
if ($hm_homes === []) {
    $hm_homes = $revenue_homes;
}
// HK: coal — interchange yards that feed Calgon via NVL.
$hk_homes = array_values(array_filter([
    $scully, $scully, $south, $demmler,
]));
if ($hk_homes === []) {
    $hk_homes = $revenue_homes;
}

$code_ids = [];
$rs = mysqli_query($dbc, 'SELECT id, code FROM car_codes');
while ($row = mysqli_fetch_assoc($rs)) {
    $code_ids[strtoupper((string) $row['code'])] = (int) $row['id'];
}

if ($pack === 'print') {
    echo "Available packs:\n";
    foreach ($packs as $name => $counts) {
        echo "  {$name}: " . json_encode($counts) . " total=+" . array_sum($counts) . "\n";
    }
    exit(0);
}

if (!isset($packs[$pack])) {
    fwrite(STDERR, "Unknown pack '{$pack}'. Use: light|target|ops|proto|proto_reclass|print\n");
    exit(1);
}

$counts = $packs[$pack];
$added = 0;
$seq = 1;
$hm_seq = 0;
$hk_seq = 0;
foreach ($counts as $cc => $n) {
    $ccid = $code_ids[$cc] ?? 0;
    if ($ccid <= 0) {
        fwrite(STDERR, "Missing car_code {$cc}\n");
        continue;
    }
    for ($i = 0; $i < $n; $i++, $seq++) {
        if ($cc === 'HM') {
            $home = $hm_homes[$hm_seq % count($hm_homes)];
            $hm_seq++;
        } elseif ($cc === 'HK') {
            $home = $hk_homes[$hk_seq % count($hk_homes)];
            $hk_seq++;
        } else {
            $home = $revenue_homes[($seq - 1) % count($revenue_homes)];
        }
        $marks = sprintf('ADD%s%02d', $cc, $i + 1);
        // Skip if already present (idempotent after partial runs).
        $exists = mysqli_query(
            $dbc,
            'SELECT id FROM cars WHERE reporting_marks = "' . mysqli_real_escape_string($dbc, $marks) . '" LIMIT 1'
        );
        if ($exists && mysqli_fetch_assoc($exists)) {
            continue;
        }
        $remarks = mysqli_real_escape_string($dbc, $cc . ' pool spare');
        $ok = mysqli_query(
            $dbc,
            'INSERT INTO cars
                (reporting_marks, car_code_id, current_location_id, position, status,
                 handled_by_job_id, remarks, load_count, home_location, RFID_code, block_id, last_spotted)
             VALUES
                ("' . mysqli_real_escape_string($dbc, $marks) . '",
                 "' . $ccid . '",
                 "' . (int) $home . '",
                 "0",
                 "Empty",
                 "0",
                 "' . $remarks . '",
                 "0",
                 "' . (int) $home . '",
                 "",
                 "0",
                 "0")'
        );
        if ($ok) {
            $added++;
            echo "added {$marks} {$cc} @loc {$home}\n";
        } else {
            fwrite(STDERR, "fail {$marks}: " . mysqli_error($dbc) . "\n");
        }
    }
}

$total = 0;
$r = mysqli_query($dbc, 'SELECT COUNT(*) AS c FROM cars');
if ($row = mysqli_fetch_assoc($r)) {
    $total = (int) $row['c'];
}
echo "PACK={$pack} added={$added} fleet_total={$total}\n";
exit(0);
