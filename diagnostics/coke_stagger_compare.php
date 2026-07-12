<?php
/**
 * Compare coke bulk generation: both lanes every session vs odd/even stagger
 * (COKE-CLEV-BULK on odd sessions, COKE-USS-BULK on even sessions).
 *
 * Usage: php coke_stagger_compare.php [sessions] [workflow]
 */

if (PHP_SAPI !== 'cli') {
    exit(1);
}

if (is_file(__DIR__ . '/open_db.php')) {
    $sts_root = __DIR__;
    chdir($sts_root);
} else {
    require_once __DIR__ . '/bootstrap.php';
    $sts_root = diagnostics_resolve_runtime();
}
require_once $sts_root . '/open_db.php';
require_once $sts_root . '/session_helpers.php';
require_once $sts_root . '/operational_steps_catalog.php';
require_once $sts_root . '/generate_order_helpers.php';

$sessions = max(10, (int) ($argv[1] ?? 40));
$workflow_arg = $argv[2] ?? 'hart_session';

$editorDir = operational_steps_editor_dir();
$resolved = operational_steps_resolve_workflow_filename($editorDir, $workflow_arg);
$jsonPath = $resolved !== ''
    ? operational_steps_workflow_path($editorDir, $resolved)
    : (is_file($workflow_arg) ? $workflow_arg : '');
if ($jsonPath === '' || !is_file($jsonPath)) {
    fwrite(STDERR, "No workflow: {$workflow_arg}\n");
    exit(1);
}
$base_recipe = operational_steps_load_recipe_from_json_file($jsonPath);

/** Bump numeric workflow step targets after an insertion point (1-based step numbers). */
function coke_stagger_bump_step_refs(array &$steps, $after_step_1based, $delta)
{
    foreach ($steps as &$step) {
        $fid = $step['function'] ?? '';
        if ($fid !== 'if_then' && $fid !== 'goto') {
            continue;
        }
        $p = &$step['params'];
        if (!empty($p['_coke_skip'])) {
            continue;
        }
        if (isset($p['step']) && ctype_digit((string) $p['step'])) {
            $sn = (int) $p['step'];
            if ($sn > $after_step_1based) {
                $p['step'] = (string) ($sn + $delta);
            }
        }
        if (isset($p['section']) && preg_match('/^step-(\d+)$/', (string) $p['section'], $m)) {
            $sn = (int) $m[1];
            if ($sn > $after_step_1based) {
                $p['section'] = 'step-' . ($sn + $delta);
            }
        }
    }
    unset($step);
}

/**
 * Insert if_then guards so CLEV bulk runs on odd sessions only and USS on even only.
 */
function coke_stagger_recipe(array $recipe)
{
    $steps = $recipe['steps'] ?? [];
    $out = [];
    $inserted = 0;
    foreach ($steps as $step) {
        $fid = $step['function'] ?? '';
        $ship = trim((string) ($step['params']['shipment'] ?? ''));
        if ($fid === 'generate_orders' && $ship === 'COKE-CLEV-BULK') {
            $out[] = [
                'function' => 'if_then',
                'params' => [
                    'variable' => 'session_is_even',
                    'operator' => '=',
                    'value' => '1',
                    '_coke_skip' => true,
                ],
            ];
            $inserted++;
            $out[] = $step;
            continue;
        }
        if ($fid === 'generate_orders' && $ship === 'COKE-USS-BULK') {
            $out[] = [
                'function' => 'if_then',
                'params' => [
                    'variable' => 'session_is_odd',
                    'operator' => '=',
                    'value' => '1',
                    '_coke_skip' => true,
                ],
            ];
            $inserted++;
            $out[] = $step;
            continue;
        }
        $out[] = $step;
    }

    // First coke guard lands where CLEV used to be (step 6); bump later goto targets by 2.
    coke_stagger_bump_step_refs($out, 5, 2);

    for ($i = 0; $i < count($out); $i++) {
        if (!empty($out[$i]['params']['_coke_skip'])) {
            // Guard at $i, coke generate at $i+1, continue at $i+2 (1-based step $i+3).
            $out[$i]['params']['step'] = (string) ($i + 3);
            unset($out[$i]['params']['_coke_skip']);
        }
    }

    $recipe['steps'] = $out;
    $recipe['name'] = ($recipe['name'] ?? 'workflow') . '_coke_stagger';

    return $recipe;
}

function coke_stagger_station_count($dbc, $st)
{
    $q = mysqli_query($dbc, 'SELECT COUNT(*) FROM cars ca JOIN locations l ON ca.current_location_id=l.Id WHERE l.station=' . (int) $st);
    return $q ? (int) mysqli_fetch_row($q)[0] : -1;
}

function coke_stagger_session_metrics(array $log, $dbc, $session_nbr)
{
    $m = [
        'session' => (int) $session_nbr,
        'gen' => 0,
        'clev_gen' => 0,
        'uss_gen' => 0,
        'ck1_pickup' => 0,
        'nvl_move' => 0,
        'weighed' => 0,
        'neville' => coke_stagger_station_count($dbc, 3),
        'shenango' => coke_stagger_station_count($dbc, 12),
    ];
    foreach ($log as $e) {
        if (!is_array($e)) {
            continue;
        }
        if (array_key_exists('generated', $e)) {
            $g = (int) $e['generated'];
            $m['gen'] += $g;
            $ship = (string) ($e['shipment'] ?? '');
            if ($ship === 'COKE-CLEV-BULK') {
                $m['clev_gen'] += $g;
            } elseif ($ship === 'COKE-USS-BULK') {
                $m['uss_gen'] += $g;
            }
        }
        $job = strtoupper((string) ($e['job'] ?? ''));
        if (array_key_exists('picked_up', $e)) {
            if ($job === 'CK1') {
                $m['ck1_pickup'] += (int) $e['picked_up'];
            } elseif ($job === 'NVL') {
                $m['nvl_move'] += (int) $e['picked_up'];
            }
        }
        if (array_key_exists('set_out', $e) && $job === 'NVL') {
            $m['nvl_move'] += (int) $e['set_out'];
        }
        if (isset($e['weigh']) && is_array($e['weigh'])) {
            $m['weighed'] += (int) ($e['weigh']['weighed'] ?? 0);
        }
    }
    return $m;
}

function coke_stagger_cv(array $values)
{
    $n = count($values);
    if ($n < 2) {
        return 0.0;
    }
    $mean = array_sum($values) / $n;
    if ($mean < 0.01) {
        return 0.0;
    }
    $var = 0.0;
    foreach ($values as $v) {
        $var += ($v - $mean) ** 2;
    }
    return sqrt($var / ($n - 1)) / $mean;
}

function coke_stagger_run_mode($label, array $recipe, $sessions)
{
    $dbc = open_db();
    list($ok, $msg) = operational_steps_restore_backup($dbc, 'hart_seed', 'hart_seed');
    if (!$ok) {
        mysqli_close($dbc);
        throw new RuntimeException("restore failed: {$msg}");
    }

    $per_session = [];
    $totals = [
        'gen' => 0,
        'clev_gen' => 0,
        'uss_gen' => 0,
        'ck1_pickup' => 0,
        'nvl_move' => 0,
        'weighed' => 0,
        'gen_spike' => 0,
        'neville_sum' => 0,
        'shenango_sum' => 0,
        'unfilled_last' => 0,
    ];

    for ($run = 1; $run <= $sessions; $run++) {
        $res = session_run_recipe($dbc, $recipe, [
            'from_step' => 1,
            'reset_output' => ($run === 1),
            'format' => 'all',
        ]);
        $sess = (int) ($res['session'] ?? session_get_db_session($dbc));
        $m = coke_stagger_session_metrics($res['log'] ?? [], $dbc, $sess);
        $per_session[] = $m;
        foreach (['gen', 'clev_gen', 'uss_gen', 'ck1_pickup', 'nvl_move', 'weighed'] as $k) {
            $totals[$k] += $m[$k];
        }
        if ($m['gen'] >= 50) {
            $totals['gen_spike']++;
        }
        $totals['neville_sum'] += $m['neville'];
        $totals['shenango_sum'] += $m['shenango'];
        $totals['unfilled_last'] = generate_orders_count_unfilled($dbc);
    }
    mysqli_close($dbc);

    $gen_series = array_column($per_session, 'gen');
    $nvl_series = array_column($per_session, 'nvl_move');

    return [
        'label' => $label,
        'gen_avg' => $totals['gen'] / $sessions,
        'gen_cv' => coke_stagger_cv($gen_series),
        'gen_spikes' => $totals['gen_spike'],
        'gen_max' => max($gen_series),
        'clev_gen_total' => $totals['clev_gen'],
        'uss_gen_total' => $totals['uss_gen'],
        'nvl_move_avg' => $totals['nvl_move'] / $sessions,
        'nvl_cv' => coke_stagger_cv($nvl_series),
        'ck1_pickup_avg' => $totals['ck1_pickup'] / $sessions,
        'weighed_avg' => $totals['weighed'] / $sessions,
        'neville_avg' => $totals['neville_sum'] / $sessions,
        'shenango_avg' => $totals['shenango_sum'] / $sessions,
        'unfilled_last' => $totals['unfilled_last'],
        'per_session' => $per_session,
    ];
}

echo "Coke bulk stagger comparison\n";
echo "Workflow base: {$jsonPath}\n";
echo "Sessions per mode: {$sessions}\n";
echo "Seed: nvl_steady profile (apply hart_seed before running)\n";
echo str_repeat('=', 100) . "\n";

$modes = [
    'both_every' => $base_recipe,
    'odd_even' => coke_stagger_recipe($base_recipe),
];

$results = [];
foreach ($modes as $key => $recipe) {
    $title = $key === 'both_every'
        ? 'Both bulk lanes every session (current)'
        : 'Staggered: CLEV odd / USS even';
    echo "==> {$title}\n";
    $results[$key] = coke_stagger_run_mode($title, $recipe, $sessions);
    $r = $results[$key];
    printf(
        "   Gen avg=%.1f CV=%.2f max=%d spikes(>=50)=%d | CLEV gen=%d USS gen=%d\n",
        $r['gen_avg'],
        $r['gen_cv'],
        $r['gen_max'],
        $r['gen_spikes'],
        $r['clev_gen_total'],
        $r['uss_gen_total']
    );
    printf(
        "   NVL move/sess=%.1f CV=%.2f CK1pu=%.1f Wgh=%.1f Nev=%.0f Shen=%.0f Unfl=%d\n",
        $r['nvl_move_avg'],
        $r['nvl_cv'],
        $r['ck1_pickup_avg'],
        $r['weighed_avg'],
        $r['neville_avg'],
        $r['shenango_avg'],
        $r['unfilled_last']
    );
}

echo str_repeat('=', 100) . "\n";
printf(
    "%-28s | %-8s %-5s %-5s %-4s | %-6s %-6s | %-6s %-5s | %s\n",
    'Mode',
    'GenAvg',
    'GenCV',
    'NVLmv',
    'Spk',
    'CLEV',
    'USS',
    'CK1pu',
    'Unfl',
    'Winner?'
);
echo str_repeat('-', 100) . "\n";

$b = $results['both_every'];
$s = $results['odd_even'];

$score_b = $b['nvl_move_avg'] * 8 - $b['gen_cv'] * 20 - $b['nvl_cv'] * 15 - $b['gen_spikes'] * 5 + min($b['ck1_pickup_avg'], 8) * 2;
$score_s = $s['nvl_move_avg'] * 8 - $s['gen_cv'] * 20 - $s['nvl_cv'] * 15 - $s['gen_spikes'] * 5 + min($s['ck1_pickup_avg'], 8) * 2;

foreach ($results as $key => $r) {
    $score = $key === 'both_every' ? $score_b : $score_s;
    $win = ($key === 'both_every' && $score_b >= $score_s) || ($key === 'odd_even' && $score_s > $score_b)
        ? 'YES' : '';
    printf(
        "%-28s | %-8.1f %-5.2f %-5.1f %-4d | %-6d %-6d | %-6.1f %-5d | %s\n",
        $r['label'],
        $r['gen_avg'],
        $r['gen_cv'],
        $r['nvl_move_avg'],
        $r['gen_spikes'],
        $r['clev_gen_total'],
        $r['uss_gen_total'],
        $r['ck1_pickup_avg'],
        $r['unfilled_last'],
        $win
    );
}

$winner = $score_s > $score_b ? 'odd_even' : 'both_every';
echo "\nRecommendation: " . ($winner === 'odd_even' ? 'USE odd/even stagger' : 'KEEP both every session') . "\n";
if ($winner === 'odd_even') {
    echo "  Add if_then guards before each coke bulk generate_orders step:\n";
    echo "    - If session is even = 1, skip COKE-CLEV-BULK (odd sessions only)\n";
    echo "    - If session is odd = 1, skip COKE-USS-BULK (even sessions only)\n";
}

// Sample per-session gen for sessions 1-15
echo "\nPer-session Gen (sessions 1-15):\n";
printf("%-6s", 'Sess');
foreach ($results as $key => $r) {
    printf(' | %-12s', $key === 'both_every' ? 'both' : 'stagger');
}
echo "\n";
for ($i = 0; $i < min(15, $sessions); $i++) {
    printf('%-6d', $i + 1);
    foreach ($results as $r) {
        printf(' | %-12d', $r['per_session'][$i]['gen'] ?? 0);
    }
    echo "\n";
}
