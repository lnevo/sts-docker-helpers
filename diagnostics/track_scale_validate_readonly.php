<?php
/**
 * Read-only validation for track scale plugin + workflow integration.
 * No INSERT/UPDATE/DELETE, no restore, no calibrate/weigh dispatch.
 *
 * Usage: php track_scale_validate_readonly.php [workflow]
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

require_once __DIR__ . '/bootstrap.php';
$root = diagnostics_bootstrap();

require_once $root . '/open_db.php';
require_once $root . '/session_helpers.php';
require_once $root . '/operational_steps_catalog.php';
require_once $root . '/plugins/plugins.php';
require_once $root . '/plugins/track_scale/track_scale_plugin.php';
require_once $root . '/plugins/track_scale/track_scale_helpers.php';

$workflow = $argv[1] ?? 'hart_session';
$pass = 0;
$fail = 0;
$warn = 0;

function ts_val_pass($msg)
{
    global $pass;
    $pass++;
    echo "  PASS  {$msg}\n";
}

function ts_val_fail($msg)
{
    global $fail;
    $fail++;
    echo "  FAIL  {$msg}\n";
}

function ts_val_warn($msg)
{
    global $warn;
    $warn++;
    echo "  WARN  {$msg}\n";
}

echo "Track scale read-only validation\n";
echo "STS runtime: {$root}\n";
echo str_repeat('=', 72) . "\n";

// --- Plugin manifest ---
plugins_bootstrap_all();
$manifests = plugins_discover();
$ts_manifest = null;
foreach ($manifests as $m) {
    if (($m['id'] ?? '') === 'track_scale') {
        $ts_manifest = $m;
        break;
    }
}
if ($ts_manifest === null) {
    ts_val_fail('track_scale plugin manifest not discovered');
} else {
    ts_val_pass('track_scale plugin manifest discovered');
    foreach (['gui_label_hooks', 'normalize_params', 'dispatch_handlers', 'catalog_steps_callback'] as $key) {
        if (empty($ts_manifest[$key])) {
            ts_val_fail("manifest missing {$key}");
        } else {
            ts_val_pass("manifest has {$key}");
        }
    }
}

// --- Hook behavior (no DB) ---
$params = ['job' => 'CK1', 'commodity' => 'coke'];
$merged = [];
track_scale_plugin_normalize_params($params);
if (($params['commodity'] ?? '') === 'COKE') {
    ts_val_pass('normalize_params uppercases commodity');
} else {
    ts_val_fail('normalize_params did not uppercase commodity: ' . json_encode($params));
}

track_scale_plugin_gui_label_merge(['job' => 'CK1', 'commodity' => 'COKE'], $merged);
if (($merged['job'] ?? '') === 'CK1' && ($merged['commodity_suffix'] ?? '') === ' (COKE)') {
    ts_val_pass('gui_label_merge builds job + commodity_suffix');
} else {
    ts_val_fail('gui_label_merge unexpected: ' . json_encode($merged));
}

// --- Catalog registration ---
$catalog = operational_steps_catalog_by_id();
foreach (['track_scale', 'calibrate_track_scale'] as $fid) {
    if (!isset($catalog[$fid])) {
        ts_val_fail("catalog missing {$fid}");
        continue;
    }
    $def = $catalog[$fid];
    if (empty($def['runnable']) || empty($def['dispatch'])) {
        ts_val_fail("{$fid}: not runnable or missing dispatch");
        continue;
    }
    ts_val_pass("catalog has runnable {$fid} (dispatch={$def['dispatch']})");
    $compiled = operational_steps_compile_gui($def, ['job' => 'CK1', 'commodity' => 'COKE', 'every_sessions' => '1']);
    if (trim($compiled) === '') {
        ts_val_fail("{$fid}: compile_gui empty");
    } else {
        ts_val_pass("{$fid}: compile_gui → {$compiled}");
    }
}

// --- Dispatch handlers exist (reflection only) ---
$ref = new ReflectionFunction('operational_steps_dispatch_step');
$dispatch_src = file_get_contents($ref->getFileName());
foreach (['track_scale', 'calibrate_track_scale'] as $dispatch) {
  if (strpos($dispatch_src, "case '{$dispatch}':") !== false) {
      ts_val_fail("{$dispatch} still in catalog switch — should be plugin-only");
  }
}
if (!empty($ts_manifest['dispatch_handlers']['track_scale']) && is_callable($ts_manifest['dispatch_handlers']['track_scale'])) {
    ts_val_pass('plugin dispatch handler track_scale is callable');
} else {
    ts_val_fail('plugin dispatch handler track_scale not callable');
}
if (!empty($ts_manifest['dispatch_handlers']['calibrate_track_scale']) && is_callable($ts_manifest['dispatch_handlers']['calibrate_track_scale'])) {
    ts_val_pass('plugin dispatch handler calibrate_track_scale is callable');
} else {
    ts_val_fail('plugin dispatch handler calibrate_track_scale not callable');
}

// --- Workflow load + normalize (hart_session) ---
$editorDir = operational_steps_editor_dir();
$resolved = operational_steps_resolve_workflow_filename($editorDir, $workflow);
if ($resolved === '') {
    ts_val_fail("workflow not found: {$workflow}");
} else {
    $path = operational_steps_workflow_path($editorDir, $resolved);
    try {
        $recipe = operational_steps_load_recipe_from_json_file($path);
        ts_val_pass("workflow loaded: {$resolved} (" . count($recipe['steps'] ?? []) . ' steps)');
    } catch (Throwable $e) {
        ts_val_fail('workflow load threw: ' . $e->getMessage());
        $recipe = ['steps' => []];
    }

    $ts_steps = [];
    foreach ($recipe['steps'] ?? [] as $i => $step) {
        $fid = $step['function'] ?? '';
        if ($fid === 'track_scale' || $fid === 'calibrate_track_scale') {
            $ts_steps[] = ['num' => $i + 1, 'function' => $fid, 'params' => $step['params'] ?? []];
        }
    }
    if (count($ts_steps) < 2) {
        ts_val_warn('expected track_scale + calibrate_track_scale in workflow, found ' . count($ts_steps));
    } else {
        ts_val_pass('workflow contains ' . count($ts_steps) . ' track-scale step(s)');
    }
    foreach ($ts_steps as $s) {
        $norm = operational_steps_normalize_step([
            'function' => $s['function'],
            'params' => $s['params'],
            'structured_import' => true,
        ]);
        if (($norm['function'] ?? '') !== $s['function']) {
            ts_val_fail("step {$s['num']} normalize changed function to " . ($norm['function'] ?? '?'));
            continue;
        }
        if ($s['function'] === 'track_scale') {
            $job = trim($norm['params']['job'] ?? '');
            $com = trim($norm['params']['commodity'] ?? '');
            if ($job === 'CK1' && $com === 'COKE') {
                ts_val_pass("step {$s['num']} track_scale params normalized (CK1 / COKE)");
            } else {
                ts_val_fail("step {$s['num']} track_scale params: job={$job} commodity={$com}");
            }
        }
        if ($s['function'] === 'calibrate_track_scale') {
            $every = (int) ($norm['params']['every_sessions'] ?? 0);
            if ($every >= 1) {
                ts_val_pass("step {$s['num']} calibrate every_sessions={$every}");
            } else {
                ts_val_fail("step {$s['num']} calibrate missing every_sessions");
            }
        }
    }

    try {
        $compiled = operational_steps_compile_recipe($recipe);
        if (count($compiled) === count($recipe['steps'])) {
            ts_val_pass('full workflow compile_recipe row count matches');
        } else {
            ts_val_fail('compile_recipe row count mismatch');
        }
    } catch (Throwable $e) {
        ts_val_fail('compile_recipe threw: ' . $e->getMessage());
    }
}

// --- Config / seed files (read only) ---
$config_path = track_scale_data_dir() . '/track_scale_config.json';
$seed_path = track_scale_seed_path();
if (is_readable($config_path)) {
    $cfg = json_decode(file_get_contents($config_path), true);
    if (is_array($cfg) && !empty($cfg['loading_location_code'])) {
        ts_val_pass('track_scale_config.json readable (location=' . $cfg['loading_location_code'] . ')');
    } else {
        ts_val_fail('track_scale_config.json invalid');
    }
} else {
    ts_val_fail('track_scale_config.json not readable: ' . $config_path);
}

if (is_readable($seed_path)) {
    $seed_json = json_decode(file_get_contents($seed_path), true);
    if (is_array($seed_json)) {
        ts_val_pass('seed.json readable (session=' . ($seed_json['session_number'] ?? '?') . ')');
    } else {
        ts_val_warn('seed.json exists but is not valid JSON');
    }
} else {
    ts_val_warn('seed.json not present yet: ' . $seed_path);
}

// --- Live DB read-only snapshot ---
$dbc = open_db();
$session = (int) session_get_db_session($dbc);
ts_val_pass('DB read-only: current session_nbr=' . $session);

$weighable = track_scale_count_weighable_cars($dbc);
ts_val_pass('DB read-only: scale_to_weigh count=' . (int) $weighable);

$config = track_scale_load_config();
$cars = track_scale_get_cars_at_scale($dbc, $config, '');
ts_val_pass('DB read-only: cars_at_scale count=' . count($cars) . ' (location=' . track_scale_loading_location_code($config) . ')');

$seed_state = track_scale_load_seed_state($dbc);
if (is_array($seed_state)) {
    $cal = $seed_state['calibration'] ?? [];
    ts_val_pass(
        'DB read-only: seed state session=' . ($seed_state['session_number'] ?? '?')
        . ' calibrated=' . (!empty($cal['locked']) ? 'yes' : 'no')
    );
} else {
    ts_val_warn('track_scale_load_seed_state returned non-array');
}

// CK1 coke cars on train (read only)
$ck1_rs = mysqli_query(
    $dbc,
    'SELECT COUNT(*) FROM cars c
     JOIN jobs j ON j.id = c.train_job_id
     WHERE j.name = "CK1"'
);
$ck1_on_train = $ck1_rs ? (int) mysqli_fetch_row($ck1_rs)[0] : -1;
ts_val_pass('DB read-only: CK1 cars on train=' . $ck1_on_train);

mysqli_close($dbc);

echo str_repeat('=', 72) . "\n";
printf("Results: %d passed, %d failed, %d warnings\n", $pass, $fail, $warn);
exit($fail > 0 ? 1 : 0);
