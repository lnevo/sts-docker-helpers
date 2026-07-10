<?php
/**
 * Session browser — lists sessions through current DB session with phases and trains.
 */
$sts_dir = dirname(__DIR__) . '/sts';
if (!is_dir($sts_dir)) {
    $sts_dir = __DIR__ . '/../sts';
}
require_once $sts_dir . '/open_db.php';
require_once $sts_dir . '/session_helpers.php';

$dbc = open_db();
$current = (int) warm_start_get_session($dbc);
mysqli_close($dbc);

$root = session_web_root();
$on_disk = session_discover_sessions($root);
$max_session = max($current, $on_disk ? max($on_disk) : 0);
$sessions = range(1, max(1, $max_session));
$sessions = array_reverse($sessions);
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Operating Sessions</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; background: #f4f6f8; color: #1a1a1a; }
    .nav { background: #1f4d2e; padding: 12px 16px; }
    .nav a { color: #fff; text-decoration: none; margin-right: 12px; }
    main { max-width: 960px; margin: 0 auto; padding: 16px; }
    .card { background: #fff; border: 1px solid #d8dee4; border-radius: 10px; padding: 14px; margin-bottom: 12px; }
    h1 { margin: 0 0 8px; font-size: 22px; }
    .muted { color: #666; font-size: 14px; }
    ul { margin: 8px 0 0; padding-left: 18px; }
    a { color: #1f4d2e; }
    .badge { display: inline-block; background: #e8f4ea; color: #1f4d2e; border-radius: 999px; padding: 2px 8px; font-size: 12px; margin-left: 6px; }
  </style>
</head>
<body>
  <nav class="nav">
    <a href="editor.html">Workflow editor</a>
    <a href="simulator.php">Simulator</a>
    <a href="/sts/index.html">STS</a>
  </nav>
  <main>
    <h1>Operating sessions</h1>
    <p class="muted">Current DB session: <strong><?php echo (int) $current; ?></strong>. Each session may have multiple switch-list phases from the workflow generator.</p>
    <?php foreach ($sessions as $n): ?>
      <?php
        $manifest = session_load_manifest($n, $root);
        $dir = session_dir_for($n, $root);
        $has_data = is_dir($dir);
        $phases = $manifest['phases'] ?? [];
        $jobs = array_keys($manifest['jobs'] ?? []);
      ?>
      <div class="card">
        <h2 style="margin:0;font-size:18px;">
          <a href="session_<?php echo (int) $n; ?>/index.php">Session <?php echo (int) $n; ?></a>
          <?php if ($n === $current): ?><span class="badge">current</span><?php endif; ?>
          <?php if (!$has_data): ?><span class="badge">no output</span><?php endif; ?>
        </h2>
        <?php if (count($phases)): ?>
          <p class="muted"><?php echo count($phases); ?> phase(s) · <?php echo count($jobs); ?> train(s)</p>
          <ul>
            <?php foreach ($jobs as $job): ?>
              <li><a href="job.php?session=<?php echo (int) $n; ?>&amp;job=<?php echo htmlspecialchars($job); ?>"><?php echo htmlspecialchars($job); ?></a></li>
            <?php endforeach; ?>
          </ul>
        <?php else: ?>
          <p class="muted">No phases generated yet.</p>
        <?php endif; ?>
      </div>
    <?php endforeach; ?>
  </main>
</body>
</html>
