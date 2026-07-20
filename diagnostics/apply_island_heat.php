<?php
/**
 * Heat Neville Island local shipment intervals (keep amount caps).
 *
 * Usage (in container):
 *   php apply_island_heat.php <case>
 *
 * Cases:
 *   none          no-op (amounts unchanged)
 *   isl_hot       ARIS/STUK/CALG/FERR/KOSM → interval 0-1
 *   ferr_boost    isl_hot + Ferrel → 0-0 (eligible every session)
 *   isl_hot_ix    isl_hot + lengthen all IX intervals by +2
 *   ferr_ix       ferr_boost + IX +2
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

chdir('/var/www/html/sts');
require_once 'open_db.php';

$case = strtolower(trim((string) ($argv[1] ?? 'isl_hot')));
$dbc = open_db();

function q($dbc, $sql)
{
    if (!mysqli_query($dbc, $sql)) {
        throw new RuntimeException(mysqli_error($dbc) . "\nSQL: " . $sql);
    }

    return mysqli_affected_rows($dbc);
}

$island = "code LIKE 'ARIS-%' OR code LIKE 'STUK-%' OR code LIKE 'CALG-%'
        OR code LIKE 'FERR-%' OR code LIKE 'KOSM-%'";

$changed = [];
if ($case === 'none' || $case === 'base') {
    echo "case=none changed=0\n";
    exit(0);
}

if (in_array($case, ['isl_hot', 'ferr_boost', 'isl_hot_ix', 'ferr_ix'], true)) {
    $changed['island_hot'] = q(
        $dbc,
        "UPDATE shipments SET min_interval=0, max_interval=1
         WHERE ($island) AND code NOT LIKE 'COKE-%'"
    );
}

if (in_array($case, ['ferr_boost', 'ferr_ix'], true)) {
    $changed['ferrel'] = q(
        $dbc,
        "UPDATE shipments SET min_interval=0, max_interval=0
         WHERE code LIKE 'FERR-%'"
    );
}

if (in_array($case, ['isl_hot_ix', 'ferr_ix'], true)) {
    $changed['ix_cool'] = q(
        $dbc,
        "UPDATE shipments
         SET min_interval = LEAST(20, min_interval + 2),
             max_interval = LEAST(24, GREATEST(max_interval + 2, min_interval + 2))
         WHERE code LIKE 'IX-%'"
    );
}

// Keep amount policy: non-coke 1-1, Aristech 1-2.
$changed['amt_cap'] = q(
    $dbc,
    "UPDATE shipments SET min_amount=1, max_amount=1 WHERE code NOT LIKE 'COKE-%'"
);
$changed['aris_amt'] = q(
    $dbc,
    "UPDATE shipments SET min_amount=1, max_amount=2 WHERE code LIKE 'ARIS-%'"
);

echo 'case=' . $case;
foreach ($changed as $k => $n) {
    echo " {$k}={$n}";
}
echo "\n";
