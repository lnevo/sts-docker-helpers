<?php
/**
 * build_d749_supplement.php [session_N]  (default: current DB session)
 *
 * DEPRECATED for live ops. Prefer integrate_d749_demmler_pool.php, which
 * assigns the Demmler yard-pool cars to D749 in the DB, generates a real
 * D749/Demmler switch-list phase, registers it in the session manifest,
 * captures waybills into the session store, and optionally completes
 * pickup/setout.
 *
 * This older helper only renders paperwork (no DB assign / no manifest).
 *
 *   docker cp integrate_d749_demmler_pool.php sts-docker-web-1:/tmp/
 *   docker exec sts-docker-web-1 php /tmp/integrate_d749_demmler_pool.php
 */
error_reporting(E_ERROR | E_PARSE);

$bootstrap = __DIR__ . '/bootstrap.php';
if (is_file($bootstrap)) {
    require $bootstrap;
    diagnostics_resolve_runtime();
} else {
    $runtime = is_file(__DIR__ . '/open_db.php') ? __DIR__ : '/var/www/html/sts';
    chdir($runtime);
}
require 'open_db.php';
require 'session_helpers.php';
require_once 'master_switchlist_helpers.php';
require_once 'waybill_print_helpers.php';
$dbc = open_db();
$root = session_web_root();

$N = (int) ($argv[1] ?? 0);
if ($N < 1) {
    $N = (int) mysqli_fetch_row(mysqli_query($dbc, 'SELECT setting_value FROM settings WHERE setting_name="session_nbr"'))[0];
}

$JOB = 'D749';
$WANT = ['001-001', '001-004', '001-010', '001-015', '002-003', '002-004'];
$in = "'" . implode("','", array_map(fn($w) => mysqli_real_escape_string($dbc, $w), $WANT)) . "'";

// Pull the same columns the stock switch-list SQL produces so the renderer sees
// a normal car row. All six are revenue orders (consignment_id > 0), so they
// render as E -> loading location with the standard destination color.
$sql = 'SELECT
        cars.reporting_marks               AS reporting_marks,
        car_codes.code                     AS car_code,
        cars.status                        AS status,
        cars.remarks                       AS remarks,
        commodities.code                   AS consignment,
        shipments.consignment              AS consignment_id,
        car_orders.waybill_number          AS waybill_number,
        shipments.special_instructions     AS special_instructions,
        routing.station                    AS current_station,
        locations.code                     AS current_location,
        loading_sta.station                AS loading_station,
        loading_loc.code                   AS loading_location,
        unloading_sta.station              AS unloading_station,
        unloading_loc.code                 AS unloading_location,
        cars.current_location_id           AS current_location_id,
        cars.position                      AS position,
        0                                  AS step_number
    FROM car_orders
    INNER JOIN cars ON cars.Id = car_orders.car
    INNER JOIN car_codes ON car_codes.id = cars.car_code_id
    INNER JOIN shipments ON shipments.id = car_orders.shipment
    INNER JOIN commodities ON commodities.id = shipments.consignment
    INNER JOIN locations loading_loc ON loading_loc.id = shipments.loading_location
    INNER JOIN routing loading_sta ON loading_sta.id = loading_loc.station
    INNER JOIN locations unloading_loc ON unloading_loc.id = shipments.unloading_location
    INNER JOIN routing unloading_sta ON unloading_sta.id = unloading_loc.station
    LEFT JOIN locations ON locations.id = cars.current_location_id
    LEFT JOIN routing ON routing.id = locations.station
    WHERE car_orders.waybill_number IN (' . $in . ')
    ORDER BY car_orders.waybill_number';
$rs = mysqli_query($dbc, $sql);
if (!$rs) {
    fwrite(STDERR, "query failed: " . mysqli_error($dbc) . "\n");
    exit(1);
}
$cars = [];
while ($row = mysqli_fetch_array($rs, MYSQLI_ASSOC)) {
    $cars[] = $row;
}
if (!$cars) {
    fwrite(STDERR, "no matching orders found for: " . implode(', ', $WANT) . "\n");
    exit(1);
}

$cars = master_sw_enrich_rows_for_render($dbc, $cars);

$sections = [];
master_sw_add_section($sections, '1 — Yard-pool pickups (Demmler)', $cars);

// --- Render switch list through the real STS renderer ----------------------
$output_dir = rtrim($root, '/') . '/session_' . $N . '/phase_08';
session_ensure_writable_dir($output_dir);

$result = master_sw_generate_phased($dbc, $JOB, $sections, $output_dir, $N, [
    'format' => 'all',
    'title' => 'D749 Supplemental',
    'info' => '(yard pool)',
]);

$job_dir = $result['job_dir'];

// --- Waybills (real STS renderer) ------------------------------------------
$wb_dir = $job_dir . '/waybills';
session_ensure_writable_dir($wb_dir);
$h = fn($s) => htmlspecialchars((string) $s, ENT_QUOTES);
$settings = waybill_print_settings($dbc);
$written = [];
$list_items = '';
$bundle = '';
foreach ($cars as $c) {
    $wb = $c['waybill_number'];
    $page = waybill_print_render_page($dbc, $wb, [
        'settings' => $settings,
        'show_controls' => true,
        'nav_html' => '<a href="index.html">Waybill list</a>',
    ]);
    if ($page === '') {
        continue;
    }
    $file = waybill_print_safe_filename($wb) . '.html';
    file_put_contents($wb_dir . '/' . $file, $page);
    $written[] = $wb;
    $list_items .= '<li><a href="' . $h($file) . '">' . $h($wb) . '</a></li>';
    $body = waybill_print_render_body($dbc, $wb, $settings);
    $bundle .= waybill_print_wrap_sheets($body);
}
$index = '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">'
    . '<title>D749 Supplemental Waybills — Session ' . $N . '</title></head><body>'
    . '<h1>D749 Supplemental Waybills — Session ' . $N . '</h1>'
    . '<p>' . count($written) . ' waybill(s) for the Demmler yard-pool orders.</p>'
    . ($written ? '<p><a href="print_all.html"><strong>Print all waybills</strong></a></p>' : '')
    . '<ul>' . $list_items . '</ul></body></html>';
file_put_contents($wb_dir . '/index.html', $index);
$print_all = waybill_print_render_bundle_page(
    'D749 Supplemental Waybills — Session ' . $N . ' — print all',
    $bundle,
    ['back_href' => 'index.html']
);
file_put_contents($wb_dir . '/print_all.html', $print_all);

// --- Report -----------------------------------------------------------------
$rel = fn($p) => ltrim(str_replace(rtrim($root, '/'), '', $p), '/');
echo "OK\n";
echo "cars: " . count($cars) . "\n";
echo "switchlist index: so.php?f=" . $rel($result['index_path']) . "\n";
echo "switchlist print : so.php?f=" . $rel($result['print_all_path']) . "\n";
echo "waybills index   : so.php?f=" . $rel($wb_dir) . "/index.html\n";
echo "waybills print   : so.php?f=" . $rel($wb_dir) . "/print_all.html\n";
echo "styles: " . implode(', ', $result['styles']) . "\n";
foreach ($cars as $c) {
    echo "  " . str_pad($c['waybill_number'], 8) . " " . str_pad($c['reporting_marks'], 12)
        . " " . $c['status'] . " -> load " . ($c['loading_location'] ?: '?')
        . " / deliver " . ($c['unloading_location'] ?: '?') . "\n";
}
