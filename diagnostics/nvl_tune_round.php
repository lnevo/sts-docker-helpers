<?php
/**
 * Run one NVL tuning simulation round (seed must already be applied).
 *
 * Usage: php nvl_tune_round.php <sessions> <workflow> [scenario_key]
 * Prints one JSON summary line prefixed with NVL_TUNE_JSON=
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

$sessions = max(10, (int) ($argv[1] ?? 25));
$workflow_arg = $argv[2] ?? 'hart_session';
$scenario_key = $argv[3] ?? 'run';

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

function nvl_station_count($dbc, $st)
{
    $q = mysqli_query($dbc, 'SELECT COUNT(*) FROM cars ca JOIN locations l ON ca.current_location_id=l.Id WHERE l.station=' . (int) $st);
    return $q ? (int) mysqli_fetch_row($q)[0] : -1;
}

function nvl_round_metrics(array $log, $dbc)
{
    $m = [
        'gen_zero_sessions' => 0,
        'nvl_pickup' => 0,
        'nvl_setout' => 0,
        'nvl_lists' => 0,
        'ck1_pickup' => 0,
        'weighed' => 0,
        'neville' => nvl_station_count($dbc, 3),
        'shenango' => nvl_station_count($dbc, 12),
        'scully' => nvl_station_count($dbc, 9),
        'unfilled' => generate_orders_count_unfilled($dbc),
    ];
    foreach ($log as $e) {
        if (!is_array($e)) {
            continue;
        }
        if (array_key_exists('generated', $e) && (int) $e['generated'] === 0) {
            $m['gen_zero_sessions']++;
        }
        $job = strtoupper((string) ($e['job'] ?? ''));
        if (array_key_exists('picked_up', $e)) {
            if ($job === 'NVL') {
                $m['nvl_pickup'] += (int) $e['picked_up'];
            } elseif ($job === 'CK1') {
                $m['ck1_pickup'] += (int) $e['picked_up'];
            }
        }
        if (array_key_exists('set_out', $e) && $job === 'NVL') {
            $m['nvl_setout'] += (int) $e['set_out'];
        }
        if (isset($e['weigh']) && is_array($e['weigh'])) {
            $m['weighed'] += (int) ($e['weigh']['weighed'] ?? 0);
        }
        if (array_key_exists('written', $e) && is_array($e['written'])) {
            foreach ($e['written'] as $w) {
                if (!is_array($w) || (int) ($w['phases'] ?? 0) < 1 || !empty($w['empty'])) {
                    continue;
                }
                if (strtoupper((string) ($w['job'] ?? '')) === 'NVL') {
                    $m['nvl_lists']++;
                }
            }
        }
    }
    return $m;
}

function nvl_cv(array $values)
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

$dbc = open_db();
list($ok, $msg) = operational_steps_restore_backup($dbc, 'hart_seed', 'hart_seed');
if (!$ok) {
    fwrite(STDERR, "RESTORE FAILED: {$msg}\n");
    exit(1);
}

$per_session = [];
$totals = [
    'gen_zero' => 0,
    'nvl_pickup' => 0,
    'nvl_setout' => 0,
    'nvl_lists' => 0,
    'ck1_pickup' => 0,
    'weighed' => 0,
    'neville_sum' => 0,
    'shenango_sum' => 0,
    'scully_sum' => 0,
    'unfilled_last' => 0,
];

for ($run = 1; $run <= $sessions; $run++) {
    $res = session_run_recipe($dbc, $recipe, [
        'from_step' => 1,
        'reset_output' => ($run === 1),
        'format' => 'all',
    ]);
    $m = nvl_round_metrics($res['log'] ?? [], $dbc);
    $per_session[] = $m['nvl_pickup'] + $m['nvl_setout'];
    $totals['gen_zero'] += $m['gen_zero_sessions'];
    foreach (['nvl_pickup', 'nvl_setout', 'nvl_lists', 'ck1_pickup', 'weighed'] as $k) {
        $totals[$k] += $m[$k];
    }
    $totals['neville_sum'] += $m['neville'];
    $totals['shenango_sum'] += $m['shenango'];
    $totals['scully_sum'] += $m['scully'];
    $totals['unfilled_last'] = $m['unfilled'];
}
mysqli_close($dbc);

$summary = [
    'scenario' => $scenario_key,
    'sessions' => $sessions,
    'nvl_move_avg' => ($totals['nvl_pickup'] + $totals['nvl_setout']) / $sessions,
    'nvl_cv' => nvl_cv($per_session),
    'nvl_lists_avg' => $totals['nvl_lists'] / $sessions,
    'ck1_pickup_avg' => $totals['ck1_pickup'] / $sessions,
    'gen_zero' => $totals['gen_zero'],
    'neville_avg' => $totals['neville_sum'] / $sessions,
    'shenango_avg' => $totals['shenango_sum'] / $sessions,
    'scully_avg' => $totals['scully_sum'] / $sessions,
    'unfilled_last' => $totals['unfilled_last'],
    'weighed_avg' => $totals['weighed'] / $sessions,
];

echo 'NVL_TUNE_JSON=' . json_encode($summary) . "\n";
