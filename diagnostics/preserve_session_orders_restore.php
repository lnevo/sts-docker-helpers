<?php
/**
 * Restore a preserve_session*_orders_*.json pack after Restart Session.
 *
 * Replaces car_orders, then restores status/location/handled_by for cars that
 * were on those orders, and shipments.last_ship_date (so generate cadence matches).
 *
 * Usage (container):
 *   php preserve_session_orders_restore.php backups/preserve_session2_orders_YYYYMMDD_HHMMSS.json
 *   php preserve_session_orders_restore.php backups/preserve_session2_orders_YYYYMMDD_HHMMSS.json --orders-only
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

chdir('/var/www/html/sts');
require_once 'open_db.php';

$path = $argv[1] ?? '';
$orders_only = in_array('--orders-only', $argv, true);
if ($path === '' || !is_file($path)) {
    // Also try under backups/
    if ($path !== '' && is_file('backups/' . basename($path))) {
        $path = 'backups/' . basename($path);
    }
}
if ($path === '' || !is_file($path)) {
    fwrite(STDERR, "Usage: php preserve_session_orders_restore.php <pack.json> [--orders-only]\n");
    exit(1);
}

$pack = json_decode((string) file_get_contents($path), true);
if (!is_array($pack) || empty($pack['orders']) || !is_array($pack['orders'])) {
    fwrite(STDERR, "Invalid pack: {$path}\n");
    exit(1);
}

$dbc = open_db();
$orders = $pack['orders'];
$cars = is_array($pack['cars'] ?? null) ? $pack['cars'] : [];
$shipments = is_array($pack['shipments_last_ship_date'] ?? null) ? $pack['shipments_last_ship_date'] : [];

mysqli_query($dbc, 'TRUNCATE TABLE car_orders');
$ins = 0;
foreach ($orders as $o) {
    $wb = mysqli_real_escape_string($dbc, (string) ($o['waybill_number'] ?? ''));
    $sh = mysqli_real_escape_string($dbc, (string) ($o['shipment'] ?? ''));
    $car = mysqli_real_escape_string($dbc, (string) ($o['car'] ?? ''));
    if ($wb === '') {
        continue;
    }
    $sql = "INSERT INTO `car_orders` VALUES (\"{$wb}\",\"{$sh}\",\"{$car}\")";
    if (!mysqli_query($dbc, $sql)) {
        fwrite(STDERR, 'Order insert failed: ' . mysqli_error($dbc) . "\n");
        exit(1);
    }
    $ins++;
}
echo "Restored {$ins} car_orders from " . basename($path) . "\n";

if ($orders_only) {
    echo "Skipped cars/shipments (--orders-only).\n";
    exit(0);
}

$car_n = 0;
foreach ($cars as $c) {
    $id = (int) ($c['Id'] ?? 0);
    if ($id < 1) {
        continue;
    }
    $status = mysqli_real_escape_string($dbc, (string) ($c['status'] ?? 'Empty'));
    $loc = (int) ($c['current_location_id'] ?? 0);
    $job = mysqli_real_escape_string($dbc, (string) ($c['handled_by_job_id'] ?? '0'));
    $pos = mysqli_real_escape_string($dbc, (string) ($c['position'] ?? '0'));
    $loads = (int) ($c['load_count'] ?? 0);
    $sql = "UPDATE cars SET status=\"{$status}\", current_location_id={$loc}, "
        . "handled_by_job_id=\"{$job}\", position=\"{$pos}\", load_count={$loads} "
        . "WHERE Id={$id}";
    if (!mysqli_query($dbc, $sql)) {
        fwrite(STDERR, 'Car update failed Id=' . $id . ': ' . mysqli_error($dbc) . "\n");
        exit(1);
    }
    $car_n++;
}
echo "Updated {$car_n} cars (status/location/job).\n";

$ship_n = 0;
foreach ($shipments as $s) {
    $id = (int) ($s['Id'] ?? 0);
    if ($id < 1) {
        continue;
    }
    $lsd = (int) ($s['last_ship_date'] ?? 0);
    if (!mysqli_query($dbc, "UPDATE shipments SET last_ship_date={$lsd} WHERE Id={$id}")) {
        fwrite(STDERR, 'Shipment update failed Id=' . $id . ': ' . mysqli_error($dbc) . "\n");
        exit(1);
    }
    $ship_n++;
}
echo "Updated {$ship_n} shipment last_ship_date values.\n";
echo "Done. Tip: skip Generate Orders in the workflow (or re-run restore after it).\n";
