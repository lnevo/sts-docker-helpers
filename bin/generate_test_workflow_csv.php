#!/usr/bin/env php
<?php
/**
 * Generate WORKFLOW_TEST_ALL_TYPES.recipe.json from selectable catalog adder commands.
 *
 * Usage:
 *   php bin/generate_test_workflow_csv.php [output.recipe.json]
 *   php bin/generate_test_workflow_csv.php --all-outputs
 */
$root = getenv('STS_HELPERS_ROOT') ?: dirname(__DIR__);
require_once $root . '/sts/operational_steps_catalog.php';
require_once $root . '/sts/catalog_test_matrix.php';

$allOutputs = in_array('--all-outputs', $argv, true);
$outArg = null;
foreach ($argv as $i => $arg) {
    if ($i === 0 || $arg === '--all-outputs') {
        continue;
    }
    if ($arg[0] !== '-') {
        $outArg = $arg;
        break;
    }
}

$steps = [];
$dbc = null;
if (is_file($root . '/sts/open_db.php')) {
    require_once $root . '/sts/open_db.php';
    $dbc = @open_db();
}
foreach (catalog_test_matrix_sections($dbc) as $section) {
    $steps[] = [
        'function' => 'section_label',
        'params' => ['label' => $section['label']],
        'description' => 'Section: ' . $section['label'],
    ];
    foreach ($section['steps'] as $step) {
        $steps[] = $step;
    }
}

$steps[] = [
    'function' => 'stop',
    'params' => [],
    'description' => 'Test: Stop',
];

$recipe = operational_steps_normalize_recipe([
    'version' => 1,
    'name' => 'test_active_catalog',
    'steps' => $steps,
]);

$json = operational_steps_encode_recipe_json($recipe);

$outputs = [];
if ($allOutputs) {
    $backups = dirname($root) . '/sts-backups/session_editor';
    if (is_dir($backups)) {
        $outputs[] = $backups . '/WORKFLOW_TEST_ALL_TYPES.recipe.json';
    }
    $outputs[] = $root . '/docs/WORKFLOW_TEST_ALL_TYPES.recipe.json';
} else {
    $outputs[] = $outArg ?? ($root . '/docs/WORKFLOW_TEST_ALL_TYPES.recipe.json');
}

foreach ($outputs as $out) {
    $dir = dirname($out);
    if (!is_dir($dir)) {
        mkdir($dir, 0755, true);
    }
    file_put_contents($out, $json);
    echo "Wrote {$out}\n";
}

$selectable = catalog_test_matrix_selectable_commands();
$covered = catalog_test_matrix_covered_command_ids($dbc);
if ($dbc) {
    mysqli_close($dbc);
    $dbc = null;
}
$covered[] = 'section_label';
$covered[] = 'stop';
$missing = [];
foreach ($selectable as $def) {
    $id = $def['id'] ?? '';
    if ($id === 'wipe_database') {
        continue;
    }
    if (!in_array($id, $covered, true)) {
        $missing[] = $id;
    }
}

$lines = substr_count($json, "\n");
echo count($recipe['steps']) . " steps, {$lines} JSON lines\n";
echo count($selectable) . " selectable adder commands; matrix covers " . count($covered) . " ids\n";
if ($missing) {
    fwrite(STDERR, "Warning: no matrix step for: " . implode(', ', $missing) . "\n");
    exit(1);
}
