<?php
/**
 * HTTP API for operational step recipe editor.
 * GET  ?action=catalog|recipe|compile
 * POST ?action=save|run_switchlists|import_csv
 */

header('Content-Type: application/json; charset=utf-8');

$sts_dir = dirname(__DIR__) . '/sts';
if (!is_dir($sts_dir)) {
    $sts_dir = __DIR__ . '/../sts';
}

require_once $sts_dir . '/open_db.php';
require_once $sts_dir . '/operational_steps_catalog.php';
require_once $sts_dir . '/session_helpers.php';

$session_dir = __DIR__;
$body = null;
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $body = operational_steps_api_body();
}
$action = $_GET['action'] ?? $_POST['action'] ?? ($body['action'] ?? '');

function operational_steps_api_json($data, $code = 200)
{
    http_response_code($code);
    echo json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}

function operational_steps_api_body()
{
    static $cached = null;
    if ($cached !== null) {
        return $cached;
    }
    $raw = file_get_contents('php://input');
    $data = json_decode($raw, true);
    $cached = is_array($data) ? $data : [];
    return $cached;
}

try {
    switch ($action) {
        case 'catalog':
            $dbc = open_db();
            $dynamic = operational_steps_fetch_dynamic_options($dbc);
            mysqli_close($dbc);
            operational_steps_api_json([
                'ok' => true,
                'categories' => operational_steps_catalog_categories(),
                'adder_categories' => operational_steps_catalog_adder_categories(),
                'jobs' => operational_steps_catalog_jobs(),
                'locations' => operational_steps_catalog_locations(),
                'dynamic_options' => $dynamic,
                'functions' => operational_steps_catalog_definitions(),
                'adder_functions' => operational_steps_catalog_adder_definitions(),
            ]);

        case 'run_options':
            $recipe = operational_steps_load_recipe($session_dir);
            $compiled = operational_steps_compile_recipe($recipe);
            $indices = operational_steps_recipe_indices($recipe);
            $dbc = open_db();
            $current_session = warm_start_get_session($dbc);
            mysqli_close($dbc);
            $existing = operational_steps_discover_switchlist_sessions($session_dir);
            operational_steps_api_json([
                'ok' => true,
                'current_session' => $current_session,
                'existing_sessions' => $existing,
                'indices' => $indices,
                'default_breakpoint' => $indices['session_end'] ?: $indices['generate_step'],
                'default_start' => $indices['operating_start'],
                'default_stop' => $indices['session_end'] ?: $indices['generate_step'],
                'breakpoints' => $indices['breakpoints'],
                'compiled' => $compiled,
            ]);

        case 'recipe':
            $recipe = operational_steps_load_recipe($session_dir);
            operational_steps_api_json([
                'ok' => true,
                'recipe' => $recipe,
                'compiled' => operational_steps_compile_recipe($recipe),
            ]);

        case 'compile':
            $body = operational_steps_api_body();
            $recipe = $body['recipe'] ?? operational_steps_load_recipe($session_dir);
            operational_steps_api_json([
                'ok' => true,
                'compiled' => operational_steps_compile_recipe($recipe),
                'csv' => operational_steps_recipe_to_csv($recipe),
            ]);

        case 'save':
            if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
                operational_steps_api_json(['ok' => false, 'error' => 'POST required'], 405);
            }
            $body = operational_steps_api_body();
            if (empty($body['recipe']) || !is_array($body['recipe'])) {
                operational_steps_api_json(['ok' => false, 'error' => 'Missing recipe'], 400);
            }
            $recipe = $body['recipe'];
            if (!isset($recipe['version'])) {
                $recipe['version'] = 1;
            }
            $recipe = operational_steps_normalize_recipe($recipe);
            $save = operational_steps_save_recipe($session_dir, $recipe);
            if (empty($save['written'])) {
                operational_steps_api_json(['ok' => false, 'error' => implode('; ', $save['errors'])], 500);
            }
            operational_steps_api_json([
                'ok' => true,
                'written' => $save['written'],
                'warnings' => $save['errors'],
                'compiled' => $save['compiled'],
                'rows' => count($save['compiled']),
            ]);

        case 'run_switchlists':
            if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
                operational_steps_api_json(['ok' => false, 'error' => 'POST required'], 405);
            }
            $body = operational_steps_api_body();
            $format = $body['format'] ?? 'phased';
            $jobs = isset($body['jobs']) ? array_values(array_filter(array_map('trim', explode(',', $body['jobs'])))) : ['D749', 'NVL', 'CK1'];
            if (isset($body['recipe']) && is_array($body['recipe'])) {
                operational_steps_save_recipe($session_dir, $body['recipe']);
            }
            $recipe = isset($body['recipe']) && is_array($body['recipe'])
                ? $body['recipe']
                : operational_steps_load_recipe($session_dir);
            $mode = $body['mode'] ?? 'current';
            $render_sessions = [];
            if (!empty($body['render_sessions']) && is_array($body['render_sessions'])) {
                $render_sessions = array_map('intval', $body['render_sessions']);
            } elseif (!empty($body['sessions']) && is_array($body['sessions'])) {
                $render_sessions = array_map('intval', $body['sessions']);
                if ($mode === 'current') {
                    $mode = 'rerender';
                }
            }
            $dbc = open_db();
            $result = operational_steps_run_generator_web($dbc, [
                'recipe' => $recipe,
                'format' => $format,
                'jobs' => $jobs,
                'mode' => $mode,
                'start_step' => (int) ($body['start_step'] ?? 0),
                'stop_step' => (int) ($body['stop_step'] ?? 0),
                'breakpoint_step' => (int) ($body['breakpoint_step'] ?? 0),
                'session_count' => (int) ($body['session_count'] ?? 1),
                'run_prep' => !isset($body['run_prep']) || (bool) $body['run_prep'],
                'play_after' => !isset($body['play_after']) || (bool) $body['play_after'],
                'render_sessions' => $render_sessions,
            ]);
            mysqli_close($dbc);
            $lines = [];
            foreach ($result['cycles'] as $cycle) {
                $lines[] = sprintf(
                    'Session %s — %d phase(s)%s',
                    $cycle['session'],
                    (int) ($cycle['phases'] ?? 0),
                    !empty($cycle['stopped']) ? ' (stopped)' : ''
                );
                foreach ($cycle['written'] ?? [] as $item) {
                    if (!is_array($item)) {
                        continue;
                    }
                    $lines[] = sprintf(
                        '  %s: %d phase(s), %d car(s)',
                        $item['job'] ?? '?',
                        $item['phases'] ?? 0,
                        $item['cars'] ?? 0
                    );
                }
            }
            $last = end($result['cycles']);
            operational_steps_api_json([
                'ok' => true,
                'mode' => $result['mode'],
                'breakpoint_step' => $result['breakpoint_step'],
                'start_step' => $result['start_step'] ?? null,
                'stop_step' => $result['stop_step'] ?? null,
                'sessions' => $result['sessions'],
                'session' => $last ? $last['session'] : '',
                'format' => $format,
                'jobs' => $jobs,
                'summary' => $lines,
                'warnings' => $result['warnings'] ?? [],
                'cycles' => $result['cycles'],
                'index_url' => '/session/index.php',
                'session_url' => $last ? '/session/session_' . $last['session'] . '/index.php' : '/session/index.php',
            ]);

        case 'normalize_recipe':
            if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
                operational_steps_api_json(['ok' => false, 'error' => 'POST required'], 405);
            }
            $body = operational_steps_api_body();
            if (!empty($body['use_file'])) {
                $paths = operational_steps_recipe_paths($session_dir);
                $csv = is_file($paths['csv']) ? file_get_contents($paths['csv']) : '';
                if ($csv === '') {
                    operational_steps_api_json(['ok' => false, 'error' => 'No CSV file'], 400);
                }
                $steps = operational_steps_parse_csv($csv);
                $recipe = operational_steps_normalize_recipe(['version' => 1, 'name' => 'imported', 'steps' => $steps]);
            } else {
                $recipe = $body['recipe'] ?? operational_steps_load_recipe($session_dir);
                $recipe = operational_steps_normalize_recipe($recipe);
            }
            operational_steps_api_json([
                'ok' => true,
                'recipe' => $recipe,
                'compiled' => operational_steps_compile_recipe($recipe),
                'rows' => count($recipe['steps'] ?? []),
            ]);

        case 'import_csv':
            if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
                operational_steps_api_json(['ok' => false, 'error' => 'POST required'], 405);
            }
            $body = operational_steps_api_body();
            $csv = $body['csv'] ?? '';
            if ($csv === '' && !empty($body['use_file'])) {
                $paths = operational_steps_recipe_paths($session_dir);
                $csv = is_file($paths['csv']) ? file_get_contents($paths['csv']) : '';
            }
            if ($csv === '') {
                operational_steps_api_json(['ok' => false, 'error' => 'No CSV content'], 400);
            }
            $steps = operational_steps_parse_csv($csv);
            $recipe = operational_steps_normalize_recipe(['version' => 1, 'name' => 'imported', 'steps' => $steps]);
            operational_steps_api_json([
                'ok' => true,
                'recipe' => $recipe,
                'compiled' => operational_steps_compile_recipe($recipe),
            ]);

        default:
            operational_steps_api_json([
                'ok' => false,
                'error' => 'Unknown action',
                'actions' => ['catalog', 'recipe', 'compile', 'save', 'run_switchlists', 'run_options', 'import_csv', 'normalize_recipe'],
            ], 400);
    }
} catch (Throwable $e) {
    operational_steps_api_json(['ok' => false, 'error' => $e->getMessage()], 500);
}
