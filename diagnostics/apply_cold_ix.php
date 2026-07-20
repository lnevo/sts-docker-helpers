<?php
/**
 * Shorten cold interchange shipment intervals (keep amount 1-1).
 *
 * Usage: php apply_cold_ix.php <case>
 *
 * Cases:
 *   none     no-op
 *   mild     IX int>=4 → subtract 2 (floor min 1); reefers untouched
 *   warm     mild + reefers 2-4; scrap 4-7; coal/pellets 2-5
 *   warmish  mild but also warm reefers to 2-4 only
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

chdir('/var/www/html/sts');
require_once 'open_db.php';

$case = strtolower(trim((string) ($argv[1] ?? 'mild')));
$dbc = open_db();

function q($dbc, $sql)
{
    if (!mysqli_query($dbc, $sql)) {
        throw new RuntimeException(mysqli_error($dbc) . "\n" . $sql);
    }

    return mysqli_affected_rows($dbc);
}

$changed = [];
if ($case === 'none' || $case === 'base') {
    echo "case=none changed=0\n";
    exit(0);
}

if (in_array($case, ['mild', 'warm', 'warmish'], true)) {
    // General cold IX (4-6 / 4-8 buckets): pull closer to local pace.
    $changed['ix_pull2'] = q(
        $dbc,
        "UPDATE shipments
         SET min_interval = GREATEST(1, CAST(min_interval AS SIGNED) - 2),
             max_interval = GREATEST(
               GREATEST(1, CAST(min_interval AS SIGNED) - 2),
               CAST(max_interval AS SIGNED) - 2
             )
         WHERE code LIKE 'IX-%'
           AND code NOT LIKE 'IX-REEFER-%'
           AND code NOT LIKE 'IX-SCRAP-%'
           AND min_interval >= 4"
    );
}

if ($case === 'warm') {
    $changed['scrap'] = q(
        $dbc,
        "UPDATE shipments SET min_interval=4, max_interval=7
         WHERE code LIKE 'IX-SCRAP-%'"
    );
    $changed['coal_pellet'] = q(
        $dbc,
        "UPDATE shipments SET min_interval=2, max_interval=5
         WHERE code LIKE 'IX-COAL-%' OR code LIKE 'IX-PELLETS-%'"
    );
    $changed['reefer'] = q(
        $dbc,
        "UPDATE shipments SET min_interval=2, max_interval=4
         WHERE code LIKE 'IX-REEFER-%'"
    );
}

if ($case === 'warmish') {
    $changed['reefer'] = q(
        $dbc,
        "UPDATE shipments SET min_interval=2, max_interval=4
         WHERE code LIKE 'IX-REEFER-%'"
    );
}

// Keep single-car IX amounts.
$changed['amt'] = q(
    $dbc,
    "UPDATE shipments SET min_amount=1, max_amount=1
     WHERE code LIKE 'IX-%'"
);

echo 'case=' . $case;
foreach ($changed as $k => $n) {
    echo " {$k}={$n}";
}
echo "\n";
