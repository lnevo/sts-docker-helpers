#!/usr/bin/env php
<?php
/**
 * Generate WORKFLOW_TEST_ALL_TYPES.csv — one step per catalog command, three sections.
 * Usage: php bin/generate_test_workflow_csv.php [output path]
 */
$root = getenv('STS_HELPERS_ROOT') ?: dirname(__DIR__);
require_once $root . '/sts/operational_steps_catalog.php';
if (!function_exists('operational_steps_catalog_definitions')) {
    require_once __DIR__ . '/operational_steps_catalog.php';
    $root = __DIR__;
}

function test_workflow_sample_params(array $def): array
{
    $params = [];
    foreach ($def['params'] ?? [] as $pdef) {
        $key = $pdef['key'] ?? '';
        if ($key === '') {
            continue;
        }
        if (($pdef['type'] ?? '') === 'filter_group') {
            $filters = operational_steps_load_unload_default_filters();
            $filters['current_location'] = 'Scully';
            $filters['status'] = 'Loading';
            $params[$key] = $filters;
            continue;
        }
        if (isset($pdef['default']) && $pdef['default'] !== '') {
            $params[$key] = $pdef['default'];
            continue;
        }
        $type = $pdef['type'] ?? '';
        switch ($type) {
            case 'job':
                $params[$key] = 'D749';
                break;
            case 'location':
            case 'setout_location':
                $params[$key] = 'Demmler';
                break;
            case 'station':
                $params[$key] = 'all';
                break;
            case 'backup':
                $params[$key] = 'hart_seed';
                break;
            case 'scope':
                $params[$key] = 'locals';
                break;
            case 'jobs_multiselect':
                $params[$key] = 'D749,NVL,CK1';
                break;
            case 'car_code':
                $params[$key] = 'BOX';
                break;
            case 'commodity':
                $params[$key] = 'CL';
                break;
            case 'select':
                $opts = $pdef['options'] ?? [];
                $params[$key] = $opts[0] ?? '';
                if ($params[$key] === '' && isset($opts[1])) {
                    $params[$key] = $opts[1];
                }
                break;
            case 'number':
                $params[$key] = (string) ($pdef['default'] ?? '1');
                break;
            default:
                if ($key === 'label') {
                    $params[$key] = '[Sample label]';
                } elseif ($key === 'section' || $key === 'section_label' || $key === 'step') {
                    // resolved after build
                } elseif ($key === 'file') {
                    $params[$key] = 'uploads/sample.csv';
                } else {
                    $params[$key] = '';
                }
        }
    }
    if (($def['id'] ?? '') === 'run_staging_job' && empty($params['job'])) {
        $params['job'] = 'STG-SCULLY';
    }
    if (($def['id'] ?? '') === 'track_scale' && empty($params['job'])) {
        $params['job'] = 'CK1';
    }
    if (($def['id'] ?? '') === 'generate_switchlists') {
        $params['jobs'] = $params['jobs'] ?? 'all';
    }
    return $params;
}

$exclude = ['section_label', 'text_instruction', 'marker', 'goto'];
$catalog = operational_steps_catalog_definitions();
$commands = [];
foreach ($catalog as $def) {
    $id = $def['id'] ?? '';
    if ($id === '' || in_array($id, $exclude, true)) {
        continue;
    }
    $commands[] = $def;
}

$chunks = array_chunk($commands, (int) ceil(count($commands) / 3));
$sectionLabels = ['[Start section]', '[Middle section]', '[End section]'];

$steps = [];
foreach ($sectionLabels as $i => $label) {
    $steps[] = [
        'function' => 'section_label',
        'params' => ['label' => $label],
        'description' => 'Test section ' . ($i + 1),
    ];
    foreach ($chunks[$i] ?? [] as $def) {
        $steps[] = [
            'function' => $def['id'],
            'params' => test_workflow_sample_params($def),
            'description' => 'Test: ' . ($def['label'] ?? $def['id']),
        ];
    }
}

$steps[] = [
    'function' => 'stop',
    'params' => [],
    'description' => 'End test workflow',
];

$recipe = operational_steps_normalize_recipe([
    'version' => 1,
    'name' => 'test_all_types',
    'steps' => $steps,
]);

$csv = operational_steps_recipe_to_csv($recipe);
$out = $argv[1] ?? ($root . '/docs/WORKFLOW_TEST_ALL_TYPES.csv');
file_put_contents($out, $csv);

$lines = substr_count($csv, "\n");
echo "Wrote {$out}\n";
echo count($recipe['steps']) . " steps, {$lines} CSV lines\n";
