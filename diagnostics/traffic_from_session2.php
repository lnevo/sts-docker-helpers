<?php
/**
 * traffic_from_session2.php
 *
 * Replay sessions 3..N from a locked end-of-session-2 DB already loaded.
 * Prints per-session train marks + holdup metrics (gen/fill/repo/weigh/reload,
 * unfilled, yard piles) and a score (higher is better).
 *
 * Usage (in container):
 *   php traffic_from_session2.php [to_session=10] [workflow=hart_session] [drain:THRESH:TARGET]
 *
 * Optional drain (third arg): cancel oldest non-coke unfilled when count > THRESH
 * down to TARGET, before each session recipe. Example: drain:40:30
 *
 * Scarce-lane pause (env, see generate_order_helpers.php):
 *   STS_SCARCE_PAUSE_UNFILLED=35 STS_SCARCE_PAUSE_CODES=HC,XM,FM,GA,GD,FC
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

chdir('/var/www/html/sts');
require_once 'open_db.php';
require_once 'session_helpers.php';
require_once 'operational_steps_catalog.php';
require_once 'generate_order_helpers.php';
require_once 'fill_order_helpers.php';
if (is_file(__DIR__ . '/drain_unfilled_orders.php')) {
    require_once __DIR__ . '/drain_unfilled_orders.php';
}

$to_session = max(3, (int) ($argv[1] ?? 10));
$workflow_arg = $argv[2] ?? 'hart_session';
$drain_threshold = 0;
$drain_target = 0;
if (isset($argv[3]) && preg_match('/^drain:(\d+):(\d+)$/', (string) $argv[3], $dm)) {
    $drain_threshold = (int) $dm[1];
    $drain_target = (int) $dm[2];
}

$editorDir = operational_steps_editor_dir();
$resolved = operational_steps_resolve_workflow_filename($editorDir, $workflow_arg);
$jsonPath = $resolved !== ''
    ? operational_steps_workflow_path($editorDir, $resolved)
    : (is_file($workflow_arg) ? $workflow_arg : '');
if ($jsonPath === '' || !is_file($jsonPath)) {
    fwrite(STDERR, "No workflow: {$workflow_arg}\n");
    exit(1);
}
$recipe = operational_steps_load_recipe_from_json_file($jsonPath);
$dbc = open_db();

function tf_s2_session($dbc)
{
    $r = mysqli_query($dbc, "SELECT setting_value FROM settings WHERE setting_name='session_nbr'");
    $row = $r ? mysqli_fetch_assoc($r) : null;
    return (int) ($row['setting_value'] ?? 0);
}

function tf_s2_q1($dbc, $sql)
{
    $r = mysqli_query($dbc, $sql);
    return $r ? (int) mysqli_fetch_row($r)[0] : -1;
}

function tf_s2_station($dbc, $st)
{
    return tf_s2_q1(
        $dbc,
        'SELECT COUNT(*) FROM cars ca JOIN locations l ON ca.current_location_id=l.Id WHERE l.station=' . (int) $st
    );
}

function tf_s2_phase_marks($session, $title, $info)
{
    $root = session_web_root();
    $dir = session_dir_for($session, $root);
    $manifest = $dir . '/manifest.json';
    if (!is_file($manifest)) {
        return [];
    }
    $m = json_decode(file_get_contents($manifest), true);
    $marks = [];
    foreach ($m['phases'] ?? [] as $ph) {
        if (($ph['title'] ?? '') !== $title) {
            continue;
        }
        if (($ph['info'] ?? '') !== $info) {
            continue;
        }
        $host = $ph['output'] ?? '';
        if ($host === '' || !is_dir($host)) {
            continue;
        }
        $masters = array_merge(
            glob($host . '/*_master.json') ?: [],
            glob($host . '/*/*_master.json') ?: [],
            glob($host . '/*/*/*_master.json') ?: []
        );
        foreach ($masters as $f) {
            $d = json_decode(file_get_contents($f), true);
            if (!is_array($d)) {
                continue;
            }
            foreach ($d['sections'] ?? [] as $sec) {
                foreach ($sec['cars'] ?? [] as $c) {
                    $marks[] = $c;
                }
            }
        }
    }
    return $marks;
}

function tf_s2_count_coke(array $cars)
{
    $n = 0;
    foreach ($cars as $c) {
        $load = (string) ($c['loading_station'] ?? '');
        $unload = (string) ($c['unloading_station'] ?? '');
        $cons = (string) ($c['consignment'] ?? '');
        if (
            stripos($load, 'Shenango') !== false
            || stripos($unload, 'Shenango') !== false
            || stripos($cons, 'COKE') !== false
            || stripos($cons, 'coke') !== false
        ) {
            $n++;
        }
    }
    return $n;
}

function tf_s2_dest_split(array $cars)
{
    $mr = 0;
    $mp = 0;
    foreach ($cars as $c) {
        $u = (string) ($c['unloading_station'] ?? '');
        if (stripos($u, 'Rocks') !== false) {
            $mr++;
        }
        if (stripos($u, 'ckeesport') !== false || stripos($u, 'Mckeesport') !== false) {
            $mp++;
        }
    }
    return [$mr, $mp];
}

function tf_s2_log_ops(array $log)
{
    $gen = 0;
    $fill = 0;
    $rep = 0;
    $asg = 0;
    $sout = 0;
    $wgh = 0;
    $rld = 0;
    $unf_before = null;
    $gen_skip = '';
    foreach ($log as $e) {
        if (!is_array($e)) {
            continue;
        }
        if (array_key_exists('generated', $e)) {
            $gen += (int) $e['generated'];
            if (isset($e['unfilled_before'])) {
                $unf_before = (int) $e['unfilled_before'];
            }
            if (!empty($e['skipped']) && !empty($e['reason']) && $gen_skip === '') {
                $gen_skip = (string) $e['reason'];
            }
        }
        if (array_key_exists('filled', $e)) {
            $fill += (int) $e['filled'];
        }
        if (array_key_exists('repositioned', $e)) {
            $rep += (int) $e['repositioned'];
        }
        if (array_key_exists('assigned', $e)) {
            $asg += (int) $e['assigned'];
        }
        if (array_key_exists('set_out', $e)) {
            $sout += (int) $e['set_out'];
        }
        if (isset($e['weigh']) && is_array($e['weigh'])) {
            $wgh += (int) ($e['weigh']['weighed'] ?? 0);
            $rld += (int) ($e['weigh']['reloads'] ?? 0);
        }
    }

    return [
        'gen' => $gen,
        'fill' => $fill,
        'rep' => $rep,
        'asg' => $asg,
        'sout' => $sout,
        'wgh' => $wgh,
        'rld' => $rld,
        'unf_before' => $unf_before,
        'gen_skip' => $gen_skip,
    ];
}

$rows = [];
$cur = tf_s2_session($dbc);
if ($cur !== 2) {
    fwrite(STDERR, "Expected session_nbr=2 at start, got {$cur}\n");
    exit(2);
}

for ($target = 3; $target <= $to_session; $target++) {
    $drain_canceled = 0;
    if ($drain_threshold > 0 && function_exists('drain_unfilled_orders')) {
        $dr = drain_unfilled_orders($dbc, [
            'threshold' => $drain_threshold,
            'target' => $drain_target,
            'keep_coke' => true,
        ]);
        $drain_canceled = (int) ($dr['canceled'] ?? 0);
    }

    $r = session_run_recipe($dbc, $recipe, [
        'format' => 'all',
        'reset_output' => true,
    ]);
    $sess = (int) ($r['session'] ?? tf_s2_session($dbc));
    $ck1 = tf_s2_phase_marks($sess, 'CK1', '');
    $d749s = tf_s2_phase_marks($sess, 'D749', 'Starting');
    $d749o = tf_s2_phase_marks($sess, 'D749', 'Outbound');
    $nvlo = tf_s2_phase_marks($sess, 'NVL', 'Outbound');
    $nvlr = tf_s2_phase_marks($sess, 'NVL', 'Return');
    $coke = tf_s2_count_coke($ck1);
    [$mr, $mp] = tf_s2_dest_split($ck1);
    $ops = tf_s2_log_ops($r['log'] ?? []);
    $unfilled = function_exists('generate_orders_count_unfilled')
        ? (int) generate_orders_count_unfilled($dbc)
        : -1;
    $open = tf_s2_q1($dbc, 'SELECT COUNT(*) FROM car_orders');
    // Yard piles (station ids match traffic_sweep / track_scale_10x10).
    $nev = tf_s2_station($dbc, 3);
    $scul = tf_s2_station($dbc, 9);
    $sth = tf_s2_station($dbc, 8);
    $dem = tf_s2_station($dbc, 10);
    $shen = tf_s2_station($dbc, 12);

    $notes = [];
    if ($ops['gen_skip'] !== '') {
        $notes[] = 'gate:' . $ops['gen_skip'];
    } elseif ($ops['gen'] === 0) {
        $notes[] = 'gen=0';
    }
    if ($unfilled > 30) {
        $notes[] = 'backlog';
    }
    if ($nev > 20) {
        $notes[] = 'NevStuck';
    }
    if ($scul > 10) {
        $notes[] = 'SculStuck';
    }
    if ($dem > 12) {
        $notes[] = 'DemStuck';
    }
    if ($sth > 25) {
        $notes[] = 'SthStuck';
    }
    if (count($nvlo) <= 0) {
        $notes[] = 'NVLOempty';
    }
    if ($ops['rld'] > 0 && $ops['wgh'] > 0 && ($ops['rld'] / max(1, $ops['wgh'])) > 0.25) {
        $notes[] = 'reloadHeavy';
    }
    if ($drain_canceled > 0) {
        $notes[] = 'drain:' . $drain_canceled;
    }

    $row = [
        's' => $sess,
        'ck1' => count($ck1),
        'coke' => $coke,
        'ck_mr' => $mr,
        'ck_mp' => $mp,
        'd749s' => count($d749s),
        'd749o' => count($d749o),
        'nvlo' => count($nvlo),
        'nvlr' => count($nvlr),
        'gen' => $ops['gen'],
        'fill' => $ops['fill'],
        'rep' => $ops['rep'],
        'asg' => $ops['asg'],
        'sout' => $ops['sout'],
        'wgh' => $ops['wgh'],
        'rld' => $ops['rld'],
        'unf_before' => $ops['unf_before'],
        'unfilled' => $unfilled,
        'drain' => $drain_canceled,
        'open' => $open,
        'nev' => $nev,
        'scul' => $scul,
        'sth' => $sth,
        'dem' => $dem,
        'shen' => $shen,
        'notes' => implode(',', $notes),
        'err' => (string) ($r['error'] ?? ''),
    ];
    $rows[] = $row;
    echo sprintf(
        "s%-2d CK1=%d coke=%d (MR=%d MP=%d) D749S=%d D749O=%d NVLO=%d NVLR=%d"
        . " | gen=%d fill=%d rep=%d wgh=%d rld=%d unf=%d%s"
        . " | Nev=%d Scul=%d Dem=%d Sth=%d%s\n",
        $row['s'],
        $row['ck1'],
        $row['coke'],
        $row['ck_mr'],
        $row['ck_mp'],
        $row['d749s'],
        $row['d749o'],
        $row['nvlo'],
        $row['nvlr'],
        $row['gen'],
        $row['fill'],
        $row['rep'],
        $row['wgh'],
        $row['rld'],
        $row['unfilled'],
        $drain_canceled > 0 ? (' drain=' . $drain_canceled) : '',
        $row['nev'],
        $row['scul'],
        $row['dem'],
        $row['sth'],
        $row['notes'] !== '' ? (' | ' . $row['notes']) : ''
    );
}

// Score: prefer steady coke ~5-7, both yards working, NVL leave+return populated
$cokes = array_column($rows, 'coke');
$nvlos = array_column($rows, 'nvlo');
$d749s = array_column($rows, 'd749s');
$d749o = array_column($rows, 'd749o');
$n = max(1, count($rows));
$avg = function (array $a) use ($n) {
    return array_sum($a) / $n;
};
$var = function (array $a) use ($avg) {
    $m = $avg($a);
    $s = 0.0;
    foreach ($a as $v) {
        $s += ($v - $m) * ($v - $m);
    }
    return $s / max(1, count($a));
};

$score = 0.0;
// coke mean near 6
$score += 20.0 - min(20.0, abs($avg($cokes) - 6.0) * 4.0);
// low coke variance
$score += 20.0 - min(20.0, $var($cokes) * 2.0);
// NVL outbound not empty
$empty_nvl = count(array_filter($nvlos, fn ($x) => $x <= 0));
$score += 15.0 - min(15.0, $empty_nvl * 5.0);
$score += min(15.0, $avg($nvlos) * 1.5);
// D749 both lists
$score += min(10.0, $avg($d749s) * 1.5);
$score += min(10.0, $avg($d749o) * 1.5);
// coke MR/MP balance
$mr = array_sum(array_column($rows, 'ck_mr'));
$mp = array_sum(array_column($rows, 'ck_mp'));
$tot = max(1, $mr + $mp);
$balance = 1.0 - abs($mr - $mp) / $tot;
$score += 10.0 * $balance;

$gen_avg = $avg(array_column($rows, 'gen'));
$fill_avg = $avg(array_column($rows, 'fill'));
$rep_avg = $avg(array_column($rows, 'rep'));
$wgh_avg = $avg(array_column($rows, 'wgh'));
$rld_avg = $avg(array_column($rows, 'rld'));
$unf_avg = $avg(array_column($rows, 'unfilled'));
$nev_avg = $avg(array_column($rows, 'nev'));
$scul_avg = $avg(array_column($rows, 'scul'));
$dem_avg = $avg(array_column($rows, 'dem'));
$sth_avg = $avg(array_column($rows, 'sth'));
$gen_zero = count(array_filter(array_column($rows, 'gen'), fn ($x) => (int) $x <= 0));
$gate_hits = count(array_filter(array_column($rows, 'notes'), fn ($n) => strpos((string) $n, 'gate:') !== false));
$stuck_hits = count(array_filter(array_column($rows, 'notes'), fn ($n) => strpos((string) $n, 'Stuck') !== false));

$note_bag = [];
foreach ($rows as $row) {
    foreach (explode(',', (string) ($row['notes'] ?? '')) as $n) {
        $n = trim($n);
        if ($n !== '') {
            $note_bag[$n] = ($note_bag[$n] ?? 0) + 1;
        }
    }
}
arsort($note_bag);
$holdup = 'capacity/idle';
if ($gen_avg < 8 || $gen_zero >= 2 || $gate_hits >= 2) {
    $holdup = 'shipments/gate';
} elseif ($stuck_hits >= 3 || $nev_avg > 20 || $scul_avg > 10 || $dem_avg > 12) {
    $holdup = 'stuck_yards';
} elseif ($wgh_avg > 0 && ($rld_avg / max(0.1, $wgh_avg)) > 0.2) {
    $holdup = 'reloads';
} elseif ($unf_avg > 25 && $fill_avg < $gen_avg * 0.5) {
    $holdup = 'fill_lag';
}

echo sprintf(
    "SCORE=%.1f | coke_avg=%.1f coke_var=%.1f nvlo_avg=%.1f nvlo_empty=%d d749s_avg=%.1f d749o_avg=%.1f coke_MR=%d coke_MP=%d\n",
    $score,
    $avg($cokes),
    $var($cokes),
    $avg($nvlos),
    $empty_nvl,
    $avg($d749s),
    $avg($d749o),
    $mr,
    $mp
);
echo sprintf(
    "HOLDUP=%s | gen_avg=%.1f fill_avg=%.1f rep_avg=%.1f wgh_avg=%.1f rld_avg=%.1f unf_avg=%.1f gen_zero=%d gate_hits=%d"
    . " | Nev=%.0f Scul=%.0f Dem=%.0f Sth=%.0f\n",
    $holdup,
    $gen_avg,
    $fill_avg,
    $rep_avg,
    $wgh_avg,
    $rld_avg,
    $unf_avg,
    $gen_zero,
    $gate_hits,
    $nev_avg,
    $scul_avg,
    $dem_avg,
    $sth_avg
);
if ($note_bag !== []) {
    $parts = [];
    foreach (array_slice($note_bag, 0, 8, true) as $k => $v) {
        $parts[] = "{$k}×{$v}";
    }
    echo 'NOTES=' . implode(' ', $parts) . "\n";
}
echo 'TRAFFIC_JSON=' . json_encode([
    'score' => $score,
    'holdup' => $holdup,
    'coke_avg' => $avg($cokes),
    'coke_var' => $var($cokes),
    'nvlo_avg' => $avg($nvlos),
    'nvlo_empty' => $empty_nvl,
    'd749s_avg' => $avg($d749s),
    'd749o_avg' => $avg($d749o),
    'coke_mr' => $mr,
    'coke_mp' => $mp,
    'gen_avg' => $gen_avg,
    'fill_avg' => $fill_avg,
    'rep_avg' => $rep_avg,
    'wgh_avg' => $wgh_avg,
    'rld_avg' => $rld_avg,
    'unf_avg' => $unf_avg,
    'gen_zero' => $gen_zero,
    'gate_hits' => $gate_hits,
    'nev_avg' => $nev_avg,
    'scul_avg' => $scul_avg,
    'dem_avg' => $dem_avg,
    'sth_avg' => $sth_avg,
    'note_bag' => $note_bag,
    'rows' => $rows,
], JSON_UNESCAPED_SLASHES) . "\n";
