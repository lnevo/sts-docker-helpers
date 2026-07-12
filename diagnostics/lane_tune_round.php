<?php
/**
 * One lane-tuning round (seed must already be applied). Uses workflow as-is
 * (max_new=14, no gate, random seed). Reports NVL vs interchange balance +
 * per-station action totals.
 *
 * Usage: php lane_tune_round.php <sessions> <workflow> <scenario_key>
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

$sessions = max(5, (int) ($argv[1] ?? 10));
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
$recipe = lane_neutralize_internal_restore($recipe);

function lane_neutralize_internal_restore(array $recipe)
{
    foreach ($recipe['steps'] ?? [] as $i => $step) {
        if (($step['function'] ?? '') === 'if_then' && ($step['params']['variable'] ?? '') === 'session_nbr') {
            $recipe['steps'][$i]['params']['operator'] = '>';
            $recipe['steps'][$i]['params']['value'] = '-1';
            break;
        }
    }
    return $recipe;
}

function lane_station_names($dbc)
{
    static $cache = null;
    if ($cache !== null) {
        return $cache;
    }
    $cache = [];
    $rs = mysqli_query($dbc, 'SELECT id, station AS name FROM routing ORDER BY sort_seq, station');
    if ($rs) {
        while ($row = mysqli_fetch_assoc($rs)) {
            $cache[(int) $row['id']] = (string) $row['name'];
        }
    }
    return $cache;
}

function lane_station_from_loc_id($dbc, $loc_id)
{
    $loc_id = (int) $loc_id;
    if ($loc_id <= 0) {
        return 'Unknown';
    }
    $rs = mysqli_query($dbc, 'SELECT station FROM locations WHERE id=' . $loc_id . ' LIMIT 1');
    $row = $rs ? mysqli_fetch_assoc($rs) : null;
    if (!$row) {
        return 'Loc#' . $loc_id;
    }
    $names = lane_station_names($dbc);
    return $names[(int) $row['station']] ?? ('Station#' . (int) $row['station']);
}

function lane_station_label($dbc, $key)
{
    $key = trim((string) $key);
    if ($key === '') {
        return 'Various';
    }
    if (ctype_digit($key)) {
        $names = lane_station_names($dbc);
        return $names[(int) $key] ?? ('Station#' . $key);
    }
    return $key;
}

function lane_empty_actions()
{
    return ['pickup' => 0, 'setout' => 0, 'assign' => 0, 'weigh' => 0];
}

function lane_add_action(array &$totals, $station, $kind, $n)
{
    if ($n <= 0) {
        return;
    }
    if (!isset($totals[$station])) {
        $totals[$station] = lane_empty_actions();
    }
    $totals[$station][$kind] += $n;
}

function lane_aggregate_station_actions(array $log, array $recipe, $dbc)
{
    $steps = $recipe['steps'] ?? [];
    $totals = [];
    foreach ($log as $entry) {
        if (!is_array($entry) || !empty($entry['skipped'])) {
            continue;
        }
        $step_n = (int) ($entry['step'] ?? 0);
        $params = is_array($steps[$step_n - 1]['params'] ?? null) ? $steps[$step_n - 1]['params'] : [];

        if (array_key_exists('picked_up', $entry) && (int) $entry['picked_up'] > 0) {
            $loc = trim((string) ($params['location'] ?? ''));
            if ($loc !== '') {
                $st = operational_steps_location_station_id($dbc, $loc);
                lane_add_action($totals, lane_station_label($dbc, $st > 0 ? (string) $st : $loc), 'pickup', (int) $entry['picked_up']);
            } else {
                lane_add_action($totals, 'Various', 'pickup', (int) $entry['picked_up']);
            }
        }
        if (array_key_exists('set_out', $entry) && (int) $entry['set_out'] > 0) {
            $n = (int) $entry['set_out'];
            if (!empty($entry['assign_destinations'])) {
                lane_add_action($totals, 'Auto-dest', 'setout', $n);
            } elseif (!empty($entry['location_id'])) {
                lane_add_action($totals, lane_station_from_loc_id($dbc, $entry['location_id']), 'setout', $n);
            } else {
                $loc = trim((string) ($params['location'] ?? ''));
                if ($loc !== '' && !operational_steps_setout_auto_assign_destinations($loc)) {
                    $loc_id = operational_steps_resolve_location_id($dbc, $loc);
                    lane_add_action($totals, lane_station_from_loc_id($dbc, $loc_id), 'setout', $n);
                } else {
                    lane_add_action($totals, 'Auto-dest', 'setout', $n);
                }
            }
        }
        if (array_key_exists('assigned', $entry) && (int) $entry['assigned'] > 0) {
            $st_key = trim((string) ($params['station'] ?? ''));
            lane_add_action($totals, $st_key !== '' ? lane_station_label($dbc, $st_key) : 'Various', 'assign', (int) $entry['assigned']);
        }
        if (isset($entry['weigh']) && is_array($entry['weigh']) && (int) ($entry['weigh']['weighed'] ?? 0) > 0) {
            lane_add_action($totals, 'South Yard (scale)', 'weigh', (int) $entry['weigh']['weighed']);
        }
    }
    uksort($totals, 'strnatcasecmp');
    return $totals;
}

function lane_station_count($dbc, $st)
{
    $q = mysqli_query($dbc, 'SELECT COUNT(*) FROM cars ca JOIN locations l ON ca.current_location_id=l.Id WHERE l.station=' . (int) $st);
    return $q ? (int) mysqli_fetch_row($q)[0] : 0;
}

function lane_cv(array $values)
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

$station_actions = [];
$gen_series = [];
$nvl_series = [];
$ix_series = [];
$totals = [
    'gen' => 0, 'fill' => 0, 'sout' => 0,
    'nvl_pickup' => 0, 'nvl_setout' => 0,
    'd749_pickup' => 0, 'stg_move' => 0,
    'ck1_pickup' => 0, 'weighed' => 0,
    'neville_sum' => 0, 'demmler_sum' => 0, 'scully_sum' => 0,
];

for ($run = 1; $run <= $sessions; $run++) {
    $res = session_run_recipe($dbc, $recipe, [
        'from_step' => 1,
        'reset_output' => ($run === 1),
        'format' => 'all',
    ]);
    $log = $res['log'] ?? [];
    $gen = 0;
    $nvl_sess = 0;
    $ix_sess = 0;

    foreach ($log as $e) {
        if (!is_array($e)) {
            continue;
        }
        if (array_key_exists('generated', $e)) {
            $gen += (int) $e['generated'];
        }
        if (array_key_exists('filled', $e)) {
            $totals['fill'] += (int) $e['filled'];
        }
        if (array_key_exists('set_out', $e)) {
            $totals['sout'] += (int) $e['set_out'];
        }
        $job = strtoupper((string) ($e['job'] ?? ''));
        if (array_key_exists('picked_up', $e)) {
            $pu = (int) $e['picked_up'];
            if ($job === 'NVL') {
                $totals['nvl_pickup'] += $pu;
                $nvl_sess += $pu;
            } elseif ($job === 'D749') {
                $totals['d749_pickup'] += $pu;
                $ix_sess += $pu;
            } elseif ($job === 'CK1') {
                $totals['ck1_pickup'] += $pu;
            } elseif (strpos($job, 'STG-') === 0) {
                $totals['stg_move'] += $pu;
                $ix_sess += $pu;
            }
        }
        if (array_key_exists('set_out', $e)) {
            $so = (int) $e['set_out'];
            if ($job === 'NVL') {
                $totals['nvl_setout'] += $so;
                $nvl_sess += $so;
            } elseif ($job === 'D749' || strpos($job, 'STG-') === 0) {
                $ix_sess += $so;
            }
        }
        if (isset($e['weigh']) && is_array($e['weigh'])) {
            $totals['weighed'] += (int) ($e['weigh']['weighed'] ?? 0);
        }
    }

    $gen_series[] = $gen;
    $nvl_series[] = $nvl_sess;
    $ix_series[] = $ix_sess;
    $totals['gen'] += $gen;
    $totals['neville_sum'] += lane_station_count($dbc, 3);
    $totals['demmler_sum'] += lane_station_count($dbc, 10);
    $totals['scully_sum'] += lane_station_count($dbc, 9);

    foreach (lane_aggregate_station_actions($log, $recipe, $dbc) as $st => $acts) {
        if (!isset($station_actions[$st])) {
            $station_actions[$st] = lane_empty_actions();
        }
        foreach ($acts as $k => $v) {
            $station_actions[$st][$k] += $v;
        }
    }
}

$yards_last = [];
foreach (session_station_car_counts($dbc) as $row) {
    $yards_last[(string) $row['station_name']] = (int) $row['car_count'];
}
$unfilled = generate_orders_count_unfilled($dbc);
mysqli_close($dbc);

$nvl_move = $totals['nvl_pickup'] + $totals['nvl_setout'];
$ix_move = $totals['d749_pickup'] + $totals['stg_move'] + ($totals['sout'] - $totals['nvl_setout']);
$nvl_avg = $nvl_move / $sessions;
$ix_avg = array_sum($ix_series) / $sessions;

$summary = [
    'scenario' => $scenario_key,
    'sessions' => $sessions,
    'gen_avg' => $totals['gen'] / $sessions,
    'gen_cv' => lane_cv($gen_series),
    'sout_avg' => $totals['sout'] / $sessions,
    'nvl_move_avg' => $nvl_avg,
    'nvl_cv' => lane_cv($nvl_series),
    'ix_move_avg' => $ix_avg,
    'ix_cv' => lane_cv($ix_series),
    'nvl_ix_ratio' => $ix_avg > 0.01 ? ($nvl_avg / $ix_avg) : $nvl_avg,
    'ck1_pickup_avg' => $totals['ck1_pickup'] / $sessions,
    'weighed_avg' => $totals['weighed'] / $sessions,
    'neville_avg' => $totals['neville_sum'] / $sessions,
    'demmler_avg' => $totals['demmler_sum'] / $sessions,
    'scully_avg' => $totals['scully_sum'] / $sessions,
    'unfilled_last' => $unfilled,
    'station_actions' => $station_actions,
    'yards_last' => $yards_last,
];

$nvl_island = ($station_actions['Neville Island']['pickup'] ?? 0) + ($station_actions['Neville Island']['setout'] ?? 0);
$ix_demmler = ($station_actions['Demmler Yard']['pickup'] ?? 0) + ($station_actions['Demmler Yard']['setout'] ?? 0)
    + ($station_actions['Demmler Yard']['assign'] ?? 0);
$ix_scully = ($station_actions['Scully Yard']['pickup'] ?? 0) + ($station_actions['Scully Yard']['setout'] ?? 0)
    + ($station_actions['Scully Yard']['assign'] ?? 0);
$summary['nvl_island_actions'] = $nvl_island;
$summary['ix_demmler_actions'] = $ix_demmler;
$summary['ix_scully_actions'] = $ix_scully;

$score = $summary['sout_avg'] * 2
    + $summary['nvl_move_avg'] * 4
    + $summary['ix_move_avg'] * 1.5
    - $summary['gen_cv'] * 15
    - $summary['nvl_cv'] * 10
    - max(0, $summary['neville_avg'] - 12) * 3
    - max(0, $summary['unfilled_last'] - 35) * 0.3;
// Prefer balanced NVL: not starving island (nvl_island > 40 over 10 sess) nor flooding Neville
if ($nvl_island < 35) {
    $score -= (35 - $nvl_island) * 0.5;
}
if ($nvl_island > 90) {
    $score -= ($nvl_island - 90) * 0.3;
}
$summary['score'] = round($score, 1);

echo 'LANE_TUNE_JSON=' . json_encode($summary) . "\n";
