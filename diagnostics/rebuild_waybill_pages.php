<?php
/**
 * One-time: re-render every session's waybill pages from the frozen store so the
 * page-break refactor (each waybill document in its own .waybill-sheet) applies
 * to already-generated sessions. Pure re-aggregation — snapshot bodies unchanged.
 *
 *   docker exec -u www-data <web> php /tmp/rebuild_waybill_pages.php
 */
error_reporting(E_ERROR | E_PARSE);

require_once __DIR__ . '/bootstrap.php';
$sts = diagnostics_resolve_runtime();
require_once $sts . '/open_db.php';
require_once $sts . '/session_helpers.php';
require_once $sts . '/waybill_print_helpers.php';

$dbc = open_db();
$rebuilt = 0;

for ($n = 1; $n <= 500; $n++) {
    $store_path = session_waybill_store_path($n);
    if (!is_readable($store_path)) {
        continue;
    }
    $store = session_waybill_store_load($n);
    if (empty($store['bodies']) || !is_array($store['bodies'])) {
        continue;
    }
    session_waybill_rebuild_pages($dbc, $n, $store);
    $rebuilt++;
    echo 'rebuilt session ' . $n . ' (' . count($store['bodies']) . " bodies)\n";
}

echo "---\nsessions rebuilt: " . $rebuilt . "\n";
