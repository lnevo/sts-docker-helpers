<?php
/**
 * One-time migration: reword the outbound-coke special instruction and re-render.
 *
 *   old: "Outbound coke: weigh at South Yard scale; record certified gross weight on waybill."
 *   new: "Outbound coke: weigh at scale; record certified gross wt."
 *
 * Also picks up the tighter special-instruction line spacing (CSS lives in
 * master_switchlist_helpers.php, so every phase is re-rendered from its cache).
 *
 * Steps:
 *   - Rewrite shipments.special_instructions in the live DB (future generation).
 *   - Rewrite the text in every cached section (JOB_session_N_master.json) and
 *     re-render ALL switch-list styles for that phase (so the reworded text and
 *     the new line spacing both land on already-generated switch lists).
 *   - Rewrite the text in every session's frozen waybill bodies and rebuild the
 *     waybill pages.
 *   - Drop stale print-all bundles so so.php rebuilds them on demand.
 *
 *   docker exec -u www-data <web> php /tmp/update_special_instructions.php
 */
error_reporting(E_ERROR | E_PARSE);

$sts = '/var/www/html/sts';
require_once $sts . '/open_db.php';
require_once $sts . '/session_helpers.php';
require_once $sts . '/master_switchlist_helpers.php';
require_once $sts . '/waybill_print_helpers.php';

$OLD = 'Outbound coke: weigh at scale; record certified gross wt.';
$NEW = 'Outgoing: weigh at scale; record gross wt.';

$dbc = open_db();
$root = session_web_root();
$config = session_merge_runtime_config([]);

// 1) Live DB — future switch-list / waybill generation uses the new wording.
$stmt = $dbc->prepare('UPDATE shipments SET special_instructions = ? WHERE special_instructions = ?');
$stmt->bind_param('ss', $NEW, $OLD);
$stmt->execute();
echo "DB shipments updated: {$dbc->affected_rows} row(s)\n";
$stmt->close();

// 2) Re-render every cached phase (text swap + new line spacing).
$rendered = 0;
$text_hits = 0;
foreach (glob($root . '/session_*', GLOB_ONLYDIR) ?: [] as $dir) {
    if (!preg_match('/session_(\d+)$/', $dir, $m)) {
        continue;
    }
    $S = (int) $m[1];

    foreach (glob($dir . '/phase_*', GLOB_ONLYDIR) ?: [] as $phase_dir) {
        foreach (glob($phase_dir . '/*_session_*_master.json') ?: [] as $cache) {
            if (!preg_match('#/([^/]+)_session_(\d+)_master\.json$#', $cache, $cm)) {
                continue;
            }
            $job = $cm[1];
            $sess = $cm[2];

            $raw = (string) file_get_contents($cache);
            if (strpos($raw, $OLD) !== false) {
                file_put_contents($cache, str_replace($OLD, $NEW, $raw));
                $text_hits++;
            }

            // Re-render all styles regardless (CSS line-spacing change applies to
            // any phase that shows special instructions).
            master_sw_generate_for_jobs($dbc, [$job], $phase_dir, $config, [
                'format' => 'all',
                'render_only' => true,
                'session_override' => (string) $sess,
            ]);
            $rendered++;
        }
    }

    // 3) Frozen waybill bodies + rebuild pages.
    $store = session_waybill_store_load($S, $root);
    if (is_array($store) && !empty($store['bodies'])) {
        $changed = false;
        foreach ($store['bodies'] as $num => $body) {
            if (strpos((string) $body, $OLD) !== false) {
                $store['bodies'][$num] = str_replace($OLD, $NEW, (string) $body);
                $changed = true;
            }
        }
        if ($changed) {
            session_waybill_store_save($S, $store, $root);
            $text_hits++;
        }
        // Always rebuild pages so waybill markup stays consistent.
        session_waybill_rebuild_pages($dbc, $S, $store, $root);
    }

    // 4) Drop stale print-all bundles; so.php rebuilds from re-rendered legs.
    foreach (array_merge(
        glob($dir . '/print_all*.html') ?: [],
        glob($dir . '/train_*.print_all*.html') ?: []
    ) as $bundle) {
        @unlink($bundle);
    }
}

echo "phases re-rendered: {$rendered}\n";
echo "files with text swapped: {$text_hits}\n";
echo "done\n";
