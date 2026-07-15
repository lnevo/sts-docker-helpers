<?php
/**
 * build_staging_board.php [session_N]  (default: current DB session)
 *
 * Emits an operator "staging board" HTML to stdout for the active fleet
 * (cars with status Ordered / Loaded / Empty). For each car it shows:
 *
 *   Placement   : IN-TRAIN (picked up, current_location_id = 0) vs IN-STATION
 *   Waybill     : live car_orders waybill + shipment code / commodity
 *   Session-N action : the car's session-open switch-list assignment (earliest
 *                      phase in the session-N master JSONs), if any
 *   Next step   : derived purely from stock STS DB status
 *                   Ordered + revenue wb -> go load at loading_location
 *                   Ordered + 'E' wb     -> reposition to destination
 *                   Ordered + no wb      -> hold (pool, awaiting order-gen)
 *                   Loaded  + wb         -> deliver to unloading_location
 *                   Loaded  + no wb      -> resident load, hold
 *                   Empty                -> reserve / reposition
 *   Conflict    : switch-list assignment vs live DB disagreement
 *
 * The HTML has All / In-Train / In-Station filter buttons for on-screen use;
 * printing (or PDF) shows every row with the Placement column.
 *
 * Run inside the web container:
 *   docker cp build_staging_board.php sts-docker-web-1:/tmp/
 *   docker exec sts-docker-web-1 php /tmp/build_staging_board.php 2 > board.html
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
$dbc = open_db();
$root = session_web_root();

$N = (int) ($argv[1] ?? 0);
if ($N < 1) {
    $N = (int) mysqli_fetch_row(mysqli_query($dbc, 'SELECT setting_value FROM settings WHERE setting_name="session_nbr"'))[0];
}

// --- Session-N switch-list membership (earliest phase per car) --------------
$sw = []; // marks -> [job, phase, status, waybill]
foreach (glob(session_dir_for($N, $root) . '/phase_*/*_master.json') ?: [] as $f) {
    if (!preg_match('#phase_(\d+)#', $f, $pm)) {
        continue;
    }
    $phase = (int) $pm[1];
    $d = json_decode((string) file_get_contents($f), true);
    if (!is_array($d) || empty($d['sections'])) {
        continue;
    }
    $job = trim((string) ($d['job'] ?? ''));
    foreach ($d['sections'] as $sec) {
        foreach (($sec['cars'] ?? []) as $c) {
            $marks = (string) ($c['reporting_marks'] ?? ($c[0] ?? ''));
            if ($marks === '') {
                continue;
            }
            if (!isset($sw[$marks]) || $phase < $sw[$marks]['phase']) {
                $sw[$marks] = [
                    'job' => $job,
                    'phase' => $phase,
                    'status' => (string) ($c['status'] ?? ''),
                    'waybill' => (string) ($c['waybill_number'] ?? ''),
                ];
            }
        }
    }
}

// --- Live fleet ------------------------------------------------------------
$sql = 'SELECT c.reporting_marks, c.status, c.current_location_id, c.handled_by_job_id,
        cc.code AS car_code, c.remarks AS car_type,
        loc.code AS cur_loc, sta.station AS cur_station,
        hom.code AS home_loc, hsta.station AS home_station,
        j.name AS job,
        co.waybill_number, co.shipment AS ship_ref,
        s.code AS ship_code, s.description AS ship_desc, s.special_instructions,
        com.code AS commodity,
        lld.code AS load_loc, sld.station AS load_station,
        lul.code AS unload_loc, sul.station AS unload_station,
        le.code AS e_dest_loc, se.station AS e_dest_station
    FROM cars c
    LEFT JOIN car_codes cc ON cc.id = c.car_code_id
    LEFT JOIN locations loc ON loc.id = c.current_location_id
    LEFT JOIN routing sta ON sta.id = loc.station
    LEFT JOIN locations hom ON hom.id = c.home_location
    LEFT JOIN routing hsta ON hsta.id = hom.station
    LEFT JOIN jobs j ON j.id = c.handled_by_job_id
    LEFT JOIN car_orders co ON co.car = c.id
    LEFT JOIN shipments s ON s.id = co.shipment AND (co.waybill_number IS NULL OR SUBSTR(co.waybill_number,5,1) != "E")
    LEFT JOIN commodities com ON com.id = s.consignment
    LEFT JOIN locations lld ON lld.id = s.loading_location
    LEFT JOIN routing sld ON sld.id = lld.station
    LEFT JOIN locations lul ON lul.id = s.unloading_location
    LEFT JOIN routing sul ON sul.id = lul.station
    LEFT JOIN locations le ON le.id = co.shipment AND co.waybill_number IS NOT NULL AND SUBSTR(co.waybill_number,5,1) = "E"
    LEFT JOIN routing se ON se.id = le.station
    WHERE c.status IN ("Ordered","Loaded","Empty")
    ORDER BY (c.current_location_id = 0) DESC, c.handled_by_job_id, sta.station, loc.code, c.reporting_marks';
$rs = mysqli_query($dbc, $sql);

$rows = [];
$counts = ['train' => 0, 'station' => 0];
$conflict_count = 0;
while ($r = mysqli_fetch_assoc($rs)) {
    $marks = (string) $r['reporting_marks'];
    $wb = (string) ($r['waybill_number'] ?? '');
    $is_e = $wb !== '' && strtoupper(substr($wb, 4, 1)) === 'E';
    $in_train = ((int) $r['current_location_id'] === 0);
    $placement = $in_train ? 'train' : 'station';
    $counts[$placement]++;

    $loc_label = $in_train
        ? ($r['job'] ? $r['job'] . ' consist' : 'on consist')
        : (($r['cur_station'] ?: '?') . ' / ' . ($r['cur_loc'] ?: '?'));

    // Waybill / shipment display.
    if ($wb === '') {
        $wb_disp = '—';
        $ship_disp = '';
    } elseif ($is_e) {
        $wb_disp = $wb . ' (empty repo)';
        $ship_disp = 'reposition';
    } else {
        $wb_disp = $wb;
        $ship_disp = trim(($r['ship_code'] ?? '') . ($r['commodity'] ? ' · ' . $r['commodity'] : ''));
    }

    // Route.
    if ($is_e) {
        $route = 'to ' . ($r['e_dest_station'] ?: '?') . ' / ' . ($r['e_dest_loc'] ?: '?');
    } elseif ($wb !== '') {
        $route = ($r['load_loc'] ?: '?') . ' → ' . ($r['unload_loc'] ?: '?');
    } else {
        $route = '—';
    }

    // Next step (stock STS DB status).
    $status = (string) $r['status'];
    if ($is_e) {
        $next = 'Reposition empty to ' . ($r['e_dest_station'] ?: '?') . ' / ' . ($r['e_dest_loc'] ?: '?');
    } elseif ($status === 'Ordered' && $wb !== '') {
        $next = $in_train
            ? ('On train → set out to load at ' . ($r['load_loc'] ?: '?') . ' (' . ($r['load_station'] ?: '?') . ')')
            : ('Pick up → load at ' . ($r['load_loc'] ?: '?') . ' (' . ($r['load_station'] ?: '?') . ')');
    } elseif ($status === 'Ordered' && $wb === '') {
        $next = 'Hold — pool car, awaiting order generation';
    } elseif ($status === 'Loaded' && $wb !== '') {
        $next = $in_train
            ? ('On train → deliver to ' . ($r['unload_loc'] ?: '?') . ' (' . ($r['unload_station'] ?: '?') . ')')
            : ('Pick up → deliver to ' . ($r['unload_loc'] ?: '?') . ' (' . ($r['unload_station'] ?: '?') . ')');
    } elseif ($status === 'Loaded' && $wb === '') {
        $next = 'Hold — pre-loaded resident, awaiting matching order';
    } elseif ($status === 'Empty') {
        $next = 'Reserve empty — available for fill/reposition';
    } else {
        $next = '—';
    }

    // Session-N action (switch-list) + conflict detection.
    $s2 = $sw[$marks] ?? null;
    if ($s2 === null) {
        $s2_disp = '—';
    } else {
        $s2_disp = $s2['job'] . ' (phase ' . $s2['phase'] . ')'
            . ($s2['waybill'] !== '' ? ' · ' . $s2['waybill'] : '');
    }

    $conflict = '';
    if ($s2 !== null) {
        if ($wb === '') {
            $conflict = 'On S' . $N . ' ' . $s2['job'] . ' list but no live order';
        } elseif ($s2['waybill'] !== '' && $s2['waybill'] !== $wb) {
            $conflict = 'S' . $N . ' list wb ' . $s2['waybill'] . ' ≠ live ' . $wb;
        }
    }
    // Loaded with no order is expected for residents; only flag if it also has a switch-list entry (handled above).
    if ($conflict !== '') {
        $conflict_count++;
    }

    $rows[] = [
        'marks' => $marks,
        'type' => trim(($r['car_code'] ?? '') . ' ' . ($r['car_type'] ?? '')),
        'status' => $status,
        'placement' => $placement,
        'loc' => $loc_label,
        'home' => ($r['home_station'] ?: '') ,
        'wb' => $wb_disp,
        'ship' => $ship_disp,
        'route' => $route,
        's2' => $s2_disp,
        'next' => $next,
        'conflict' => $conflict,
    ];
}

$generated = date('D M j, Y g:i A');
$total = count($rows);

// --- Render ----------------------------------------------------------------
$h = fn($s) => htmlspecialchars((string) $s, ENT_QUOTES);
ob_start();
?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>HART Session <?= $N ?> — Operating Board</title>
<style>
  body { font-family: Georgia, "Times New Roman", serif; font-size: 10.5pt; margin: 0.5in; color: #111; }
  h1 { font-size: 16pt; margin: 0 0 4px; }
  .meta { font-size: 9.5pt; color: #444; margin-bottom: 10px; }
  .controls { margin: 10px 0; }
  .controls button { font: inherit; font-size: 10pt; padding: 5px 12px; margin-right: 6px; cursor: pointer;
    border: 1px solid #666; background: #eee; border-radius: 4px; }
  .controls button.active { background: #2a5; color: #fff; border-color: #183; }
  .note { font-size: 9pt; background: #f5f5f0; border: 1px solid #ccc; padding: 8px; margin-bottom: 12px; }
  table { width: 100%; border-collapse: collapse; font-size: 8.8pt; }
  th, td { border: 1px solid #999; padding: 3px 5px; vertical-align: top; text-align: left; }
  th { background: #e8e8e0; }
  tr.train { background: #eef6ff; }
  tr.station { background: #fff; }
  .badge { font-size: 7.5pt; font-weight: bold; padding: 1px 5px; border-radius: 3px; color: #fff; }
  .b-train { background: #1a6; }
  .b-station { background: #789; }
  .st-Ordered { color: #b60; font-weight: bold; }
  .st-Loaded { color: #063; font-weight: bold; }
  .st-Empty { color: #667; font-weight: bold; }
  .conflict { color: #a00; font-weight: bold; }
  .hidden { display: none; }
  @media print {
    .controls { display: none; }
    tr { break-inside: avoid; }
    body { margin: 0.4in; }
  }
</style>
</head>
<body>

<h1>HART Railroad — Session <?= $N ?> Operating Board</h1>
<p class="meta">Active fleet: <?= $total ?> cars · In-train (picked up): <?= $counts['train'] ?> · In-station: <?= $counts['station'] ?> · Conflicts: <?= $conflict_count ?> · Generated <?= $h($generated) ?></p>

<div class="note">
  <strong>Placement:</strong> <span class="badge b-train">IN-TRAIN</span> = picked up / on a consist (no station).
  <span class="badge b-station">IN-STATION</span> = sitting at a yard or industry spot.<br>
  <strong>Session <?= $N ?> action</strong> = the car's switch-list assignment (job + phase) at session open.
  <strong>Next step</strong> is derived from stock STS database status (waybill + shipment), not the switch list.
  A <span class="conflict">conflict</span> means the switch-list assignment disagrees with the live database.
</div>

<div class="controls">
  <button data-filter="all" class="active" onclick="flt('all',this)">All (<?= $total ?>)</button>
  <button data-filter="train" onclick="flt('train',this)">In-Train (<?= $counts['train'] ?>)</button>
  <button data-filter="station" onclick="flt('station',this)">In-Station (<?= $counts['station'] ?>)</button>
</div>

<table id="board">
<thead>
<tr>
  <th>Car</th><th>Type</th><th>Status</th><th>Placement</th>
  <th>Waybill</th><th>Shipment</th><th>Route (load → deliver)</th>
  <th>Session <?= $N ?> action</th><th>Next step (from DB)</th><th>Conflict</th>
</tr>
</thead>
<tbody>
<?php foreach ($rows as $r): ?>
<tr class="<?= $r['placement'] ?>" data-placement="<?= $r['placement'] ?>">
  <td><strong><?= $h($r['marks']) ?></strong></td>
  <td><?= $h($r['type']) ?></td>
  <td><span class="st-<?= $h($r['status']) ?>"><?= $h($r['status']) ?></span></td>
  <td><span class="badge b-<?= $r['placement'] ?>"><?= $r['placement'] === 'train' ? 'IN-TRAIN' : 'STATION' ?></span> <?= $h($r['loc']) ?></td>
  <td><?= $h($r['wb']) ?></td>
  <td><?= $h($r['ship']) ?></td>
  <td><?= $h($r['route']) ?></td>
  <td><?= $h($r['s2']) ?></td>
  <td><?= $h($r['next']) ?></td>
  <td class="conflict"><?= $h($r['conflict']) ?></td>
</tr>
<?php endforeach; ?>
</tbody>
</table>

<script>
function flt(mode, btn) {
  document.querySelectorAll('.controls button').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('#board tbody tr').forEach(tr => {
    tr.classList.toggle('hidden', mode !== 'all' && tr.dataset.placement !== mode);
  });
}
</script>

</body>
</html>
<?php
echo ob_get_clean();
