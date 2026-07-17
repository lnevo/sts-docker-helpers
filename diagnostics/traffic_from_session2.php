<?php
/**
 * traffic_from_session2.php
 *
 * Replay sessions (current+1)..N from a locked baseline DB already loaded
 * (historically end-of-session-2; also works from hart_session3_locked etc.).
 * Prints per-session switchlist job marks + holdup metrics (gen/fill/repo/weigh/reload,
 * unfilled, yard piles) and a score (higher is better).
 *
 * Switchlist jobs are discovered from the workflow's generate_switchlists steps
 * (title + info). Scoring treats each as one job — no legacy D749 Starting /
 * Outbound split when those phases are merged.
 *
 * Usage (in container):
 *   php traffic_from_session2.php [to_session=10] [workflow=hart_session] [drain:THRESH:TARGET]
 *
 * Optional drain (third arg): cancel oldest non-coke unfilled when count > THRESH
 * down to TARGET, before each session recipe. Example: drain:40:30
 * Prefer cancel_orders in the workflow when that step is already present.
 *
 * Scarce-lane pause (env, see generate_order_helpers.php):
 *   STS_SCARCE_PAUSE_UNFILLED=35 STS_SCARCE_PAUSE_CODES=HC,XM,FM,GA,GD,FC
 *
 * Deterministic comparison seed (optional):
 *   STS_TRAFFIC_SEED=42 php traffic_from_session2.php 30 hart_session
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

$to_session = max(1, (int) ($argv[1] ?? 10));
$workflow_arg = $argv[2] ?? 'hart_session';
$traffic_seed = trim((string) (getenv('STS_TRAFFIC_SEED') ?: ''));
if ($traffic_seed !== '' && preg_match('/^-?\d+$/', $traffic_seed)) {
    mt_srand((int) $traffic_seed);
    srand((int) $traffic_seed);
}
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

/**
 * Break down cars at a station for yard-pressure notes.
 * "Pressure" = Loaded / Loading / Unloading / Ordered-with-order (real traffic).
 * Orphan Ordered (status Ordered, no car_orders row) and idle Empty/Unavailable
 * inflate raw headcount without being interchange backlog.
 *
 * @return array{total:int,pressure:int,orphan_ordered:int,idle:int,loaded:int,ordered:int}
 */
function tf_s2_station_mix($dbc, $st)
{
    $st = (int) $st;
    $sql = 'SELECT ca.status,
                   CASE
                     WHEN co.car IS NOT NULL AND co.car != "" AND co.car != "0" THEN 1
                     ELSE 0
                   END AS has_order
            FROM cars ca
            JOIN locations l ON ca.current_location_id = l.Id
            LEFT JOIN car_orders co ON co.car = ca.id
            WHERE l.station = ' . $st;
    $r = mysqli_query($dbc, $sql);
    $out = [
        'total' => 0,
        'pressure' => 0,
        'orphan_ordered' => 0,
        'idle' => 0,
        'loaded' => 0,
        'ordered' => 0,
    ];
    if (!$r) {
        return $out;
    }
    while ($row = mysqli_fetch_assoc($r)) {
        $out['total']++;
        $status = (string) ($row['status'] ?? '');
        $has_order = (int) ($row['has_order'] ?? 0) === 1;
        if ($status === 'Ordered' && !$has_order) {
            $out['orphan_ordered']++;
            continue;
        }
        if (in_array($status, ['Loaded', 'Loading', 'Unloading'], true)) {
            $out['loaded']++;
            $out['pressure']++;
            continue;
        }
        if ($status === 'Ordered' && $has_order) {
            $out['ordered']++;
            $out['pressure']++;
            continue;
        }
        $out['idle']++;
    }
    return $out;
}

/**
 * Discover switchlist jobs from the recipe (one job per generate_switchlists).
 * Staging (STG-*) is tracked for display but scored lightly; road jobs are primary.
 *
 * @return list<array{key:string,title:string,info:string,jobs:string,label:string,staging:bool}>
 */
function tf_s2_workflow_switchlist_jobs(array $recipe)
{
    $out = [];
    $seen = [];
    foreach ($recipe['steps'] ?? [] as $step) {
        if (($step['function'] ?? '') !== 'generate_switchlists') {
            continue;
        }
        $p = $step['params'] ?? [];
        $title = trim((string) ($p['title'] ?? ''));
        $jobs = trim((string) ($p['jobs'] ?? ''));
        if ($title === '') {
            $title = $jobs !== '' ? explode(',', $jobs)[0] : 'LIST';
        }
        $info = trim((string) ($p['info'] ?? ''));
        $key = $title . '|' . $info;
        if (isset($seen[$key])) {
            continue;
        }
        $seen[$key] = true;
        $staging = (stripos($title, 'STG') === 0 || stripos($jobs, 'STG') === 0);
        $label = $info !== '' ? ($title . ' ' . $info) : $title;
        $out[] = [
            'key' => $key,
            'title' => $title,
            'info' => $info,
            'jobs' => $jobs !== '' ? $jobs : $title,
            'label' => $label,
            'staging' => $staging,
        ];
    }
    return $out;
}

function tf_s2_job_short_label(array $job)
{
    $title = strtoupper((string) ($job['title'] ?? ''));
    $info = (string) ($job['info'] ?? '');
    if ($title === 'CK1') {
        if (stripos($info, 'Return') !== false) {
            return 'CK1R';
        }
        return 'CK1';
    }
    if ($title === 'D749') {
        if (stripos($info, 'Return') !== false) {
            return 'D749R';
        }
        if (stripos($info, 'Next') !== false) {
            return 'D749ND';
        }
        if (stripos($info, 'Start') !== false) {
            return 'D749S';
        }
        return 'D749';
    }
    if ($title === 'NVL') {
        if (stripos($info, 'Return') !== false) {
            return 'NVLR';
        }
        return 'NVLO';
    }
    if (!empty($job['staging'])) {
        return preg_replace('/[^A-Za-z0-9]+/', '', $title) ?: 'STG';
    }
    $base = preg_replace('/[^A-Za-z0-9]+/', '', $title) ?: 'JOB';
    if ($info !== '') {
        $base .= substr(preg_replace('/[^A-Za-z0-9]+/', '', $info), 0, 3);
    }
    return $base;
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

/** Count cars by destination family for NVL variety (island / coke / yards / industries). */
function tf_s2_nvl_dest_buckets(array $cars)
{
    $b = ['ni' => 0, 'shen' => 0, 'south' => 0, 'dem' => 0, 'mp' => 0, 'mr' => 0, 'scul' => 0, 'other' => 0];
    foreach ($cars as $c) {
        $u = (string) ($c['unloading_station'] ?? '');
        $l = (string) ($c['loading_station'] ?? '');
        $hay = $u !== '' ? $u : $l;
        if (stripos($hay, 'Neville') !== false) {
            $b['ni']++;
        } elseif (stripos($hay, 'Shenango') !== false) {
            $b['shen']++;
        } elseif (stripos($hay, 'South') !== false) {
            $b['south']++;
        } elseif (stripos($hay, 'Demmler') !== false) {
            $b['dem']++;
        } elseif (stripos($hay, 'ckeesport') !== false || stripos($hay, 'Mckeesport') !== false) {
            $b['mp']++;
        } elseif (stripos($hay, 'Rocks') !== false) {
            $b['mr']++;
        } elseif (stripos($hay, 'Scully') !== false) {
            $b['scul']++;
        } else {
            $b['other']++;
        }
    }
    return $b;
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

$switchlist_jobs = tf_s2_workflow_switchlist_jobs($recipe);
if ($switchlist_jobs === []) {
    // Fallback if recipe has no generate_switchlists (shouldn't happen for HART).
    $switchlist_jobs = [
        ['key' => 'CK1|', 'title' => 'CK1', 'info' => '', 'jobs' => 'CK1', 'label' => 'CK1', 'staging' => false],
        ['key' => 'D749|Outbound', 'title' => 'D749', 'info' => 'Outbound', 'jobs' => 'D749', 'label' => 'D749 Outbound', 'staging' => false],
        ['key' => 'NVL|Outbound', 'title' => 'NVL', 'info' => 'Outbound', 'jobs' => 'NVL', 'label' => 'NVL Outbound', 'staging' => false],
        ['key' => 'NVL|Return', 'title' => 'NVL', 'info' => 'Return', 'jobs' => 'NVL', 'label' => 'NVL Return', 'staging' => false],
    ];
}
$job_shorts = [];
foreach ($switchlist_jobs as $j) {
    $job_shorts[$j['key']] = tf_s2_job_short_label($j);
}
fwrite(STDERR, 'traffic jobs: ' . implode(', ', array_column($switchlist_jobs, 'label')) . "\n");

$rows = [];
$cur = tf_s2_session($dbc);
$from_session = $cur + 1;
if ($cur < 1) {
    fwrite(STDERR, "Expected loaded baseline session_nbr>=1 at start, got {$cur}\n");
    exit(2);
}
if ($to_session < $from_session) {
    fwrite(STDERR, "to_session={$to_session} must be >= next session {$from_session} (baseline={$cur})\n");
    exit(2);
}
fwrite(STDERR, "traffic: baseline session={$cur} → run {$from_session}..{$to_session}\n");

for ($target = $from_session; $target <= $to_session; $target++) {
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

    $job_marks = [];
    $job_counts = [];
    foreach ($switchlist_jobs as $j) {
        $marks = tf_s2_phase_marks($sess, $j['title'], $j['info']);
        $job_marks[$j['key']] = $marks;
        $job_counts[$j['key']] = count($marks);
    }

    $ck1_key = null;
    $nvlo_key = null;
    $nvlr_key = null;
    foreach ($switchlist_jobs as $j) {
        if ($ck1_key === null && strcasecmp($j['title'], 'CK1') === 0) {
            $ck1_key = $j['key'];
        }
        if ($nvlo_key === null && strcasecmp($j['title'], 'NVL') === 0 && stripos($j['info'], 'Outbound') !== false) {
            $nvlo_key = $j['key'];
        }
        if ($nvlr_key === null && strcasecmp($j['title'], 'NVL') === 0 && stripos($j['info'], 'Return') !== false) {
            $nvlr_key = $j['key'];
        }
    }
    $ck1 = $ck1_key !== null ? ($job_marks[$ck1_key] ?? []) : [];
    $nvlo = $nvlo_key !== null ? ($job_marks[$nvlo_key] ?? []) : [];
    $nvlr = $nvlr_key !== null ? ($job_marks[$nvlr_key] ?? []) : [];
    $coke = tf_s2_count_coke($ck1);
    [$mr, $mp] = tf_s2_dest_split($ck1);
    $nvl_all = array_merge($nvlo, $nvlr);
    $nvl_dest = tf_s2_nvl_dest_buckets($nvl_all);
    $ops = tf_s2_log_ops($r['log'] ?? []);
    $unfilled = function_exists('generate_orders_count_unfilled')
        ? (int) generate_orders_count_unfilled($dbc)
        : -1;
    $open = tf_s2_q1($dbc, 'SELECT COUNT(*) FROM car_orders');
    // Yard piles (station ids match traffic_sweep / track_scale_10x10).
    $nev = tf_s2_station($dbc, 3);
    $scul_mix = tf_s2_station_mix($dbc, 9);
    $scul = $scul_mix['total'];
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
    // Scully: flag pressure (staged/live traffic), not raw count inflated by
    // orphan Ordered or idle empties from the virtual interchange yard.
    if ($scul_mix['pressure'] > 10) {
        $notes[] = 'SculStuck';
    }
    if ($scul_mix['orphan_ordered'] > 0) {
        $notes[] = 'SculOrphan:' . $scul_mix['orphan_ordered'];
    }
    if ($dem > 12) {
        $notes[] = 'DemStuck';
    }
    if ($sth > 25) {
        $notes[] = 'SthStuck';
    }
    if ($nvlo_key !== null && count($nvlo) <= 0) {
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
        'jobs' => $job_counts,
        'ck1' => count($ck1),
        'coke' => $coke,
        'ck_mr' => $mr,
        'ck_mp' => $mp,
        'nvlo' => count($nvlo),
        'nvlr' => count($nvlr),
        'nvl_ni' => $nvl_dest['ni'],
        'nvl_shen' => $nvl_dest['shen'],
        'nvl_south' => $nvl_dest['south'],
        'nvl_dem' => $nvl_dest['dem'],
        'nvl_mp' => $nvl_dest['mp'],
        'nvl_mr' => $nvl_dest['mr'],
        'nvl_scul' => $nvl_dest['scul'],
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
        'scul_pressure' => $scul_mix['pressure'],
        'scul_orphan' => $scul_mix['orphan_ordered'],
        'scul_idle' => $scul_mix['idle'],
        'sth' => $sth,
        'dem' => $dem,
        'shen' => $shen,
        'notes' => implode(',', $notes),
        'err' => (string) ($r['error'] ?? ''),
    ];
    // Convenience aliases for common road jobs (compat with older TSV scrapers).
    foreach ($switchlist_jobs as $j) {
        $short = $job_shorts[$j['key']];
        $row[strtolower($short)] = $job_counts[$j['key']];
    }
    $rows[] = $row;

    $job_parts = [];
    foreach ($switchlist_jobs as $j) {
        if ($j['staging']) {
            continue; // keep per-session line readable; staging in SCORE summary
        }
        $job_parts[] = $job_shorts[$j['key']] . '=' . $job_counts[$j['key']];
    }
    echo sprintf(
        "s%-2d %s coke=%d (MR=%d MP=%d) NVL[NI=%d Shen=%d Sth=%d Dem=%d MP=%d MR=%d]"
        . " | gen=%d fill=%d rep=%d wgh=%d rld=%d unf=%d%s"
        . " | Nev=%d Scul=%d(p=%d/o=%d/i=%d) Dem=%d Sth=%d%s\n",
        $row['s'],
        implode(' ', $job_parts),
        $row['coke'],
        $row['ck_mr'],
        $row['ck_mp'],
        $row['nvl_ni'],
        $row['nvl_shen'],
        $row['nvl_south'],
        $row['nvl_dem'],
        $row['nvl_mp'],
        $row['nvl_mr'],
        $row['gen'],
        $row['fill'],
        $row['rep'],
        $row['wgh'],
        $row['rld'],
        $row['unfilled'],
        $drain_canceled > 0 ? (' drain=' . $drain_canceled) : '',
        $row['nev'],
        $row['scul'],
        $row['scul_pressure'],
        $row['scul_orphan'],
        $row['scul_idle'],
        $row['dem'],
        $row['sth'],
        $row['notes'] !== '' ? (' | ' . $row['notes']) : ''
    );
}

// Optional warmup window: run all sessions but only score from this session on
// (e.g. STS_SCORE_FROM=11 warms 4-10 then scores 11..to_session).
$all_rows = $rows;
$score_from = (int) (getenv('STS_SCORE_FROM') ?: 0);
if ($score_from > 0) {
    $scored = array_values(array_filter($rows, fn ($r) => (int) ($r['s'] ?? 0) >= $score_from));
    if ($scored !== []) {
        $rows = $scored;
    }
}

$n = max(1, count($rows));
$avg = function (array $a) use ($n) {
    return $a === [] ? 0.0 : array_sum($a) / max(1, count($a));
};
$var = function (array $a) use ($avg) {
    if ($a === []) {
        return 0.0;
    }
    $m = $avg($a);
    $s = 0.0;
    foreach ($a as $v) {
        $s += ($v - $m) * ($v - $m);
    }
    return $s / max(1, count($a));
};

$cokes = array_column($rows, 'coke');
$nvlos = array_column($rows, 'nvlo');
$empty_nvl = count(array_filter($nvlos, fn ($x) => (int) $x <= 0));

/*
 * Score priorities (user-ranked):
 *  1) NVL Outbound never empty          ~20
 *  2) Coke MR/MP balance                ~15
 *  3) Coke session consistency (low var)~20
 *  4) Coke avg near ~6                  ~10
 *  5) Soft volume per switchlist job    ~35 (road jobs share; staging light)
 * Max ~100. Train volumes may swing; empty NVL Outbound is heavily penalized.
 */
$score = 0.0;
$score += 20.0 - min(20.0, $empty_nvl * 8.0);                 // (1) nonempty NVL Outbound
$mr = array_sum(array_column($rows, 'ck_mr'));
$mp = array_sum(array_column($rows, 'ck_mp'));
$tot = max(1, $mr + $mp);
$balance = 1.0 - abs($mr - $mp) / $tot;
$score += 15.0 * $balance;                                    // (2) MR/MP
$score += 20.0 - min(20.0, $var($cokes) * 2.0);               // (3) coke consistency
$score += 10.0 - min(10.0, abs($avg($cokes) - 6.0) * 2.5);   // (4) coke avg soft

$road_jobs = array_values(array_filter($switchlist_jobs, fn ($j) => empty($j['staging'])));
$stg_jobs = array_values(array_filter($switchlist_jobs, fn ($j) => !empty($j['staging'])));
$road_budget = 30.0;
$stg_budget = 5.0;
$job_avgs = [];
if ($road_jobs !== []) {
    $share = $road_budget / count($road_jobs);
    foreach ($road_jobs as $j) {
        $counts = [];
        foreach ($rows as $row) {
            $counts[] = (int) (($row['jobs'][$j['key']] ?? 0));
        }
        $a = $avg($counts);
        $job_avgs[$j['key']] = $a;
        // Soft volume: full share by ~8 cars avg; empty is 0 for that job.
        $score += min($share, $a * ($share / 8.0));
    }
}
if ($stg_jobs !== []) {
    $share = $stg_budget / count($stg_jobs);
    foreach ($stg_jobs as $j) {
        $counts = [];
        foreach ($rows as $row) {
            $counts[] = (int) (($row['jobs'][$j['key']] ?? 0));
        }
        $a = $avg($counts);
        $job_avgs[$j['key']] = $a;
        $score += min($share, $a * ($share / 6.0));
    }
}

$gen_avg = $avg(array_column($rows, 'gen'));
$fill_avg = $avg(array_column($rows, 'fill'));
$rep_avg = $avg(array_column($rows, 'rep'));
$wgh_avg = $avg(array_column($rows, 'wgh'));
$rld_avg = $avg(array_column($rows, 'rld'));
$unf_avg = $avg(array_column($rows, 'unfilled'));
$nev_avg = $avg(array_column($rows, 'nev'));
$scul_avg = $avg(array_column($rows, 'scul'));
$scul_pressure_avg = $avg(array_column($rows, 'scul_pressure'));
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
if ($empty_nvl >= 2) {
    $holdup = 'nvl_empty';
} elseif ($gen_avg < 8 || $gen_zero >= 2 || $gate_hits >= 2) {
    $holdup = 'shipments/gate';
} elseif ($stuck_hits >= 3 || $nev_avg > 20 || $scul_pressure_avg > 10 || $dem_avg > 12) {
    $holdup = 'stuck_yards';
} elseif ($wgh_avg > 0 && ($rld_avg / max(0.1, $wgh_avg)) > 0.2) {
    $holdup = 'reloads';
} elseif ($unf_avg > 25 && $fill_avg < $gen_avg * 0.5) {
    $holdup = 'fill_lag';
}

$job_summary = [];
foreach ($switchlist_jobs as $j) {
    $job_summary[] = $job_shorts[$j['key']] . '=' . sprintf('%.1f', $job_avgs[$j['key']] ?? 0.0);
}

echo sprintf(
    "SCORE=%.1f | coke_avg=%.1f coke_var=%.1f coke_MR=%d coke_MP=%d nvlo_empty=%d | jobs: %s\n",
    $score,
    $avg($cokes),
    $var($cokes),
    $mr,
    $mp,
    $empty_nvl,
    implode(' ', $job_summary)
);
echo sprintf(
    "HOLDUP=%s | gen_avg=%.1f fill_avg=%.1f rep_avg=%.1f wgh_avg=%.1f rld_avg=%.1f unf_avg=%.1f gen_zero=%d gate_hits=%d"
    . " | Nev=%.0f Scul=%.0f(p=%.0f) Dem=%.0f Sth=%.0f\n",
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
    $scul_pressure_avg,
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
    'coke_mr' => $mr,
    'coke_mp' => $mp,
    'nvlo_avg' => $avg($nvlos),
    'nvlo_empty' => $empty_nvl,
    'job_avgs' => $job_avgs,
    'job_labels' => array_column($switchlist_jobs, 'label', 'key'),
    'job_shorts' => $job_shorts,
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
    'scul_pressure_avg' => $scul_pressure_avg,
    'dem_avg' => $dem_avg,
    'sth_avg' => $sth_avg,
    'score_from' => $score_from,
    'scored_sessions' => count($rows),
    'note_bag' => $note_bag,
    'rows' => $all_rows,
], JSON_UNESCAPED_SLASHES) . "\n";
