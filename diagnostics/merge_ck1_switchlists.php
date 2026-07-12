<?php
/**
 * One-time migration: collapse CK1's two switch-list phases (Inbound + Outbound)
 * in each existing session into a single phase titled just "CK1".
 *
 * For every session that still has more than one CK1 phase:
 *   - Merge the cached sections (cars) from all CK1 phases into one section,
 *     keeping the lowest CK1 phase number as the surviving phase.
 *   - Re-render every style for the merged phase from the combined cache.
 *   - Rewrite the manifest so CK1 has one phase, title "CK1", no info note.
 *   - Delete the now-orphaned CK1 phase directory.
 *   - Fold the frozen waybill store groups (CK1|<dropped>) into CK1|<kept>
 *     WITHOUT re-rendering any waybill body (historical snapshots preserved),
 *     then rebuild the waybill pages.
 *   - Drop stale print-all bundles so so.php rebuilds them on demand.
 *
 *   docker exec -u www-data <web> php /tmp/merge_ck1_switchlists.php
 */
error_reporting(E_ERROR | E_PARSE);

$sts = '/var/www/html/sts';
require_once $sts . '/open_db.php';
require_once $sts . '/session_helpers.php';
require_once $sts . '/master_switchlist_helpers.php';
require_once $sts . '/waybill_print_helpers.php';

$dbc = open_db();
$root = session_web_root();
$config = session_merge_runtime_config([]);
$JOB = 'CK1';

$merged_sessions = 0;

foreach (glob($root . '/session_*', GLOB_ONLYDIR) ?: [] as $dir) {
    if (!preg_match('/session_(\d+)$/', $dir, $m)) {
        continue;
    }
    $S = (int) $m[1];
    $man = session_load_manifest($S, $root);
    $phases = is_array($man['phases'] ?? null) ? $man['phases'] : [];

    // Index the CK1 phases (in manifest order).
    $ck1 = [];
    foreach ($phases as $i => $p) {
        if (in_array($JOB, (array) ($p['jobs'] ?? []), true)) {
            $ck1[] = ['i' => $i, 'phase' => (int) $p['phase']];
        }
    }
    if (count($ck1) < 1) {
        echo "session $S: no CK1 phase — skipped\n";
        continue;
    }

    // Lowest CK1 phase number survives; the rest are folded in and removed.
    usort($ck1, static function ($a, $b) {
        return $a['phase'] <=> $b['phase'];
    });
    $keep_pn = $ck1[0]['phase'];
    $keep_dir = session_phase_output_dir($S, $keep_pn, $root);
    $drop_pns = array_map(static function ($c) {
        return $c['phase'];
    }, array_slice($ck1, 1));

    // Merge cached cars from every CK1 phase into one deduped section.
    $merged_cars = [];
    $seen_marks = [];
    $label = '';
    foreach ($ck1 as $c) {
        $secs = master_sw_load_sections_cache(session_phase_output_dir($S, $c['phase'], $root), $JOB, $S);
        if (!is_array($secs)) {
            continue;
        }
        foreach ($secs as $sec) {
            if ($label === '') {
                $label = (string) ($sec['label'] ?? '');
            }
            foreach ($sec['cars'] ?? [] as $car) {
                $marks = (string) ($car['reporting_marks'] ?? '');
                if ($marks !== '' && isset($seen_marks[$marks])) {
                    continue;
                }
                $seen_marks[$marks] = true;
                $merged_cars[] = $car;
            }
        }
    }
    if ($label === '') {
        $label = '1 — Current assignment';
    }
    $merged_sections = [['label' => $label, 'cars' => $merged_cars]];

    // Persist merged cache titled just "CK1" and re-render every style from it.
    master_sw_save_sections_cache($keep_dir, $JOB, $S, $merged_sections, ['title' => $JOB, 'info' => '']);
    master_sw_generate_for_jobs($dbc, [$JOB], $keep_dir, $config, [
        'format' => 'all',
        'render_only' => true,
        'session_override' => (string) $S,
    ]);

    // Rewrite manifest: one CK1 phase (title CK1, no info), drop the extras.
    $new_phases = [];
    foreach ($phases as $i => $p) {
        $pn = (int) $p['phase'];
        if (in_array($pn, $drop_pns, true)) {
            continue;
        }
        if ($pn === $keep_pn) {
            $p['jobs'] = [$JOB];
            $p['title'] = $JOB;
            $p['info'] = '';
            // Drop the trailing " · <info>" (e.g. "· Inbound") from the label so
            // session_phase_info() no longer recovers a stale info note from it.
            if (isset($p['label'])) {
                $p['label'] = preg_replace('/\s*\x{00B7}.*$/u', '', (string) $p['label']);
            }
        }
        $new_phases[] = $p;
    }
    $man['phases'] = $new_phases;

    // Rebuild jobs map from surviving phases.
    $jobs = [];
    foreach ($new_phases as $p) {
        $pn = (int) $p['phase'];
        foreach ((array) ($p['jobs'] ?? []) as $j) {
            $j = trim((string) $j);
            if ($j === '') {
                continue;
            }
            if (!isset($jobs[$j])) {
                $jobs[$j] = ['phases' => []];
            }
            if (!in_array($pn, $jobs[$j]['phases'], true)) {
                $jobs[$j]['phases'][] = $pn;
            }
        }
    }
    $man['jobs'] = $jobs;

    // Delete orphaned CK1 phase directories.
    foreach ($drop_pns as $pn) {
        session_rrmdir(session_phase_output_dir($S, $pn, $root));
    }

    // Fold frozen waybill store groups CK1|<dropped> into CK1|<kept>; keep bodies.
    $store = session_waybill_store_load($S, $root);
    if (is_array($store) && !empty($store['groups'])) {
        $keep_key = $JOB . '|' . $keep_pn;
        $kept = $store['groups'][$keep_key] ?? [];
        foreach ($drop_pns as $pn) {
            $dk = $JOB . '|' . $pn;
            if (isset($store['groups'][$dk])) {
                foreach ($store['groups'][$dk] as $wb) {
                    if (!in_array($wb, $kept, true)) {
                        $kept[] = $wb;
                    }
                }
                unset($store['groups'][$dk]);
            }
        }
        // Preserve session order for the merged group.
        $store['groups'][$keep_key] = session_waybill_order_subset($store, $kept);
        session_waybill_store_save($S, $store, $root);
        session_waybill_rebuild_pages($dbc, $S, $store, $root);
    }

    // Drop stale print-all bundles so so.php rebuilds from the merged manifest.
    foreach (array_merge(
        glob($dir . '/print_all*.html') ?: [],
        glob($dir . '/train_*.print_all*.html') ?: []
    ) as $bundle) {
        @unlink($bundle);
    }

    session_save_manifest($S, $man, $root);
    $merged_sessions++;
    echo "session $S: merged CK1 -> phase $keep_pn ("
        . count($merged_cars) . " cars), removed phases [" . implode(',', $drop_pns) . "]\n";
}

echo "---\nsessions merged: $merged_sessions\n";
