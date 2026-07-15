<?php
/**
 * CLI: Cancel Orders
 *   php drain_unfilled_orders.php [threshold=40] [target=30] [order=oldest_first|newest_first]
 */
chdir('/var/www/html/sts');
require_once 'open_db.php';
require_once 'fill_order_helpers.php';
require_once 'drain_unfilled_orders.php';

$threshold = max(0, (int) ($argv[1] ?? 40));
$target = max(0, (int) ($argv[2] ?? 30));
$order = (string) ($argv[3] ?? 'oldest_first');
$dbc = open_db();
$out = cancel_orders($dbc, [
    'threshold' => $threshold,
    'target' => $target,
    'keep_coke' => true,
    'order' => $order,
]);
echo 'CANCEL before=' . $out['before']
    . ' canceled=' . $out['canceled']
    . ' after=' . $out['after']
    . ' order=' . ($out['order'] ?? $order)
    . ' threshold=' . $threshold
    . ' target=' . $target
    . (!empty($out['skipped']) ? (' skip=' . ($out['reason'] ?? '1')) : '')
    . "\n";
