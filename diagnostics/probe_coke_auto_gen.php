<?php
/**
 * Probe whether automatic generate_orders can create COKE-* orders.
 *
 * Usage (in container):
 *   php probe_coke_auto_gen.php
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

chdir('/var/www/html/sts');
require_once 'open_db.php';
require_once 'generate_order_helpers.php';
require_once 'session_helpers.php';

$d = open_db();

function probe_coke_counts($d)
{
    $r = mysqli_query(
        $d,
        'SELECT s.code, COUNT(*) c
         FROM car_orders o
         JOIN shipments s ON s.Id = o.shipment
         WHERE s.code LIKE "COKE%"
         GROUP BY s.code'
    );
    $out = [];
    while ($r && ($row = mysqli_fetch_assoc($r))) {
        $out[$row['code']] = (int) $row['c'];
    }

    return $out;
}

function probe_coke_rows($d)
{
    $r = mysqli_query(
        $d,
        'SELECT code, min_interval, max_interval, min_amount, max_amount, last_ship_date
         FROM shipments WHERE code LIKE "COKE%" ORDER BY code'
    );
    $out = [];
    while ($r && ($row = mysqli_fetch_assoc($r))) {
        $out[] = $row;
    }

    return $out;
}

function probe_delta($before, $after)
{
    $codes = array_unique(array_merge(array_keys($before), array_keys($after)));
    $lines = [];
    $coke = 0;
    foreach ($codes as $code) {
        $b = $before[$code] ?? 0;
        $a = $after[$code] ?? 0;
        if ($a === $b) {
            continue;
        }
        $lines[] = "  {$code}: {$b}->{$a}";
        if (str_starts_with($code, 'COKE-')) {
            $coke += ($a - $b);
        }
    }

    return [$lines, $coke];
}

$session = (int) generate_orders_get_session($d);
echo "=== LIVE COKE SHIPMENTS (session={$session}) ===\n";
foreach (probe_coke_rows($d) as $row) {
    $earliest = (int) $row['last_ship_date'] + (int) $row['min_interval'];
    $due = $earliest <= $session ? 'YES' : 'no';
    echo sprintf(
        "%s int=%s-%s amt=%s-%s last=%s earliest_due=%s due_now=%s\n",
        $row['code'],
        $row['min_interval'],
        $row['max_interval'],
        $row['min_amount'],
        $row['max_amount'],
        $row['last_ship_date'],
        $earliest,
        $due
    );
}
echo 'open coke: ' . json_encode(probe_coke_counts($d)) . "\n";

// --- Test A: gate-skip leak at next session ---
mysqli_begin_transaction($d);
$test_session = $session + 1;
mysqli_query($d, 'UPDATE settings SET setting_value="' . $test_session . '" WHERE setting_name="session_nbr"');
echo "\n=== TEST A: automatic only at session={$test_session} (simulate gate skip) ===\n";
foreach (probe_coke_rows($d) as $row) {
    if (strpos($row['code'], 'BULK') === false) {
        continue;
    }
    $earliest = (int) $row['last_ship_date'] + (int) $row['min_interval'];
    echo sprintf(
        "%s last=%s earliest=%s due=%s\n",
        $row['code'],
        $row['last_ship_date'],
        $earliest,
        $earliest <= $test_session ? 'YES' : 'no'
    );
}
$before = probe_coke_counts($d);
$gen = generate_orders_run_automatic($d, $test_session, 0, 7, 4);
[$lines, $coke_delta] = probe_delta($before, probe_coke_counts($d));
echo "automatic generated_total={$gen}\n";
echo implode("\n", $lines) . (count($lines) ? "\n" : '');
echo "coke_orders_from_automatic={$coke_delta}\n";
echo $coke_delta > 0
    ? "RESULT A: LEAK — random auto created coke when gated steps skipped\n"
    : "RESULT A: no coke from auto on this snapshot\n";
mysqli_rollback($d);

// --- Test B: gates fire then automatic ---
mysqli_begin_transaction($d);
$test_session = $session + 1;
mysqli_query($d, 'UPDATE settings SET setting_value="' . $test_session . '" WHERE setting_name="session_nbr"');
$g1 = session_manual_generate_shipment($d, 'COKE-CLEV-BULK');
$g2 = session_manual_generate_shipment($d, 'COKE-USS-BULK');
echo "\n=== TEST B: gates then automatic at session={$test_session} ===\n";
echo 'gated CLEV=' . json_encode($g1) . ' USS=' . json_encode($g2) . "\n";
foreach (probe_coke_rows($d) as $row) {
    if (strpos($row['code'], 'BULK') === false) {
        continue;
    }
    $earliest = (int) $row['last_ship_date'] + (int) $row['min_interval'];
    echo sprintf(
        "%s last=%s earliest=%s due=%s\n",
        $row['code'],
        $row['last_ship_date'],
        $earliest,
        $earliest <= $test_session ? 'YES' : 'no'
    );
}
$before = probe_coke_counts($d);
$gen = generate_orders_run_automatic($d, $test_session, 200, 11, 4);
[$lines, $coke_delta] = probe_delta($before, probe_coke_counts($d));
echo "automatic generated_total={$gen}\n";
echo implode("\n", $lines) . (count($lines) ? "\n" : '');
echo "coke_orders_from_automatic={$coke_delta}\n";
echo $coke_delta > 0
    ? "RESULT B: LEAK — auto still added coke after gates\n"
    : "RESULT B: OK — auto adds no coke after gates update last_ship\n";
mysqli_rollback($d);

echo "\n=== DISABLE STRENGTH (50/50 vs old 99/99) ===\n";
foreach (probe_coke_rows($d) as $row) {
    if (strpos($row['code'], 'BULK') !== false) {
        continue;
    }
    $due50 = (int) $row['last_ship_date'] + (int) $row['min_interval'];
    $due99 = (int) $row['last_ship_date'] + 99;
    echo "{$row['code']}: with current int first due ~{$due50}; with 99/99 would be ~{$due99}\n";
}

echo "\nDONE\n";
