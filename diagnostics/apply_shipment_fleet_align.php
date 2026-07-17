<?php
/**
 * Remap scarce shipment car codes onto fleet-plentiful types (no order deletes).
 *
 * Usage (in container):
 *   php apply_shipment_fleet_align.php <option>
 *
 * Options:
 *   A   coal→HM, coils/tinplate/FC→FM, bulk gon→HM, pellets→HC; boost XM/FM intervals
 *   B   coal→HM, coils/tinplate→XM, bulk gon→HM, pellets→HC; boost XM intervals harder
 *   B2  coal→HM (throttled int 6-10 amt 1); coils→XM; agg→HC; billets/steel/scrap→FM;
 *       pellets→HC (frees HM for coke). Boost XM/FM/HC/TA.
 *   C   coal→HM only; lengthen scarce GA/FC/HP/HT intervals; shorten XM/FM/HC/TA
 *   coke_smooth  set COKE-*-BULK amt 2-3 int 1-2 (call alone or with A/B/B2/C)
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

chdir('/var/www/html/sts');
require_once 'open_db.php';

$opt = strtoupper(trim((string) ($argv[1] ?? 'A')));
$dbc = open_db();

function code_id($dbc, $code)
{
    $code = mysqli_real_escape_string($dbc, $code);
    $rs = mysqli_query($dbc, "SELECT Id FROM car_codes WHERE code=\"$code\" LIMIT 1");
    if (!$rs || !($row = mysqli_fetch_row($rs))) {
        throw new RuntimeException("missing car_code $code");
    }

    return (int) $row[0];
}

function remap_codes($dbc, array $map)
{
    $n = 0;
    foreach ($map as $ship => $code) {
        $id = code_id($dbc, $code);
        $ship_esc = mysqli_real_escape_string($dbc, $ship);
        mysqli_query($dbc, "UPDATE shipments SET car_code=$id WHERE code=\"$ship_esc\"");
        $n += mysqli_affected_rows($dbc) >= 0 ? 1 : 0;
    }

    return $n;
}

function remap_by_prefix_codes($dbc, array $prefixes, $to_code)
{
    $id = code_id($dbc, $to_code);
    $n = 0;
    foreach ($prefixes as $pfx) {
        $pfx_esc = mysqli_real_escape_string($dbc, $pfx);
        mysqli_query($dbc, "UPDATE shipments s
            INNER JOIN car_codes cc ON cc.Id=s.car_code
            SET s.car_code=$id
            WHERE s.code LIKE \"$pfx_esc%\"
              AND cc.code IN (\"GA\",\"FC\",\"HK\",\"HP\",\"HT\")");
        $n += mysqli_affected_rows($dbc);
    }

    return $n;
}

function bump_intervals($dbc, array $codes, $delta_min, $delta_max, $floor = 0)
{
    $in = implode(',', array_map(static function ($c) use ($dbc) {
        return '"' . mysqli_real_escape_string($dbc, $c) . '"';
    }, $codes));
    // Widen or tighten: new = GREATEST(floor, old+delta)
    mysqli_query($dbc, "UPDATE shipments s
        INNER JOIN car_codes cc ON cc.Id=s.car_code
        SET s.min_interval = GREATEST($floor, CAST(s.min_interval AS SIGNED) + ($delta_min)),
            s.max_interval = GREATEST(
                GREATEST($floor, CAST(s.min_interval AS SIGNED) + ($delta_min)),
                CAST(s.max_interval AS SIGNED) + ($delta_max)
            )
        WHERE cc.code IN ($in)
          AND s.code NOT LIKE 'COKE-%'");

    return mysqli_affected_rows($dbc);
}

function coke_smooth($dbc)
{
    mysqli_query($dbc, "UPDATE shipments SET min_amount=2, max_amount=3, min_interval=1, max_interval=2
        WHERE code IN (\"COKE-CLEV-BULK\",\"COKE-USS-BULK\")");

    return mysqli_affected_rows($dbc);
}

/** Slow coal so HM hoppers stay available for coke (coal is low priority). */
function coal_throttle($dbc)
{
    mysqli_query($dbc, "UPDATE shipments SET min_interval=6, max_interval=10, min_amount=1, max_amount=1
        WHERE code LIKE \"CALG-COAL-%\" OR code LIKE \"IX-COAL-%\"");

    return mysqli_affected_rows($dbc);
}

$changed = [];
if ($opt === 'COKE_SMOOTH' || $opt === 'COKE') {
    $changed['coke_smooth'] = coke_smooth($dbc);
    echo "option=COKE_SMOOTH coke_rows={$changed['coke_smooth']}\n";
    exit(0);
}

// Always smooth coke bulk with A/B/C so gates see smaller bites.
$changed['coke_smooth'] = coke_smooth($dbc);

if ($opt === 'A') {
    // Fleet-align: scarce → plentiful by equipment class.
    $changed['coal_hm'] = remap_by_prefix_codes($dbc, ['CALG-COAL-IN-', 'IX-COAL-'], 'HM');
    $changed['fc_fm'] = 0;
    foreach (['IX-COILS-REP-DEERE', 'IX-COILS-WEIRTON-RYERSON', 'IX-TINPLATE-WHEELING-HEINZ', 'STUK-COILS-OUT-RYERSON'] as $ship) {
        $changed['fc_fm'] += remap_codes($dbc, [$ship => 'FM']);
    }
    $changed['gon_hm'] = remap_codes($dbc, [
        'KOSM-AGG-IN-US-AGG' => 'HM',
        'KOSM-AGG-IN-MI-LIME' => 'HM',
        'KOSM-AGG-IN-MARTIN' => 'HM',
        'STUK-BILLETS-IN-MCCONWAY' => 'HM',
        'STUK-STEEL-IN-REP-STEEL' => 'HM',
        'IX-SCRAP-ALLEGHENY-MCCONWAY' => 'HM',
    ]);
    $changed['pellet_hc'] = remap_by_prefix_codes($dbc, ['ARIS-PELLETS-', 'IX-PELLETS-'], 'HC');
    // Compensate: fire XM/FM/TA a bit more often (shorter intervals).
    $changed['boost_xm_fm_ta'] = bump_intervals($dbc, ['XM', 'FM', 'TA'], -1, -1, 0);
} elseif ($opt === 'B') {
    $changed['coal_hm'] = remap_by_prefix_codes($dbc, ['CALG-COAL-IN-', 'IX-COAL-'], 'HM');
    $changed['coils_xm'] = remap_codes($dbc, [
        'IX-COILS-REP-DEERE' => 'XM',
        'IX-COILS-WEIRTON-RYERSON' => 'XM',
        'IX-TINPLATE-WHEELING-HEINZ' => 'XM',
        'STUK-COILS-OUT-RYERSON' => 'XM',
    ]);
    $changed['gon_hm'] = remap_codes($dbc, [
        'KOSM-AGG-IN-US-AGG' => 'HM',
        'KOSM-AGG-IN-MI-LIME' => 'HM',
        'KOSM-AGG-IN-MARTIN' => 'HM',
        'STUK-BILLETS-IN-MCCONWAY' => 'HM',
        'STUK-STEEL-IN-REP-STEEL' => 'HM',
        'IX-SCRAP-ALLEGHENY-MCCONWAY' => 'HM',
    ]);
    $changed['pellet_hc'] = remap_by_prefix_codes($dbc, ['ARIS-PELLETS-', 'IX-PELLETS-'], 'HC');
    $changed['boost_xm'] = bump_intervals($dbc, ['XM'], -1, -2, 0);
    $changed['boost_fm_ta'] = bump_intervals($dbc, ['FM', 'TA'], -1, -1, 0);
} elseif ($opt === 'B2') {
    // Free HM for coke: only coal stays on HM; move other B-era gon demand off HM.
    $changed['coal_hm'] = remap_by_prefix_codes($dbc, ['CALG-COAL-IN-', 'IX-COAL-'], 'HM');
    $changed['coal_throttle'] = coal_throttle($dbc);
    $changed['coils_xm'] = remap_codes($dbc, [
        'IX-COILS-REP-DEERE' => 'XM',
        'IX-COILS-WEIRTON-RYERSON' => 'XM',
        'IX-TINPLATE-WHEELING-HEINZ' => 'XM',
        'STUK-COILS-OUT-RYERSON' => 'XM',
    ]);
    $changed['agg_hc'] = remap_codes($dbc, [
        'KOSM-AGG-IN-US-AGG' => 'HC',
        'KOSM-AGG-IN-MI-LIME' => 'HC',
        'KOSM-AGG-IN-MARTIN' => 'HC',
    ]);
    $changed['steel_fm'] = remap_codes($dbc, [
        'STUK-BILLETS-IN-MCCONWAY' => 'FM',
        'STUK-STEEL-IN-REP-STEEL' => 'FM',
        'IX-SCRAP-ALLEGHENY-MCCONWAY' => 'FM',
    ]);
    $changed['pellet_hc'] = remap_by_prefix_codes($dbc, ['ARIS-PELLETS-', 'IX-PELLETS-'], 'HC');
    $changed['boost_xm_fm_hc_ta'] = bump_intervals($dbc, ['XM', 'FM', 'HC', 'TA'], -1, -1, 0);
} elseif ($opt === 'C') {
    // Minimal car remap (coal only) + interval rebalance.
    $changed['coal_hm'] = remap_by_prefix_codes($dbc, ['CALG-COAL-IN-', 'IX-COAL-'], 'HM');
    $changed['slow_scarce'] = bump_intervals($dbc, ['GA', 'FC', 'HP', 'HT', 'HK'], 2, 3, 2);
    $changed['boost_plentiful'] = bump_intervals($dbc, ['XM', 'FM', 'HC', 'TA'], -1, -1, 0);
} else {
    fwrite(STDERR, "Unknown option $opt (use A, B, B2, C, or coke_smooth)\n");
    exit(2);
}

echo 'option=' . $opt . ' ' . json_encode($changed) . "\n";

// Summary of remaining scarce demand.
$rs = mysqli_query($dbc, 'SELECT cc.code, COUNT(*) c FROM shipments s
  JOIN car_codes cc ON cc.Id=s.car_code
  WHERE cc.code IN ("GA","FC","HK","HP","HT")
  GROUP BY cc.code ORDER BY cc.code');
echo "remaining_scarce:";
while ($row = mysqli_fetch_assoc($rs)) {
    echo ' ' . $row['code'] . '=' . $row['c'];
}
echo "\n";
