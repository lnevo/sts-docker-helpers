#!/usr/bin/env php
<?php
/**
 * Validate catalog ↔ API ↔ compile/import parity for selectable adder commands.
 *
 * Usage: php bin/validate_catalog_api.php
 */
$root = getenv('STS_HELPERS_ROOT') ?: dirname(__DIR__);
require_once $root . '/sts/operational_steps_catalog.php';
require_once $root . '/sts/catalog_test_matrix.php';

$errors = [];
$passed = 0;

require_once $root . '/sts/open_db.php';
$dbc = open_db();

$catalog = operational_steps_catalog_by_id();
$selectable = catalog_test_matrix_selectable_commands();
$disabled = catalog_test_matrix_disabled_adder_commands();
$roundTripSkip = array_flip(catalog_test_matrix_round_trip_skip());
$runnerDispatch = array_flip(catalog_test_matrix_runner_dispatch_ids());
$dispatchCases = catalog_test_api_dispatch_cases();
// Plugin-provided steps (e.g. track_scale, calibrate_track_scale) are dispatched
// through plugins_try_dispatch() before the switch, so they have no case label.
if (function_exists('plugins_dispatch_ids')) {
    foreach (plugins_dispatch_ids() as $pluginDispatch) {
        $dispatchCases[$pluginDispatch] = true;
    }
}
$covered = array_flip(catalog_test_matrix_covered_command_ids($dbc));
$covered['section_label'] = true;
$covered['stop'] = true;

foreach ($selectable as $def) {
    $id = $def['id'] ?? '';
    if ($id === '') {
        $errors[] = 'Selectable command missing id';
        continue;
    }

    if (empty($def['label']) || empty($def['gui_template'])) {
        $errors[] = "{$id}: missing label or gui_template";
        continue;
    }

    if (!isset($catalog[$id])) {
        $errors[] = "{$id}: not in operational_steps_catalog_definitions()";
        continue;
    }

    if ($id !== 'wipe_database' && !isset($covered[$id])) {
        $errors[] = "{$id}: no test step in catalog_test_matrix_sections()";
        continue;
    }

    $runnable = !empty($def['runnable']);
    $dispatch = $def['dispatch'] ?? '';
    if ($runnable && $dispatch !== '' && !isset($runnerDispatch[$dispatch])
        && !isset($dispatchCases[$dispatch])) {
        $errors[] = "{$id}: dispatch '{$dispatch}' has no handler in operational_steps_dispatch_step()";
        continue;
    }

    $passed++;
}

foreach ($disabled as $def) {
    $id = $def['id'] ?? '';
    if (empty($def['disabled'])) {
        $errors[] = "{$id}: expected disabled=true in adder (reports/waybills greyed out)";
    } else {
        $passed++;
    }
}

$matrixSteps = [];
foreach (catalog_test_matrix_sections($dbc) as $section) {
    foreach ($section['steps'] as $step) {
        $matrixSteps[] = $step;
    }
}
mysqli_close($dbc);

foreach ($matrixSteps as $step) {
    $id = $step['function'] ?? '';
    $params = $step['params'] ?? [];
    if (!isset($catalog[$id])) {
        $errors[] = "Matrix step {$id}: unknown catalog id";
        continue;
    }

    $def = $catalog[$id];
    $instruction = operational_steps_compile_gui($def, $params);
    if (trim($instruction) === '') {
        $errors[] = "{$id}: compile produced empty instruction";
        continue;
    }

    $probeRecipe = [
        'version' => 1,
        'name' => 'probe',
        'steps' => [['function' => $id, 'params' => $params]],
    ];
    $compiled = operational_steps_compile_recipe($probeRecipe);
    $compiledInstruction = trim($compiled[0]['instruction'] ?? '');
    if ($compiledInstruction !== $instruction) {
        $errors[] = "{$id}: compile_recipe instruction mismatch — expected '{$instruction}', got '{$compiledInstruction}'";
        continue;
    }

    $csv = operational_steps_recipe_to_csv($probeRecipe);
    $csvLines = array_values(array_filter(explode("\n", trim($csv))));
    // CSV columns: Step #, Function, Params, STS GUI Instruction, ... — the
    // instruction is column index 3.
    $csvCols = str_getcsv($csvLines[1] ?? '');
    $csvInstruction = trim($csvCols[3] ?? '');
    if ($csvInstruction !== $instruction) {
        $errors[] = "{$id}: CSV instruction mismatch — expected '{$instruction}', got '{$csvInstruction}'";
        continue;
    }

    if (isset($roundTripSkip[$id])) {
        $passed++;
        continue;
    }

    $guessed = operational_steps_guess_function($csvInstruction);
    if ($guessed !== $id) {
        $errors[] = "{$id}: round-trip guess_function got '{$guessed}' for '{$instruction}'";
        continue;
    }

    $passed++;
}

$adderIds = array_column(operational_steps_catalog_adder_definitions(), 'id');
$hiddenReportIds = [
    'report_waybill_list',
    'report_waybill_cars_print',
    'report_waybill_shipments_print',
    'report_station_car',
    'report_wheel',
    'report_fleet',
    'report_shipment_forecast',
    'report_car_forecast',
    'report_car_qr',
    'report_location_qr',
];
foreach ($hiddenReportIds as $id) {
    if (in_array($id, $adderIds, true)) {
        $errors[] = "{$id}: must not appear in adder dropdown (hidden until implemented)";
    }
}

echo "Catalog API validation\n";
echo "  Passed checks: {$passed}\n";
if ($errors) {
    echo "  Errors: " . count($errors) . "\n";
    foreach ($errors as $e) {
        echo "    - {$e}\n";
    }
    exit(1);
}

echo "  All checks passed.\n";
exit(0);

/**
 * @return array<string, true>
 */
function catalog_test_api_dispatch_cases()
{
    $ref = new ReflectionFunction('operational_steps_dispatch_step');
    $src = file_get_contents($ref->getFileName());
    if ($src === false) {
        return [];
    }
    $cases = [];
    if (preg_match_all("/case\s+'([^']+)':/", $src, $m)) {
        foreach ($m[1] as $label) {
            $cases[$label] = true;
        }
    }
    return $cases;
}
