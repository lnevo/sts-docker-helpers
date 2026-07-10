<?php
/**
 * Session output (/session/), phase manifest, waybills, recipe control flow.
 */

require_once __DIR__ . '/warm_start_helpers.php';

function session_web_root()
{
    return '/var/www/html/session';
}

function session_repo_root($helpers_root = null)
{
    if ($helpers_root === null) {
        $helpers_root = dirname(__DIR__);
    }
    return rtrim($helpers_root, '/') . '/../session';
}

function session_dir_for($session_nbr, $root = null)
{
    $root = $root ?? session_web_root();
    return rtrim($root, '/') . '/session_' . (int) $session_nbr;
}

function session_manifest_path($session_nbr, $root = null)
{
    return session_dir_for($session_nbr, $root) . '/manifest.json';
}

function session_load_manifest($session_nbr, $root = null)
{
    $path = session_manifest_path($session_nbr, $root);
    if (!is_readable($path)) {
        return ['session' => (string) $session_nbr, 'phases' => [], 'jobs' => []];
    }
    $data = json_decode(file_get_contents($path), true);
    return is_array($data) ? $data : ['session' => (string) $session_nbr, 'phases' => [], 'jobs' => []];
}

function session_save_manifest($session_nbr, array $manifest, $root = null)
{
    $dir = session_dir_for($session_nbr, $root);
    if (!is_dir($dir)) {
        mkdir($dir, 0755, true);
    }
    $manifest['session'] = (string) $session_nbr;
    $manifest['updated'] = date('c');
    file_put_contents(session_manifest_path($session_nbr, $root), json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    session_write_session_index($session_nbr, $root);
}

function session_write_session_index($session_nbr, $root = null)
{
    $dir = session_dir_for($session_nbr, $root);
    if (!is_dir($dir)) {
        mkdir($dir, 0755, true);
    }
    $template = dirname(__DIR__) . '/session/session_index_template.php';
    if (is_readable($template)) {
        copy($template, $dir . '/index.php');
    }
}

function session_condition_variables()
{
    return [
        ['key' => 'session_nbr', 'label' => 'Session number'],
        ['key' => 'unfilled_count', 'label' => 'Unfilled order count'],
        ['key' => 'stg_backlog_eligible', 'label' => 'STG backlog eligible at Scully'],
        ['key' => 'stg_backlog_on_jobs', 'label' => 'STG backlog on staging jobs'],
        ['key' => 'cars_on_job', 'label' => 'Cars on job (param: job name)'],
        ['key' => 'cars_at_location', 'label' => 'Cars at location (param: location code)'],
        ['key' => 'awaiting_assignment', 'label' => 'Cars awaiting assignment'],
    ];
}

function session_condition_operators()
{
    return ['=', '!=', '<', '<=', '>', '>='];
}

function session_evaluate_context($dbc, array $config = [])
{
    $session = warm_start_get_session($dbc);
    $staging = warm_start_staging_job_names($dbc, $config);
    $scully = warm_start_staging_backlog_for_job($dbc, 'STG-SCULLY', $config);
    $summary = warm_start_summarize($dbc);
    return [
        'session_nbr' => (int) $session,
        'unfilled_count' => warm_start_count_unfilled($dbc),
        'stg_backlog_eligible' => (int) ($scully['eligible'] ?? 0),
        'stg_backlog_on_jobs' => (int) ($scully['on_jobs'] ?? 0),
        'awaiting_assignment' => (int) ($summary['awaiting_assignment'] ?? 0),
        '_dbc' => $dbc,
        '_config' => $config,
    ];
}

function session_evaluate_condition(array $ctx, $variable, $operator, $value, array $extra = [])
{
    $left = null;
    switch ($variable) {
        case 'session_nbr':
        case 'unfilled_count':
        case 'stg_backlog_eligible':
        case 'stg_backlog_on_jobs':
        case 'awaiting_assignment':
            $left = (float) ($ctx[$variable] ?? 0);
            break;
        case 'cars_on_job':
            $job = trim($extra['job'] ?? $value);
            $dbc = $ctx['_dbc'];
            $jid = warm_start_job_id($dbc, $job);
            if ($jid <= 0) {
                $left = 0;
            } else {
                $rs = mysqli_query($dbc, 'SELECT COUNT(*) AS c FROM cars WHERE handled_by_job_id = "' . (int) $jid . '" AND current_location_id = 0');
                $left = (float) mysqli_fetch_array($rs)['c'];
            }
            break;
        case 'cars_at_location':
            $loc = trim($extra['location'] ?? $value);
            $dbc = $ctx['_dbc'];
            $lid = warm_start_location_id_by_code($dbc, strtoupper($loc));
            if ($lid <= 0) {
                $left = 0;
            } else {
                $rs = mysqli_query($dbc, 'SELECT COUNT(*) AS c FROM cars WHERE current_location_id = "' . (int) $lid . '"');
                $left = (float) mysqli_fetch_array($rs)['c'];
            }
            break;
        default:
            return true;
    }
    $right = (float) $value;
    switch ($operator) {
        case '=': return $left == $right;
        case '!=': return $left != $right;
        case '<': return $left < $right;
        case '<=': return $left <= $right;
        case '>': return $left > $right;
        case '>=': return $left >= $right;
        default: return true;
    }
}

function session_manual_generate_shipment($dbc, $shipment_code)
{
    $session = warm_start_get_session($dbc);
    $code_esc = mysqli_real_escape_string($dbc, $shipment_code);
    $rs = mysqli_query($dbc, 'SELECT id, min_amount, max_amount FROM shipments WHERE code = "' . $code_esc . '" LIMIT 1');
    if (!$rs || mysqli_num_rows($rs) === 0) {
        return ['generated' => 0, 'error' => 'Shipment not found: ' . $shipment_code];
    }
    $ship = mysqli_fetch_array($rs);
    $shipment_id = (int) $ship['id'];
    mysqli_query($dbc, 'UPDATE shipments SET last_ship_date = ' . (int) $session . ' WHERE id = "' . $shipment_id . '"');

    $rs = mysqli_query($dbc, 'SELECT max(substr(waybill_number, 6, 2)) FROM car_orders WHERE waybill_number LIKE "' . str_pad($session, 3, '0', STR_PAD_LEFT) . '-M__"');
    $row = mysqli_fetch_row($rs);
    $order_counter = (int) ($row[0] ?? 0);

    $min_amount = (float) $ship['min_amount'];
    $max_amount = (float) $ship['max_amount'];
    $num_cars = max(1, (int) round(mt_rand((int) ($min_amount * 100), (int) ($max_amount * 100)) / 100));

    $generated = 0;
    for ($j = 0; $j < $num_cars; $j++) {
        $order_counter++;
        $wb = str_pad($session, 3, '0', STR_PAD_LEFT) . '-M' . str_pad($order_counter, 2, '0', STR_PAD_LEFT);
        if (!mysqli_query($dbc, 'INSERT INTO car_orders (waybill_number, shipment, car) VALUES ("' . mysqli_real_escape_string($dbc, $wb) . '", "' . $shipment_id . '", "0")')) {
            break;
        }
        $generated++;
    }
    return ['generated' => $generated, 'shipment' => $shipment_code, 'session' => $session];
}

function session_resolve_jobs_param($jobs_param)
{
    $jobs_param = trim((string) $jobs_param);
    if ($jobs_param === '' || strtolower($jobs_param) === 'all') {
        return ['D749', 'NVL', 'CK1'];
    }
    return array_values(array_filter(array_map('trim', explode(',', $jobs_param))));
}

function session_phase_output_dir($session_nbr, $phase_num, $root = null)
{
    return session_dir_for($session_nbr, $root) . '/phase_' . str_pad((int) $phase_num, 2, '0', STR_PAD_LEFT);
}

function session_register_phase(array &$manifest, $phase_num, array $meta)
{
    $manifest['phases'] = $manifest['phases'] ?? [];
    $manifest['phases'][] = array_merge(['phase' => (int) $phase_num], $meta);
    foreach ($meta['jobs'] ?? [] as $job) {
        if (!isset($manifest['jobs'][$job])) {
            $manifest['jobs'][$job] = ['phases' => []];
        }
        if (!in_array((int) $phase_num, $manifest['jobs'][$job]['phases'], true)) {
            $manifest['jobs'][$job]['phases'][] = (int) $phase_num;
        }
    }
}

function session_generate_waybills_for_phase($dbc, $session_nbr, $phase_num, $root = null)
{
    $root = $root ?? session_web_root();
    $out_dir = session_phase_output_dir($session_nbr, $phase_num, $root) . '/waybills';
    if (!is_dir($out_dir)) {
        mkdir($out_dir, 0755, true);
    }

    $session = (int) $session_nbr;
    $rs = mysqli_query(
        $dbc,
        'SELECT car_orders.waybill_number, car_orders.car, shipments.code AS shipment_code,
                shipments.description, commodities.description AS commodity
         FROM car_orders
         INNER JOIN shipments ON shipments.id = car_orders.shipment
         LEFT JOIN commodities ON commodities.id = shipments.commodity
         WHERE car_orders.waybill_number LIKE "' . str_pad($session, 3, '0', STR_PAD_LEFT) . '-%"
         ORDER BY car_orders.waybill_number'
    );

    $rows = [];
    while ($row = mysqli_fetch_array($rs)) {
        $rows[] = $row;
    }

    $cards = '';
    foreach ($rows as $row) {
        $wb = htmlspecialchars($row['waybill_number']);
        $cards .= '<div class="card"><h3>' . $wb . '</h3>'
            . '<p><strong>Shipment:</strong> ' . htmlspecialchars($row['shipment_code']) . '</p>'
            . '<p>' . htmlspecialchars($row['description'] ?? '') . '</p>'
            . '<p><em>' . htmlspecialchars($row['commodity'] ?? '') . '</em></p>'
            . '<p>Car: ' . htmlspecialchars($row['car'] ?: 'unassigned') . '</p>'
            . '<a href="/sts/printable_waybill.php" target="_blank">Print in STS</a></div>';
    }

    $html = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Waybills session ' . $session . ' phase ' . (int) $phase_num . '</title>'
        . '<style>body{font-family:sans-serif;max-width:960px;margin:0 auto;padding:16px}.card{border:1px solid #ccc;border-radius:8px;padding:12px;margin:12px 0}</style></head><body>'
        . '<nav><a href="../index.php">← Phase</a> · <a href="../../index.php">Session</a> · <a href="/session/index.php">All sessions</a></nav>'
        . '<h1>Waybills — session ' . $session . ', phase ' . (int) $phase_num . '</h1>'
        . ($cards !== '' ? $cards : '<p>No waybills for this session.</p>')
        . '</body></html>';
    file_put_contents($out_dir . '/index.html', $html);
    return ['path' => $out_dir . '/index.html', 'count' => count($rows)];
}

function session_run_recipe($dbc, array $recipe, array $options = [])
{
    require_once __DIR__ . '/operational_steps_catalog.php';
    require_once __DIR__ . '/master_switchlist_helpers.php';
    $config = warm_start_merge_config($options['config'] ?? []);
    $format = $options['format'] ?? 'phased';
    $root = $options['session_root'] ?? session_web_root();
    $from_step = max(1, (int) ($options['from_step'] ?? 1));
    $to_step = min(count($recipe['steps'] ?? []), (int) ($options['to_step'] ?? count($recipe['steps'] ?? [])));
    $session_nbr = warm_start_get_session($dbc);
    $manifest = session_load_manifest($session_nbr, $root);
    $phase_num = count($manifest['phases'] ?? []);
    $ctx = session_evaluate_context($dbc, $config);
    $log = [];
    $stopped = false;

    for ($pc = $from_step - 1; $pc < $to_step; $pc++) {
        $step = $recipe['steps'][$pc] ?? null;
        if (!is_array($step)) {
            continue;
        }
        $n = $pc + 1;
        $fid = $step['function'] ?? '';

        if ($fid === 'stop') {
            $stopped = true;
            $log[] = ['step' => $n, 'action' => 'stop'];
            break;
        }
        if ($fid === 'goto') {
            $target = (int) ($step['params']['step'] ?? 0);
            if ($target >= 1 && $target <= count($recipe['steps'])) {
                $pc = $target - 2;
                $log[] = ['step' => $n, 'action' => 'goto', 'target' => $target];
            }
            continue;
        }
        if ($fid === 'if_then') {
            $p = $step['params'] ?? [];
            $ok = session_evaluate_condition(
                $ctx,
                $p['variable'] ?? 'session_nbr',
                $p['operator'] ?? '=',
                $p['value'] ?? '0',
                $p
            );
            $log[] = ['step' => $n, 'action' => 'if_then', 'result' => $ok];
            if (!$ok) {
                $pc++;
            }
            continue;
        }
        if ($fid === 'section_label') {
            $log[] = ['step' => $n, 'action' => 'section_label', 'label' => $step['params']['label'] ?? ''];
            continue;
        }

        if ($fid === 'generate_switchlists') {
            $phase_num++;
            $jobs = session_resolve_jobs_param($step['params']['jobs'] ?? 'all');
            $phase_dir = session_phase_output_dir($session_nbr, $phase_num, $root);
            $fmt = $step['params']['format'] ?? $format;
            $written = master_sw_generate_for_jobs($dbc, $jobs, $phase_dir, $config, ['format' => $fmt]);
            session_register_phase($manifest, $phase_num, [
                'step' => $n,
                'jobs' => $jobs,
                'format' => $fmt,
                'label' => operational_steps_compile_recipe(['steps' => [$step]])[0]['instruction'] ?? 'Generate Switch Lists',
                'output' => $phase_dir,
            ]);
            $log[] = ['step' => $n, 'phase' => $phase_num, 'written' => $written];
            continue;
        }
        if ($fid === 'generate_waybills') {
            if ($phase_num < 1) {
                $phase_num = 1;
            }
            $wb = session_generate_waybills_for_phase($dbc, $session_nbr, $phase_num, $root);
            $log[] = ['step' => $n, 'phase' => $phase_num, 'waybills' => $wb];
            continue;
        }

        $dispatch_opts = array_merge($config, ['session_root' => $root, 'phase' => $phase_num]);
        $result = operational_steps_dispatch_step($dbc, $step, $dispatch_opts);
        $log[] = array_merge(['step' => $n], $result);
        $ctx = session_evaluate_context($dbc, $config);
    }

    session_save_manifest($session_nbr, $manifest, $root);
    return [
        'session' => (string) $session_nbr,
        'phases' => $phase_num,
        'stopped' => $stopped,
        'log' => $log,
        'manifest' => $manifest,
    ];
}

function session_discover_sessions($root = null)
{
    $root = $root ?? session_web_root();
    $sessions = [];
    if (!is_dir($root)) {
        return $sessions;
    }
    foreach (scandir($root) ?: [] as $entry) {
        if (preg_match('/^session_(\d+)$/', $entry, $m)) {
            $sessions[] = (int) $m[1];
        }
    }
    sort($sessions);
    return $sessions;
}
